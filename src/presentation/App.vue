<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { repository } from '../infrastructure/repository'
import Workspace from './Workspace.vue'

const session = ref(undefined), authError = ref('')
let subscription
onMounted(async () => {
  const result = await repository.auth.getSession()
  if (result.error) authError.value = result.error.message
  session.value = result.data.session
  subscription = repository.auth.onAuthStateChange((_event, value) => { session.value = value }).data.subscription
})
onUnmounted(() => subscription?.unsubscribe())
async function login() {
  const { error } = await repository.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: location.origin } })
  if (error) authError.value = error.message
}
</script>

<template>
  <main v-if="session === undefined" class="auth-screen" aria-live="polite">Đang tải Shiftly...</main>
  <main v-else-if="!session" class="auth-screen">
    <section class="auth-box">
      <div class="brand"><span class="brand-mark">S</span><strong>SHIFTLY</strong></div>
      <h1>Mọi lịch diễn.<br>Trong một nơi.</h1>
      <p>Sắp lịch, kết nối nhân sự và theo dõi giờ làm cho đội ngũ âm thanh ánh sáng.</p>
      <p v-if="authError" class="alert" role="alert">{{ authError }}</p>
      <fluent-button appearance="accent" class="google-button" @click="login">Tiếp tục với Google</fluent-button>
      <small>Đăng nhập để truy cập lịch làm việc của bạn.</small>
    </section>
  </main>
  <Workspace v-else :key="session.user.id" :user="session.user" />
</template>
