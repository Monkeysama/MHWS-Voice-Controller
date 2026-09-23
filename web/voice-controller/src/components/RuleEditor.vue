<script setup lang="ts">
import {computed, onMounted, onUnmounted, reactive, shallowRef} from 'vue';
import {useI18n} from 'vue-i18n';
import {ArrowDown, ArrowRight, Delete, Plus} from '@element-plus/icons-vue';
import type {AudioEvent, CatalogEntry, FolderReject, GroupConflict, ReplaceStrategy, RuleGroup, RuleMode, UnwritableFolder} from '@/types';
import RuleCard from './RuleCard.vue';

const props = defineProps<{
  groups: RuleGroup[];
  catalogEntries: CatalogEntry[];
  savedEvents: AudioEvent[];
  warnings: readonly string[];
  conflicts: GroupConflict[];
  folderRejects: FolderReject[];
  unwritableFolders: UnwritableFolder[];
  defaultMode: RuleMode;
  defaultStrategy: ReplaceStrategy;
  busy: boolean;
}>();
const emit = defineEmits<{
  addGroup: [payload: Record<string, unknown>];
  updateGroup: [payload: Record<string, unknown>];
  removeGroup: [payload: Record<string, unknown>];
  addRuleFromSaved: [payload: Record<string, unknown>];
  updateRule: [payload: Record<string, unknown>];
  removeRule: [payload: Record<string, unknown>];
  addCandidate: [payload: Record<string, unknown>];
  updateCandidate: [payload: Record<string, unknown>];
  removeCandidate: [payload: Record<string, unknown>];
  testCandidate: [payload: Record<string, unknown>];
}>();

const newGroupName = shallowRef('');
const {t} = useI18n();
// 展开状态仅属于当前 REFF 页面会话；默认空数组保证所有分组初始折叠。
const expandedGroupIds = shallowRef<string[]>([]);
const selection = reactive<Record<string, {stableKey: string; file: string}>>({});
// 目录名含非 ASCII 的分组：REFramework 的文件 API 按本机代码页解释路径，回写清单只会生成乱码目录（测试 → 娴嬭瘯）。
const unwritableFolders = computed(() => new Map(
  props.unwritableFolders.map(item => [String(item.id), item.folder])));
const folderWarnings = computed(() => props.warnings
  .filter(item => item.startsWith('folder_not_writable.'))
  .map(item => {
    const rest = item.slice('folder_not_writable.'.length);
    const separator = rest.indexOf('.');
    return separator < 0
      ? {id: rest, folder: ''}
      : {id: rest.slice(0, separator), folder: rest.slice(separator + 1)};
  }));
const savedEventNotes = computed(() => new Map(
  props.savedEvents
    .filter(event => Boolean(event.note))
    .map(event => [event.stableKey, event.note!] as const),
));
function modeLabel(mode?: string) {
  if (mode === 'observe' || mode === 'overlay' || mode === 'replace') return t(`common.${mode}`);
  return mode ?? t('common.unknown');
}

function unwritableFolder(group: RuleGroup) {
  if (unwritableFolders.value.has(String(group.id))) return unwritableFolders.value.get(String(group.id))!;
  const folder = (group.audioDirectory ?? '').match(/Groups\\([^\\]+)\\Audio$/i)?.[1];
  return folder && /[^\x20-\x7e]/.test(folder) ? folder : '';
}

function groupFiles(group: RuleGroup) {
  const prefix = `${group.audioDirectory ?? ''}\\`.toLowerCase();
  return prefix === '\\' ? [] : props.catalogEntries.filter(entry => entry.file.toLowerCase().startsWith(prefix));
}

function formatCatalogEntry(entry: CatalogEntry) {
  const duration = entry.durationMs && entry.durationMs > 0
    ? t('common.seconds', {value: (entry.durationMs / 1000).toFixed(2)})
    : t('common.durationUnknown');
  return `${entry.file} · ${duration}`;
}

function groupSelection(groupId: string) {
  if (!selection[groupId]) selection[groupId] = {stableKey: '', file: ''};
  return selection[groupId];
}

function savedEventLabel(event: AudioEvent) {
  const source = event.sourcePath || event.sourceObject || t('common.unknownSource');
  return event.note ? `${event.note} · ${event.stableKey} · ${source}` : `${event.stableKey} · ${source}`;
}

