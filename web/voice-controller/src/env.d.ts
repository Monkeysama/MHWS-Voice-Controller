/// <reference types="vite/client" />

declare module '@reff/ui' {
  import type {App} from 'vue';
  export const REFF_UI_VERSION: string;
  export const ElMessage: {
    success(message: string): void;
    error(message: string): void;
    warning(message: string): void;
  };
  export function installReffUi(app: App): App;
}
