<script setup lang="ts">
import {computed, shallowRef} from 'vue';
import {useI18n} from 'vue-i18n';
import {Check, Close, Delete, EditPen, Search, VideoPlay} from '@element-plus/icons-vue';
import type {AudioEvent} from '@/types';
import {audioActionKey, audioActionLabel} from '@/utils/audioActions';
import PlaybackStatus from '@/components/PlaybackStatus.vue';

const props = defineProps<{events: AudioEvent[]; busy: boolean}>();
const emit = defineEmits<{
  play: [payload: {stableKey: string}];
  remove: [payload: {stableKey: string}];
  updateNote: [payload: {stableKey: string; note: string}];
}>();
const query = shallowRef('');
const category = shallowRef('all');
const editingKey = shallowRef('');
const noteDraft = shallowRef('');
const {t} = useI18n();
const categoryLabels = computed<Record<string, string>>(() => ({
  player: t('common.player'), npc: t('common.npc'), otomo: t('common.companion'),
  weapon: t('common.weapon'), unknown: t('common.uncategorized'),
}));
const visibleEvents = computed(() => {
  const needle = query.value.trim().toLowerCase();
  return props.events.filter(event => {
    if (category.value !== 'all' && event.category !== category.value) return false;
    return !needle || [event.stableKey, event.sourcePath, event.sourceObject,
      ...(event.observedActions ?? []).flatMap(action => [audioActionKey(action), action.typeName])]
      .some(value => String(value ?? '').toLowerCase().includes(needle));
  });
});
function formatDuration(durationMs?: number) {
  return durationMs
    ? t('common.seconds', {value: (durationMs / 1000).toFixed(2)})
    : t('common.durationPending');
}
function formatAction(action: NonNullable<AudioEvent['observedActions']>[number]) {
  return audioActionLabel(action, {
    controller: t('action.controller'),
    category: t('action.category'),
    action: t('action.id'),
  });
}
// 新记录已是本地时间格式；旧版 UTC ISO 时间在展示时转换到当前系统时区，保持历史数据兼容。
function formatSavedAt(value?: string) {
  if (!value) return t('common.unknownTime');
  const localFormat = value.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})$/);
  if (localFormat && !value.endsWith('Z')) return `${localFormat[1]} ${localFormat[2]}`;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return value;
  const part = (number: number) => String(number).padStart(2, '0');
  return `${parsed.getFullYear()}-${part(parsed.getMonth() + 1)}-${part(parsed.getDate())} ${part(parsed.getHours())}:${part(parsed.getMinutes())}:${part(parsed.getSeconds())}`;
}
function beginNoteEdit(event: AudioEvent) {
  editingKey.value = event.stableKey;
  noteDraft.value = event.note ?? '';
}
function cancelNoteEdit() {
  editingKey.value = '';
  noteDraft.value = '';
}
function saveNote(event: AudioEvent) {
  emit('updateNote', {stableKey: event.stableKey, note: noteDraft.value.trim()});
  cancelNoteEdit();
}
// 切换 REFF 标签页后固定由当前列表处理滚轮，避免滚动事件落到宿主页面。
function handleListWheel(event: WheelEvent) {
  const list = event.currentTarget as HTMLElement | null;
  if (!list || list.scrollHeight <= list.clientHeight) return;
  event.preventDefault();
  event.stopPropagation();
  list.scrollTop += event.deltaY;
}
</script>