// 路径摘要优先采用磁盘来源名，再从音频目录提取，确保中文文件夹显示真实名称而非内部分组 ID。
function groupFolder(group: RuleGroup) {
  if (group.source?.folder) return group.source.folder;
  const audioDirectory = String(group.audioDirectory ?? '').replace(/\//g, '\\').replace(/\\+$/, '');
  return audioDirectory.match(/(?:^|\\)Groups\\([^\\]+)(?:\\Audio)?$/i)?.[1] ?? group.id;
}

function groupDirectory(group: RuleGroup) {
  return `reframework\\data\\VoiceController\\Groups\\${groupFolder(group)}`;
}

function isGroupExpanded(groupId: string) {
  return expandedGroupIds.value.includes(groupId);
}

function toggleGroup(groupId: string) {
  expandedGroupIds.value = isGroupExpanded(groupId)
    ? expandedGroupIds.value.filter(id => id !== groupId)
    : [...expandedGroupIds.value, groupId];
}

function addGroup() {
  const name = newGroupName.value.trim();
  if (!name) return;
  emit('addGroup', {name});
  newGroupName.value = '';
}

function addRule(group: RuleGroup) {
  const value = groupSelection(group.id);
  if (!value.stableKey || !value.file) return;
  emit('addRuleFromSaved', {
    groupId: group.id,
    stableKey: value.stableKey,
    actionKey: '',
    file: value.file,
  });
  value.stableKey = '';
  value.file = '';
}

function setGroupEnabled(groupId: string, value: string | number | boolean) {
  emit('updateGroup', {groupId, enabled: value === true});
}

// 分组配置内容较长时固定由面板自身滚动，避免切换标签页后宿主页面抢占滚轮。
function handlePanelWheel(event: WheelEvent) {
  const panel = event.currentTarget as HTMLElement | null;
  if (!panel || panel.scrollHeight <= panel.clientHeight) return;
  event.preventDefault();
  event.stopPropagation();
  panel.scrollTop += event.deltaY;
}

// REFF 宿主有时会抢走传送到 body 的下拉菜单滚轮；捕获后只滚动 Element Plus 自身列表。
function handleSelectDropdownWheel(event: WheelEvent) {
  const target = event.target;
  if (!(target instanceof Element)) return;
  const dropdown = target.closest('.el-select__popper, .el-select-dropdown');
  if (!dropdown) return;
  const scroller = (target.closest('.el-scrollbar__wrap')
    ?? dropdown.querySelector('.el-scrollbar__wrap')) as HTMLElement | null;
  if (!scroller || scroller.scrollHeight <= scroller.clientHeight) return;
  event.preventDefault();
  event.stopPropagation();
  scroller.scrollTop += event.deltaY;
}

onMounted(() => document.addEventListener('wheel', handleSelectDropdownWheel, {capture: true, passive: false}));
onUnmounted(() => document.removeEventListener('wheel', handleSelectDropdownWheel, true));
</script>

<template>
  <section class="rule-editor">
    <header class="section-heading">
      <div><span class="eyebrow">{{ t('groups.eyebrow') }}</span><h2>{{ t('groups.title') }}</h2></div>
      <div class="new-group"><el-input v-model="newGroupName" maxlength="64" :placeholder="t('groups.newName')" @keyup.enter="addGroup" /><el-button :icon="Plus" :disabled="busy || !newGroupName.trim()" @click="addGroup">{{ t('groups.add') }}</el-button></div>
    </header>
    <div class="rule-editor-content" @wheel="handlePanelWheel">
      <details v-if="conflicts.length" class="conflict-panel">
        <summary class="conflict-summary">
          <span class="conflict-toggle" aria-hidden="true"><ArrowRight /></span>
          <span>{{ t('groups.conflicts') }} <small>{{ t('common.groups', {count: conflicts.length}) }}</small></span>
        </summary>
        <div class="conflict-content">
          <div v-for="conflict in conflicts" :key="conflict.matchKey || conflict.stableKey" class="conflict-row">
            <code>{{ conflict.stableKey }}</code>
            <el-tag v-if="conflict.actionKey" size="small" effect="plain">{{ t('groups.actionConflict', {key: conflict.actionKey}) }}</el-tag>
            <div class="conflict-entries">
              <div v-if="conflict.winner" class="conflict-entry winner">
                <el-tag size="small" type="success" effect="dark">{{ t('groups.active') }}</el-tag>
                <span>{{ conflict.winner.group_name }}</span>
                <span class="conflict-meta">{{ t('common.rule') }} {{ conflict.winner.rule_id }} · {{ modeLabel(conflict.winner.mode) }}</span>
              </div>
              <div v-else class="conflict-entry">
                <el-tag size="small" type="info" effect="plain">{{ t('groups.noActive') }}</el-tag>
                <span class="conflict-meta">{{ t('groups.allDisabled') }}</span>
              </div>
              <div v-for="loser in conflict.losers" :key="`${loser.group_id}:${loser.rule_id}`" class="conflict-entry">
                <el-tag size="small" :type="loser.enabled ? 'warning' : 'info'" effect="plain">
                  {{ loser.enabled ? t('groups.occupied') : t('common.disabled') }}
                </el-tag>
                <span>{{ loser.group_name }}</span>
                <span class="conflict-meta">{{ t('common.rule') }} {{ loser.rule_id }} · {{ modeLabel(loser.mode) }}</span>
              </div>
            </div>
          </div>
        </div>
      </details>
      <section v-for="group in groups" :key="group.id" class="rule-group">
        <header
          class="group-header"
          role="button"
          tabindex="0"
          :aria-expanded="isGroupExpanded(group.id)"
          :aria-label="isGroupExpanded(group.id) ? t('groups.collapseGroup') : t('groups.expandGroup')"
          @click="toggleGroup(group.id)"
          @keydown.enter.self.prevent="toggleGroup(group.id)"
          @keydown.space.self.prevent="toggleGroup(group.id)"
        >
          <div class="group-identity">
            <el-tooltip :content="isGroupExpanded(group.id) ? t('groups.collapseRules') : t('groups.expandRules')">
              <el-button
                class="group-toggle"
                :icon="isGroupExpanded(group.id) ? ArrowDown : ArrowRight"
                circle
                text
                :aria-label="isGroupExpanded(group.id) ? t('groups.collapseRules') : t('groups.expandRules')"
                @click.stop="toggleGroup(group.id)"
              />
            </el-tooltip>
            <el-switch :model-value="group.enabled !== false" :disabled="busy" @click.stop @change="setGroupEnabled(group.id, $event)" />
            <strong class="group-name">{{ group.name || group.id }}</strong>
          </div>
          <el-tooltip :content="t('groups.manualDelete')">
            <span class="disabled-delete" @click.stop>
              <el-button :icon="Delete" circle text type="danger" disabled :aria-label="t('groups.manualDelete')" />
            </span>
          </el-tooltip>
        </header>

        <div v-show="isGroupExpanded(group.id)" class="group-content">
          <div class="group-paths">
            <div><span>{{ t('groups.groupPath') }}</span><code>{{ groupDirectory(group) }}</code></div>
            <div><span>{{ t('groups.audioPath') }}</span><code>{{ groupDirectory(group) }}\Audio</code></div>
          </div>

          <div class="rule-create">
            <el-select v-model="groupSelection(group.id).stableKey" filterable clearable :placeholder="t('groups.selectSaved')">
              <el-option v-for="event in savedEvents" :key="event.stableKey" :label="savedEventLabel(event)" :value="event.stableKey" />
            </el-select>
            <el-select v-model="groupSelection(group.id).file" filterable clearable :placeholder="groupFiles(group).length ? t('groups.selectAudio') : t('groups.emptyAudio')">
              <el-option v-for="entry in groupFiles(group)" :key="entry.file" :label="formatCatalogEntry(entry)" :value="entry.file" />
            </el-select>
            <el-button :icon="Plus" :disabled="busy || !groupSelection(group.id).stableKey || !groupSelection(group.id).file" @click="addRule(group)">{{ t('groups.addRule') }}</el-button>
          </div>

          <div v-if="group.rules.length" class="rules">
            <div v-for="rule in group.rules" :key="rule.id" class="rule-wrap">
              <RuleCard
                :group-id="group.id" :rule="rule" :catalog-entries="groupFiles(group)"
                :event-note="savedEventNotes.get(`${rule.eventId}:${rule.triggerId}`)"
                :observed-actions="savedEvents.find(event => event.stableKey === `${rule.eventId}:${rule.triggerId}`)?.observedActions ?? []"
                :default-mode="defaultMode" :default-strategy="defaultStrategy" :busy="busy"
                @update-rule="emit('updateRule', $event)" @remove-rule="emit('removeRule', $event)"
                @add-candidate="emit('addCandidate', $event)" @update-candidate="emit('updateCandidate', $event)"
                @remove-candidate="emit('removeCandidate', $event)" @test-candidate="emit('testCandidate', $event)"
              />
            </div>
          </div>
          <div v-else class="empty-group">{{ t('groups.emptyRules') }}</div>
        </div>
      </section>
      <div v-if="groups.length === 0" class="empty-state">{{ t('groups.empty') }}</div>

      <el-alert
        v-if="folderRejects.length"
        class="spaced"
        type="error"
        :closable="false"
        show-icon
        :title="t('groups.loadFailed')"
        :description="folderRejects.map(item => `${item.id}：${item.code}`).join('；')"
      />
    </div>

  </section>
</template>

<style scoped>
.rule-editor { display: flex; min-width: 0; height: 100%; flex-direction: column; padding: 18px 20px; }
.rule-editor-content { min-height: 0; flex: 1; overflow-x: hidden; overflow-y: auto; overscroll-behavior: contain; scrollbar-gutter: stable; touch-action: pan-y; }
.blocked-panel { position: absolute; top: 18px; right: 20px; width: 320px; padding: 12px; border: 1px solid var(--vc-border); border-radius: 6px; background: var(--vc-surface); }
.blocked-add, .blocked-row { display: flex; align-items: center; gap: 8px; }
.blocked-add { margin-bottom: 8px; }
.blocked-row { justify-content: space-between; min-height: 32px; border-top: 1px solid var(--vc-border); }
.blocked-row code { overflow: hidden; color: var(--vc-accent); text-overflow: ellipsis; white-space: nowrap; }
.section-heading, .group-header, .group-identity, .new-group { display: flex; align-items: center; }
.section-heading, .group-header { justify-content: space-between; gap: 12px; }
.section-heading { margin-bottom: 14px; }
.section-heading h2 { margin: 3px 0 0; font-size: 17px; letter-spacing: 0; }
.eyebrow, .empty-group { color: var(--vc-muted); font-size: 12px; }
.new-group { width: min(430px, 52%); gap: 8px; }
.rule-group { margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--vc-border); }
.group-header { min-height: 56px; padding: 7px 10px; border: 1px solid var(--vc-border); border-radius: 6px; background: var(--vc-surface); cursor: pointer; transition: border-color 120ms ease, background-color 120ms ease; }
.group-header:hover, .group-header:focus-visible { border-color: var(--vc-accent); background: var(--vc-accent-soft); outline: none; }
.group-identity { min-width: 0; flex: 1; gap: 10px; }
.group-name { overflow: hidden; color: var(--vc-text); font-weight: 600; text-overflow: ellipsis; white-space: nowrap; }
.group-toggle { width: 40px; min-width: 40px; height: 40px; padding: 0; border-color: transparent !important; background: transparent !important; }
.group-toggle :deep(.el-icon) { font-size: 14px; }
.group-toggle:hover, .group-toggle:focus-visible { color: var(--vc-accent-strong); }
.disabled-delete { display: inline-flex; cursor: not-allowed; }
.group-paths { display: grid; gap: 6px; margin: 12px 0 2px 50px; color: var(--vc-muted); line-height: 1.6; }
.group-paths > div { display: flex; min-width: 0; gap: 4px; }
.group-paths span { flex: none; }
.group-paths code { overflow: hidden; color: var(--vc-accent); text-overflow: ellipsis; white-space: nowrap; }
.spaced { margin-top: 14px; }
.conflict-panel { margin-top: 18px; border: 1px solid var(--vc-border); border-radius: 6px; background: var(--vc-surface); }
.conflict-summary { display: flex; min-height: 56px; align-items: center; gap: 10px; padding: 7px 10px; cursor: pointer; font-weight: 600; }
.conflict-summary::-webkit-details-marker { display: none; }
.conflict-toggle { display: grid; width: 40px; min-width: 40px; height: 40px; place-items: center; color: var(--vc-muted); font-size: 14px; transition: color 120ms ease, transform 120ms ease; }
.conflict-toggle > svg { width: 14px; height: 14px; }
.conflict-panel[open] > .conflict-summary .conflict-toggle { transform: rotate(90deg); }
.conflict-summary > span { flex: 1; }
.conflict-summary > .conflict-toggle { flex: none; }
.conflict-summary small { margin-left: 6px; color: var(--vc-accent); font-size: inherit; font-weight: 400; }
.conflict-summary:hover, .conflict-summary:focus-visible { background: var(--vc-accent-soft); outline: none; }
.conflict-summary:hover .conflict-toggle, .conflict-summary:focus-visible .conflict-toggle { color: var(--vc-accent-strong); }
.conflict-content { padding: 0 13px 4px; border-top: 1px solid var(--vc-border); }
.conflict-meta { color: var(--vc-muted); font-size: 12px; }
.conflict-row { padding: 10px 0; border-bottom: 1px solid var(--vc-border); }
.conflict-row:last-child { border-bottom: 0; }
.conflict-row code { color: var(--vc-accent); }
.conflict-entries { display: grid; gap: 6px; margin-top: 6px; }
.conflict-entry { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 13px; }
.conflict-entry.winner { font-weight: 600; }
.rule-create { display: grid; grid-template-columns: minmax(190px, 1fr) minmax(220px, 1fr) auto; gap: 8px; margin: 12px 0; }
.rules, .rule-wrap { display: grid; gap: 8px; }
.empty-group, .empty-state { padding: 24px 12px; text-align: center; }
.empty-state { color: var(--vc-muted); }
@media (max-width: 800px) { .section-heading { align-items: stretch; flex-direction: column; } .new-group, .group-identity { width: 100%; } .group-paths { margin-left: 0; } .rule-create { grid-template-columns: 1fr; } }
</style>
