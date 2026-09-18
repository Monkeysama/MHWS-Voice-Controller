<script setup lang="ts">
import {computed, reactive, shallowRef} from 'vue';
import {Delete, Plus} from '@element-plus/icons-vue';
import type {AudioEvent, FolderReject, GroupConflict, ReplaceStrategy, RuleGroup, RuleMode, UnwritableFolder} from '@/types';
import RuleCard from './RuleCard.vue';

const props = defineProps<{
  groups: RuleGroup[];
  catalogFiles: string[];
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

function unwritableFolder(group: RuleGroup) {
  if (unwritableFolders.value.has(String(group.id))) return unwritableFolders.value.get(String(group.id))!;
  const folder = (group.audioDirectory ?? '').match(/Groups\\([^\\]+)\\Audio$/i)?.[1];
  return folder && /[^\x20-\x7e]/.test(folder) ? folder : '';
}

function groupFiles(group: RuleGroup) {
  const prefix = `${group.audioDirectory ?? ''}\\`.toLowerCase();
  return prefix === '\\' ? [] : props.catalogFiles.filter(file => file.toLowerCase().startsWith(prefix));
}

function groupSelection(groupId: string) {
  if (!selection[groupId]) selection[groupId] = {stableKey: '', file: ''};
  return selection[groupId];
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
  emit('addRuleFromSaved', {groupId: group.id, stableKey: value.stableKey, file: value.file});
  value.stableKey = '';
  value.file = '';
}

function setGroupEnabled(groupId: string, value: string | number | boolean) {
  emit('updateGroup', {groupId, enabled: value === true});
}

function setGroupName(groupId: string, value: string) {
  emit('updateGroup', {groupId, name: value});
}
</script>

<template>
  <section class="rule-editor">
    <header class="section-heading">
      <div><span class="eyebrow">自定义配置</span><h2>分组与替换规则</h2></div>
      <div class="new-group"><el-input v-model="newGroupName" maxlength="64" placeholder="新分组名称" @keyup.enter="addGroup" /><el-button :icon="Plus" :disabled="busy || !newGroupName.trim()" @click="addGroup">新增分组</el-button></div>
    </header>
    <section v-if="conflicts.length" class="conflict-panel">
      <header class="section-heading">
        <div><span class="eyebrow">同一个游戏内音频被多个分组使用</span><h2>占用明细</h2></div>
        <el-tag effect="plain">{{ conflicts.length }} 组</el-tag>
      </header>
      <div v-for="conflict in conflicts" :key="conflict.stableKey" class="conflict-row">
        <code>{{ conflict.stableKey }}</code>
        <div class="conflict-entries">
          <div v-if="conflict.winner" class="conflict-entry winner">
            <el-tag size="small" type="success" effect="dark">生效中</el-tag>
            <span>{{ conflict.winner.group_name }}</span>
            <span class="conflict-meta">规则 {{ conflict.winner.rule_id }} · {{ conflict.winner.mode }}</span>
          </div>
          <div v-else class="conflict-entry">
            <el-tag size="small" type="info" effect="plain">无生效规则</el-tag>
            <span class="conflict-meta">该音频的所有规则当前都被禁用</span>
          </div>
          <div v-for="loser in conflict.losers" :key="`${loser.group_id}:${loser.rule_id}`" class="conflict-entry">
            <el-tag size="small" :type="loser.enabled ? 'warning' : 'info'" effect="plain">
              {{ loser.enabled ? '被占用' : '已禁用' }}
            </el-tag>
            <span>{{ loser.group_name }}</span>
            <span class="conflict-meta">规则 {{ loser.rule_id }} · {{ loser.mode }}</span>
          </div>
        </div>
      </div>
    </section>
    <section v-for="group in groups" :key="group.id" class="rule-group">
      <header class="group-header">
        <div class="group-identity">
          <el-switch :model-value="group.enabled !== false" :disabled="busy" @change="setGroupEnabled(group.id, $event)" />
          <el-input :model-value="group.name || group.id" :disabled="busy" maxlength="64" @change="setGroupName(group.id, $event)" />
          <el-tag v-if="group.source" size="small" type="warning" effect="plain">文件夹 {{ group.source.folder }}</el-tag>
        </div>
        <code>{{ group.audioDirectory || `VoiceController\\Groups\\${group.id}\\Audio` }}</code>
        <el-tooltip :content="group.source ? '还原为包体，丢弃本机修改' : '删除分组和规则；不会删除磁盘 Audio 文件夹'">
          <el-button :icon="Delete" circle text type="danger" :disabled="busy" :aria-label="group.source ? '还原为包体' : '删除分组'" @click="emit('removeGroup', {groupId: group.id})" />
        </el-tooltip>
      </header>

      <div v-if="group.source" class="source-note">
        来自文件夹 <code>Groups\{{ group.source.folder }}\</code><template v-if="group.source.version"> v{{ group.source.version }}</template><template v-if="!group.source.hasManifest">（尚无 group.json）</template>；
        修改会随保存写回该文件夹的 <code>group.json</code>，把整个文件夹压缩即可分发。
      </div>

      <div class="rule-create">
        <el-select v-model="groupSelection(group.id).stableKey" filterable clearable placeholder="从保存列表选择游戏内音频">
          <el-option v-for="event in savedEvents" :key="event.stableKey" :label="`${event.stableKey} · ${event.sourcePath || event.sourceObject || '未知来源'}`" :value="event.stableKey" />
        </el-select>
        <el-select v-model="groupSelection(group.id).file" filterable clearable :placeholder="groupFiles(group).length ? '选择该分组的外部音频' : '该分组 Audio 文件夹为空'">
          <el-option v-for="file in groupFiles(group)" :key="file" :label="file" :value="file" />
        </el-select>
        <el-button :icon="Plus" :disabled="busy || !groupSelection(group.id).stableKey || !groupSelection(group.id).file" @click="addRule(group)">添加规则</el-button>
      </div>

      <div v-if="group.rules.length" class="rules">
        <div v-for="rule in group.rules" :key="rule.id" class="rule-wrap">
          <RuleCard
            :group-id="group.id" :rule="rule" :catalog-files="groupFiles(group)"
            :default-mode="defaultMode" :default-strategy="defaultStrategy" :busy="busy"
            @update-rule="emit('updateRule', $event)" @remove-rule="emit('removeRule', $event)"
            @add-candidate="emit('addCandidate', $event)" @update-candidate="emit('updateCandidate', $event)"
            @remove-candidate="emit('removeCandidate', $event)" @test-candidate="emit('testCandidate', $event)"
          />
        </div>
      </div>
      <div v-else class="empty-group">从保存列表选择游戏内音频，并将外部音频放入此分组的 Audio 文件夹。</div>
    </section>
    <div v-if="groups.length === 0" class="empty-state">尚未创建分组</div>

    <el-alert
      v-if="folderRejects.length"
      class="spaced"
      type="error"
      :closable="false"
      show-icon
      title="有分组文件夹无法加载"
      :description="folderRejects.map(item => `${item.id}：${item.code}`).join('；')"
    />

  </section>
</template>

<style scoped>
.rule-editor { padding: 18px 20px; }
.blocked-panel { position: absolute; top: 18px; right: 20px; width: 320px; padding: 12px; border: 1px solid var(--vc-border); border-radius: 6px; background: var(--vc-surface); }
.blocked-add, .blocked-row { display: flex; align-items: center; gap: 8px; }
.blocked-add { margin-bottom: 8px; }
.blocked-row { justify-content: space-between; min-height: 32px; border-top: 1px solid var(--vc-border); }
.blocked-row code { overflow: hidden; color: var(--vc-accent); text-overflow: ellipsis; white-space: nowrap; }
.section-heading, .group-header, .group-identity, .new-group { display: flex; align-items: center; }
.section-heading, .group-header { justify-content: space-between; gap: 12px; }
.section-heading { margin-bottom: 14px; }
.section-heading h2 { margin: 3px 0 0; font-size: 17px; letter-spacing: 0; }
.eyebrow, .group-header code, .empty-group { color: var(--vc-muted); font-size: 12px; }
.new-group { width: min(430px, 52%); gap: 8px; }
.rule-group { margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--vc-border); }
.group-identity { width: min(420px, 45%); gap: 10px; }
.source-note { margin: 8px 0 0; padding: 6px 10px; border-radius: 4px; background: var(--vc-accent-soft); color: var(--vc-muted); font-size: 12px; }
.source-note code { color: var(--vc-accent); }
.spaced { margin-top: 14px; }
.conflict-panel { margin-top: 18px; }
.conflict-hint, .conflict-meta { color: var(--vc-muted); font-size: 12px; }
.conflict-hint { margin: 0 0 8px; }
.conflict-row { padding: 10px 0; border-top: 1px solid var(--vc-border); }
.conflict-row code { color: var(--vc-accent); }
.conflict-entries { display: grid; gap: 6px; margin-top: 6px; }
.conflict-entry { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 13px; }
.conflict-entry.winner { font-weight: 600; }
.group-header code { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rule-create { display: grid; grid-template-columns: minmax(220px, 1fr) minmax(240px, 1fr) auto; gap: 8px; margin: 12px 0; }
.rules, .rule-wrap { display: grid; gap: 8px; }
.empty-group, .empty-state { padding: 24px 12px; text-align: center; }
.empty-state { color: var(--vc-muted); }
@media (max-width: 800px) { .section-heading, .group-header { align-items: stretch; flex-direction: column; } .new-group, .group-identity { width: 100%; } .rule-create { grid-template-columns: 1fr; } }
</style>
