<script setup lang="ts">
import {shallowRef} from 'vue';
import {Delete, Plus} from '@element-plus/icons-vue';
import CandidateEditor from './CandidateEditor.vue';
import type {ReplaceStrategy, RuleMode, VoiceRule} from '@/types';

const props = defineProps<{
  groupId: string;
  rule: VoiceRule;
  catalogFiles: string[];
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
      <span class="rule-state" :class="{enabled: rule.enabled !== false}" />
      <span class="rule-name">{{ rule.id }}</span>
      <code>{{ rule.eventId }}:{{ rule.triggerId }}</code>
      <el-tag size="small" effect="plain">{{ rule.mode || defaultMode }}</el-tag>
    </summary>

    <div class="rule-body">
      <div class="rule-controls">
        <label class="switch-field">
          <span>启用</span>
          <el-switch :model-value="rule.enabled !== false" :disabled="busy" @change="setEnabled" />
        </label>
        <label>
          <span>模式</span>
          <el-select :model-value="rule.mode || defaultMode" :disabled="busy" @change="setMode">
            <el-option label="观察" value="observe" />
            <el-option label="叠加" value="overlay" />
            <el-option label="替换" value="replace" />
          </el-select>
        </label>
        <label v-if="(rule.mode || defaultMode) === 'replace'">
          <span>抑制策略</span>
          <el-select :model-value="rule.replaceStrategy || defaultStrategy" :disabled="busy" @change="setStrategy">
            <el-option label="跳过原始请求" value="skip_original" />
            <el-option label="停止 PlayingId" value="stop_playing_id" />
          </el-select>
        </label>
        <label>
          <span>冷却 ms</span>
          <el-input-number :model-value="rule.cooldownMs ?? 0" :min="0" :max="3600000" :step="50" controls-position="right" :disabled="busy" @change="setCooldown" />
        </label>
        <label>
          <span>最大并发</span>
          <el-input-number :model-value="rule.maxConcurrent ?? 1" :min="1" :max="32" :step="1" controls-position="right" :disabled="busy" @change="setConcurrent" />
        </label>
      </div>

      <div class="candidate-list">
        <CandidateEditor
          v-for="(candidate, index) in rule.candidates"
          :key="`${candidate.file}:${index}`"
          :candidate="candidate"
          :index="index"
          :count="rule.candidates.length"
          :busy="busy"
          @update="updateCandidate"
          @remove="removeCandidate"
          @test="testCandidate"
        />
      </div>

      <div class="rule-actions">
        <el-select v-model="selectedFile" filterable clearable placeholder="添加目录中的音频">
          <el-option v-for="file in catalogFiles" :key="file" :label="file" :value="file" />
        </el-select>
        <el-button :icon="Plus" :disabled="busy || !selectedFile" @click="addCandidate">添加候选</el-button>
        <el-tooltip content="删除规则" placement="top">
          <el-button :icon="Delete" type="danger" plain :disabled="busy" @click="emit('removeRule', ruleRef())">删除规则</el-button>
        </el-tooltip>
      </div>
    </div>
  </details>
</template>

<style scoped>
.rule-card { overflow: hidden; border: 1px solid var(--vc-border); border-radius: 6px; background: var(--vc-surface); }
.rule-card + .rule-card { margin-top: 9px; }
.rule-card summary { display: grid; min-height: 48px; grid-template-columns: 10px minmax(120px, .7fr) minmax(180px, 1fr) auto; align-items: center; gap: 10px; padding: 0 13px; cursor: pointer; list-style: none; }
.rule-card summary::-webkit-details-marker { display: none; }
.rule-state { width: 8px; height: 8px; border-radius: 50%; background: #7c8796; }
.rule-state.enabled { background: #5eac87; }
.rule-name { overflow: hidden; font-weight: 650; text-overflow: ellipsis; white-space: nowrap; }
.rule-card code { color: var(--vc-muted); font-size: 12px; }
.rule-body { padding: 12px; border-top: 1px solid var(--vc-border); }
.rule-controls { display: grid; grid-template-columns: 90px repeat(4, minmax(125px, 1fr)); gap: 9px; }
.rule-controls label > span { display: block; margin-bottom: 5px; color: var(--vc-muted); font-size: 11px; }
.rule-controls :deep(.el-select), .rule-controls :deep(.el-input-number) { width: 100%; }
.switch-field { display: flex; flex-direction: column; align-items: flex-start; }
.candidate-list { display: grid; gap: 8px; margin-top: 12px; }
.rule-actions { display: grid; grid-template-columns: minmax(220px, 1fr) auto auto; gap: 8px; margin-top: 11px; }
@media (max-width: 900px) { .rule-controls { grid-template-columns: repeat(2, minmax(125px, 1fr)); } }
@media (max-width: 620px) { .rule-card summary { grid-template-columns: 10px 1fr auto; } .rule-card summary code { grid-column: 2 / -1; } .rule-controls, .rule-actions { grid-template-columns: 1fr; } }
</style>
