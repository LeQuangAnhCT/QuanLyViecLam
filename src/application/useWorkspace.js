import { ref, computed, watch } from 'vue'
import { preferredCompanyId } from '../domain/calendar.js'
import { repository as repo } from '../infrastructure/repository'

export function useWorkspace(user) {
  const isAdmin = user.app_metadata?.role === 'admin'
  const companies = ref([]), directory = ref([]), invitations = ref([]), companyId = ref(''), members = ref([]), shifts = ref([]), compensation = ref([]), compensationUnavailable = ref(false)
  const applications = ref([]), freelancers = ref([]), profile = ref(null), accounts = ref([]), adminCompanies = ref([]), requests = ref([]), restriction = ref(null)
  const notifications = ref([]), notificationsUnavailable = ref(false), notificationsError = ref('')
  const clockRecords = ref([]), clockUnavailable = ref(false), clockError = ref('')
  const busy = ref(false), loading = ref(true), error = ref(''), message = ref('')
  const current = computed(() => companies.value.find(c => c.id === companyId.value))
  const manager = computed(() => current.value?.role === 'manager')
  const canSchedule = computed(() => !isAdmin && manager.value)
  async function refreshNotifications() {
    if (isAdmin) return
    try {
      notifications.value = await repo.notifications(user.id) || []
      notificationsUnavailable.value = false
      notificationsError.value = ''
    } catch(e) {
      if (['PGRST205','42P01','PGRST116'].includes(e?.code)) {
        notificationsUnavailable.value = true
        notificationsError.value = 'Supabase chưa có bảng thông báo. Cần chạy supabase/shift_notifications.sql.'
      } else {
        notificationsError.value = e?.message || 'Không tải được thông báo.'
      }
    }
  }
  let companyRequest = 0
  watch(companyId, () => { companyRequest++; members.value = []; shifts.value = []; clockRecords.value = []; requests.value = []; compensation.value = []; freelancers.value = []; compensationUnavailable.value = false }, { flush: 'sync' })
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
    companyId.value = preferredCompanyId(companies.value, companyId.value)
    invitations.value = (invites || []).filter(i => i.email.toLowerCase() === user.email?.toLowerCase())
    applications.value = apps || []; profile.value = own
    accounts.value = isAdmin ? await repo.accounts() : []
    await refreshCompany()
    await refreshNotifications()
  }
  async function refreshCompany() {
    const id = companyId.value
    const request = ++companyRequest
    members.value = []; shifts.value = []; clockRecords.value = []; requests.value = []; compensation.value = []; freelancers.value = []; compensationUnavailable.value = false
    if (!id) return
    const [roster, schedule, pending, pay, availableFreelancers, actualClock] = await Promise.all([repo.roster(id), repo.shifts(id), manager.value ? repo.requests(id) : Promise.resolve([]), manager.value ? repo.compensation(id).then(value => ({value})).catch(error => ({error})) : Promise.resolve({value: []}), manager.value ? repo.freelancers() : Promise.resolve([]), repo.attendance(id).then(value=>({value})).catch(error=>({error}))])
    if (request !== companyRequest || id !== companyId.value) return
    members.value = roster || []; shifts.value = schedule || []
    requests.value = pending || []
    clockRecords.value = actualClock.value || []
    clockUnavailable.value = !!actualClock.error && ['42P01','PGRST205'].includes(actualClock.error.code)
    clockError.value = clockUnavailable.value ? 'Chấm công chưa được kích hoạt trong Supabase. Cần chạy supabase/shift_attendance.sql.' : (actualClock.error?.message || '')
    // Do not recruit employees who have already joined this company.
    const existingMembers = new Set((roster || []).map(m => m.user_id))
    freelancers.value = (availableFreelancers || []).filter(f => f.visible && f.user_id !== user.id && !existingMembers.has(f.user_id))
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
  return { isAdmin, companies, directory, invitations, companyId, members, shifts, compensation, compensationUnavailable, applications, freelancers, profile, accounts, adminCompanies, requests, restriction, notifications, notificationsUnavailable, notificationsError, refreshNotifications, clockRecords, clockUnavailable, clockError, busy, loading, error, message, current, manager, canSchedule, refresh, refreshCompany, perform, repo }
}
