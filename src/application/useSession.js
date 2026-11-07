import { ref, onMounted, onUnmounted } from 'vue'
import { auth } from '../infrastructure/auth'

export function useSession() {
  const session = ref(undefined)
  const authError = ref('')
  const signingIn = ref(false)
  let subscription
  let revision = 0
  let disposed = false

  onMounted(async () => {
    subscription = auth.onAuthStateChange((_event, value) => {
      if (disposed) return
      revision++
      session.value = value
    }).data.subscription
    const startedAtRevision = revision
    try {
      const result = await auth.getSession()
      if (disposed) return
      if (result.error)
        authError.value = 'Không thể khôi phục phiên đăng nhập. Vui lòng đăng nhập lại.'
      if (startedAtRevision === revision) session.value = result.data?.session ?? null
    } catch {
      if (disposed) return
      authError.value = 'Không thể khôi phục phiên đăng nhập. Vui lòng đăng nhập lại.'
      if (startedAtRevision === revision) session.value = null
    }
  })

  onUnmounted(() => {
    disposed = true
    subscription?.unsubscribe()
  })

  async function login() {
    if (signingIn.value) return
    signingIn.value = true
    authError.value = ''
    try {
      const { error } = await auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: location.origin }
      })
      if (error) authError.value = 'Chưa thể mở đăng nhập Google. Vui lòng thử lại.'
    } catch {
      authError.value = 'Chưa thể mở đăng nhập Google. Vui lòng thử lại.'
    } finally {
      signingIn.value = false
    }
  }

  return { session, authError, signingIn, login }
}
