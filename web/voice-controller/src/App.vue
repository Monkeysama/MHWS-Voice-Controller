<script setup lang="ts">
import {computed, shallowRef} from 'vue';
import {REFF_ELEMENT_LOCALES} from '@reff/ui';
import {useI18n} from 'vue-i18n';
import EventBrowser from '@/components/EventBrowser.vue';
import RuleEditor from '@/components/RuleEditor.vue';
import SavedEventBrowser from '@/components/SavedEventBrowser.vue';
import SaveBar from '@/components/SaveBar.vue';
import BlockedSourceEditor from '@/components/BlockedSourceEditor.vue';
import StatusPanel from '@/components/StatusPanel.vue';
import {useVoiceController} from '@/composables/useVoiceController';

const controller = useVoiceController();
const {locale, t} = useI18n();
const elementLocale = computed(() => REFF_ELEMENT_LOCALES[locale.value as 'zh-CN' | 'en-US']);
const activeTab = shallowRef('events');
const defaultMode = computed(() => {
  const mode = controller.state.value?.config?.mode;
  return mode === 'overlay' || mode === 'replace' ? mode : 'replace';
});
const defaultStrategy = computed(() => controller.state.value?.config?.replaceStrategy ?? 'skip_original');
const savedKeys = computed(() => new Set(controller.savedEvents.value.map(event => event.stableKey)));
const visibleEvents = computed(() => controller.events.value);
</script>

<template>
  <el-config-provider :locale="elementLocale">
  <main class="voice-controller-page">
    <StatusPanel
      :state="controller.state.value"
      :loading="controller.loading.value"
      :error="controller.error.value"
    />

    <el-tabs v-model="activeTab" class="workspace-tabs">
      <el-tab-pane :label="t('tabs.recent')" name="events" class="events-pane">
        <EventBrowser
          :events="visibleEvents"
          :saved-keys="savedKeys"
          :busy="controller.busy.value"
          @save="controller.saveEvent"
          @play="controller.playEvent"
          @set-lock="controller.setRecentLock"
        />
      </el-tab-pane>
      <el-tab-pane :label="t('tabs.saved')" name="saved" class="saved-pane">
        <SavedEventBrowser
          :events="controller.savedEvents.value"
          :busy="controller.busy.value"
          @play="controller.playEvent"
          @remove="controller.removeSavedEvent"
          @update-note="controller.updateSavedEventNote"
        />
      </el-tab-pane>
      <el-tab-pane :label="t('tabs.groups')" name="rules" class="rules-pane">
        <RuleEditor
          :groups="controller.groups.value"
          :catalog-entries="controller.catalogEntries.value"
          :saved-events="controller.savedEvents.value"
          :warnings="controller.state.value?.warnings ?? []"
          :conflicts="controller.conflicts.value"
          :folder-rejects="controller.folderRejects.value"
          :unwritable-folders="controller.unwritableFolders.value"
          :default-mode="defaultMode"
          :default-strategy="defaultStrategy"
          :busy="controller.busy.value"
          @add-group="controller.addGroup"
          @update-group="controller.updateGroup"
          @remove-group="controller.removeGroup"
          @add-rule-from-saved="controller.addRuleFromSaved"
          @update-rule="controller.updateRule"
          @remove-rule="controller.removeRule"
          @add-candidate="controller.addCandidate"
          @update-candidate="controller.updateCandidate"
          @remove-candidate="controller.removeCandidate"
          @test-candidate="controller.testCandidate"
        />
      </el-tab-pane>
      <el-tab-pane :label="t('tabs.blocked')" name="blocked">
        <BlockedSourceEditor :prefixes="controller.state.value?.config?.blockedSourcePrefixes ?? []" :busy="controller.busy.value" @update="controller.updateBlockedSources" />
      </el-tab-pane>
    </el-tabs>

    <SaveBar
      :dirty="controller.state.value?.editor.dirty ?? false"
      :busy="controller.busy.value"
      @save="controller.save"
      @reload="controller.reloadConfig"
    />
  </main>
  </el-config-provider>
</template>
