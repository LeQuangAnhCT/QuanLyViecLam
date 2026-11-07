<script setup>
import { onUnmounted, ref } from 'vue'

const toasts = ref([])
const timers = new Map()
let nextId = 0

function dismiss(id) {
  window.clearTimeout(timers.get(id))
  timers.delete(id)
  toasts.value = toasts.value.filter(toast => toast.id !== id)
}

function show(text, { kind = 'info', title = 'Thông báo mới', action } = {}) {
  if (!text) return
  if (toasts.value.length === 3) dismiss(toasts.value[0].id)
  const id = ++nextId
  toasts.value.push({ id, kind, title, text, action })
  timers.set(id, window.setTimeout(() => dismiss(id), kind === 'error' ? 6000 : 4500))
}
function openToast(toast) {
  toast.action()
  dismiss(toast.id)
}

onUnmounted(() => { for (const timer of timers.values()) window.clearTimeout(timer) })
defineExpose({ show })
</script>

<template>
  <div class="toast-stack">
    <article v-for="toast in toasts" :key="toast.id" class="toast-card" :class="'toast-'+toast.kind">
      <div :role="toast.kind === 'error' ? 'alert' : 'status'" aria-atomic="true">
        <strong>{{ toast.title }}</strong>
        <p>{{ toast.text }}</p>
        <button v-if="toast.action" class="toast-open" type="button" @click="openToast(toast)">Xem ca</button>
      </div>
      <button type="button" aria-label="Đóng thông báo nổi" @click="dismiss(toast.id)">×</button>
    </article>
  </div>
</template>
