<script setup lang="ts">
import {computed, shallowRef} from 'vue';
import {useI18n} from 'vue-i18n';
import {ArrowRight, Delete, Plus} from '@element-plus/icons-vue';
import CandidateEditor from './CandidateEditor.vue';
import type {CatalogEntry, ReplaceStrategy, RuleMode, VoiceRule} from '@/types';

const props = defineProps<{
  groupId: string;
  rule: VoiceRule;
  eventNote?: string;
  catalogEntries: CatalogEntry[];
  defaultMode: RuleMode;
  defaultStrategy: ReplaceStrategy;
  busy: boolean;
}>();
const emit = defineEmits<{
  updateRule: [payload: Record<string, unknown>];
  removeRule: [payload: Record<string, unknown>];
  addCandidate: [payload: Record<string, unknown>];
  updateCandidate: [payload: Record<string, unknown>];
  removeCandidate: [payload: Record<string, unknown>];
  testCandidate: [payload: Record<string, unknown>];
}>();

const selectedFile = shallowRef('');
const {t} = useI18n();
const catalogByFile = computed(() => new Map(
  props.catalogEntries.map(entry => [entry.file.toLowerCase(), entry] as const),
));

function catalogDuration(file: string) {
  return catalogByFile.value.get(file.toLowerCase())?.durationMs;
}

function catalogLabel(entry: CatalogEntry) {
  const duration = entry.durationMs && entry.durationMs > 0
    ? t('common.seconds', {value: (entry.durationMs / 1000).toFixed(2)})
    : t('common.durationUnknown');
  return `${entry.file} · ${duration}`;
}

function modeLabel(mode?: RuleMode) {
  return t(`common.${mode ?? props.defaultMode}`);
}

function ruleRef() {
  return {groupId: props.groupId, ruleId: props.rule.id};
}

function updateRule(patch: Record<string, unknown>) {
  emit('updateRule', {...ruleRef(), ...patch});
}

function addCandidate() {
  if (!selectedFile.value) return;
  emit('addCandidate', {...ruleRef(), file: selectedFile.value, weight: 1});
  selectedFile.value = '';
}

function updateCandidate(index: number, patch: Record<string, unknown>) {
  emit('updateCandidate', {...ruleRef(), candidateIndex: index + 1, ...patch});
}

function removeCandidate(index: number) {
  emit('removeCandidate', {...ruleRef(), candidateIndex: index + 1});
}

function testCandidate(index: number) {
  emit('testCandidate', {...ruleRef(), candidateIndex: index + 1});
}

function setEnabled(value: string | number | boolean) {
  updateRule({enabled: value === true});
}

function setMode(value: string) {
  updateRule({mode: value});
}

function setStrategy(value: string) {
  updateRule({replaceStrategy: value});
}

function setInteger(field: 'cooldownMs' | 'maxConcurrent', value: number | undefined) {
  if (value !== undefined) updateRule({[field]: value});
}

const setCooldown = (value: number | undefined) => setInteger('cooldownMs', value);
const setConcurrent = (value: number | undefined) => setInteger('maxConcurrent', value);
</script>

