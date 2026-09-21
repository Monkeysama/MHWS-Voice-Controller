import {createApp} from 'vue';
import {installReffUi} from '@reff/ui';
import App from './App.vue';
import {i18n, installReffLocaleBridge} from './i18n';
import './style.css';

// 先监听 REFF 偏好事件，再请求 Shell 下发主题与语言，避免首个语言消息丢失。
installReffLocaleBridge();
const app = createApp(App);
app.use(i18n);
installReffUi(app).mount('#app');
