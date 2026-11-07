import { ref, computed, watch, onScopeDispose } from 'vue'
import { preferredCompanyId, workerRole } from '../domain/calendar.js'
import { legacyPayrollRows } from '../domain/payroll.js'
import { noticeHasExpired } from '../domain/notifications.js'
import { repository as repo } from '../infrastructure/repository'

const companyEventsByRole = {
  manager: new Set(['join_request', 'attendance_in', 'attendance_out']),
  staff: new Set(['created', 'updated', 'cancelled', 'employment_changed'])
}

export function useWorkspace(user) {
  const isAdmin = user.app_metadata?.role === 'admin'
  const companies = ref([]),
    directory = ref([]),
    invitations = ref([]),
    companyId = ref(''),
    members = ref([]),
    memberStatuses = ref([]),
    shifts = ref([]),
    compensation = ref([]),
    compensationUnavailable = ref(false)
  const applications = ref([]),
    freelancers = ref([]),
    profile = ref(null),
    accounts = ref([]),
    adminCompanies = ref([]),
    requests = ref([]),
    restriction = ref(null)
  const workspaceRoles = ref(null)
  const activeRole = ref(isAdmin ? 'admin' : '')
  const companyLoading = ref(false),
    companyError = ref('')
  const supplementalLoading = ref(false),
    supplementalError = ref('')
  let supplementalRequest = 0
  async function refreshSupplemental() {
    if (isAdmin) return
    const request = ++supplementalRequest
    supplementalLoading.value = true
    supplementalError.value = ''
    const results = await Promise.allSettled([
      repo.invitations(),
      repo.applications(),
      repo.profile(user.id)
    ])
    if (request !== supplementalRequest) return
    if (results[0].status === 'fulfilled') {
      invitations.value = (results[0].value || []).filter(
        (invitation) => invitation.email?.toLowerCase() === user.email?.toLowerCase()
      )
    }
    if (results[1].status === 'fulfilled') applications.value = results[1].value || []
    if (results[2].status === 'fulfilled') profile.value = results[2].value
    supplementalError.value = results.some((result) => result.status === 'rejected')
      ? 'Chưa tải được đầy đủ lời mời và hồ sơ việc làm. Vui lòng thử lại.'
      : ''
    supplementalLoading.value = false
  }
  const companyNotifications = ref([]),
    notificationsHydrated = ref(false),
    notificationsLoading = ref(false),
    notificationsError = ref('')
  const notificationNow = ref(Date.now())
  const notifications = computed(() => {
    if (isAdmin) {
      return applications.value
        .filter((application) => application.status === 'pending')
        .map((application) => ({
          id: `application-${application.id}`,
          event: 'company_application',
          title: 'Đơn đăng ký công ty chờ duyệt',
          body: application.company_name,
          created_at: application.created_at,
          read_at: null
        }))
    }
    const roles = new Map(companies.value.map((company) => [company.id, company.role]))
    return companyNotifications.value.filter(
      (item) =>
        item.user_id === user.id &&
        companyEventsByRole[roles.get(item.company_id)]?.has(item.event) &&
        !noticeHasExpired(item, notificationNow.value)
    )
  })
  const clockRecords = ref([]),
    clockUnavailable = ref(false),
    clockError = ref('')
  const payroll = ref([]),
    payrollLoading = ref(false),
    payrollError = ref('')
  let payrollRequest = 0
  async function refreshPayroll(monthDate) {
    const request = ++payrollRequest,
      id = companyId.value
    payroll.value = []
    payrollError.value = ''
    payrollLoading.value = !!(manager.value && id)
    if (!payrollLoading.value) return
    try {
      const result = (await repo.staffSummary(id, monthDate)) || []
      if (request !== payrollRequest || id !== companyId.value) return
      if (result.length) {
        const [assignments, pay] = await Promise.all([
          repo.payrollShifts(id, monthDate),
          result.some((row) => row.monthly_allowance_vnd == null) ? repo.compensation(id) : []
        ])
        if (request !== payrollRequest || id !== companyId.value) return
        payroll.value = legacyPayrollRows(result, assignments, pay)
      }
    } catch (e) {
      if (request !== payrollRequest || id !== companyId.value) return
      payroll.value = []
      payrollError.value = ['42P01', 'PGRST202', 'PGRST205'].includes(e?.code)
        ? 'Báo cáo chưa được cài đặt trong Supabase. Hãy chạy supabase/monthly_cast_payroll.sql.'
        : e?.message || 'Không thể tải bảng công và lương.'
    } finally {
      if (request === payrollRequest && id === companyId.value) payrollLoading.value = false
    }
  }
  const busy = ref(false),
    loading = ref(true),
    error = ref(''),
    message = ref('')
  const current = computed(() => companies.value.find((c) => c.id === companyId.value))
  const manager = computed(() => current.value?.role === 'manager')
  const canSchedule = computed(() => !isAdmin && manager.value)
  let notificationRequest = 0
  async function refreshNotifications() {
    const request = ++notificationRequest
    notificationNow.value = Date.now()
    notificationsLoading.value = true
    try {
      const rows = await (isAdmin ? repo.applications() : repo.notifications(user.id))
      if (request !== notificationRequest) return
      notificationsHydrated.value = true
      if (isAdmin) applications.value = rows || []
      else companyNotifications.value = rows || []
      notificationsError.value = ''
    } catch (e) {
      if (request !== notificationRequest) return
      notificationsError.value = isAdmin
        ? 'Không tải được danh sách đơn đăng ký công ty.'
        : 'Không tải được thông báo. Vui lòng thử làm mới.'
    } finally {
      if (request === notificationRequest) notificationsLoading.value = false
    }
  }
  async function markNotificationRead(id) {
    if (isAdmin) return
    const updated = await repo.markNotificationRead(id, user.id)
    const item = companyNotifications.value.find((notification) => notification.id === id)
    if (item) item.read_at = updated?.[0]?.read_at || new Date().toISOString()
    await refreshNotifications()
  }
  let companyRequest = 0
  watch(
    companyId,
    () => {
      companyRequest++
      companyLoading.value = !!companyId.value
      companyError.value = ''
      members.value = []
      memberStatuses.value = []
      shifts.value = []
      clockRecords.value = []
      requests.value = []
      compensation.value = []
      freelancers.value = []
      compensationUnavailable.value = false
      workspaceRoles.value = null
    },
    { flush: 'sync' }
  )
  async function refresh() {
    const initial = loading.value
    restriction.value = await repo.restriction(user.id)
    if (restriction.value?.disabled) return
    if (isAdmin) {
      const results = await Promise.allSettled([
        refreshNotifications(),
        repo.accounts(),
        repo.adminCompanies(),
        repo.workspaceRoles()
      ])
      if (results[1].status === 'fulfilled') accounts.value = results[1].value || []
      if (results[2].status === 'fulfilled') adminCompanies.value = results[2].value || []
      workspaceRoles.value = results[3].status === 'fulfilled' ? results[3].value : null
      const failed = results.find((result) => result.status === 'rejected')
      if (failed) throw failed.reason
      return
    }
    const [all, memberships] = await Promise.all([repo.companies(), repo.memberships(user.id)])
    directory.value = all || []
    companies.value = directory.value
      .map((c) => ({ ...c, role: memberships?.find((m) => m.company_id === c.id)?.role }))
      .filter((c) => isAdmin || c.role)
    companyId.value = preferredCompanyId(companies.value, companyId.value)
    const supplemental = refreshSupplemental()
    const notices = refreshNotifications()
    await refreshCompany()
    if (!initial) await Promise.all([supplemental, notices])
  }
  async function refreshCompany() {
    const id = companyId.value
    const request = ++companyRequest
    const blocking = loading.value || companyLoading.value || !activeRole.value
    companyError.value = ''
    companyLoading.value = !!id && blocking
    if (!id) {
      activeRole.value = isAdmin ? 'admin' : 'freelance'
      return
    }
    try {
      const [roster, status, schedule, pending, pay, availableFreelancers, actualClock, roles] =
        await Promise.all([
          repo.roster(id),
          repo.memberStatuses(id),
          repo.shifts(id),
          manager.value ? repo.requests(id) : [],
          repo
            .compensation(id)
            .then((value) => ({ value }))
            .catch((error) => ({ error })),
          manager.value ? repo.freelancers() : [],
          repo
            .attendance(id)
            .then((value) => ({ value }))
            .catch((error) => ({ error })),
          manager.value ? null : repo.workspaceRoles(id).catch(() => null)
        ])
      if (request !== companyRequest || id !== companyId.value) return
      memberStatuses.value = status || []
      members.value = (roster || []).map((m) => ({
        ...m,
        is_active: (status || []).find((row) => row.user_id === m.user_id)?.is_active !== false
      }))
      shifts.value = schedule || []
      requests.value = pending || []
      clockRecords.value = actualClock.value || []
      clockUnavailable.value =
        !!actualClock.error && ['42P01', 'PGRST205'].includes(actualClock.error.code)
      clockError.value = clockUnavailable.value
        ? 'Chấm công chưa được kích hoạt trong Supabase. Cần chạy supabase/shift_attendance.sql.'
        : actualClock.error?.message || ''
      // Do not recruit employees who have already joined this company.
      const existingMembers = new Set((roster || []).map((m) => m.user_id))
      freelancers.value = (availableFreelancers || []).filter(
        (f) => f.visible && f.user_id !== user.id && !existingMembers.has(f.user_id)
      )
      if (pay.error && !['42P01', 'PGRST205'].includes(pay.error.code)) throw pay.error
      compensationUnavailable.value = !!pay.error
      compensation.value = pay.value || []
      workspaceRoles.value = roles
      activeRole.value = manager.value
        ? 'manager'
        : workerRole(compensation.value.find((pay) => pay.user_id === user.id)?.employment_type)
    } catch (failure) {
      if (request === companyRequest && id === companyId.value) {
        const text = failure?.message || 'Không tải được dữ liệu công ty.'
        if (blocking) companyError.value = text
        else error.value = text
      }
      throw failure
    } finally {
      if (request === companyRequest) companyLoading.value = false
    }
  }
  async function perform(fn, success) {
    busy.value = true
    error.value = ''
    message.value = ''
    try {
      await fn()
      await refresh()
      message.value = success
      return true
    } catch (e) {
      error.value =
        e?.code === '23P01'
          ? 'Nhân viên đã có ca trùng giờ (có thể ở công ty khác). Hãy đổi thời gian.'
          : e?.message || 'Có lỗi xảy ra. Vui lòng thử lại.'
      return false
    } finally {
      busy.value = false
      loading.value = false
    }
  }
  onScopeDispose(() => {
    supplementalRequest++
    notificationRequest++
    companyRequest++
  })
  return {
    isAdmin,
    activeRole,
    companyLoading,
    companyError,
    supplementalLoading,
    supplementalError,
    refreshSupplemental,
    companies,
    directory,
    invitations,
    companyId,
    members,
    memberStatuses,
    shifts,
    compensation,
    compensationUnavailable,
    applications,
    freelancers,
    profile,
    accounts,
    adminCompanies,
    requests,
    restriction,
    workspaceRoles,
    notifications,
    notificationNow,
    notificationsHydrated,
    notificationsLoading,
    notificationsError,
    refreshNotifications,
    markNotificationRead,
    clockRecords,
    clockUnavailable,
    clockError,
    payroll,
    payrollLoading,
    payrollError,
    refreshPayroll,
    busy,
    loading,
    error,
    message,
    current,
    manager,
    canSchedule,
    refresh,
    refreshCompany,
    perform,
    repo
  }
}
