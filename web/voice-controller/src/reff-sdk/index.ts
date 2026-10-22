import { ReffError, ReffClient, ReffSubscription, ReffTransport, InputFocusReporter, DevReloadController } from './types';
export * from './types';

// 通过宿主绑定的文档通道通信；每个请求只等待一次结果，关闭或重置后不自动重放写请求。
export function createReffClient(transport: ReffTransport): ReffClient {
  let closed = false;
  const subscriptions = new Set<string>();
  const listeners = new Map<string, EventListener>();
  const call = async <T>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
    if (closed) throw new ReffError('HOST_DISCONNECTED', 'REFF 宿主已断开');
    try { return await transport.call(method, params) as T; }
    catch (error) { if (error instanceof ReffError) throw error; throw new ReffError('TRANSPORT_ERROR', String(error)); }
  };
  // 页面销毁时移除 DOM 监听并阻止后续请求；取消订阅请求不在 unload 阶段强行等待。
  const dispose = () => {
    if (closed) return;
    closed = true;
    for (const subscriptionId of subscriptions) {
      const handler = listeners.get(subscriptionId);
      if (handler) window.removeEventListener(`reff:${subscriptionId}`, handler);
    }
    subscriptions.clear(); listeners.clear(); transport.dispose?.();
  };
  const client: ReffClient = {
    async ready() {
      for (let attempt = 0; attempt < 60; attempt += 1) {
        const status = await call<{ ready: boolean }>('ui.status');
        if (status.ready) return;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      throw new ReffError('NOT_READY', '脚本尚未就绪');
    },
    call,
    async subscribe<T>(eventName: string, listener: (payload: T) => void): Promise<ReffSubscription> {
      if (!/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(eventName)) throw new ReffError('INVALID_ARGUMENT', '事件名不合法');
      const randomId = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
      const subscriptionId = `${eventName}:${randomId}`;
      await call('ui.subscribe', { eventName, subscriptionId });
      subscriptions.add(subscriptionId);
      // 事件由原生宿主按文档身份分发；插件不会直接访问 IPC 通道。
      const handler = (event: Event) => listener((event as CustomEvent<T>).detail);
      window.addEventListener(`reff:${subscriptionId}`, handler);
      listeners.set(subscriptionId, handler);
      return { async unsubscribe() { if (!subscriptions.delete(subscriptionId)) return; listeners.delete(subscriptionId); window.removeEventListener(`reff:${subscriptionId}`, handler); await call('ui.unsubscribe', { subscriptionId }); } };
    },
    dispose,
  };
  window.addEventListener('pagehide', dispose, { once: true });
  return client;
}

/** 开发期轮询版本标记，构建成功后仅刷新当前插件页面。 */
export function installDevReload(client: ReffClient, intervalMs = 700): DevReloadController {
  // WebView2 隔离页由 Shell 统一监视，避免两端同时重载造成文档失效与重复订阅。
  if (window.parent !== window && hasWebView2Transport()) return () => {};
  let stopped = false;
  let lastVersion = '';
  let timer: number | undefined;
  const poll = async () => {
    if (stopped) return;
    try {
      const result = await client.call<{ version: string }>('ui.dev.version');
      if (lastVersion && result.version !== lastVersion) { await client.call('ui.reload'); return; }
      lastVersion = result.version;
    } catch { /* 页面切换或正式运行时接口不可用，下一轮继续。 */ }
    if (!stopped) timer = window.setTimeout(poll, intervalMs);
  };
  void poll();
  return () => { stopped = true; if (timer !== undefined) window.clearTimeout(timer); };
}

// WebView2 由原生 DocumentCreated 注入；此能力只说明当前后端，权限仍由实际 frame/文档绑定校验。
export function hasWebView2Transport(): boolean {
  return typeof (window as Window & { reffNativeCall?: unknown }).reffNativeCall === 'function';
}

