import { fileURLToPath, URL } from 'node:url';
import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';

const root = fileURLToPath(new URL('./ui', import.meta.url));
const output = fileURLToPath(new URL('../../reframework/reff/plugins/voice-controller/ui/dist', import.meta.url));
const shared = 'reff://shell/shared/reff-ui.mjs';

// REFF 页面复用宿主提供的 Vue 和公共 UI，业务代码与 SDK 打包进隔离页面。
export default defineConfig({
  root,
  plugins: [vue()],
  base: './',
  resolve: {alias: {'@': fileURLToPath(new URL('./src', import.meta.url))}},
  build: {
    target: 'es2020',
    outDir: output,
    emptyOutDir: true,
    rollupOptions: {
      input: fileURLToPath(new URL('./ui/index.html', import.meta.url)),
      external: ['vue', '@reff/ui'],
      output: {paths: {vue: shared, '@reff/ui': shared}}
    }
  }
});
