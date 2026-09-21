<script setup lang="ts">
import {computed} from 'vue';
import {useI18n} from 'vue-i18n';
import type {PlaybackStatus} from '@/types';

const props = defineProps<{status?: PlaybackStatus; error?: string}>();
const {t} = useI18n();
const label = computed(() => props.status ? t(`playback.${props.status}`) : '');
const tooltip = computed(() => props.status === 'failed' && props.error
  ? t('playback.failedDetail', {error: props.error})
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