// 每个文档通过宿主注入的原生通道通信；权限由真实 frame、会话和文档代次校验。
export function createHostTransport(): ReffTransport {
  return { async call(method, params = {}) {
    const nativeCall = (window as Window & { reffNativeCall?: (method: string, params: Record<string, unknown>) => Promise<unknown> }).reffNativeCall;
    if (!nativeCall) throw new ReffError('HOST_DISCONNECTED', 'WebView2 桥接不可用');
    try { return await nativeCall(method, params); }
    catch (error) {
      const value = error as { code?: string; message?: string };
      throw new ReffError(value?.code || 'TRANSPORT_ERROR', value?.message || 'WebView2 桥接不可用');
    }
  } };
}

// 隔离页业务直达原生 frame；只有输入法坐标由 Shell 换算到顶层视口。
export function createEmbeddedTransport(): ReffTransport {
  const native = createHostTransport();
  let sequence = 0;
  let closed = false;
  const pending = new Map<string, { resolve: (value: unknown) => void; reject: (reason: unknown) => void }>();
  const listener = (event: MessageEvent) => {
    if (closed) return;
    if (event.source !== window.parent) return;
    if (event.data?.type !== 'reff:response') return;
    const item = pending.get(event.data.id); if (!item) return; pending.delete(event.data.id);
    event.data.ok ? item.resolve(event.data.result) : item.reject(new ReffError(event.data.code || 'TRANSPORT_ERROR', event.data.message || '隔离页面请求失败'));
  };
  window.addEventListener('message', listener);
  return {
    call(method, params = {}) {
      // iframe 的业务调用直接绑定原生文档；只有焦点坐标需要由 Shell 换算到顶层视口。
      if (method !== 'ui.input.focus') {
        if (closed) return Promise.reject(new ReffError('HOST_DISCONNECTED', '隔离页面已销毁'));
        return native.call(method, params);
      }
      return new Promise((resolve, reject) => {
        if (closed) { reject(new ReffError('HOST_DISCONNECTED', '隔离页面已销毁')); return; }
        const id = `embedded:${++sequence}`;
        pending.set(id, { resolve, reject });
        window.parent.postMessage({ type: 'reff:request', id, method, params }, '*');
      });
    },
    // 页面卸载时一次性失败所有等待中的 Promise，避免旧 iframe 持有悬挂请求和消息监听。
    dispose() {
      if (closed) return;
      closed = true;
      window.removeEventListener('message', listener);
      const error = new ReffError('HOST_DISCONNECTED', '隔离页面已销毁');
      for (const item of pending.values()) item.reject(error);
      pending.clear();
    },
  };
}

