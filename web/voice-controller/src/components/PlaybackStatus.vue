<script setup lang="ts">
import {computed} from 'vue';
import type {PlaybackStatus} from '@/types';

const props = defineProps<{status?: PlaybackStatus; error?: string}>();
const labels: Record<PlaybackStatus, string> = {
  trying: '尝试播放中',
  success: '播放成功',
  failed: '播放失败',
};
const label = computed(() => props.status ? labels[props.status] : '');
const tooltip = computed(() => props.status === 'failed' && props.error
  ? `播放失败：${props.error}`
  : label.value);
</script>

<template>
  <el-tooltip v-if="status" :content="tooltip">
    <span class="playback-status" :class="`is-${status}`">{{ label }}</span>
  </el-tooltip>
</template>

<style scoped>
.playback-status {
  display: inline-grid;
  width: 78px;
  height: 24px;
  place-items: center;
  border: 1px solid var(--vc-border);
  border-radius: 4px;
  color: var(--vc-muted);
  background: var(--vc-bg-soft);
  font-size: 11px;
  white-space: nowrap;
}
.is-trying { color: var(--vc-text); border-color: color-mix(in srgb, var(--vc-muted) 55%, var(--vc-border)); }
.is-success { color: var(--vc-accent-strong); border-color: color-mix(in srgb, var(--vc-accent) 62%, var(--vc-border)); background: var(--vc-accent-soft); }
.is-failed { color: var(--vc-danger); border-color: color-mix(in srgb, var(--vc-danger) 58%, var(--vc-border)); background: color-mix(in srgb, var(--vc-danger) 10%, var(--vc-surface)); }
</style>
