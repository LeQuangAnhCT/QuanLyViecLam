// Browser function for Chrome DevTools evaluate_script. It uses the real application
// startup with an optional job-profile request held pending until the check finishes.
;async () => {
  const source = await (await fetch('/src/application/useWorkspace.js')).text()
  const vueUrl = source.match(/from\s+"([^"]*vue\.js\?[^"]*)"/)[1]
  const { effectScope } = await import(vueUrl)
  const { repository } = await import('/src/infrastructure/repository.js')
  const { useWorkspace } = await import(
    '/src/application/useWorkspace.js?startup-probe=' + Date.now()
  )
  const saved = { ...repository }
  const calls = []
  const scope = effectScope()
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
  let releaseProfile
  const blockedProfile = new Promise((resolve) => {
    releaseProfile = resolve
  })
  const company = { id: 'probe-company', name: 'Performance probe', role: 'staff' }
  const stub =
    (name, value, delay = 0) =>
    async () => {
      calls.push(name)
      if (delay) await wait(delay)
      return value
    }
  Object.assign(repository, {
    restriction: stub('restriction', null),
    companies: stub('companies', [company]),
    memberships: stub('memberships', [{ company_id: company.id, role: 'staff' }]),
    invitations: stub('invitations', []),
    applications: stub('applications', []),
    profile: async () => {
      calls.push('profile')
      return blockedProfile
    },
    roster: stub('roster', []),
    memberStatuses: stub('memberStatuses', []),
    shifts: stub('shifts', []),
    compensation: stub('compensation', [{ user_id: 'probe-staff', employment_type: 'employee' }]),
    attendance: stub('attendance', []),
    workspaceRoles: stub('workspaceRoles', { 'probe-staff': 'staff' }),
    notifications: stub('notifications', [])
  })
  try {
    const workspace = scope.run(() =>
      useWorkspace({ id: 'probe-staff', email: 'probe@example.test' })
    )
    const start = performance.now()
    const loading = workspace.perform(() => Promise.resolve(), '')
    const available = await Promise.race([loading, wait(650).then(() => false)])
    const elapsed = Math.round(performance.now() - start)
    const readyRole = workspace.activeRole.value
    releaseProfile(null)
    await loading
    return {
      verdict: available && readyRole === 'staff' ? 'PASS' : 'SLOW',
      elapsedMs: elapsed,
      allowedMs: 650,
      role: workspace.activeRole.value,
      requested: calls,
      scenario: 'Opening a staff calendar before the unrelated job profile returns'
    }
  } finally {
    releaseProfile(null)
    Object.assign(repository, saved)
    scope.stop()
  }
}
