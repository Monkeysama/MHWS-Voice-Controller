<script setup lang="ts">
import {computed, onBeforeUnmount, shallowRef, watch} from 'vue';
import {useI18n} from 'vue-i18n';
import {CollectionTag, Lock, Search, Unlock, VideoPlay} from '@element-plus/icons-vue';
import type {AudioEvent} from '@/types';
import PlaybackStatus from '@/components/PlaybackStatus.vue';

const props = defineProps<{
  events: AudioEvent[];
  savedKeys: Set<string>;
  busy: boolean;
  recentCaptureEnabled: boolean;
  recentCaptureAvailable: boolean;
}>();
const emit = defineEmits<{
  save: [payload: {stableKey: string}];
  play: [payload: {stableKey: string}];
  setLock: [payload: {locked: boolean; category: string; query: string}];
  setCapture: [payload: {enabled: boolean}];
}>();
const query = shallowRef('');
const category = shallowRef('all');
const locked = shallowRef(false);
let lockUpdateTimer: number | undefined;
const {t} = useI18n();
const categoryLabels = computed<Record<string, string>>(() => ({
  player: t('common.player'), npc: t('common.npc'), otomo: t('common.companion'),
  weapon: t('common.weapon'), unknown: t('common.uncategorized'),
}));
function formatDuration(durationMs?: number) {
  return durationMs
    ? t('common.seconds', {value: (durationMs / 1000).toFixed(2)})
    : t('common.durationPending');
}
// REFF 宿主切换标签页后可能重新接管 wheel 事件；显式把增量交给近期事件容器，避免滚动上下文漂移。
function handleListWheel(event: WheelEvent) {
  const list = event.currentTarget as HTMLElement | null;
  if (!list || list.scrollHeight <= list.clientHeight) return;
  event.preventDefault();
  event.stopPropagation();
  list.scrollTop += event.deltaY;
}
function emitLockState() {
  emit('setLock', {locked: locked.value, category: category.value, query: query.value.trim()});
}
function scheduleLockedFilterUpdate() {
  if (!locked.value) return;
  if (lockUpdateTimer !== undefined) window.clearTimeout(lockUpdateTimer);
  lockUpdateTimer = window.setTimeout(() => {
    lockUpdateTimer = undefined;
    emitLockState();
  }, 250);
}
function toggleLock() {
  locked.value = !locked.value;
  if (lockUpdateTimer !== undefined) window.clearTimeout(lockUpdateTimer);
  lockUpdateTimer = undefined;
  emitLockState();
}
watch(category, () => {
  emitLockState();
}, {flush: 'sync'});
watch(query, () => {
  if (!locked.value) return;
  scheduleLockedFilterUpdate();
}, {flush: 'sync'});
onBeforeUnmount(() => {
  if (lockUpdateTimer !== undefined) window.clearTimeout(lockUpdateTimer);
});
const visibleEvents = computed(() => {
  const needle = query.value.trim().toLowerCase();
  return [...props.events].reverse().filter(event => {
    if (category.value !== 'all' && event.category !== category.value) return false;
    return !needle || [event.stableKey, event.sourcePath, event.sourceObject, event.origin]
      .some(value => String(value ?? '').toLowerCase().includes(needle));
  }).slice(0, 120);
});
</script>