<template>
  <section class="saved-browser">
    <header class="section-heading"><div><span class="eyebrow">{{ t('saved.eyebrow') }}</span><h2>{{ t('saved.title') }}</h2></div><el-tag effect="plain">{{ t('common.entries', {count: visibleEvents.length}) }}</el-tag></header>
    <div class="toolbar">
      <el-input v-model="query" :prefix-icon="Search" clearable :placeholder="t('saved.search')" />
      <el-select v-model="category" :aria-label="t('saved.categoryAria')">
        <el-option :label="t('common.allCategories')" value="all" />
        <el-option :label="t('common.player')" value="player" />
        <el-option :label="t('common.npc')" value="npc" />
        <el-option :label="t('common.companion')" value="otomo" />
        <el-option :label="t('common.weapon')" value="weapon" />
        <el-option :label="t('common.uncategorized')" value="unknown" />
      </el-select>
    </div>
    <div class="saved-list" @wheel="handleListWheel">
      <article v-for="event in visibleEvents" :key="event.stableKey" class="saved-row">
        <div class="saved-main">
          <div class="saved-key"><code>{{ event.stableKey }}</code><el-tag size="small" effect="plain" disable-transitions>{{ categoryLabels[event.category || 'unknown'] || event.category }}</el-tag></div>
          <div v-if="editingKey === event.stableKey" class="note-editor">
            <el-input v-model="noteDraft" maxlength="64" show-word-limit :placeholder="t('saved.noteInput')" @keyup.enter="saveNote(event)" @keyup.esc="cancelNoteEdit" />
            <el-button :icon="Check" text :aria-label="t('saved.noteSave')" :disabled="busy" @click="saveNote(event)" />
            <el-button :icon="Close" text :aria-label="t('saved.noteCancel')" :disabled="busy" @click="cancelNoteEdit" />
          </div>
          <div v-else class="note-line">
            <strong v-if="event.note" class="event-note">{{ event.note }}</strong>
            <span v-else>{{ t('saved.noNote') }}</span>
            <el-tooltip :content="t('saved.noteEdit')">
              <el-button class="note-edit" :icon="EditPen" text :aria-label="t('saved.noteEdit')" :disabled="busy" @click="beginNoteEdit(event)" />
            </el-tooltip>
          </div>
          <div v-if="event.observedActions?.length" class="observed-actions">
            <span>{{ t('saved.observedActions') }}</span>
            <el-tag v-for="action in event.observedActions" :key="audioActionKey(action)" size="small" effect="plain" disable-transitions>
              {{ formatAction(action) }}
            </el-tag>
          </div>
          <div v-else class="observed-actions"><span>{{ t('saved.actionUnavailable') }}</span></div>
          <span>{{ event.sourcePath || event.sourceObject || t('common.unknownSource') }}</span><small>{{ formatDuration(event.durationMs) }} · {{ t('saved.savedAt', {time: formatSavedAt(event.savedAt)}) }}</small>
        </div>
        <div class="actions">
          <PlaybackStatus :status="event.playbackStatus" :error="event.playbackError" />
          <el-tooltip :content="event.replayable ? t('saved.play') : t('saved.resolveAndPlay')">
            <el-button class="play-button" :icon="VideoPlay" :disabled="busy || event.playbackStatus === 'trying'" :aria-label="t('saved.play')" @click="emit('play', {stableKey: event.stableKey})" />
          </el-tooltip>
          <el-tooltip :content="t('saved.removeHint')">
            <el-button :icon="Delete" circle text type="danger" :disabled="busy" :aria-label="t('saved.remove')" @click="emit('remove', {stableKey: event.stableKey})" />
          </el-tooltip>
        </div>
      </article>
      <div v-if="visibleEvents.length === 0" class="empty-state">{{ t('saved.empty') }}</div>
    </div>
  </section>
</template>

<style scoped>
.saved-browser { display: flex; min-width: 0; height: 100%; flex-direction: column; padding: 18px 20px; }
.section-heading, .saved-row, .actions { display: flex; align-items: center; }
.section-heading, .saved-row { justify-content: space-between; gap: 14px; }
.section-heading { margin-bottom: 12px; }
.section-heading h2 { margin: 3px 0 0; font-size: 17px; letter-spacing: 0; }
.eyebrow, .saved-main > span, .saved-main > small { color: var(--vc-muted); font-size: 12px; }
.toolbar { display: grid; grid-template-columns: minmax(220px, 1fr) 150px; gap: 8px; margin-bottom: 12px; }
.saved-list { min-height: 0; flex: 1; overflow-x: hidden; overflow-y: auto; overscroll-behavior: contain; scrollbar-gutter: stable; touch-action: pan-y; border: 1px solid var(--vc-border); border-radius: 6px; }
.saved-row { min-height: 72px; padding: 10px 12px; border-bottom: 1px solid var(--vc-border); background: var(--vc-surface); }
.saved-row:last-child { border-bottom: 0; }
.saved-main { display: grid; min-width: 0; gap: 4px; }
.saved-key { display: flex; align-items: center; gap: 8px; min-width: 0; }
.note-line, .note-editor { display: flex; align-items: center; min-width: 0; gap: 4px; }
.event-note { overflow: hidden; color: var(--vc-text); font-size: 13px; font-weight: 600; text-overflow: ellipsis; white-space: nowrap; }
.note-line > span { color: var(--vc-muted); font-size: 12px; }
.note-edit { width: 24px; min-width: 24px; height: 24px; padding: 0; color: var(--vc-muted); }
.note-editor :deep(.el-input) { width: min(280px, 100%); }
.note-editor :deep(.el-input__wrapper) { min-height: 28px; }
.saved-main code { color: var(--vc-accent); }
.saved-main > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.observed-actions { display: flex; min-width: 0; align-items: center; gap: 6px; flex-wrap: wrap; }
.observed-actions > span { color: var(--vc-muted); font-size: 12px; }
.observed-actions :deep(.el-tag) { color: var(--vc-text); }
.actions { gap: 6px; }
.play-button { width: 32px; min-width: 32px; height: 32px; padding: 0; border-radius: 4px !important; }
.empty-state { padding: 36px 16px; color: var(--vc-muted); text-align: center; }
@media (max-width: 760px) { .toolbar { grid-template-columns: 1fr; } .saved-row { align-items: flex-start; flex-direction: column; } }
</style>
