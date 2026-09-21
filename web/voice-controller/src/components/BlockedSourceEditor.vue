<script setup lang="ts">
import {shallowRef} from 'vue';
import {useI18n} from 'vue-i18n';
import {Delete, Plus} from '@element-plus/icons-vue';
const props = defineProps<{prefixes: readonly string[]; busy: boolean}>();
const emit = defineEmits<{update: [payload: Record<string, unknown>]}>();
const value = shallowRef('');
const {t} = useI18n();
function add() { const item = value.value.trim(); if (!item || props.prefixes.includes(item)) return; emit('update', {prefixes: [...props.prefixes, item]}); value.value = ''; }
function remove(item: string) { emit('update', {prefixes: props.prefixes.filter(prefix => prefix !== item)}); }
</script>
<template>
  <section class="blocked-editor">
    <header class="section-heading"><div><span class="eyebrow">{{ t('blocked.eyebrow') }}</span><h2>{{ t('blocked.title') }}</h2></div></header>
    <p class="description">{{ t('blocked.description') }}</p>
    <div class="blocked-add"><el-input v-model="value" :placeholder="t('blocked.placeholder')" @keyup.enter="add" /><el-button :icon="Plus" :disabled="busy || !value.trim()" @click="add">{{ t('blocked.add') }}</el-button></div>
    <div v-for="prefix in prefixes" :key="prefix" class="blocked-row"><code>{{ prefix }}</code><el-button :icon="Delete" text type="danger" :disabled="busy" :aria-label="t('blocked.remove')" @click="remove(prefix)" /></div>
    <div v-if="prefixes.length === 0" class="empty-state">{{ t('blocked.empty') }}</div>
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
