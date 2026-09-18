<script setup lang="ts">
import {CircleCheck, Warning} from '@element-plus/icons-vue';
import type {DeepReadonly} from 'vue';
import type {ControllerState} from '@/types';

const props = defineProps<{
  state: DeepReadonly<ControllerState> | null;
  connected: boolean;
  loading: boolean;
  error: string;
}>();
</script>

<template>
  <section class="status-panel" aria-label="运行状态">
    <header class="section-heading">
      <div>
        <span class="eyebrow">运行状态</span>
        <h2>捕获与替换管线</h2>
      </div>
      <el-tag :class="['connection-tag', {'connection-tag--offline': !connected}]" effect="plain">
        <CircleCheck v-if="connected" class="status-icon" />
        <Warning v-else class="status-icon" />
        {{ connected ? 'REFF 已连接' : '等待连接' }}
      </el-tag>
    </header>

    <el-alert v-if="error" :title="error" type="error" :closable="false" show-icon />
    <div v-if="state" class="metric-grid">
      <div class="metric"><span>Hook</span><strong>{{ state.status.hooksReady ? '3 / 3' : '未就绪' }}</strong></div>
      <div class="metric"><span>捕获事件</span><strong>{{ state.status.totalCaptured }}</strong></div>
      <div class="metric"><span>语音索引</span><strong>{{ state.status.voiceIndexReady ? '就绪' : '构建中' }}</strong></div>
      <div class="metric"><span>外部音频</span><strong>{{ state.status.catalogCount }}</strong></div>
      <div class="metric"><span>规则</span><strong>{{ state.status.ruleCount }}</strong></div>
      <div class="metric"><span>当前模式</span><strong>{{ state.status.mode }}</strong></div>
      <div class="metric"><span>音频提交</span><strong>{{ state.status.submitted }}</strong></div>
      <div class="metric"><span>队列丢弃</span><strong>{{ state.status.droppedPending }}</strong></div>
    </div>
    <el-alert v-else-if="loading" title="正在读取 VoiceController 状态" type="info" :closable="false" />
  </section>
</template>

<style scoped>
.status-panel { padding: 18px 20px; border-bottom: 1px solid var(--vc-border); }
.section-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 14px; }
.section-heading h2 { margin: 3px 0 0; font-size: 17px; letter-spacing: 0; }
.eyebrow { color: var(--vc-muted); font-size: 12px; }
.status-icon { width: 13px; height: 13px; margin-right: 4px; vertical-align: -2px; }
.connection-tag { color: var(--vc-accent-strong) !important; border-color: color-mix(in srgb, var(--vc-accent) 62%, var(--vc-border)) !important; background: var(--vc-accent-soft) !important; }
.connection-tag--offline { color: var(--vc-muted) !important; border-color: var(--vc-border) !important; background: var(--vc-bg-soft) !important; }
.metric-grid { display: grid; grid-template-columns: repeat(4, minmax(110px, 1fr)); gap: 1px; overflow: hidden; border: 1px solid var(--vc-border); border-radius: 6px; background: var(--vc-border); }
.metric { display: flex; min-height: 62px; flex-direction: column; justify-content: center; padding: 10px 13px; background: var(--vc-surface); }
.metric span { color: var(--vc-muted); font-size: 12px; }
.metric strong { margin-top: 5px; font-size: 16px; font-weight: 650; }
@media (max-width: 760px) { .metric-grid { grid-template-columns: repeat(2, minmax(100px, 1fr)); } }
</style>
