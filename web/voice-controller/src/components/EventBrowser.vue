<script setup lang="ts">
import {computed, shallowRef, watch} from 'vue';
import {CollectionTag, Search, VideoPlay} from '@element-plus/icons-vue';
import type {AudioEvent} from '@/types';

const props = defineProps<{events: AudioEvent[]; savedKeys: Set<string>; busy: boolean}>();
const emit = defineEmits<{
  save: [payload: {stableKey: string}];
  play: [payload: {stableKey: string}];
}>();
const query = shallowRef('');
const category = shallowRef('all');
const categoryStartSequence = shallowRef(0);
const categoryLabels: Record<string, string> = {player: '玩家', npc: 'NPC', otomo: '坐骑', weapon: '武器', unknown: '未分类'};
function formatDuration(durationMs?: number) { return durationMs ? `${(durationMs / 1000).toFixed(2)} 秒` : '时长待获取'; }
watch(category, () => {
  categoryStartSequence.value = Math.max(0, ...props.events.map(event => event.sequence ?? 0));
});
const visibleEvents = computed(() => {
  const needle = query.value.trim().toLowerCase();
  return [...props.events].reverse().filter(event => {
    if (category.value !== 'all' && event.category !== category.value) return false;
    if ((event.sequence ?? 0) <= categoryStartSequence.value) return false;
    return !needle || [event.stableKey, event.sourcePath, event.sourceObject, event.origin]
      .some(value => String(value ?? '').toLowerCase().includes(needle));
  }).slice(0, 120);
});
</script>

<template>
  <section class="event-browser">
    <header class="section-heading">
      <div><span class="eyebrow">自然游戏流程</span><h2>近期音频事件</h2></div>
      <el-tag effect="plain">{{ visibleEvents.length }} 条</el-tag>
    </header>
    <div class="toolbar">
      <el-input v-model="query" :prefix-icon="Search" clearable placeholder="事件键、来源或资源路径" />
      <el-select v-model="category" aria-label="事件类别">
        <el-option label="全部类别" value="all" />
        <el-option label="玩家" value="player" />
        <el-option label="NPC" value="npc" />
        <el-option label="坐骑" value="otomo" />
        <el-option label="武器" value="weapon" />
        <el-option label="未分类" value="unknown" />
      </el-select>
    </div>
    <div class="event-list">
      <article v-for="event in visibleEvents" :key="`${event.stableKey}:${event.sequence}`" class="event-row">
        <div class="event-main">
          <div class="event-key">
            <code>{{ event.stableKey }}</code>
            <el-tag size="small" effect="plain" disable-transitions>{{ categoryLabels[event.category || 'unknown'] || event.category }}</el-tag>
            <el-tag v-if="(event.triggerCount ?? 1) > 1" size="small" type="warning" effect="plain" disable-transitions>触发 {{ event.triggerCount }} 次</el-tag>
          </div>
          <div class="event-source">{{ event.sourcePath || event.sourceObject || '未知来源' }}</div>
          <div class="event-meta">最近 #{{ event.sequence }} · {{ event.origin || 'unknown' }} · {{ formatDuration(event.durationMs) }}</div>
        </div>
        <div class="event-actions">
          <el-tooltip :content="event.replayable ? '播放游戏内音频' : '当前会话无法解析此音频'">
            <el-button class="play-button" :icon="VideoPlay" :disabled="busy || !event.replayable" aria-label="播放游戏内音频" @click="emit('play', {stableKey: event.stableKey})" />
          </el-tooltip>
          <el-tag v-if="savedKeys.has(event.stableKey)" class="saved-tag" effect="plain">已收藏</el-tag>
          <el-button v-else :icon="CollectionTag" :disabled="busy" @click="emit('save', {stableKey: event.stableKey})">收藏</el-button>
        </div>
      </article>
      <div v-if="visibleEvents.length === 0" class="empty-state">没有匹配的事件</div>
    </div>
  </section>
</template>

<style scoped>
.event-browser { display: flex; min-width: 0; height: 100%; flex-direction: column; padding: 18px 20px; }
.section-heading, .event-row, .event-actions, .event-key { display: flex; align-items: center; }
.section-heading, .event-row { justify-content: space-between; }
.section-heading { gap: 12px; margin-bottom: 14px; }
.section-heading h2 { margin: 3px 0 0; font-size: 17px; letter-spacing: 0; }
.eyebrow, .event-source, .event-meta { color: var(--vc-muted); font-size: 12px; }
.toolbar { display: grid; grid-template-columns: minmax(220px, 1fr) 150px; gap: 8px; margin-bottom: 12px; }
.event-list {
  min-height: 0;
  flex: 1;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
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
