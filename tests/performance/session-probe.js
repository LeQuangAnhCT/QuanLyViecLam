// Browser function for Chrome DevTools evaluate_script. Exercises the actual
// session composable without redirecting to Google or changing stored sessions.
;async () => {
  const source = await (await fetch('/src/application/useSession.js')).text()
  const vueUrl = source.match(/from\s+"([^"]*vue\.js\?[^"]*)"/)[1]
  const { createApp, h, nextTick } = await import(vueUrl)
  const { auth } = await import('/src/infrastructure/auth.js')
  const { useSession } = await import('/src/application/useSession.js?session-probe=' + Date.now())
  const saved = {
    getSession: auth.getSession,
    onAuthStateChange: auth.onAuthStateChange,
    signInWithOAuth: auth.signInWithOAuth
  }
  let listener,
    releaseSession,
    releaseLogin,
    model,
    unsubscribeCount = 0,
    loginCalls = 0
  const pendingSession = new Promise((resolve) => {
    releaseSession = resolve
  })
  const pendingLogin = new Promise((resolve) => {
    releaseLogin = resolve
  })
  auth.getSession = () => pendingSession
  auth.onAuthStateChange = (callback) => {
    listener = callback
    return { data: { subscription: { unsubscribe: () => unsubscribeCount++ } } }
  }
  auth.signInWithOAuth = () => {
    loginCalls++
    return pendingLogin
  }
  const host = document.createElement('div')
  const app = createApp({
    setup() {
      model = useSession()
      return () => h('span')
    }
  })
  try {
    app.mount(host)
    listener('SIGNED_IN', { user: { id: 'session-probe' } })
    releaseSession({ data: { session: null }, error: null })
    await nextTick()
    await nextTick()
    const currentSessionPreserved = model.session.value?.user.id === 'session-probe'
    const firstLogin = model.login()
    const secondLogin = model.login()
    const duplicateLoginPrevented = model.signingIn.value && loginCalls === 1
    releaseLogin({ error: null })
    await Promise.all([firstLogin, secondLogin])
    app.unmount()
    return {
      verdict:
        currentSessionPreserved && duplicateLoginPrevented && unsubscribeCount === 1
          ? 'PASS'
          : 'FAIL',
      currentSessionPreserved,
      duplicateLoginPrevented,
      listenerRemoved: unsubscribeCount === 1
    }
  } finally {
    releaseSession({ data: { session: null }, error: null })
    releaseLogin({ error: null })
    if (unsubscribeCount === 0) app.unmount()
    Object.assign(auth, saved)
    host.remove()
  }
}
