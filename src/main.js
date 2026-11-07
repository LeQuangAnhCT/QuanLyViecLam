import { createApp } from 'vue'
import App from './presentation/App.vue'
import { createWorkspaceRouter } from './presentation/router'
import './presentation/styles/index.css'
createApp(App).use(createWorkspaceRouter()).mount('#root')
