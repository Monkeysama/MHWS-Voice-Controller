<script setup lang="ts">
import {DocumentChecked, Refresh} from '@element-plus/icons-vue';
import {useI18n} from 'vue-i18n';

defineProps<{dirty: boolean; busy: boolean}>();
const emit = defineEmits<{save: []; reload: []}>();
const {t} = useI18n();
</script>

<template>
  <footer class="save-bar">
    <div class="save-state">
      <i :class="{dirty}" />
      <span>{{ dirty ? t('saveBar.dirty') : t('saveBar.synced') }}</span>
    </div>
    <div class="actions">
      <el-tooltip :content="t('saveBar.reloadHint')" placement="top">
        <el-button :icon="Refresh" :disabled="busy" @click="emit('reload')">{{ t('saveBar.reload') }}</el-button>
      </el-tooltip>
      <el-button class="save-button" type="primary" :icon="DocumentChecked" :loading="busy" :disabled="busy || !dirty" @click="emit('save')">
        {{ t('saveBar.save') }}
      </el-button>
    </div>
  </footer>
</template>

<style scoped>
.save-bar { position: sticky; bottom: 0; z-index: 3; display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 12px 20px; border-top: 1px solid var(--vc-border); background: color-mix(in srgb, var(--vc-bg) 92%, transparent); backdrop-filter: blur(12px); }
.save-state, .actions { display: flex; align-items: center; gap: 9px; }
.save-state { color: var(--vc-muted); font-size: 13px; }
.save-state i { width: 8px; height: 8px; border-radius: 50%; background: #5eac87; }
.save-state i.dirty { background: #e2a93b; }
.save-button.is-disabled { color: var(--vc-muted); border-color: var(--vc-border); background: var(--vc-bg-soft); opacity: .62; }
</style>
