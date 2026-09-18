import { ReffError, ReffClient, ReffSubscription, ReffTransport, InputFocusReporter, DevReloadController } from './types';
export * from './types';

// 生产环境使用 CEF cefQuery；每个请求只等待一次结果，关闭或重置后不自动重放写请求。
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
      // 事件由 Shell 的受控分发器转交；插件不会直接监听 CEF/IPC 通道。
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

// 创建 CEF 页面默认传输；不存在 cefQuery 时由调用者注入 mock transport。
export function createCefTransport(): ReffTransport {
  return { call(method, params = {}) { return new Promise((resolve, reject) => {
    const query = (window as Window & { cefQuery?: Function }).cefQuery;
    if (!query) { reject(new ReffError('HOST_DISCONNECTED', 'CEF 桥接不可用')); return; }
    query({ request: JSON.stringify({ method, params }), onSuccess: (raw: string) => { try { resolve(JSON.parse(raw)); } catch { reject(new ReffError('INVALID_MESSAGE', '响应不是 JSON')); } }, onFailure: (code: number, reason: string) => reject(new ReffError(String(code), reason)) });
  }); } };
}

// 隔离页面传输：只通过父级 REFF Shell 转发请求，不直接暴露 CEF 查询接口。
export function createEmbeddedTransport(): ReffTransport {
  let sequence = 0;
  let closed = false;
  const pending = new Map<string, { resolve: (value: unknown) => void; reject: (reason: unknown) => void }>();
  const listener = (event: MessageEvent) => {
    if (closed) return;
    if (event.source !== window.parent) return;
    if (event.data?.type === 'reff:event' && typeof event.data.subscriptionId === 'string') {
      window.dispatchEvent(new CustomEvent(`reff:${event.data.subscriptionId}`, { detail: event.data.payload }));
      return;
    }
    if (event.data?.type !== 'reff:response') return;
    const item = pending.get(event.data.id); if (!item) return; pending.delete(event.data.id);
    event.data.ok ? item.resolve(event.data.result) : item.reject(new ReffError(event.data.code || 'TRANSPORT_ERROR', event.data.message || '隔离页面请求失败'));
  };
  window.addEventListener('message', listener);
  return {
    call(method, params = {}) {
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
    const selectionStart = element.selectionStart ?? element.value.length;
    const selectionEnd = element.selectionEnd ?? selectionStart;
    void client.call('ui.input.focus', {
      active,
      inputId: element.id || 'reff-input',
      text: element.value,
      selectionStart,
      selectionEnd,
      x: Math.round(rect.left),
      y: Math.round(rect.top),
      width: Math.max(1, Math.round(rect.width)),
      height: Math.max(1, Math.round(rect.height)),
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
    // 部分 CEF 版本在 iframe 内不会把 focusin 冒泡到 window；从组合事件路径识别真实输入控件并立即激活。
    const element = event.composedPath().find(isTextControl);
    if (element && isTextControl(element)) activate(element);
    else if (focused) deactivate();
  };
  const onEmbeddedIme = (event: MessageEvent) => {
    if (event.source !== window.parent || event.data?.type !== 'reff:ime' || !focused || event.data.action !== 'commit') return;
    const text = typeof event.data.text === 'string' ? event.data.text : '';
    const start = focused.selectionStart ?? focused.value.length;
    const end = focused.selectionEnd ?? start;
    const available = focused.maxLength >= 0 ? Math.max(0, focused.maxLength - (focused.value.length - (end - start))) : text.length;
    focused.setRangeText(text.slice(0, available), start, end, 'end');
    // Vue/React/原生页面都通过标准 input 事件观察提交结果；不模拟键盘事件，避免重复输入。
    focused.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertCompositionText', data: text, isComposing: false }));
    report(focused, true);
  };
  window.addEventListener('focusin', onFocusIn);
  window.addEventListener('focusout', onFocusOut);
  document.addEventListener('focus', onFocusIn, true);
  window.addEventListener('pointerdown', onPointerDown, true);
  window.addEventListener('resize', updateBounds);
  window.addEventListener('scroll', updateBounds, true);
  window.addEventListener('message', onEmbeddedIme);
  // 不监听 window.blur：隔离 iframe 在原生 EDIT 代理接管焦点时也会收到 blur，不能据此关闭 IME。
  return () => {
    if (disposed) return;
    deactivate();
    disposed = true;
    window.removeEventListener('focusin', onFocusIn);
    window.removeEventListener('focusout', onFocusOut);
    document.removeEventListener('focus', onFocusIn, true);
    window.removeEventListener('pointerdown', onPointerDown, true);
    window.removeEventListener('resize', updateBounds);
    window.removeEventListener('scroll', updateBounds, true);
    window.removeEventListener('message', onEmbeddedIme);
  };
}
