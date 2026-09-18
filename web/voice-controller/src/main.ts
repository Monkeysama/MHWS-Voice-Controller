import {createApp} from 'vue';
import {installReffUi} from '@reff/ui';
import App from './App.vue';
import './style.css';

// 页面入口只安装 REFF 公共 UI 并挂载业务外壳。
installReffUi(createApp(App)).mount('#app');
