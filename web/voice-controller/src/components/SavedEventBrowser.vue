<script setup lang="ts">
import {computed, shallowRef} from 'vue';
import {Delete, Search, VideoPlay} from '@element-plus/icons-vue';
import type {AudioEvent} from '@/types';
import PlaybackStatus from '@/components/PlaybackStatus.vue';

const props = defineProps<{events: AudioEvent[]; busy: boolean}>();
const emit = defineEmits<{
  play: [payload: {stableKey: string}];
  remove: [payload: {stableKey: string}];
}>();
const query = shallowRef('');
const visibleEvents = computed(() => {
  const needle = query.value.trim().toLowerCase();
  return props.events.filter(event => !needle || [event.stableKey, event.sourcePath, event.sourceObject]
    .some(value => String(value ?? '').toLowerCase().includes(needle)));
});
function formatDuration(durationMs?: number) { return durationMs ? `${(durationMs / 1000).toFixed(2)} 秒` : '时长待获取'; }
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
    <header class="section-heading"><div><span class="eyebrow">永久记录</span><h2>保存列表</h2></div><el-tag effect="plain">{{ events.length }} 条</el-tag></header>
    <el-input v-model="query" class="search" :prefix-icon="Search" clearable placeholder="搜索收藏的游戏内音频" />
    <div class="saved-list" @wheel="handleListWheel">
      <article v-for="event in visibleEvents" :key="event.stableKey" class="saved-row">
        <div class="saved-main"><code>{{ event.stableKey }}</code><span>{{ event.sourcePath || event.sourceObject || '未知来源' }}</span><small>{{ formatDuration(event.durationMs) }} · 收藏于 {{ event.savedAt || '未知时间' }}</small></div>
        <div class="actions">
          <PlaybackStatus :status="event.playbackStatus" :error="event.playbackError" />
          <el-tooltip :content="event.replayable ? '播放游戏内音频' : '播放时尝试从当前场景解析音频'">
            <el-button class="play-button" :icon="VideoPlay" :disabled="busy || event.playbackStatus === 'trying'" aria-label="播放游戏内音频" @click="emit('play', {stableKey: event.stableKey})" />
          </el-tooltip>
          <el-tooltip content="删除收藏；被规则引用时会拒绝删除">
            <el-button :icon="Delete" circle text type="danger" :disabled="busy" aria-label="删除收藏" @click="emit('remove', {stableKey: event.stableKey})" />
          </el-tooltip>
        </div>
      </article>
      <div v-if="visibleEvents.length === 0" class="empty-state">尚未收藏游戏内音频</div>
    </div>
  </section>
</template>

<style scoped>
.saved-browser { display: flex; min-width: 0; height: 100%; flex-direction: column; padding: 18px 20px; }
.section-heading, .saved-row, .actions { display: flex; align-items: center; }
.section-heading, .saved-row { justify-content: space-between; gap: 14px; }
.section-heading { margin-bottom: 12px; }
.section-heading h2 { margin: 3px 0 0; font-size: 17px; letter-spacing: 0; }
.eyebrow, .saved-main span, .saved-main small { color: var(--vc-muted); font-size: 12px; }
.search { margin-bottom: 12px; }
.saved-list { min-height: 0; flex: 1; overflow-x: hidden; overflow-y: auto; overscroll-behavior: contain; scrollbar-gutter: stable; touch-action: pan-y; border: 1px solid var(--vc-border); border-radius: 6px; }
.saved-row { min-height: 72px; padding: 10px 12px; border-bottom: 1px solid var(--vc-border); background: var(--vc-surface); }
.saved-row:last-child { border-bottom: 0; }
.saved-main { display: grid; min-width: 0; gap: 4px; }
.saved-main code { color: var(--vc-accent); }
.saved-main span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.actions { gap: 6px; }
.play-button { width: 32px; min-width: 32px; height: 32px; padding: 0; border-radius: 4px !important; }
.empty-state { padding: 36px 16px; color: var(--vc-muted); text-align: center; }
</style>
