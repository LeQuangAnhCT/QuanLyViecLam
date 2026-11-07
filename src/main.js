import { createApp } from 'vue'
import App from './presentation/App.vue'
import { createWorkspaceRouter } from './presentation/router'
import './presentation/styles/index.css'
import '@fluentui/web-components/button.js'
import { setTheme } from '@fluentui/web-components'
import { webLightTheme } from '@fluentui/tokens'

setTheme(webLightTheme)
createApp(App).use(createWorkspaceRouter()).mount('#root')
