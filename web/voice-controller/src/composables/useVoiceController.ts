import {computed, onBeforeUnmount, onMounted, readonly, shallowRef} from 'vue';
import {useI18n} from 'vue-i18n';
import {ElMessage, REFF_UI_VERSION} from '@reff/ui';
import {
  createEmbeddedTransport,
  createReffClient,
  installDevReload,
  installInputFocusReporter,
  ReffError,
  type ReffSubscription,
} from '@/reff-sdk';
import type {ControllerState} from '@/types';

const PLUGIN_ID = 'voice-controller';
const CHANGE_EVENT = 'voice-controller.changed';

// 浏览器线程管理 REFF 连接、订阅和轮询；本页面拥有监听器和定时器，销毁后异步连接不得恢复它们。
export function useVoiceController() {
  const {t} = useI18n();
  const client = createReffClient(createEmbeddedTransport());
  const state = shallowRef<ControllerState | null>(null);
  const connected = shallowRef(false);
  const loading = shallowRef(true);
  const busy = shallowRef(false);
  const error = shallowRef('');
  let pollTimer: number | undefined;
  let subscription: ReffSubscription | undefined;
  let stopDevReload: (() => void) | undefined;
  let stopInputReporter: (() => void) | undefined;
  let requestInFlight = false;
  let disposed = false;

  function formatError(reason: unknown) {
    if (!(reason instanceof ReffError)) return String(reason);
    const keys: Record<string, string> = {
      HOST_DISCONNECTED: 'errors.hostDisconnected',
      NOT_READY: 'errors.notReady',
      INVALID_ARGUMENT: 'errors.invalidArgument',
      INVALID_MESSAGE: 'errors.invalidMessage',
      TRANSPORT_ERROR: 'errors.transport',
    };
    return keys[reason.code] ? t(keys[reason.code]) : String(reason);
  }

  const groups = computed(() => (state.value?.config?.groups ?? []).map(group => ({
    ...group,
    rules: Array.isArray(group.rules) ? group.rules : [],
  })));
  const events = computed(() => state.value?.events ?? []);
  const savedEvents = computed(() => state.value?.savedEvents ?? []);
  const catalogEntries = computed(() => state.value?.catalog?.files ?? []);
  // 分组文件夹元数据与占用关系；规则体本身就在 config.groups 里。
  // REFramework 的 JSON 编码会把空 Lua 表写成 null，数组字段统一规范化，
  // 否则模板里的 .length 会直接抛错并让整块列表渲染失败。
  const groupFolders = computed(() => (state.value?.groupFolders ?? []).map(folder => ({
    ...folder,
    warnings: Array.isArray(folder.warnings) ? folder.warnings : [],
  })));
  const conflicts = computed(() => (state.value?.conflicts ?? []).map(conflict => ({
    ...conflict,
    losers: Array.isArray(conflict.losers) ? conflict.losers : [],
  })));
  const folderRejects = computed(() => state.value?.folderRejects ?? []);
  // 目录名含非 ASCII 的分组：能播放但无法回写 group.json，界面按分组提示。
  const unwritableFolders = computed(() => state.value?.unwritableFolders ?? []);
  const configuredKeys = computed(() => new Set(
    groups.value.flatMap(group => group.rules.map(rule => `${rule.eventId}:${rule.triggerId}`)),
  ));

  async function refresh(options: {silent?: boolean} = {}) {
    if (disposed || requestInFlight || busy.value) return;
    requestInFlight = true;
    try {
      const snapshot = await client.call<ControllerState>('voice-controller.get-state');
      if (disposed) return;
      state.value = snapshot;
      error.value = '';
    } catch (reason) {
      if (disposed) return;
      error.value = formatError(reason);
      if (!options.silent) ElMessage.error(error.value);
    } finally {
      requestInFlight = false;
      loading.value = false;
    }
  }

  async function mutate(method: string, params: Record<string, unknown> = {}) {
    if (disposed) return false;
    busy.value = true;
    try {
      const snapshot = await client.call<ControllerState>(method, params);
      if (disposed) return false;
      state.value = snapshot;
      error.value = '';
      return true;
    } catch (reason) {
      if (disposed) return false;
      error.value = formatError(reason);
      ElMessage.error(error.value);
      return false;
    } finally {
      busy.value = false;
    }
  }

  async function save() {
    const saved = await mutate('voice-controller.save');
    if (saved) ElMessage({message: t('saveBar.saved'), customClass: 'vc-theme-message'});
  }

  async function reloadConfig() {
    const reloaded = await mutate('voice-controller.reload-config');
    if (reloaded) ElMessage({message: t('saveBar.reloaded'), customClass: 'vc-theme-message'});
  }

  async function testCandidate(params: Record<string, unknown>) {
    const queued = await mutate('voice-controller.test-candidate', params);
    if (queued) ElMessage.success(t('saveBar.previewQueued'));
  }

  onMounted(async () => {
    stopDevReload = installDevReload(client);
    stopInputReporter = installInputFocusReporter(client);
    try {
      await client.ready();
      if (disposed) return;
      const identity = await client.call<{pluginId: string | null}>('ui.identity');
      if (disposed) return;
      if (identity.pluginId !== PLUGIN_ID) throw new Error(t('errors.identityMismatch'));
      subscription = await client.subscribe<ControllerState>(CHANGE_EVENT, value => {
        if (!disposed) state.value = value;
      });
      if (disposed) {
        void subscription.unsubscribe().catch(() => {});
        return;
      }
      connected.value = true;
      await refresh();
      if (disposed) return;
      pollTimer = window.setInterval(() => void refresh({silent: true}), 1000);
      window.parent.postMessage({
        type: 'reff:plugin-ready',
        pluginId: PLUGIN_ID,
        uiVersion: REFF_UI_VERSION,
        styled: true,
      }, '*');
    } catch (reason) {
      if (disposed) return;
      error.value = formatError(reason);
      loading.value = false;
      ElMessage.error(error.value);
    }
  });

  onBeforeUnmount(() => {
    disposed = true;
    connected.value = false;
    if (pollTimer !== undefined) window.clearInterval(pollTimer);
    // pagehide 时 SDK 可能已关闭原生通道；取消订阅仍会清理本地监听，关闭错误无需弹窗。
    void subscription?.unsubscribe().catch(() => {});
    stopInputReporter?.();
    stopDevReload?.();
    client.dispose();
  });

  return {
    state: readonly(state),
    connected: readonly(connected),
    loading: readonly(loading),
    busy: readonly(busy),
    error: readonly(error),
    groups,
    events,
    savedEvents,
    catalogEntries,
    configuredKeys,
    groupFolders,
    conflicts,
    folderRejects,
    unwritableFolders,
    refresh,
    save,
    reloadConfig,
    saveEvent: (params: Record<string, unknown>) => mutate('voice-controller.save-event', params),
    removeSavedEvent: (params: Record<string, unknown>) => mutate('voice-controller.remove-saved-event', params),
    updateSavedEventNote: (params: Record<string, unknown>) => mutate('voice-controller.update-saved-event-note', params),
    playEvent: (params: Record<string, unknown>) => mutate('voice-controller.play-event', params),
    setRecentLock: (params: Record<string, unknown>) => mutate('voice-controller.set-recent-lock', params),
    setRecentCapture: (params: Record<string, unknown>) => mutate('voice-controller.set-recent-capture', params),
    addGroup: (params: Record<string, unknown>) => mutate('voice-controller.add-group', params),
    updateGroup: (params: Record<string, unknown>) => mutate('voice-controller.update-group', params),
    updateBlockedSources: (params: Record<string, unknown>) => mutate('voice-controller.update-blocked-sources', params),
    removeGroup: (params: Record<string, unknown>) => mutate('voice-controller.remove-group', params),
    addRuleFromSaved: (params: Record<string, unknown>) => mutate('voice-controller.add-rule-from-saved', params),
    updateRule: (params: Record<string, unknown>) => mutate('voice-controller.update-rule', params),
    removeRule: (params: Record<string, unknown>) => mutate('voice-controller.remove-rule', params),
    addCandidate: (params: Record<string, unknown>) => mutate('voice-controller.add-candidate', params),
    updateCandidate: (params: Record<string, unknown>) => mutate('voice-controller.update-candidate', params),
    removeCandidate: (params: Record<string, unknown>) => mutate('voice-controller.remove-candidate', params),
    testCandidate,
  };
}
