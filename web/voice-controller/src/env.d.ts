/// <reference types="vite/client" />

declare module '@reff/ui' {
  import type {App} from 'vue';
  export type ReffLanguage = 'zh-CN' | 'en-US';
  export type ReffPreferences = {language: ReffLanguage; appearance: Record<string, unknown>};
  export const REFF_UI_VERSION: string;
  export const REFF_ELEMENT_LOCALES: Record<ReffLanguage, unknown>;
  export const ElMessage: {
    (message: string | {message: string; customClass?: string}): void;
    success(message: string): void;
    error(message: string): void;
    warning(message: string): void;
  };
  export function installReffUi(app: App): App;
}