<template>
  <details class="rule-card">
    <summary>
      <span class="rule-toggle" aria-hidden="true"><ArrowRight /></span>
      <el-switch
        class="rule-enabled"
        :model-value="rule.enabled !== false"
        :disabled="busy"
        :aria-label="t('common.enabled')"
        @click.stop
        @change="setEnabled"
      />
      <span class="rule-name">{{ eventNote || rule.id }}</span>
      <code>{{ rule.eventId }}:{{ rule.triggerId }}</code>
      <el-tag size="small" effect="plain">{{ modeLabel(rule.mode) }}</el-tag>
    </summary>

    <div class="rule-body">
      <div class="rule-controls">
        <label>
          <span>{{ t('common.mode') }}</span>
          <el-select :model-value="rule.mode || defaultMode" :disabled="busy" @change="setMode">
            <el-option :label="t('common.overlay')" value="overlay" />
            <el-option :label="t('common.replace')" value="replace" />
          </el-select>
        </label>
        <label v-if="(rule.mode || defaultMode) === 'replace'">
          <span>{{ t('rule.strategy') }}</span>
          <el-select :model-value="rule.replaceStrategy || defaultStrategy" :disabled="busy" @change="setStrategy">
            <el-option :label="t('rule.skipOriginal')" value="skip_original" />
            <el-option :label="t('rule.stopPlayingId')" value="stop_playing_id" />
          </el-select>
        </label>
        <label>
          <span>{{ t('rule.cooldown') }}</span>
          <el-input-number :model-value="rule.cooldownMs ?? 0" :min="0" :max="3600000" :step="50" controls-position="right" :disabled="busy" @change="setCooldown" />
        </label>
        <label>
          <span>{{ t('rule.maxConcurrent') }}</span>
          <el-input-number :model-value="rule.maxConcurrent ?? 1" :min="1" :max="32" :step="1" controls-position="right" :disabled="busy" @change="setConcurrent" />
        </label>
      </div>

      <div class="candidate-list">
        <CandidateEditor
          v-for="(candidate, index) in rule.candidates"
          :key="`${candidate.file}:${index}`"
          :candidate="candidate"
          :duration-ms="catalogDuration(candidate.file)"
          :index="index"
          :count="rule.candidates.length"
          :busy="busy"
          @update="updateCandidate"
          @remove="removeCandidate"
          @test="testCandidate"
        />
      </div>

      <div class="rule-actions">
        <el-select v-model="selectedFile" filterable clearable :placeholder="t('rule.addAudio')">
          <el-option v-for="entry in catalogEntries" :key="entry.file" :label="catalogLabel(entry)" :value="entry.file" />
        </el-select>
        <el-button :icon="Plus" :disabled="busy || !selectedFile" @click="addCandidate">{{ t('rule.addCandidate') }}</el-button>
        <el-tooltip :content="t('rule.remove')" placement="top">
          <el-button :icon="Delete" type="danger" plain :disabled="busy" @click="emit('removeRule', ruleRef())">{{ t('rule.remove') }}</el-button>
        </el-tooltip>
      </div>
    </div>
  </details>
</template>

<style scoped>
.rule-card { overflow: hidden; border: 1px solid var(--vc-border); border-radius: 6px; background: var(--vc-surface); transition: border-color 120ms ease, background-color 120ms ease; }
.rule-card + .rule-card { margin-top: 9px; }
.rule-card summary { display: grid; min-height: 56px; grid-template-columns: 40px auto minmax(120px, .7fr) minmax(180px, 1fr) auto; align-items: center; gap: 10px; padding: 7px 10px; cursor: pointer; list-style: none; }
.rule-card summary::-webkit-details-marker { display: none; }
.rule-card summary:hover, .rule-card summary:focus-visible { background: var(--vc-accent-soft); outline: none; }
.rule-card:has(> summary:hover), .rule-card:has(> summary:focus-visible) { border-color: var(--vc-accent); }
.rule-toggle { display: grid; width: 40px; height: 40px; place-items: center; color: var(--vc-muted); font-size: 14px; transition: color 120ms ease, transform 120ms ease; }
.rule-toggle > svg { width: 14px; height: 14px; }
.rule-card[open] > summary .rule-toggle { transform: rotate(90deg); }
.rule-card summary:hover .rule-toggle, .rule-card summary:focus-visible .rule-toggle { color: var(--vc-accent-strong); }
.rule-enabled { cursor: default; }
.rule-name { overflow: hidden; font-weight: 650; text-overflow: ellipsis; white-space: nowrap; }
.rule-card code { color: var(--vc-muted); font-size: 12px; }
.rule-body { padding: 12px; border-top: 1px solid var(--vc-border); }
.rule-controls { display: grid; grid-template-columns: repeat(4, minmax(125px, 1fr)); gap: 9px; }
.rule-controls label > span { display: block; margin-bottom: 5px; color: var(--vc-muted); font-size: 11px; }
.rule-controls :deep(.el-select), .rule-controls :deep(.el-input-number) { width: 100%; }
.candidate-list { display: grid; gap: 8px; margin-top: 12px; }
.rule-actions { display: grid; grid-template-columns: minmax(220px, 1fr) auto auto; gap: 8px; margin-top: 11px; }
@media (max-width: 900px) { .rule-controls { grid-template-columns: repeat(2, minmax(125px, 1fr)); } }
@media (max-width: 620px) { .rule-card summary { grid-template-columns: 40px auto 1fr auto; } .rule-card summary code { grid-column: 3 / -1; } .rule-controls, .rule-actions { grid-template-columns: 1fr; } }
</style>