<template>
  <section class="event-browser">
    <header class="section-heading">
      <div><span class="eyebrow">{{ t('recent.eyebrow') }}</span><h2>{{ t('recent.title') }}</h2></div>
      <div class="capture-toggle">
        <span>{{ !props.recentCaptureAvailable ? t('recent.captureNeedsReset') : props.recentCaptureEnabled ? t('recent.captureOn') : t('recent.captureOff') }}</span>
        <el-tooltip :content="props.recentCaptureAvailable ? t('recent.captureAria') : t('recent.captureNeedsReset')">
          <el-switch
            :model-value="props.recentCaptureEnabled"
            :disabled="busy || !props.recentCaptureAvailable"
            :aria-label="t('recent.captureAria')"
            @update:model-value="(enabled: boolean) => emit('setCapture', {enabled})"
          />
        </el-tooltip>
        <el-tag effect="plain">{{ t('common.entries', {count: visibleEvents.length}) }}</el-tag>
      </div>
    </header>
    <div class="toolbar">
      <div class="search-lock">
        <el-input v-model="query" :prefix-icon="Search" clearable :placeholder="t('recent.search')" />
        <el-tooltip :content="locked ? t('recent.unlock') : t('recent.lock')" placement="top">
          <el-button
            class="lock-button"
            :class="{active: locked}"
            :icon="locked ? Lock : Unlock"
            :disabled="busy"
            :aria-pressed="locked"
            :aria-label="locked ? t('recent.unlockAria') : t('recent.lockAria')"
            @click="toggleLock"
          />
        </el-tooltip>
      </div>
      <el-select v-model="category" :aria-label="t('recent.categoryAria')">
        <el-option :label="t('common.allCategories')" value="all" />
        <el-option :label="t('common.player')" value="player" />
        <el-option :label="t('common.npc')" value="npc" />
        <el-option :label="t('common.companion')" value="otomo" />
        <el-option :label="t('common.weapon')" value="weapon" />
        <el-option :label="t('common.uncategorized')" value="unknown" />
      </el-select>
    </div>
    <div class="event-list" @wheel="handleListWheel">
      <article v-for="event in visibleEvents" :key="`${event.stableKey}:${event.sequence}`" class="event-row">
        <div class="event-main">
          <div class="event-key">
            <code>{{ event.stableKey }}</code>
            <el-tag size="small" effect="plain" disable-transitions>{{ categoryLabels[event.category || 'unknown'] || event.category }}</el-tag>
            <el-tag v-if="Number(event.triggerCount ?? 1) > 1" size="small" type="warning" effect="plain" disable-transitions>{{ t('recent.triggered', {count: event.triggerCount}) }}</el-tag>
          </div>
          <div class="event-source">{{ event.sourcePath || event.sourceObject || t('common.unknownSource') }}</div>
          <div class="event-meta">{{ t('recent.latest', {sequence: event.sequence}) }} · {{ event.origin || 'unknown' }} · {{ formatDuration(event.durationMs) }}</div>
        </div>
        <div class="event-actions">
          <PlaybackStatus :status="event.playbackStatus" :error="event.playbackError" />
          <el-tooltip :content="event.replayable ? t('recent.play') : t('recent.unavailable')">
            <el-button class="play-button" :icon="VideoPlay" :disabled="busy || !event.replayable || event.playbackStatus === 'trying'" :aria-label="t('recent.play')" @click="emit('play', {stableKey: event.stableKey})" />
          </el-tooltip>
          <el-tag v-if="savedKeys.has(event.stableKey)" class="saved-tag" effect="plain">{{ t('recent.saved') }}</el-tag>
          <el-button v-else :icon="CollectionTag" :disabled="busy" @click="emit('save', {stableKey: event.stableKey})">{{ t('recent.save') }}</el-button>
        </div>
      </article>
      <div v-if="visibleEvents.length === 0" class="empty-state">{{ t('recent.empty') }}</div>
    </div>
  </section>
</template>

<style scoped>
.event-browser { display: flex; min-width: 0; height: 100%; flex-direction: column; padding: 18px 20px; }
.section-heading, .event-row, .event-actions, .event-key { display: flex; align-items: center; }
.section-heading, .event-row { justify-content: space-between; }
.section-heading { gap: 12px; margin-bottom: 14px; }
.capture-toggle { display: flex; align-items: center; gap: 8px; color: var(--vc-muted); font-size: 12px; }
.section-heading h2 { margin: 3px 0 0; font-size: 17px; letter-spacing: 0; }
.eyebrow, .event-source, .event-meta { color: var(--vc-muted); font-size: 12px; }
.toolbar { display: grid; grid-template-columns: minmax(220px, 1fr) 150px; gap: 8px; margin-bottom: 12px; }
.search-lock { display: grid; grid-template-columns: minmax(0, 1fr) 32px; align-items: center; gap: 8px; }
.lock-button { width: 32px; min-width: 32px; height: 32px; padding: 0; }
.lock-button.active { color: var(--vc-accent-strong); border-color: color-mix(in srgb, var(--vc-accent) 62%, var(--vc-border)); background: var(--vc-accent-soft); }
.event-list {
  min-height: 0;
  flex: 1;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
  touch-action: pan-y;
  scrollbar-gutter: stable;
  border: 1px solid var(--vc-border);
  border-radius: 6px;
}
.event-row { min-height: 74px; gap: 16px; padding: 10px 12px; border-bottom: 1px solid var(--vc-border); background: var(--vc-surface); }
.event-row:last-child { border-bottom: 0; }
.event-main { min-width: 0; }
.event-actions, .event-key { gap: 8px; }
.saved-tag { color: var(--vc-accent-strong) !important; border-color: color-mix(in srgb, var(--vc-accent) 62%, var(--vc-border)) !important; background: var(--vc-accent-soft) !important; }
.play-button { width: 32px; min-width: 32px; height: 32px; padding: 0; border-radius: 4px !important; }
.event-key code { color: var(--vc-accent); font-size: 13px; }
.event-source, .event-meta { overflow: hidden; margin-top: 5px; text-overflow: ellipsis; white-space: nowrap; }
.empty-state { padding: 36px 16px; color: var(--vc-muted); text-align: center; }
@media (max-width: 760px) { .toolbar { grid-template-columns: 1fr; } .event-row { align-items: flex-start; flex-direction: column; } }
</style>
