import { ref, computed } from 'vue'
import { repository as repo } from '../infrastructure/repository'

export function useWorkspace(user) {
  const isAdmin = user.app_metadata?.role === 'admin'
  const companies = ref([]), directory = ref([]), invitations = ref([]), companyId = ref(''), members = ref([]), shifts = ref([])
  const applications = ref([]), freelancers = ref([]), profile = ref(null), accounts = ref([]), requests = ref([]), restriction = ref(null)
  const busy = ref(false), loading = ref(true), error = ref(''), message = ref('')
  const current = computed(() => companies.value.find(c => c.id === companyId.value))
  const manager = computed(() => current.value?.role === 'manager')
  const canSchedule = computed(() => isAdmin || manager.value)
  async function refresh() {
    restriction.value = await repo.restriction(user.id)
    if (restriction.value?.disabled) return
    const [all, memberships, invites, apps, own] = await Promise.all([repo.companies(), repo.memberships(user.id), repo.invitations(), repo.applications(), repo.profile(user.id)])
    directory.value = all || []
    companies.value = directory.value.map(c => ({ ...c, role: memberships?.find(m => m.company_id === c.id)?.role })).filter(c => isAdmin || c.role)
    if (!companies.value.some(c => c.id === companyId.value)) companyId.value = companies.value[0]?.id || ''
    invitations.value = (invites || []).filter(i => i.email.toLowerCase() === user.email?.toLowerCase())
    applications.value = apps || []; profile.value = own
    accounts.value = isAdmin ? await repo.accounts() : []
    freelancers.value = manager.value ? (await repo.freelancers()).filter(f => f.visible && f.user_id !== user.id) : []
    await refreshCompany()
  }
  async function refreshCompany() {
    if (!companyId.value) { members.value = []; shifts.value = []; requests.value = []; return }
    const [roster, schedule] = await Promise.all([repo.roster(companyId.value), repo.shifts(companyId.value)])
    members.value = roster || []; shifts.value = schedule || []
    requests.value = manager.value ? await repo.requests(companyId.value) : []
  }
  async function perform(fn, success) {
    busy.value = true; error.value = ''; message.value = ''
    try { await fn(); await refresh(); message.value = success; return true }
    catch (e) { error.value = e?.message || 'Có lỗi xảy ra. Vui lòng thử lại.'; return false }
    finally { busy.value = false; loading.value = false }
  }
  return { isAdmin, companies, directory, invitations, companyId, members, shifts, applications, freelancers, profile, accounts, requests, restriction, busy, loading, error, message, current, manager, canSchedule, refresh, perform, repo }
}
