<script setup lang="ts">
import {shallowRef} from 'vue';
import {Delete, Plus} from '@element-plus/icons-vue';
const props = defineProps<{prefixes: readonly string[]; busy: boolean}>();
const emit = defineEmits<{update: [payload: Record<string, unknown>]}>();
const value = shallowRef('');
function add() { const item = value.value.trim(); if (!item || props.prefixes.includes(item)) return; emit('update', {prefixes: [...props.prefixes, item]}); value.value = ''; }
function remove(item: string) { emit('update', {prefixes: props.prefixes.filter(prefix => prefix !== item)}); }
</script>
<template>
  <section class="blocked-editor">
    <header class="section-heading"><div><span class="eyebrow">捕获过滤</span><h2>屏蔽列表</h2></div></header>
    <p class="description">匹配 SourceObject 前缀的事件不会进入近期事件、分类统计、重放或规则匹配。</p>
    <div class="blocked-add"><el-input v-model="value" placeholder="输入 SourceObject 前缀" @keyup.enter="add" /><el-button :icon="Plus" :disabled="busy || !value.trim()" @click="add">添加</el-button></div>
    <div v-for="prefix in prefixes" :key="prefix" class="blocked-row"><code>{{ prefix }}</code><el-button :icon="Delete" text type="danger" :disabled="busy" aria-label="删除屏蔽项" @click="remove(prefix)" /></div>
    <div v-if="prefixes.length === 0" class="empty-state">尚未配置屏蔽项</div>
  </section>
</template>
<style scoped>
.blocked-editor { padding: 18px 20px; }
.section-heading { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
.section-heading h2 { margin: 3px 0 0; font-size: 17px; }
.eyebrow, .description, .empty-state { color: var(--vc-muted); font-size: 12px; }
.description { margin: 0 0 14px; }
.blocked-add, .blocked-row { display: flex; align-items: center; gap: 8px; }
.blocked-add { max-width: 620px; margin-bottom: 8px; }
.blocked-row { justify-content: space-between; max-width: 620px; min-height: 36px; border-top: 1px solid var(--vc-border); }
.blocked-row code { overflow: hidden; color: var(--vc-accent); text-overflow: ellipsis; white-space: nowrap; }
.empty-state { padding: 30px 0; }
</style>