// 将 Shell 或隔离插件页面的文本焦点和视口坐标交给宿主；坐标始终是当前网页视口逻辑像素。
// 该监听器只拥有 DOM 事件，不持有输入框或原生窗口；清理函数必须在页面销毁前调用。
export function installInputFocusReporter(client: ReffClient): InputFocusReporter {
  let focused: HTMLInputElement | HTMLTextAreaElement | null = null;
  let disposed = false;
  const textTypes = new Set(['text', 'search', 'url', 'email', 'tel', 'password']);
  const isTextControl = (value: EventTarget | null): value is HTMLInputElement | HTMLTextAreaElement => {
    if (value instanceof HTMLTextAreaElement) return true;
    return value instanceof HTMLInputElement && textTypes.has(value.type);
  };
  const report = (element: HTMLInputElement | HTMLTextAreaElement, active: boolean) => {
    if (disposed) return;
    const rect = element.getBoundingClientRect();
    // 标准 EDIT 的插入点以文字区域为原点；扣除 CSS 边框/内边距，并匹配单行文本的垂直居中。
    const style = getComputedStyle(element);
    const px = (value: string) => Number.parseFloat(value) || 0;
    const scaleX = rect.width / Math.max(1, element.offsetWidth);
    const scaleY = rect.height / Math.max(1, element.offsetHeight);
    const fontSize = Math.max(1, px(style.fontSize) * scaleY);
    const leftInset = (px(style.borderLeftWidth) + px(style.paddingLeft)) * scaleX;
    const rightInset = (px(style.borderRightWidth) + px(style.paddingRight)) * scaleX;
    const topInset = (px(style.borderTopWidth) + px(style.paddingTop)) * scaleY;
    const bottomInset = (px(style.borderBottomWidth) + px(style.paddingBottom)) * scaleY;
    const contentHeight = Math.max(1, rect.height - topInset - bottomInset);
    const lineHeight = Math.max(fontSize, px(style.lineHeight) * scaleY || fontSize * 1.2);
    const selectionStart = element.selectionStart ?? element.value.length;
    const selectionEnd = element.selectionEnd ?? selectionStart;
    void client.call('ui.input.focus', {
      active,
      inputId: element.id || 'reff-input',
      text: element.value,
      selectionStart,
      selectionEnd,
      x: Math.round(rect.left + leftInset),
      y: Math.round(rect.top + topInset + (element instanceof HTMLInputElement ? Math.max(0, (contentHeight - lineHeight) / 2) : 0)),
      width: Math.max(1, Math.round(rect.width - leftInset - rightInset)),
      height: Math.max(1, Math.round(element instanceof HTMLInputElement ? lineHeight : contentHeight)),
      fontSize: Math.round(fontSize),
      viewportWidth: Math.max(1, Math.round(window.innerWidth)),
      viewportHeight: Math.max(1, Math.round(window.innerHeight)),
    }).catch(() => { /* 页面切换或宿主关闭时，焦点撤销无需向用户显示错误。 */ });
  };
  const deactivate = () => {
    if (!focused) return;
    report(focused, false);
    focused = null;
  };
  const activate = (element: HTMLInputElement | HTMLTextAreaElement) => {
    // 一次点击会依次触发 pointerdown、捕获 focus 和冒泡 focusin；同一控件只建立一次会话，避免原生代理反复抢焦点。
    if (focused === element) return;
    if (focused && focused !== element) report(focused, false);
    focused = element;
    report(element, true);
  };
  const onFocusIn = (event: FocusEvent) => {
    const element = isTextControl(event.target) ? event.target : null;
    if (!element) return;
    activate(element);
  };
  const onFocusOut = (event: FocusEvent) => {
    const element = isTextControl(event.target) ? event.target : null;
    if (!element) return;
    // 原生透明 EDIT 接管键盘焦点时，iframe 常收到 relatedTarget=null 的伪 focusout；
    // 保留逻辑焦点，避免 IME 代理在激活后立即被关闭。真实切换到按钮等控件会带有目标，直接撤销。
    if (event.relatedTarget && !isTextControl(event.relatedTarget)) deactivate();
  };
  const updateBounds = () => { if (focused) report(focused, true); };
  const onPointerDown = (event: PointerEvent) => {
    // iframe 内的焦点事件可能未冒泡到 window；从组合事件路径识别真实输入控件并立即激活。
    const element = event.composedPath().find(isTextControl);
    if (element && isTextControl(element)) {
      if (focused === element) window.setTimeout(() => { if (focused === element) report(element, true); }, 0);
      else activate(element);
    }
    else if (focused) deactivate();
  };
  window.addEventListener('focusin', onFocusIn);
  window.addEventListener('reff:input-suspend', deactivate);
  window.addEventListener('focusout', onFocusOut);
  document.addEventListener('focus', onFocusIn, true);
  window.addEventListener('pointerdown', onPointerDown, true);
  window.addEventListener('resize', updateBounds);
  window.addEventListener('scroll', updateBounds, true);
  // 不监听 window.blur：隔离 iframe 在原生 EDIT 代理接管焦点时也会收到 blur，不能据此关闭 IME。
  return () => {
    if (disposed) return;
    deactivate();
    disposed = true;
    window.removeEventListener('focusin', onFocusIn);
    window.removeEventListener('reff:input-suspend', deactivate);
    window.removeEventListener('focusout', onFocusOut);
    document.removeEventListener('focus', onFocusIn, true);
    window.removeEventListener('pointerdown', onPointerDown, true);
    window.removeEventListener('resize', updateBounds);
    window.removeEventListener('scroll', updateBounds, true);
  };
}
