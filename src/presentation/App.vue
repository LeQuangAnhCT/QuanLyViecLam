<script setup>
import { defineAsyncComponent, h } from 'vue'
import { useSession } from '../application/useSession'

const { session, authError, signingIn, login } = useSession()
const WorkspaceRouter = defineAsyncComponent({
  loader: () => import('./WorkspaceRouter.vue'),
  loadingComponent: {
    render: () => h('main', { class: 'auth-screen', role: 'status' }, 'Đang mở Shiftly...')
  },
  delay: 0
})
</script>

<template>
  <main v-if="session === undefined" class="auth-screen" aria-live="polite">
    Đang tải Shiftly...
  </main>
  <main v-else-if="!session" class="auth-screen">
    <section class="auth-box">
      <div class="brand">
        <span class="brand-mark">S</span>
        <strong>SHIFTLY</strong>
      </div>
      <h1>
        Mọi lịch diễn.
        <br />
        Trong một nơi.
      </h1>
      <p>Sắp lịch, kết nối nhân sự và theo dõi giờ làm cho đội ngũ âm thanh ánh sáng.</p>
      <p v-if="authError" class="alert" role="alert">{{ authError }}</p>
      <button type="button" class="google-button" :disabled="signingIn" @click="login">
        {{ signingIn ? 'Đang mở Google...' : 'Tiếp tục với Google' }}
      </button>
      <small>Đăng nhập để truy cập lịch làm việc của bạn.</small>
    </section>
  </main>
  <WorkspaceRouter v-else :key="session.user.id" :user="session.user" />
</template>
