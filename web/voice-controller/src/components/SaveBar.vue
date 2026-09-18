<script setup lang="ts">
import {DocumentChecked, Refresh} from '@element-plus/icons-vue';

defineProps<{dirty: boolean; busy: boolean}>();
const emit = defineEmits<{save: []; refresh: []}>();
</script>

<template>
  <footer class="save-bar">
    <div class="save-state">
      <i :class="{dirty}" />
      <span>{{ dirty ? '有未保存修改' : '配置已同步' }}</span>
    </div>
    <div class="actions">
      <el-button :icon="Refresh" :disabled="busy" @click="emit('refresh')">刷新</el-button>
      <el-button type="primary" :icon="DocumentChecked" :loading="busy" :disabled="!dirty" @click="emit('save')">
        保存配置
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
</style>
