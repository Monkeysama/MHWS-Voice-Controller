<script setup lang="ts">
import {Delete, VideoPlay} from '@element-plus/icons-vue';
import {useI18n} from 'vue-i18n';
import type {AudioAction, AudioCandidate} from '@/types';
import {audioActionKey, audioActionLabel} from '@/utils/audioActions';

const props = defineProps<{
  candidate: AudioCandidate;
  observedActions: AudioAction[];
  durationMs?: number;
  index: number;
  count: number;
  busy: boolean;
}>();
const emit = defineEmits<{
  update: [index: number, patch: Record<string, unknown>];
  remove: [index: number];
  test: [index: number];
}>();
const {t} = useI18n();

function formatAction(action: AudioAction) {
  return audioActionLabel(action, {
    controller: t('action.controller'), category: t('action.category'), action: t('action.id'),
  });
}

function updateAction(key: string) { update({actionKey: key}); }

function update(patch: Record<string, unknown>) {
  emit('update', props.index, patch);
}

function updateNumber(field: 'weight' | 'volume' | 'speed' | 'maxDurationMs', value: number | undefined) {
  if (value !== undefined) update({[field]: value});
}

const updateWeight = (value: number | undefined) => updateNumber('weight', value);
const updateVolume = (value: number | undefined) => updateNumber('volume', value);
const updateSpeed = (value: number | undefined) => updateNumber('speed', value);
const updateDuration = (value: number | undefined) => updateNumber('maxDurationMs', value);
function formatDuration(durationMs?: number) {
  return durationMs && durationMs > 0
    ? t('common.seconds', {value: (durationMs / 1000).toFixed(2)})
    : t('common.durationUnknown');
}
</script>

<template>
  <div class="candidate-editor">
    <div class="candidate-file">
      <span class="candidate-index">{{ index + 1 }}</span>
      <code :title="candidate.file">{{ candidate.file }}</code>
      <div class="candidate-actions">
        <span class="candidate-duration">{{ formatDuration(durationMs) }}</span>
        <el-tooltip :content="t('candidate.preview')" placement="top">
          <el-button
            :icon="VideoPlay"
            circle
            text
            type="primary"
            :disabled="busy"
            :aria-label="t('candidate.preview')"
            @click="emit('test', index)"
          />
        </el-tooltip>
        <el-tooltip :content="t('candidate.remove')" placement="top">
          <el-button
            :icon="Delete"
            circle
            text
            type="danger"
            :disabled="busy || count <= 1"
            :aria-label="t('candidate.remove')"
            @click="emit('remove', index)"
          />
        </el-tooltip>
      </div>
    </div>
    <div class="candidate-fields">
      <label>
        <span>{{ t('candidate.weight') }}</span>
        <el-input-number :model-value="candidate.weight ?? 1" :min="0.01" :max="1000000" :step="0.25" controls-position="right" @change="updateWeight" />
      </label>
      <label>
        <span>{{ t('candidate.volume') }}</span>
        <el-input-number :model-value="candidate.volume ?? 1.5" :min="0" :max="5" :step="0.05" :precision="2" controls-position="right" @change="updateVolume" />
      </label>
      <label>
        <span>{{ t('candidate.speed') }}</span>
        <el-input-number :model-value="candidate.speed ?? 1" :min="0.1" :max="8" :step="0.05" :precision="2" controls-position="right" @change="updateSpeed" />
      </label>
      <label>
        <span>{{ t('candidate.maxDuration') }}</span>
        <el-input-number :model-value="candidate.maxDurationMs ?? 0" :min="0" :max="3600000" :step="100" controls-position="right" @change="updateDuration" />
      </label>
      <label>
        <span>{{ t('action.id') }}</span>
        <el-select :model-value="candidate.action ? audioActionKey(candidate.action) : ''" :empty-values="[null, undefined]" :disabled="busy" @change="updateAction">
          <el-option :label="t('action.all')" value="" />
          <el-option v-for="action in observedActions" :key="audioActionKey(action)" :label="formatAction(action)" :value="audioActionKey(action)" />
        </el-select>
      </label>
    </div>
  </div>
</template>

<style scoped>
.candidate-editor { padding: 11px 12px; border: 1px solid var(--vc-border); border-radius: 5px; background: var(--vc-bg-soft); }
.candidate-file { display: grid; grid-template-columns: 24px minmax(0, 1fr) auto; align-items: center; gap: 8px; }
.candidate-index { display: grid; width: 22px; height: 22px; place-items: center; border-radius: 4px; background: var(--vc-accent-soft); color: var(--vc-accent); font-size: 11px; font-weight: 700; }
.candidate-file code { overflow: hidden; color: var(--vc-text); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }
.candidate-actions { display: grid; grid-template-columns: auto 32px 32px; align-items: center; gap: 8px; }
.candidate-actions :deep(.el-button) { width: 32px; height: 32px; margin: 0; padding: 0; }
.candidate-duration { display: flex; height: 32px; align-items: center; color: var(--vc-muted); white-space: nowrap; }
.candidate-fields { display: grid; grid-template-columns: repeat(5, minmax(120px, 1fr)); gap: 9px; margin-top: 10px; }
.candidate-fields label { min-width: 0; }
.candidate-fields label > span { display: block; margin-bottom: 5px; color: var(--vc-muted); font-size: 11px; }
.candidate-fields :deep(.el-input-number) { width: 100%; }
@media (max-width: 900px) { .candidate-fields { grid-template-columns: repeat(2, minmax(120px, 1fr)); } }
@media (max-width: 560px) { .candidate-fields { grid-template-columns: 1fr; } }
</style>
