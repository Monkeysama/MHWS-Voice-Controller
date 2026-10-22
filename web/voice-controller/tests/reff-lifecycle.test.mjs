import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import vm from 'node:vm';
import * as vue from 'vue';
import ts from 'typescript';

// 在独立浏览器替身中运行实际 SDK 和 composable；只替换宿主/DOM，不触碰游戏或原生 DLL。
function compile(path, context, imports = {}) {
  const source = readFileSync(new URL(path, import.meta.url), 'utf8');
  const code = ts.transpileModule(source, {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS},
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, {...context, exports, require: name => {
    assert.ok(name in imports, `unexpected import: ${name}`);
    return imports[name];
  }});
  return exports;
}

// 记录监听、计时器和原生调用，供页面销毁后的资源断言使用；对象由各测试独占。
class TrackedTarget extends EventTarget {
  listeners = new Map();
  addEventListener(type, callback, options) {
    super.addEventListener(type, callback, options);
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(callback);
  }
  removeEventListener(type, callback, options) {
    super.removeEventListener(type, callback, options);
    this.listeners.get(type)?.delete(callback);
  }
  count(type) { return this.listeners.get(type)?.size ?? 0; }
}

function event(type, properties) {
  return Object.assign(new Event(type), properties);
}

function harness(nativeCall = async () => ({})) {
  const calls = [], messages = [], timers = new Set();
  const window = new TrackedTarget();
  const document = new TrackedTarget();
  window.parent = {postMessage: value => messages.push(value)};
  window.reffNativeCall = async (method, params) => {
    calls.push({method, params});
    return nativeCall(method, params);
  };
  window.setInterval = callback => { timers.add(callback); return callback; };
  window.clearInterval = callback => timers.delete(callback);
  window.setTimeout = setTimeout;
  window.innerWidth = 1000;
  window.innerHeight = 700;
  class Input {
    type = 'text'; id = 'note'; value = '中文备注'; selectionStart = 2; selectionEnd = 2;
    offsetWidth = 100; offsetHeight = 32;
    getBoundingClientRect() { return {left: 10, top: 20, width: 100, height: 32}; }
  }
  const context = {window, document, crypto, setTimeout, HTMLInputElement: Input,
    HTMLTextAreaElement: class {}, getComputedStyle: () => ({fontSize: '14px', lineHeight: '20px'})};
  const types = compile('../src/reff-sdk/types.ts', context);
  const sdk = compile('../src/reff-sdk/index.ts', context, {'./types': types});
  return {window, document, calls, messages, timers, Input, context, sdk};
}

test('隔离页业务直达原生文档；仅输入坐标转发给 Shell，并校验响应来源', async () => {
  const h = harness(async () => ({ok: true}));
  const transport = h.sdk.createEmbeddedTransport();
  assert.equal((await transport.call('voice-controller.save', {value: '中文'})).ok, true);
  assert.equal(h.calls[0].method, 'voice-controller.save');
  assert.equal(h.messages.length, 0);
  const focus = transport.call('ui.input.focus', {active: true});
  const request = h.messages[0];
  assert.equal(request.method, 'ui.input.focus');
  let settled = false;
  void focus.then(() => { settled = true; });
  h.window.dispatchEvent(event('message', {source: {}, data: {
    type: 'reff:response', id: request.id, ok: true, result: 'spoof',
  }}));
  await Promise.resolve();
  assert.equal(settled, false);
  h.window.dispatchEvent(event('message', {source: h.window.parent, data: {
    type: 'reff:response', id: request.id, ok: true, result: 'accepted',
  }}));
  assert.equal(await focus, 'accepted');
  assert.equal(h.calls.length, 1);
  const pending = transport.call('ui.input.focus');
  const rejected = assert.rejects(pending, error => error.code === 'HOST_DISCONNECTED');
  transport.dispose();
  await rejected;
  assert.equal(h.window.count('message'), 0);
  await assert.rejects(transport.call('voice-controller.save'), error => error.code === 'HOST_DISCONNECTED');
});

