import {createI18n} from 'vue-i18n';
import type {ReffPreferences} from '@reff/ui';

export type SupportedLocale = 'zh-CN' | 'en-US';

const messages = {
  'zh-CN': {
    tabs: {recent: '近期事件', saved: '保存列表', groups: '分组配置', blocked: '屏蔽列表'},
    common: {
      add: '添加', remove: '删除', unknown: '未知', unknownSource: '未知来源', unknownTime: '未知时间',
      entries: '{count} 条', groups: '{count} 组', seconds: '{value} 秒', durationPending: '时长待获取',
      durationUnknown: '时长未知', player: '玩家', npc: 'NPC', companion: '随从', weapon: '武器',
      uncategorized: '未分类', allCategories: '全部类别', enabled: '启用', disabled: '已禁用',
      mode: '模式', overlay: '叠加', replace: '替换', observe: '观察', rule: '规则',
    },
    status: {
      title: '运行状态', captured: '捕获事件', saved: '保存列表', groups: '分组', blocked: '屏蔽',
      loading: '正在读取 VoiceController 状态',
    },
    recent: {
      eyebrow: '自然游戏流程', title: '近期音频事件', search: '事件键、来源或资源路径',
      lock: '锁定当前分类和搜索条件', unlock: '解除锁定并重新记录全部匹配事件',
      lockAria: '锁定近期事件条件', unlockAria: '解除近期事件锁定', categoryAria: '事件类别',
      triggered: '触发 {count} 次', latest: '最近 #{sequence}', play: '播放游戏内音频',
      unavailable: '当前会话无法解析此音频', saved: '已收藏', save: '收藏', empty: '没有匹配的事件',
    },
    saved: {
      eyebrow: '永久记录', title: '保存列表', search: '搜索收藏的游戏内音频', categoryAria: '保存列表音频分类',
      noteInput: '输入备注名', noteSave: '保存备注名', noteCancel: '取消编辑备注名', noNote: '未设置备注名',
      noteEdit: '编辑备注名', savedAt: '收藏于 {time}', play: '播放游戏内音频',
      resolveAndPlay: '播放时尝试从当前场景解析音频', remove: '删除收藏',
      removeHint: '删除收藏；不会影响已保存的分组规则', empty: '尚未收藏游戏内音频',
    },
    playback: {trying: '尝试播放中', success: '播放成功', failed: '播放失败', failedDetail: '播放失败：{error}'},
    blocked: {
      eyebrow: '捕获过滤', title: '屏蔽列表', description: '匹配 SourceObject 前缀的事件不会进入近期事件、分类统计、重放或规则匹配。',
      placeholder: '输入 SourceObject 前缀', add: '添加', remove: '删除屏蔽项', empty: '尚未配置屏蔽项',
    },
    groups: {
      eyebrow: '自定义配置', title: '分组与替换规则', newName: '新分组名称', add: '新增分组',
      conflicts: '冲突明细', active: '生效中', noActive: '无生效规则', allDisabled: '该音频的所有规则当前都被禁用', occupied: '被占用',
      collapseGroup: '折叠分组规则', expandGroup: '展开分组规则', collapseRules: '折叠规则', expandRules: '展开规则',
      manualDelete: '删除分组需手动删除分组文件夹', groupPath: '分组位置：', audioPath: '外部音频位置：',
      selectSaved: '从保存列表选择游戏内音频', selectAudio: '选择该分组的外部音频', emptyAudio: '该分组 Audio 文件夹为空',
      addRule: '添加规则', emptyRules: '从保存列表选择游戏内音频，并将外部音频放入此分组的 Audio 文件夹。',
      empty: '尚未创建分组', loadFailed: '有分组文件夹无法加载',
    },
    rule: {
      strategy: '抑制策略', skipOriginal: '跳过原始请求', stopPlayingId: '停止 PlayingId', cooldown: '冷却 ms',
      maxConcurrent: '最大并发', addAudio: '添加目录中的音频', addCandidate: '添加候选', remove: '删除规则',
    },
    candidate: {preview: '试听候选', remove: '删除候选', weight: '权重', volume: '音量', speed: '速度', maxDuration: '最大时长 ms'},
    saveBar: {
      dirty: '有未保存修改', synced: '配置已同步', reloadHint: '从磁盘重新加载配置；未保存修改将被丢弃',
      reload: '重新加载配置', save: '保存配置', saved: '配置已保存', reloaded: '配置已重新加载', previewQueued: '试听请求已排队',
    },
    errors: {
      identityMismatch: 'REFF 插件身份不匹配', hostDisconnected: 'REFF 宿主已断开', notReady: 'REFF 脚本尚未就绪',
      invalidArgument: '请求参数无效', invalidMessage: 'REFF 响应格式无效', transport: 'REFF 通信失败',
    },
  },
  'en-US': {
    tabs: {recent: 'Recent Events', saved: 'Saved Audio', groups: 'Group Settings', blocked: 'Block List'},
    common: {
      add: 'Add', remove: 'Remove', unknown: 'Unknown', unknownSource: 'Unknown source', unknownTime: 'Unknown time',
      entries: '{count} entries', groups: '{count} groups', seconds: '{value} sec', durationPending: 'Duration pending',
      durationUnknown: 'Unknown duration', player: 'Player', npc: 'NPC', companion: 'Companion', weapon: 'Weapon',
      uncategorized: 'Uncategorized', allCategories: 'All categories', enabled: 'Enabled', disabled: 'Disabled',
      mode: 'Mode', overlay: 'Overlay', replace: 'Replace', observe: 'Observe', rule: 'Rule',
    },
    status: {
      title: 'Runtime Status', captured: 'Captured Events', saved: 'Saved Audio', groups: 'Groups', blocked: 'Blocked',
      loading: 'Reading VoiceController status',
    },
    recent: {
      eyebrow: 'Natural Gameplay', title: 'Recent Audio Events', search: 'Event key, source, or resource path',
      lock: 'Lock the current category and search', unlock: 'Unlock and start a new matching event window',
      lockAria: 'Lock recent event filter', unlockAria: 'Unlock recent event filter', categoryAria: 'Event category',
      triggered: 'Triggered {count} times', latest: 'Latest #{sequence}', play: 'Play in-game audio',
      unavailable: 'Audio cannot be resolved in this session', saved: 'Saved', save: 'Save', empty: 'No matching events',
    },
    saved: {
      eyebrow: 'Permanent Records', title: 'Saved Audio', search: 'Search saved in-game audio', categoryAria: 'Saved audio category',
      noteInput: 'Enter a note', noteSave: 'Save note', noteCancel: 'Cancel note editing', noNote: 'No note',
      noteEdit: 'Edit note', savedAt: 'Saved at {time}', play: 'Play in-game audio',
      resolveAndPlay: 'Resolve audio from the current scene when playing', remove: 'Remove saved audio',
      removeHint: 'Remove saved audio without affecting saved group rules', empty: 'No in-game audio has been saved',
    },
    playback: {trying: 'Trying', success: 'Played', failed: 'Failed', failedDetail: 'Playback failed: {error}'},
    blocked: {
      eyebrow: 'Capture Filter', title: 'Block List', description: 'Events matching a SourceObject prefix are excluded from recent events, category totals, replay, and rule matching.',
      placeholder: 'Enter a SourceObject prefix', add: 'Add', remove: 'Remove blocked prefix', empty: 'No blocked prefixes configured',
    },
    groups: {
      eyebrow: 'Custom Configuration', title: 'Groups and Replacement Rules', newName: 'New group name', add: 'Add Group',
      conflicts: 'Conflict Details', active: 'Active', noActive: 'No active rule', allDisabled: 'All rules for this audio are currently disabled', occupied: 'Occupied',
      collapseGroup: 'Collapse group rules', expandGroup: 'Expand group rules', collapseRules: 'Collapse rules', expandRules: 'Expand rules',
      manualDelete: 'Delete the group folder manually to remove this group', groupPath: 'Group location:', audioPath: 'External audio location:',
      selectSaved: 'Select in-game audio from saved audio', selectAudio: 'Select external audio for this group', emptyAudio: 'This group Audio folder is empty',
      addRule: 'Add Rule', emptyRules: 'Select saved in-game audio and place external audio in this group’s Audio folder.',
      empty: 'No groups created', loadFailed: 'Some group folders could not be loaded',
    },
    rule: {
      strategy: 'Suppression Strategy', skipOriginal: 'Skip original request', stopPlayingId: 'Stop PlayingId', cooldown: 'Cooldown ms',
      maxConcurrent: 'Max Concurrent', addAudio: 'Add audio from the folder', addCandidate: 'Add Candidate', remove: 'Delete Rule',
    },
    candidate: {preview: 'Preview candidate', remove: 'Delete candidate', weight: 'Weight', volume: 'Volume', speed: 'Speed', maxDuration: 'Max duration ms'},
    saveBar: {
      dirty: 'Unsaved changes', synced: 'Configuration synced', reloadHint: 'Reload configuration from disk and discard unsaved changes',
      reload: 'Reload Configuration', save: 'Save Configuration', saved: 'Configuration saved', reloaded: 'Configuration reloaded', previewQueued: 'Preview request queued',
    },
    errors: {
      identityMismatch: 'REFF plugin identity mismatch', hostDisconnected: 'REFF host disconnected', notReady: 'REFF scripts are not ready',
      invalidArgument: 'Invalid request argument', invalidMessage: 'Invalid REFF response', transport: 'REFF communication failed',
    },
  },
} as const;

function normalizeLocale(value: unknown): SupportedLocale {
  return String(value).toLowerCase().startsWith('zh') ? 'zh-CN' : 'en-US';
}

export const i18n = createI18n({
  legacy: false,
  locale: normalizeLocale(document.documentElement.lang),
  fallbackLocale: 'en-US',
  messages,
});

// REFF Shell 是语言状态的唯一所有者；插件仅消费偏好变更，不在本地重复持久化。
export function installReffLocaleBridge(): () => void {
  const listener = (event: Event) => {
    const preferences = (event as CustomEvent<ReffPreferences>).detail;
    if (preferences?.language) i18n.global.locale.value = normalizeLocale(preferences.language);
  };
  window.addEventListener('reff:preferences-changed', listener);
  return () => window.removeEventListener('reff:preferences-changed', listener);
}
