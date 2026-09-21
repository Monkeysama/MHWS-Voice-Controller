<script setup lang="ts">
import {computed} from 'vue';
import {useI18n} from 'vue-i18n';
import type {DeepReadonly} from 'vue';
import type {ControllerState} from '@/types';

const props = defineProps<{
  state: DeepReadonly<ControllerState> | null;
  loading: boolean;
  error: string;
}>();
const {t} = useI18n();

const capturedCount = computed(() => props.state?.status.totalCaptured ?? 0);
const savedCount = computed(() => props.state?.savedEvents.length ?? 0);
const groupCount = computed(() => props.state?.config?.groups.length ?? 0);
const blockedCount = computed(() => props.state?.config?.blockedSourcePrefixes?.length ?? 0);
</script>

<template>
  <section class="status-panel" :aria-label="t('status.title')">
    <header class="section-heading">
      <span class="eyebrow">{{ t('status.title') }}</span>
    </header>

    <el-alert v-if="error" :title="error" type="error" :closable="false" show-icon />
    <div v-if="state" class="metric-grid">
      <div class="metric"><span>{{ t('status.captured') }}</span><strong>{{ capturedCount }}</strong></div>
      <div class="metric"><span>{{ t('status.saved') }}</span><strong>{{ savedCount }}</strong></div>
      <div class="metric"><span>{{ t('status.groups') }}</span><strong>{{ groupCount }}</strong></div>
      <div class="metric"><span>{{ t('status.blocked') }}</span><strong>{{ blockedCount }}</strong></div>
    </div>
    <el-alert v-else-if="loading" :title="t('status.loading')" type="info" :closable="false" />
  </section>
</template>

<style scoped>
.status-panel { padding: 18px 20px; border-bottom: 1px solid var(--vc-border); }
.section-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 14px; }
.eyebrow { color: var(--vc-muted); font-size: 12px; }
.metric-grid { display: grid; grid-template-columns: repeat(4, minmax(110px, 1fr)); gap: 1px; overflow: hidden; border: 1px solid var(--vc-border); border-radius: 6px; background: var(--vc-border); }
.metric { display: flex; min-height: 62px; flex-direction: column; justify-content: center; padding: 10px 13px; background: var(--vc-surface); }
.metric span { color: var(--vc-muted); font-size: 12px; }
.metric strong { margin-top: 5px; font-size: 16px; font-weight: 650; }
@media (max-width: 760px) { .metric-grid { grid-template-columns: repeat(2, minmax(100px, 1fr)); } }
</style>
