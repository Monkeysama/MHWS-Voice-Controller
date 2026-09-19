<script setup lang="ts">
import {computed, shallowRef} from 'vue';
import EventBrowser from '@/components/EventBrowser.vue';
import RuleEditor from '@/components/RuleEditor.vue';
import SavedEventBrowser from '@/components/SavedEventBrowser.vue';
import SaveBar from '@/components/SaveBar.vue';
import BlockedSourceEditor from '@/components/BlockedSourceEditor.vue';
import StatusPanel from '@/components/StatusPanel.vue';
import {useVoiceController} from '@/composables/useVoiceController';

const controller = useVoiceController();
const activeTab = shallowRef('events');
const defaultMode = computed(() => controller.state.value?.config?.mode ?? 'observe');
const defaultStrategy = computed(() => controller.state.value?.config?.replaceStrategy ?? 'skip_original');
const savedKeys = computed(() => new Set(controller.savedEvents.value.map(event => event.stableKey)));
const visibleEvents = computed(() => controller.events.value);
</script>

<template>
  <main class="voice-controller-page">
    <StatusPanel
      :state="controller.state.value"
      :loading="controller.loading.value"
      :error="controller.error.value"
    />

    <el-tabs v-model="activeTab" class="workspace-tabs">
      <el-tab-pane label="近期事件" name="events" class="events-pane">
        <EventBrowser
          :events="visibleEvents"
          :saved-keys="savedKeys"
          :busy="controller.busy.value"
          @save="controller.saveEvent"
          @play="controller.playEvent"
        />
      </el-tab-pane>
      <el-tab-pane label="保存列表" name="saved" class="saved-pane">
        <SavedEventBrowser
          :events="controller.savedEvents.value"
          :busy="controller.busy.value"
          @play="controller.playEvent"
          @remove="controller.removeSavedEvent"
        />
      </el-tab-pane>
      <el-tab-pane label="分组配置" name="rules" class="rules-pane">
        <RuleEditor
          :groups="controller.groups.value"
          :catalog-files="controller.catalogFiles.value"
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
      <el-tab-pane label="屏蔽列表" name="blocked">
        <BlockedSourceEditor :prefixes="controller.state.value?.config?.blockedSourcePrefixes ?? []" :busy="controller.busy.value" @update="controller.updateBlockedSources" />
      </el-tab-pane>
    </el-tabs>

    <SaveBar
      :dirty="controller.state.value?.editor.dirty ?? false"
      :busy="controller.busy.value"
      @save="controller.save"
      @refresh="controller.refresh"
    />
  </main>
</template>
