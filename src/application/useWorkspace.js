import { ref, computed, watch } from 'vue'
import { repository as repo } from '../infrastructure/repository'

export function useWorkspace(user) {
  const isAdmin = user.app_metadata?.role === 'admin'
  const companies = ref([]), directory = ref([]), invitations = ref([]), companyId = ref(''), members = ref([]), shifts = ref([]), compensation = ref([]), compensationUnavailable = ref(false)
  const applications = ref([]), freelancers = ref([]), profile = ref(null), accounts = ref([]), adminCompanies = ref([]), requests = ref([]), restriction = ref(null)
  const busy = ref(false), loading = ref(true), error = ref(''), message = ref('')
  const current = computed(() => companies.value.find(c => c.id === companyId.value))
  const manager = computed(() => current.value?.role === 'manager')
  const canSchedule = computed(() => !isAdmin && manager.value)
  let companyRequest = 0
  watch(companyId, () => { companyRequest++; members.value = []; shifts.value = []; requests.value = []; compensation.value = []; freelancers.value = []; compensationUnavailable.value = false }, { flush: 'sync' })
  async function refresh() {
    restriction.value = await repo.restriction(user.id)
    if (restriction.value?.disabled) return
    if (isAdmin) {
      const results = await Promise.allSettled([repo.applications(), repo.accounts(), repo.adminCompanies()])
      if (results[0].status === 'fulfilled') applications.value = results[0].value || []
      if (results[1].status === 'fulfilled') accounts.value = results[1].value || []
      if (results[2].status === 'fulfilled') adminCompanies.value = results[2].value || []
      const failed = results.find(result => result.status === 'rejected')
      if (failed) throw failed.reason
      return
    }
    const [all, memberships, invites, apps, own] = await Promise.all([repo.companies(), repo.memberships(user.id), repo.invitations(), repo.applications(), repo.profile(user.id)])
    directory.value = all || []
    companies.value = directory.value.map(c => ({ ...c, role: memberships?.find(m => m.company_id === c.id)?.role })).filter(c => isAdmin || c.role)
    if (!companies.value.some(c => c.id === companyId.value)) companyId.value = companies.value[0]?.id || ''
    invitations.value = (invites || []).filter(i => i.email.toLowerCase() === user.email?.toLowerCase())
    applications.value = apps || []; profile.value = own
    accounts.value = isAdmin ? await repo.accounts() : []
    await refreshCompany()
  }
  async function refreshCompany() {
    const id = companyId.value
    const request = ++companyRequest
    members.value = []; shifts.value = []; requests.value = []; compensation.value = []; freelancers.value = []; compensationUnavailable.value = false
    if (!id) return
    const [roster, schedule, pending, pay, availableFreelancers] = await Promise.all([repo.roster(id), repo.shifts(id), manager.value ? repo.requests(id) : Promise.resolve([]), manager.value ? repo.compensation(id).then(value => ({value})).catch(error => ({error})) : Promise.resolve({value: []}), manager.value ? repo.freelancers() : Promise.resolve([])])
    if (request !== companyRequest || id !== companyId.value) return
    members.value = roster || []; shifts.value = schedule || []
    requests.value = pending || []
    freelancers.value = (availableFreelancers || []).filter(f => f.visible && f.user_id !== user.id)
    if (pay.error && !['42P01','PGRST205'].includes(pay.error.code)) throw pay.error
    compensationUnavailable.value = !!pay.error
    compensation.value = pay.value || []
  }
  async function perform(fn, success) {
    busy.value = true; error.value = ''; message.value = ''
    try { await fn(); await refresh(); message.value = success; return true }
    catch (e) { error.value = e?.code === '23P01' ? 'Nhân viên đã có ca trùng giờ (có thể ở công ty khác). Hãy đổi thời gian.' : (e?.message || 'Có lỗi xảy ra. Vui lòng thử lại.'); return false }
    finally { busy.value = false; loading.value = false }
  }
  return { isAdmin, companies, directory, invitations, companyId, members, shifts, compensation, compensationUnavailable, applications, freelancers, profile, accounts, adminCompanies, requests, restriction, busy, loading, error, message, current, manager, canSchedule, refresh, refreshCompany, perform, repo }
}