test('原生文档订阅只接收目标事件，pagehide 后释放监听并阻止写请求', async () => {
  const h = harness();
  const client = h.sdk.createReffClient(h.sdk.createEmbeddedTransport());
  const values = [];
  await client.subscribe('voice-controller.changed', payload => values.push(payload));
  const id = h.calls[0].params.subscriptionId;
  h.window.dispatchEvent(event(`reff:${id}`, {detail: 'new snapshot'}));
  assert.deepEqual(values, ['new snapshot']);
  h.window.dispatchEvent(new Event('pagehide'));
  h.window.dispatchEvent(event(`reff:${id}`, {detail: 'old document'}));
  assert.deepEqual(values, ['new snapshot']);
  assert.equal(h.window.count(`reff:${id}`), 0);
  assert.equal(h.window.count('message'), 0);
  await assert.rejects(client.call('voice-controller.save'), error => error.code === 'HOST_DISCONNECTED');
  assert.equal(h.calls.length, 1, '销毁不能重放写请求');
});

test('输入报告器清理会撤销中文输入焦点，重复清理不再发送请求', async () => {
  const h = harness();
  const calls = [];
  const stop = h.sdk.installInputFocusReporter({call: async (...args) => calls.push(args)});
  const focus = new Event('focusin');
  Object.defineProperty(focus, 'target', {value: new h.Input()});
  h.window.dispatchEvent(focus);
  assert.equal(calls[0][1].active, true);
  assert.equal(calls[0][1].text, '中文备注');
  stop(); stop();
  assert.equal(calls.length, 2);
  assert.equal(calls[1][1].active, false);
  for (const type of ['focusin', 'focusout', 'pointerdown', 'resize', 'scroll', 'reff:input-suspend']) {
    assert.equal(h.window.count(type), 0, type);
  }
  assert.equal(h.document.count('focus'), 0);
});

const responses = {
  'ui.status': {ready: true}, 'ui.identity': {pluginId: 'voice-controller'},
  'ui.subscribe': {}, 'voice-controller.get-state': {events: []},
};

// 用真实 Vue 状态、真实 SDK 加生命周期钩子替身，控制每个连接阶段的异步完成顺序。
function controllerHarness(nativeCall) {
  const h = harness(nativeCall);
  const mounted = [], unmount = [], notifications = [];
  const message = value => notifications.push(value);
  message.error = message.success = message;
  const {useVoiceController} = compile('../src/composables/useVoiceController.ts', h.context, {
    vue: {...vue, onMounted: callback => mounted.push(callback), onBeforeUnmount: callback => unmount.push(callback)},
    'vue-i18n': {useI18n: () => ({t: key => key})},
    '@reff/ui': {ElMessage: message, REFF_UI_VERSION: 'test'}, '@/reff-sdk': h.sdk,
  });
  return {...h, state: useVoiceController(), mount: () => mounted[0](),
    unmount: () => unmount[0](), notifications};
}

for (const stage of Object.keys(responses)) {
  test(`连接在 ${stage} 等待时销毁页面，不得复活订阅、定时器或通知`, async () => {
    let resolve;
    const h = controllerHarness(method => method === stage
      ? new Promise(done => { resolve = done; }) : Promise.resolve(responses[method]));
    const mounting = h.mount();
    await new Promise(setImmediate);
    assert.ok(resolve, '已到达指定异步阶段');
    h.unmount();
    resolve(responses[stage]);
    await mounting;
    assert.equal(h.state.connected.value, false);
    assert.equal(h.state.state.value, null);
    assert.equal(h.timers.size, 0);
    assert.equal(h.messages.filter(value => value.type === 'reff:plugin-ready').length, 0);
    assert.deepEqual(h.notifications, []);
    for (const [type, handlers] of h.window.listeners) {
      if (type !== 'pagehide') assert.equal(handlers.size, 0, type);
    }
    assert.equal(h.document.count('focus'), 0);
  });
}

test('连接成功后事件可更新快照；销毁后的在途写操作不能更新页面或弹错', async () => {
  let finishSave;
  const h = controllerHarness(method => method === 'voice-controller.save'
    ? new Promise(resolve => { finishSave = resolve; }) : Promise.resolve(responses[method]));
  await h.mount();
  assert.equal(h.state.connected.value, true);
  assert.equal(h.timers.size, 1);
  const id = h.calls.find(value => value.method === 'ui.subscribe').params.subscriptionId;
  h.window.dispatchEvent(event(`reff:${id}`, {detail: {events: ['new']}}));
  assert.equal(h.state.events.value[0], 'new');
  const saving = h.state.save();
  h.unmount();
  finishSave({events: ['late']});
  await saving;
  assert.equal(h.state.events.value[0], 'new');
  assert.equal(h.timers.size, 0);
  assert.equal(h.window.count(`reff:${id}`), 0);
  assert.deepEqual(h.notifications, []);
});
