<script setup>
import { computed, onMounted, provide, ref, watch } from 'vue'
import { RouterView, useRoute, useRouter } from 'vue-router'
import { useWorkspace } from '../application/useWorkspace'
import { workspaceKey } from './composables/useWorkspaceContext'

const props = defineProps({ user: { type: Object, required: true } })
const w = useWorkspace(props.user)
provide(workspaceKey, w)

const route = useRoute()
const router = useRouter()
const routeError = ref('')
const startupError = ref('')
const {
  activeRole,
  companyLoading,
  companyError,
  loading,
  restriction,
  error,
  companies,
  companyId,
  busy,
  repo
} = w
const pageReady = computed(
  () => !loading.value && !!activeRole.value && route.meta.role === activeRole.value
)

async function openRolePage() {
  if (
    loading.value ||
    companyLoading.value ||
    companyError.value ||
    startupError.value ||
    restriction.value?.disabled ||
    !activeRole.value
  )
    return
  routeError.value = ''
  if (route.meta.role === activeRole.value) return
  try {
    await router.replace({ name: activeRole.value })
  } catch {
    routeError.value = 'Không tải được giao diện tài khoản. Hãy thử lại.'
  }
}

async function reloadWorkspace() {
  startupError.value = ''
  const success = await w.perform(() => Promise.resolve(), '')
  if (!success) {
    startupError.value = companyError.value || error.value || 'Không tải được dữ liệu tài khoản.'
    return
  }
  await openRolePage()
}

async function selectCompany(id) {
  if (busy.value || companyLoading.value) return
  startupError.value = ''
  routeError.value = ''
  companyId.value = id
  try {
    await w.refreshCompany()
  } catch {
    /* The company error remains visible for retry. */
  }
}

watch(
  [activeRole, companyLoading, companyError, startupError, loading, () => route.meta.role],
  openRolePage,
  { immediate: true }
)
onMounted(reloadWorkspace)
</script>

<template>
  <main v-if="restriction?.disabled" class="workspace-status">
    <section class="workspace-status-card">
      <h1>Tài khoản đã bị vô hiệu hóa</h1>
      <p>{{ restriction.reason }}</p>
      <button type="button" @click="repo.auth.signOut()">Đăng xuất</button>
    </section>
  </main>
  <main
    v-else-if="companyError || startupError || routeError || (!loading && !activeRole && error)"
    class="workspace-status"
  >
    <section class="workspace-status-card">
      <h1>Chưa tải được trang</h1>
      <p role="alert">{{ companyError || startupError || routeError || error }}</p>
      <button type="button" :disabled="busy || companyLoading" @click="reloadWorkspace">
        Thử lại
      </button>
      <div v-if="companies.length > 1" class="workspace-company-recovery">
        <button
          v-for="company in companies"
          :key="company.id"
          type="button"
          :disabled="busy || companyLoading"
          @click="selectCompany(company.id)"
        >
          {{ company.name }}
        </button>
      </div>
    </section>
  </main>
  <template v-else>
    <div v-if="loading || !pageReady" class="workspace-status" role="status">
      Đang tải giao diện tài khoản...
    </div>
    <RouterView v-slot="{ Component }">
      <component :is="Component" v-if="pageReady" :key="activeRole" :user="user" />
    </RouterView>
    <div
      v-if="companyLoading && !loading && pageReady"
      class="workspace-transition"
      role="status"
      aria-live="polite"
    >
      Đang tải công ty...
    </div>
  </template>
</template>
