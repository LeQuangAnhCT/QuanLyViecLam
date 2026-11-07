<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import {
  localDate,
  roleLabel,
  workerRole,
  shiftRows,
  shiftEditPlan,
  sameWorkSlot,
  ShiftOverlapError,
  effectiveShiftEnd
} from '../../../domain/calendar'
import { formatWorkDuration } from '../../formatters/work-duration'
import LocationPicker from '../../LocationPicker.vue'
import ToastStack from '../../ToastStack.vue'
import {
  isShiftNotification,
  noticeIsPast,
  shiftNoticeSnapshot
} from '../../../domain/notifications.js'
import { useWorkspaceContext } from '../../composables/useWorkspaceContext'

const props = defineProps({ user: { type: Object, required: true } })

const w = useWorkspaceContext()

const {
  isAdmin,
  companies,
  directory,
  invitations,
  companyId,
  members,
  shifts,
  compensation,
  compensationUnavailable,
  freelancers,
  requests,
  restriction,
  notifications,
  notificationNow,
  notificationsLoading,
  notificationsError,
  clockRecords,
  payroll,
  payrollLoading,
  payrollError,
  busy,
  loading,
  error,
  message,
  current,
  manager,
  canSchedule,
  repo
} = w

const tab = ref('calendar')

const month = ref(new Date(new Date().getFullYear(), new Date().getMonth(), 1))

const selectedDate = ref(localDate(new Date()))

const modal = ref('')

const dialogClose = ref(null)

const toastStack = ref(null)

watch(
  modal,
  () => {
    error.value = ''
  },
  { flush: 'sync' }
)

watch(
  modal,
  (next) => {
    if (next === 'shift-picker') dialogClose.value?.focus()
  },
  { flush: 'post' }
)

watch(error, (text) => {
  if (!text || modal.value) return
  toastStack.value?.show(text, { kind: 'error', title: 'Cần chú ý' })
  error.value = ''
})

watch(message, (text) => {
  if (!text) return
  toastStack.value?.show(text, { kind: 'success', title: 'Thành công' })
  message.value = ''
})

const seenNotificationIds = new Set(notifications.value.map((item) => item.id))

watch(notifications, (items) => {
  const incoming = items.filter((item) => !item.read_at && !seenNotificationIds.has(item.id))
  for (const item of items) seenNotificationIds.add(item.id)
  if (
    !loading.value &&
    incoming.some(
      (item) => item.event === 'employment_changed' && item.company_id === companyId.value
    )
  ) {
    w.refreshCompany().catch(() => {})
  }
  if (loading.value || tab.value === 'notifications' || !incoming.length) return
  if (incoming.length === 1) {
    const item = incoming[0]
    toastStack.value?.show(item.body || item.title, {
      title: item.title,
      action: () => openNotification(item)
    })
  } else {
    toastStack.value?.show(`Có ${incoming.length} thông báo mới. Mở mục Thông báo để xem chi tiết.`)
  }
})

const notificationGroup = ref('current')

const notificationPage = ref(1)

const notificationPageSize = 8

const notificationDialog = ref(null)

const activeNotification = ref(null)

const notificationDetail = ref(null)

const notificationDetailLoading = ref(false)

const notificationReadError = ref('')

const notificationShifts = computed(() => {
  const live = new Map(shifts.value.map((shift) => [shift.id, shift]))
  return new Map(
    notifications.value
      .filter(isShiftNotification)
      .map((item) => [item.id, shiftNoticeSnapshot(item) || live.get(item.shift_id) || null])
  )
})

const notificationGroups = computed(() => {
  const groups = { current: [], past: [] }
  for (const item of notifications.value) {
    const past = noticeIsPast(item, notificationShifts.value.get(item.id), notificationNow.value)
    groups[past ? 'past' : 'current'].push(item)
  }
  return groups
})

const notificationPages = computed(() =>
  Math.max(
    1,
    Math.ceil(notificationGroups.value[notificationGroup.value].length / notificationPageSize)
  )
)

const visibleNotifications = computed(() => {
  const offset = (notificationPage.value - 1) * notificationPageSize
  return notificationGroups.value[notificationGroup.value].slice(
    offset,
    offset + notificationPageSize
  )
})

watch(notificationPages, (count) => {
  notificationPage.value = Math.min(notificationPage.value, count)
})

function selectNotificationGroup(group) {
  notificationGroup.value = group
  notificationPage.value = 1
}

const noticeDateFormat = new Intl.DateTimeFormat('vi-VN', {
  timeZone: 'Asia/Ho_Chi_Minh',
  dateStyle: 'short',
  timeStyle: 'short'
})

async function openNotification(item) {
  const request = { ...item }
  activeNotification.value = request
  notificationReadError.value = ''
  notificationDetail.value = notificationShifts.value.get(item.id) || null
  notificationDetailLoading.value =
    isShiftNotification(item) &&
    !notificationDetail.value &&
    !!item.shift_id &&
    item.event !== 'cancelled'
  await nextTick()
  if (!notificationDialog.value?.open) notificationDialog.value?.showModal()
  if (!item.read_at) {
    w.markNotificationRead(item.id).catch(() => {
      if (activeNotification.value?.id === item.id)
        notificationReadError.value = 'Chưa thể đánh dấu đã đọc. Hãy thử mở lại thông báo.'
    })
  }
  if (!notificationDetailLoading.value) return
  try {
    const detail = await repo.notificationShift(item, props.user.id)
    if (activeNotification.value?.id === item.id) notificationDetail.value = detail
  } catch {
    // The original message remains available if the assignment can no longer be loaded.
  } finally {
    if (activeNotification.value?.id === item.id) notificationDetailLoading.value = false
  }
}

const inviteEmail = ref('')

const editingShiftId = ref('')

const peopleSearch = ref('')

const peopleFilter = ref('all')

const accountProfile = reactive({
  full_name: props.user.user_metadata?.full_name || '',
  birth_date: '',
  hometown: '',
  active_location: '',
  avatar_url: ''
})

const avatarFile = ref(null)

const defaultAvatar =
  'data:image/svg+xml,' +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#e4e6eb"/><circle cx="50" cy="38" r="19" fill="#b0b3b8"/><path d="M14 100c2-24 16-37 36-37s34 13 36 37" fill="#b0b3b8"/></svg>'
  )

const avatarPreview = ref('')

function chooseAvatar(event) {
  const file = event.target.files?.[0]
  if (!file) return
  if (
    !['image/jpeg', 'image/png', 'image/webp'].includes(file.type) ||
    file.size > 2 * 1024 * 1024
  ) {
    avatarFile.value = null
    error.value = 'Ảnh phải là JPG, PNG hoặc WebP và không quá 2 MB.'
    event.target.value = ''
    return
  }
  avatarFile.value = file
  if (avatarPreview.value) URL.revokeObjectURL(avatarPreview.value)
  avatarPreview.value = URL.createObjectURL(file)
}

async function saveAccountProfile() {
  const name = accountProfile.full_name.trim()
  if (!name) {
    error.value = 'Vui lòng nhập họ tên.'
    return
  }
  if (accountProfile.birth_date && new Date(accountProfile.birth_date) > new Date()) {
    error.value = 'Ngày sinh không hợp lệ.'
    return
  }
  busy.value = true
  error.value = ''
  message.value = ''
  try {
    const avatar_url = avatarFile.value
      ? await repo.uploadAvatar(props.user.id, avatarFile.value)
      : accountProfile.avatar_url
    await repo.saveAccountProfile(props.user.id, {
      full_name: name,
      birth_date: accountProfile.birth_date || null,
      hometown: accountProfile.hometown.trim() || null,
      active_location: accountProfile.active_location.trim() || null,
      avatar_url: avatar_url || null
    })
    await repo.auth.updateUser({ data: { full_name: name } })
    Object.assign(accountProfile, { full_name: name, avatar_url })
    avatarFile.value = null
    if (avatarPreview.value) {
      URL.revokeObjectURL(avatarPreview.value)
      avatarPreview.value = ''
    }
    message.value = 'Đã cập nhật hồ sơ.'
  } catch (e) {
    error.value = e?.message || 'Không thể lưu hồ sơ.'
  } finally {
    busy.value = false
  }
}

const shift = reactive({
  title: '',
  location: '',
  date: localDate(new Date()),
  end_date: localDate(new Date()),
  start: '08:00',
  end: '12:00',
  cast_vnd: 300000,
  user_ids: []
})

const payForm = reactive({
  user_id: '',
  name: '',
  employment_type: 'freelancer',
  monthly_base_vnd: '',
  monthly_allowance_vnd: 0
})

const reportMonth = ref(new Date(new Date().getFullYear(), new Date().getMonth(), 1))

const reportMonthText = computed(() => localDate(reportMonth.value))

const monthlyReportTotals = computed(() => ({
  scheduled: payroll.value.reduce((a, row) => a + Number(row.scheduled_shifts || 0), 0),
  completed: payroll.value.reduce((a, row) => a + Number(row.completed_shifts || 0), 0),
  workedMs: payroll.value.reduce((total, row) => total + Number(row.worked_ms || 0), 0),
  plannedCast: payroll.value.reduce((a, row) => a + Number(row.planned_cast_vnd || 0), 0),
  cast: payroll.value.reduce((a, row) => a + Number(row.cast_total_vnd || 0), 0),
  total: payroll.value.reduce((a, row) => a + Number(row.estimated_total_vnd || 0), 0)
}))

function changeReportMonth(delta) {
  reportMonth.value = new Date(
    reportMonth.value.getFullYear(),
    reportMonth.value.getMonth() + delta,
    1
  )
}

const employmentLabel = (type) => roleLabel(workerRole(type))

const profileRoleLabel = roleLabel('manager')

const selectableCompanies = computed(() => companies.value)

const assignableMembers = computed(() =>
  members.value.filter((m) => m.role === 'staff' && m.is_active)
)

const unreadCount = computed(() => notifications.value.filter((n) => !n.read_at).length)

const attendanceByShift = computed(
  () => new Map(clockRecords.value.map((record) => [record.shift_id, record]))
)

const clockRecordFor = (shiftId) => attendanceByShift.value.get(shiftId)

const shiftEndFor = (item) => effectiveShiftEnd(item, clockRecordFor(item.id))

const editingShift = computed(() => shifts.value.find((s) => s.id === editingShiftId.value))

const editingCrew = computed(() =>
  editingShift.value ? shifts.value.filter((s) => sameWorkSlot(s, editingShift.value)) : []
)

const crewHasClocked = computed(() => editingCrew.value.some((s) => clockRecordFor(s.id)))

const completedShiftIds = computed(
  () =>
    new Set(
      clockRecords.value.filter((record) => record.checked_out_at).map((record) => record.shift_id)
    )
)

const workIsCompleted = (item) =>
  shifts.value.some((shift) => completedShiftIds.value.has(shift.id) && sameWorkSlot(shift, item))

const completedWorkMessage = 'Ca đã hoàn tất chấm công nên không thể cập nhật.'

const endedWorkMessage = 'Ca đã qua giờ kết thúc nên không thể sửa.'

const scheduleNow = ref(Date.now())

const shiftHasEnded = (item, now = Date.now()) => Date.parse(item.ends_at) <= now

const editingShiftHasEnded = computed(
  () => !!editingShift.value && shiftHasEnded(editingShift.value, scheduleNow.value)
)

function shiftEditLockLabel(item) {
  if (workIsCompleted(item)) return 'Đã hoàn tất · Không thể sửa'
  return shiftHasEnded(item, scheduleNow.value) ? 'Đã qua giờ kết thúc · Không thể sửa' : ''
}

const crewMemberClocked = (userId) =>
  editingCrew.value.some((s) => s.user_id === userId && clockRecordFor(s.id))

const notificationEventLabel = (event) =>
  ({
    company_application: 'Chờ duyệt',
    created: 'Ca mới',
    updated: 'Thay đổi lịch',
    cancelled: 'Ca đã hủy',
    employment_changed: 'Đổi vai trò',
    attendance_in: 'Chấm công vào',
    attendance_out: 'Chấm công ra',
    join_request: 'Yêu cầu gia nhập'
  })[event] || 'Thông báo'

const tabs = computed(() => [
  ['calendar', 'Phân ca'],
  ['payroll', 'Bảng công & lương'],
  ['notifications', 'Thông báo'],
  ['people', 'Quản lý nhân sự'],
  ['community', 'Tuyển nhân sự'],
  ['profile', 'Hồ sơ của tôi']
])

const days = computed(() => {
  const year = month.value.getFullYear(),
    m = month.value.getMonth(),
    offset = (new Date(year, m, 1).getDay() + 6) % 7,
    count = new Date(year, m + 1, 0).getDate()
  return [...Array(offset).fill(null), ...Array.from({ length: count }, (_, i) => i + 1)]
})

const nameOf = (id) => members.value.find((m) => m.user_id === id)?.full_name || 'Nhân viên'

const payFor = (id) => compensation.value.find((p) => p.user_id === id)

function memberRole(member) {
  return member.role === 'manager' ? 'manager' : workerRole(payFor(member.user_id)?.employment_type)
}

const filteredMembers = computed(() =>
  members.value.filter((person) => {
    const query = peopleSearch.value.trim().toLocaleLowerCase('vi-VN')
    if (query && !`${person.full_name} ${person.email}`.toLocaleLowerCase('vi-VN').includes(query))
      return false
    if (peopleFilter.value === 'active') return person.is_active
    if (peopleFilter.value === 'inactive') return !person.is_active
    if (peopleFilter.value === 'staff' || peopleFilter.value === 'freelance')
      return person.is_active && memberRole(person) === peopleFilter.value
    return true
  })
)

const memberGroups = computed(() => {
  const list = filteredMembers.value
  return [
    { label: roleLabel('manager'), items: list.filter((m) => m.role === 'manager') },
    {
      label: roleLabel('staff'),
      items: list.filter((m) => m.is_active && memberRole(m) === 'staff')
    },
    {
      label: roleLabel('freelance'),
      items: list.filter((m) => m.is_active && memberRole(m) === 'freelance')
    },
    {
      label: 'Đã tạm ngừng làm việc',
      items: list.filter((m) => m.role !== 'manager' && !m.is_active)
    }
  ].filter((group) => group.items.length)
})

async function toggleMember(person) {
  const active = !person.is_active
  const prompt = active
    ? `Kích hoạt lại ${person.full_name}?`
    : `Tạm ngừng hợp tác với ${person.full_name}? Các ca trong tương lai chưa chấm công sẽ được hủy và nhân viên nhận thông báo.`
  if (!window.confirm(prompt)) return
  await perform(
    () =>
      repo.rpc('manager_set_staff_active', {
        p_company: companyId.value,
        p_user: person.user_id,
        p_active: active
      }),
    active
      ? 'Đã kích hoạt lại nhân viên.'
      : 'Đã tạm ngừng nhân viên; các ca tương lai chưa chấm công đã được hủy.'
  )
}

const vndFormat = new Intl.NumberFormat('vi-VN')

const money = (value) =>
  value != null && Number.isFinite(Number(value))
    ? `${vndFormat.format(Number(value))} ₫`
    : 'Chưa có'

function openPay(member) {
  if (
    isAdmin ||
    !manager.value ||
    member.role !== 'staff' ||
    busy.value ||
    compensationUnavailable.value
  )
    return
  const pay = payFor(member.user_id)
  Object.assign(payForm, {
    user_id: member.user_id,
    name: member.full_name,
    employment_type: pay?.employment_type || 'freelancer',
    monthly_base_vnd: pay?.monthly_base_vnd ?? '',
    monthly_allowance_vnd: pay?.monthly_allowance_vnd ?? 0
  })
  error.value = ''
  modal.value = 'pay'
}

function savePay() {
  if (
    isAdmin ||
    !manager.value ||
    busy.value ||
    compensationUnavailable.value ||
    !members.value.some((member) => member.user_id === payForm.user_id && member.role === 'staff')
  )
    return
  const base = payForm.employment_type === 'freelancer' ? null : Number(payForm.monthly_base_vnd)
  const allowance = Number(payForm.monthly_allowance_vnd)
  if (
    payForm.monthly_allowance_vnd === '' ||
    (base !== null && payForm.monthly_base_vnd === '') ||
    !Number.isSafeInteger(allowance) ||
    allowance < 0 ||
    allowance > 99999999999999 ||
    (base !== null && (!Number.isSafeInteger(base) || base < 0 || base > 99999999999999))
  ) {
    error.value = 'Hãy nhập số tiền hợp lệ, không âm.'
    return
  }
  perform(
    () =>
      repo.saveCompensation({
        company_id: companyId.value,
        user_id: payForm.user_id,
        employment_type: payForm.employment_type,
        monthly_base_vnd: base,
        monthly_allowance_vnd: allowance,
        updated_at: new Date().toISOString()
      }),
    'Đã lưu vai trò và lương.',
    true
  )
}

function shiftsForDate(dateText, schedule = shifts.value) {
  const start = new Date(dateText + 'T00:00:00')
  const end = new Date(start)
  end.setDate(end.getDate() + 1)
  return schedule.filter((s) => new Date(s.starts_at) < end && new Date(shiftEndFor(s)) > start)
}

const shiftsOn = (day) =>
  shiftsForDate(localDate(new Date(month.value.getFullYear(), month.value.getMonth(), day)))

const monthShifts = computed(() =>
  shifts.value.filter((s) => {
    const d = new Date(s.starts_at)
    return d.getFullYear() === month.value.getFullYear() && d.getMonth() === month.value.getMonth()
  })
)

const upcomingCount = computed(
  () => shifts.value.filter((s) => new Date(s.starts_at) > new Date()).length
)

const selectedShifts = computed(() =>
  shiftsForDate(selectedDate.value).sort((a, b) => new Date(a.starts_at) - new Date(b.starts_at))
)

watch(
  [canSchedule, selectedShifts],
  ([allowed, items], _, onCleanup) => {
    if (!allowed || !items.length) return
    const endTimes = items.map((item) => Date.parse(item.ends_at))
    let timer
    function refreshScheduleTime() {
      const now = Date.now()
      scheduleNow.value = now
      const nextEnd = Math.min(...endTimes.filter((end) => end > now))
      if (Number.isFinite(nextEnd)) {
        timer = window.setTimeout(refreshScheduleTime, Math.min(nextEnd - now, 2 ** 31 - 1))
      }
    }
    onCleanup(() => window.clearTimeout(timer))
    refreshScheduleTime()
  },
  { immediate: true }
)

const selectedDayHasAttendance = computed(() =>
  selectedShifts.value.some((item) => clockRecordFor(item.id))
)

const attendedDayMessage = 'Ngày này đã có chấm công nên không thể thêm hoặc sửa ca.'

const selectedDayAddBlock = computed(() =>
  selectedDayHasAttendance.value
    ? attendedDayMessage
    : selectedDate.value < localDate(new Date())
      ? 'Chỉ có thể phân ca với giờ bắt đầu trong tương lai.'
      : ''
)

const selectedDateLabel = computed(() =>
  new Date(selectedDate.value + 'T12:00:00').toLocaleDateString('vi-VN', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric'
  })
)

const timeOf = (stamp) =>
  new Date(stamp).toLocaleTimeString('vi-VN', { hour: '2-digit', minute: '2-digit' })

function isMorningShift(start, end) {
  const noon = new Date(start)
  noon.setHours(12, 0, 0, 0)
  return end > start && start < noon && end <= noon
}

function assignedShiftText(item) {
  const start = new Date(item.starts_at)
  const end = new Date(item.ends_at)
  const period = isMorningShift(start, end) ? 'ca sáng' : 'ca'
  return `${nameOf(item.user_id)} đã được phân ${period} “${item.title}” (${timeOf(start)} - ${timeOf(end)})`
}

const morningAssignments = computed(() => {
  const start = new Date(`${shift.date}T${shift.start}`)
  const end = new Date(`${shift.end_date}T${shift.end}`)
  if (!isMorningShift(start, end)) return []
  const editingIds = new Set(editingCrew.value.map((item) => item.id))
  return shifts.value.filter((item) => {
    if (!shift.user_ids.includes(item.user_id) || editingIds.has(item.id)) return false
    const assignedStart = new Date(item.starts_at)
    return (
      localDate(assignedStart) === shift.date &&
      isMorningShift(assignedStart, new Date(item.ends_at))
    )
  })
})

const dateForDay = (day) =>
  localDate(new Date(month.value.getFullYear(), month.value.getMonth(), day))

const isToday = (day) => dateForDay(day) === localDate(new Date())

const dayAction = (day) => (shiftsOn(day).length ? 'Quản lý ca trong ngày' : 'Phân ca mới')

function clickCalendarCell(day) {
  if (!canSchedule.value || busy.value) return
  selectedDate.value = dateForDay(day)
  if (selectedShifts.value.length) {
    error.value = ''
    modal.value = 'shift-picker'
  } else {
    openShift(day)
  }
}

function chooseShiftStaff(userId, checked) {
  if (editingShiftId.value && crewMemberClocked(userId) && !checked) return
  shift.user_ids = checked
    ? [...new Set([...shift.user_ids, userId])]
    : shift.user_ids.filter((id) => id !== userId)
}

function editShift(item) {
  if (!canSchedule.value || busy.value || selectedDayHasAttendance.value || workIsCompleted(item))
    return
  scheduleNow.value = Date.now()
  if (shiftHasEnded(item, scheduleNow.value)) return
  const start = new Date(item.starts_at),
    end = new Date(item.ends_at)
  selectedDate.value = localDate(start)
  month.value = new Date(start.getFullYear(), start.getMonth(), 1)
  editingShiftId.value = item.id
  Object.assign(shift, {
    title: item.title,
    location: item.location || '',
    date: localDate(start),
    end_date: localDate(end),
    start: inputTime(start),
    end: inputTime(end),
    cast_vnd: Number(item.cast_vnd || 0),
    user_ids: shifts.value.filter((s) => sameWorkSlot(s, item)).map((s) => s.user_id)
  })
  error.value = ''
  modal.value = 'shift'
}

function goToToday() {
  month.value = new Date(new Date().getFullYear(), new Date().getMonth(), 1)
  selectedDate.value = localDate(new Date())
}

function createShiftOnSelectedDay() {
  if (!canSchedule.value) return
  const [y, m, d] = selectedDate.value.split('-').map(Number)
  month.value = new Date(y, m - 1, 1)
  openShift(d)
}

function changeMonth(delta) {
  month.value = new Date(month.value.getFullYear(), month.value.getMonth() + delta, 1)
  selectedDate.value = localDate(month.value)
}

function openShift(day) {
  if (!canSchedule.value || busy.value) return
  if (selectedDayAddBlock.value) {
    error.value = selectedDayAddBlock.value
    return
  }
  error.value = ''
  editingShiftId.value = ''
  const date = dateForDay(day)
  Object.assign(shift, {
    title: '',
    location: accountProfile.active_location || '',
    date,
    end_date: date,
    start: '08:00',
    end: '12:00',
    cast_vnd: 300000,
    user_ids: []
  })
  modal.value = 'shift'
}

const inputTime = (date) =>
  [date.getHours(), date.getMinutes()].map((value) => String(value).padStart(2, '0')).join(':')

const shiftPeriods = {
  morning: ['08:00', '12:00'],
  afternoon: ['13:00', '17:00'],
  evening: ['18:00', '23:00'],
  all: ['08:00', '23:00']
}

const shiftPeriod = computed(
  () =>
    Object.keys(shiftPeriods).find((key) => {
      const [start, end] = shiftPeriods[key]
      return start === shift.start && end === shift.end
    }) || 'custom'
)

function setPeriod(event) {
  const times = shiftPeriods[event.target.value]
  if (times) [shift.start, shift.end] = times
}

async function perform(fn, success, close = false) {
  if ((await w.perform(fn, success)) && close) modal.value = ''
}

async function saveShift() {
  if (busy.value) return
  if (!canSchedule.value) {
    error.value = 'Chỉ Manager mới được phân ca.'
    return
  }
  if (editingShift.value && workIsCompleted(editingShift.value)) {
    error.value = completedWorkMessage
    return
  }
  scheduleNow.value = Date.now()
  if (editingShiftHasEnded.value) {
    error.value = endedWorkMessage
    return
  }
  let rows = [],
    plan = null
  try {
    const eligible = new Set(assignableMembers.value.map((m) => m.user_id))
    if (!shift.user_ids.every((id) => eligible.has(id)))
      throw new Error('Chỉ được phân ca cho nhân viên thuộc công ty.')
    if (editingShiftId.value) {
      plan = shiftEditPlan(
        shift,
        companyId.value,
        editingShiftId.value,
        shifts.value,
        clockRecords.value.map((c) => c.shift_id)
      )
    } else rows = shiftRows(shift, companyId.value, shifts.value)
  } catch (e) {
    error.value =
      e instanceof ShiftOverlapError
        ? `${assignedShiftText(e.shift)}, trùng giờ với ca này.`
        : e?.message || 'Ca làm việc chưa hợp lệ.'
    return
  }
  busy.value = true
  error.value = ''
  message.value = ''
  try {
    const company = companyId.value
    const shiftId = editingShiftId.value
    const original = editingShift.value
    const date = shift.date
    const work = plan ? plan.updates[0]?.changes || plan.addedRows[0] : rows[0]
    const userIds = [...shift.user_ids]
    const changesTime =
      !original ||
      new Date(work.starts_at).getTime() !== new Date(original.starts_at).getTime() ||
      new Date(work.ends_at).getTime() !== new Date(original.ends_at).getTime()
    if (changesTime && Date.parse(work.starts_at) <= Date.now()) {
      throw new Error('Giờ bắt đầu ca phải ở tương lai.')
    }
    const [attendance, schedule] = await Promise.all([
      repo.attendance(company),
      repo.shifts(company)
    ])
    if (
      companyId.value !== company ||
      editingShiftId.value !== shiftId ||
      modal.value !== 'shift'
    ) {
      busy.value = false
      return
    }
    clockRecords.value = attendance || []
    const attendedIds = new Set(clockRecords.value.map((record) => record.shift_id))
    const workEndDate = localDate(new Date(Date.parse(work.ends_at) - 1))
    if (
      [date, workEndDate].some((day) =>
        shiftsForDate(day, schedule).some((item) => attendedIds.has(item.id))
      )
    ) {
      throw new Error(attendedDayMessage)
    }
    if (changesTime && Date.parse(work.starts_at) <= Date.now()) {
      throw new Error('Giờ bắt đầu ca phải ở tương lai.')
    }
    if (shiftId) {
      const latestShift = schedule.find((item) => item.id === shiftId)
      if (!latestShift) throw new Error('Không tìm thấy ca làm cần sửa. Hãy tải lại lịch.')
      if (shiftHasEnded(original) || shiftHasEnded(latestShift)) {
        shifts.value = schedule
        scheduleNow.value = Date.now()
        throw new Error(endedWorkMessage)
      }
      await repo.updateWorkAssignments(shiftId, work, userIds)
    } else {
      await repo.insert('company_shifts', rows)
    }
  } catch (e) {
    const errors = {
      '23P01': 'Nhân viên bị trùng ca, có thể ở công ty khác. Hãy chọn giờ khác.',
      23503: 'Nhân viên không thuộc công ty này.',
      23514: 'Thời lượng ca không hợp lệ.',
      42501: 'Tài khoản chưa được cấp quyền phân ca.',
      P4510: 'Ca đã chấm công, không được hủy.',
      P4511: 'Ca đã chấm công, không được đổi nhân viên hoặc giờ làm.',
      P4512: 'Ca đã chấm công, không được thay đổi Cast hoặc bỏ nhân viên đã chấm công.',
      P4561: 'Chỉ Manager mới được cập nhật phân công.',
      PGRST202: 'Cần chạy supabase/multi_staff_assignment.sql trong Supabase.',
      P4562: 'Danh sách phân công hoặc dữ liệu ca chưa hợp lệ.',
      PGRST205: 'Bảng lịch chưa tồn tại trong Supabase.'
    }
    error.value = errors[e?.code] || e?.message || 'Không thể lưu ca. Vui lòng thử lại.'
    busy.value = false
    return
  }
  modal.value = ''
  message.value = editingShiftId.value
    ? `Đã cập nhật phân công cho ${shift.user_ids.length} nhân viên.`
    : `Đã lưu ${rows.length} ca làm việc thành công.`
  editingShiftId.value = ''
  try {
    await w.refreshCompany()
  } catch (e) {
    error.value = 'Ca đã lưu thành công, nhưng chưa tải lại được lịch. Vui lòng tải lại trang.'
  } finally {
    busy.value = false
  }
}

async function removeShift(item) {
  const items = item ? [item] : selectedShifts.value
  if (!canSchedule.value || busy.value || !items.length) return
  if (items.some((shift) => clockRecordFor(shift.id))) {
    error.value = 'Có ca đã chấm công nên không thể xóa.'
    return
  }
  const confirmation = item
    ? `Hủy ca "${item.title}" của ${nameOf(item.user_id)}?`
    : `Xóa tất cả ${items.length} ca hiển thị vào ${selectedDateLabel.value}? Ca qua đêm cũng sẽ bị xóa khỏi những ngày liên quan.`
  if (!window.confirm(confirmation)) return
  busy.value = true
  error.value = ''
  message.value = ''
  try {
    const removed = await repo.deleteShifts(
      items.map((shift) => shift.id),
      companyId.value
    )
    modal.value = ''
    message.value = item ? 'Đã hủy ca làm việc.' : `Đã xóa ${removed.length} ca làm việc.`
    try {
      await w.refreshCompany()
    } catch {
      error.value = 'Đã hủy ca nhưng chưa tải lại được lịch. Hãy làm mới trang.'
    }
  } catch (e) {
    error.value =
      e?.code === 'P4510' || e?.code === '23503'
        ? 'Có ca đã chấm công nên không thể xóa. Vui lòng tải lại lịch.'
        : e?.message || 'Không thể hủy ca này.'
  } finally {
    busy.value = false
  }
}

function onWindowFocus() {
  if (restriction.value?.disabled || document.visibilityState === 'hidden') return
  w.refreshNotifications()
  if (tab.value === 'calendar') w.refreshCompany().catch(() => {})
}

let notificationPoll = null

function changeCompany(id) {
  if (id === companyId.value || busy.value) return
  companyId.value = id
  modal.value = ''
  error.value = ''
  message.value = ''
  w.refreshCompany().catch((e) => {
    if (companyId.value === id) error.value = e?.message || 'Không tải được công ty.'
  })
}

watch(tabs, (available) => {
  if (!available.some((item) => item[0] === tab.value)) tab.value = 'calendar'
})

watch(tab, (next) => {
  if (next === 'notifications') w.refreshNotifications()
  if (next === 'payroll') w.refreshPayroll(reportMonthText.value)
})

watch(reportMonth, () => {
  if (tab.value === 'payroll') w.refreshPayroll(reportMonthText.value)
})

watch(companyId, () => {
  if (tab.value === 'payroll') w.refreshPayroll(reportMonthText.value)
})

onMounted(() => {
  repo
    .accountProfile(props.user.id)
    .then((p) => {
      if (p)
        Object.assign(accountProfile, {
          full_name: p.full_name || accountProfile.full_name,
          birth_date: p.birth_date || '',
          hometown: p.hometown || '',
          active_location: p.active_location || '',
          avatar_url: p.avatar_url || ''
        })
    })
    .catch((e) => {
      error.value = e?.message || 'Không tải được hồ sơ.'
    })

  window.addEventListener('focus', onWindowFocus)
  // Keep the unread badge fresh without requiring users to open the inbox.
  notificationPoll = window.setInterval(() => {
    if (!restriction.value?.disabled && document.visibilityState === 'visible')
      w.refreshNotifications()
  }, 60000)
})

onUnmounted(() => {
  if (avatarPreview.value) URL.revokeObjectURL(avatarPreview.value)
  window.removeEventListener('focus', onWindowFocus)
  if (notificationPoll) window.clearInterval(notificationPoll)
})
</script>

<template>
  <div class="role-page role-manager">
    <ToastStack ref="toastStack" />
    <dialog
      ref="notificationDialog"
      class="shift-notice-dialog"
      aria-labelledby="shift-notice-title"
      @close="activeNotification = null"
    >
      <template v-if="activeNotification">
        <div class="shift-notice-header">
          <div>
            <p>{{ notificationEventLabel(activeNotification.event) }}</p>
            <h2 id="shift-notice-title">
              {{ notificationDetail?.title || activeNotification.title }}
            </h2>
          </div>
          <form method="dialog"><button type="submit" autofocus>Đóng</button></form>
        </div>
        <p v-if="activeNotification.event === 'cancelled'" class="notice">
          Ca này đã bị hủy. Thông tin dưới đây là lịch trước khi hủy.
        </p>
        <p v-if="notificationReadError" class="alert" role="alert">{{ notificationReadError }}</p>
        <dl v-if="notificationDetail" class="shift-notice-fields">
          <div>
            <dt>Công ty</dt>
            <dd>
              {{
                directory.find((c) => c.id === activeNotification.company_id)?.name ||
                'Công ty phân ca'
              }}
            </dd>
          </div>
          <div>
            <dt>Địa điểm</dt>
            <dd>{{ notificationDetail.location || 'Chưa cập nhật' }}</dd>
          </div>
          <div>
            <dt>Bắt đầu</dt>
            <dd>{{ noticeDateFormat.format(new Date(notificationDetail.starts_at)) }}</dd>
          </div>
          <div>
            <dt>Kết thúc</dt>
            <dd>{{ noticeDateFormat.format(new Date(notificationDetail.ends_at)) }}</dd>
          </div>
        </dl>
        <p v-else-if="notificationDetailLoading" role="status">Đang tải chi tiết ca...</p>
        <p v-else>{{ activeNotification.body }}</p>
      </template>
    </dialog>
    <div class="app-shell">
      <aside class="sidebar">
        <div class="brand">
          <span class="brand-mark">S</span>
          <div>
            <strong>SHIFTLY</strong>
            <small>Quản lý nhân sự sự kiện</small>
          </div>
        </div>
        <div class="workspace-profile">
          <img
            class="profile-avatar"
            :src="avatarPreview || accountProfile.avatar_url || defaultAvatar"
            alt="Ảnh đại diện"
          />
          <div class="profile-details">
            <div class="profile-name-row">
              <b class="profile-name" :title="accountProfile.full_name || 'Tài khoản'">
                {{ accountProfile.full_name || 'Tài khoản' }}
              </b>
              <span class="profile-role" :title="roleLabel('manager')">{{ profileRoleLabel }}</span>
            </div>
            <small class="profile-email" :title="user.email">{{ user.email }}</small>
          </div>
        </div>
        <div class="side-label">QUẢN LÝ CÔNG TY</div>
        <nav aria-label="Điều hướng chính">
          <button
            v-for="item in tabs"
            :key="item[0]"
            :class="{ selected: tab === item[0] }"
            :aria-current="tab === item[0] ? 'page' : undefined"
            @click="tab = item[0]"
          >
            {{ item[1] }}
            <span v-if="item[0] === 'notifications' && unreadCount" class="nav-unread">
              {{ unreadCount }}
            </span>
          </button>
          <button type="button" class="nav-sign-out" @click="repo.auth.signOut()">Đăng xuất</button>
        </nav>
      </aside>
      <div class="main-area">
        <header class="mobile-header">
          <div class="brand">
            <span class="brand-mark">S</span>
            <div>
              <strong>SHIFTLY</strong>
              <small>Quản lý nhân sự sự kiện</small>
            </div>
          </div>
          <div class="workspace-profile">
            <img
              class="profile-avatar"
              :src="avatarPreview || accountProfile.avatar_url || defaultAvatar"
              alt="Ảnh đại diện"
            />
            <div class="profile-details">
              <div class="profile-name-row">
                <b class="profile-name" :title="accountProfile.full_name || 'Tài khoản'">
                  {{ accountProfile.full_name || 'Tài khoản' }}
                </b>
                <span class="profile-role" :title="roleLabel('manager')">
                  {{ profileRoleLabel }}
                </span>
              </div>
              <small class="profile-email" :title="user.email">{{ user.email }}</small>
            </div>
          </div>
        </header>
        <nav class="mobile-nav" aria-label="Điều hướng trên điện thoại">
          <button
            v-for="item in tabs"
            :key="item[0]"
            :class="{ selected: tab === item[0] }"
            :aria-current="tab === item[0] ? 'page' : undefined"
            @click="tab = item[0]"
          >
            {{ item[1] }}
            <span v-if="item[0] === 'notifications' && unreadCount" class="nav-unread">
              {{ unreadCount }}
            </span>
          </button>
          <button type="button" class="nav-sign-out" @click="repo.auth.signOut()">Đăng xuất</button>
        </nav>
        <main class="content">
          <div class="page-heading">
            <div>
              <p class="eyebrow">{{ roleLabel('manager') }}</p>
              <h1>{{ tabs.find((t) => t[0] === tab)?.[1] }}</h1>
              <p v-if="tab !== 'people'">
                {{
                  tab === 'notifications'
                    ? 'Theo dõi ca làm và thay đổi ở các công ty bạn tham gia.'
                    : 'Điều phối ca làm việc và nhân sự của công ty đang chọn.'
                }}
              </p>
            </div>
            <div v-if="current" class="company-context">
              <p id="company-options-label" class="company-options-label">
                Công ty của bạn
                <span>{{ selectableCompanies.length }}</span>
              </p>
              <div class="company-options" role="group" aria-labelledby="company-options-label">
                <button
                  v-for="company in selectableCompanies"
                  :key="company.id"
                  class="company-choice"
                  type="button"
                  :aria-pressed="companyId === company.id"
                  :disabled="busy"
                  @click="changeCompany(company.id)"
                >
                  {{ company.name }}
                </button>
              </div>
            </div>
          </div>
          <section v-if="tab === 'profile'" class="surface section">
            <h2>Hồ sơ của tôi</h2>
            <p>
              Áp dụng cho tài khoản {{ roleLabel('manager') }}. Cập nhật quê quán, khu vực hoạt động
              và ảnh đại diện.
            </p>
            <form class="form" @submit.prevent="saveAccountProfile">
              <img
                class="profile-avatar profile-avatar-large"
                :src="avatarPreview || accountProfile.avatar_url || defaultAvatar"
                alt="Ảnh đại diện"
              />
              <label>
                Ảnh đại diện
                <input
                  type="file"
                  accept="image/jpeg,image/png,image/webp"
                  @change="chooseAvatar"
                />
              </label>
              <label>
                Họ và tên
                <input v-model="accountProfile.full_name" required maxlength="120" />
              </label>
              <label>
                Ngày sinh
                <input v-model="accountProfile.birth_date" type="date" />
              </label>
              <div class="location-field">
                <span class="location-title">Quê quán</span>
                <LocationPicker v-model="accountProfile.hometown" />
              </div>
              <div class="location-field">
                <span class="location-title">Khu vực đang hoạt động (mặc định khi phân ca)</span>
                <LocationPicker v-model="accountProfile.active_location" />
              </div>
              <button class="primary" :disabled="busy">Lưu hồ sơ</button>
            </form>
          </section>
          <section v-if="invitations.length" class="surface section">
            <h2>Lời mời tham gia</h2>
            <div v-for="i in invitations" :key="i.id" class="row">
              <span>{{ directory.find((c) => c.id === i.company_id)?.name || 'Công ty' }}</span>
              <button
                :disabled="busy"
                @click="
                  perform(
                    () => repo.rpc('accept_company_invitation', { p_invitation: i.id }),
                    'Đã tham gia công ty.'
                  )
                "
              >
                Chấp nhận
              </button>
            </div>
          </section>
          <template v-if="tab === 'calendar'">
            <section v-if="!companyId" class="surface empty">
              <h2>Bạn chưa tham gia công ty nào</h2>
              <p>Hãy vào mục Cộng đồng để gửi yêu cầu tham gia hoặc chấp nhận lời mời phía trên.</p>
            </section>
            <template v-else>
              <section class="overview-grid" aria-label="Tổng quan lịch làm việc">
                <div class="overview-tile">
                  <span>Nhân sự</span>
                  <strong>{{ members.length }}</strong>
                  <small>Thành viên của công ty</small>
                </div>
                <div class="overview-tile">
                  <span>Ca trong tháng</span>
                  <strong>{{ monthShifts.length }}</strong>
                  <small>Tất cả ca được phân</small>
                </div>
                <div class="overview-tile">
                  <span>Ca sắp tới</span>
                  <strong>{{ upcomingCount }}</strong>
                  <small>Ca của đội ngũ</small>
                </div>
              </section>
              <div>
                <div>
                  <div class="calendar-controls">
                    <div>
                      <h2>
                        {{ month.toLocaleDateString('vi-VN', { month: 'long', year: 'numeric' }) }}
                      </h2>
                      <p>Nhấn ô trống để phân ca. Nhấn ô có ca để mở menu quản lý.</p>
                    </div>
                    <div class="calendar-tools">
                      <div class="button-group">
                        <button type="button" aria-label="Tháng trước" @click="changeMonth(-1)">
                          ‹
                        </button>
                        <button type="button" @click="goToToday">Hôm nay</button>
                        <button type="button" aria-label="Tháng sau" @click="changeMonth(1)">
                          ›
                        </button>
                      </div>
                      <button
                        type="button"
                        class="primary add-shift-button"
                        :disabled="busy || !!selectedDayAddBlock"
                        :title="selectedDayAddBlock"
                        @click="createShiftOnSelectedDay"
                      >
                        + Phân ca mới
                      </button>
                    </div>
                  </div>
                  <div class="calendar-wrap">
                    <div class="calendar">
                      <div
                        v-for="name in ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN']"
                        :key="name"
                        class="weekday"
                      >
                        {{ name }}
                      </div>
                      <div
                        v-for="(day, index) in days"
                        :key="index"
                        class="day"
                        :class="{
                          blank: !day,
                          active: day && selectedDate === dateForDay(day),
                          'has-shifts': day && shiftsOn(day).length
                        }"
                      >
                        <button
                          v-if="day"
                          type="button"
                          class="day-button"
                          :aria-description="dayAction(day)"
                          :aria-current="isToday(day) ? 'date' : undefined"
                          :aria-pressed="selectedDate === dateForDay(day)"
                          @click="clickCalendarCell(day)"
                        >
                          <span class="day-number">{{ day }}</span>
                          <span v-if="shiftsOn(day).length" class="day-shift-count">
                            {{ shiftsOn(day).length }} ca
                          </span>
                          <template>
                            <span v-for="s in shiftsOn(day)" :key="s.id" class="shift-chip">
                              {{ timeOf(s.starts_at) }} {{ s.title }}
                              <small>{{ nameOf(s.user_id) }}</small>
                            </span>
                          </template>
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
                <section
                  :id="undefined"
                  class="surface section day-detail"
                  aria-label="Chi tiết ca theo ngày"
                >
                  <div class="section-title">
                    <div>
                      <h2>Ca làm · {{ selectedDateLabel }}</h2>
                      <p>Lịch phân công của công ty.</p>
                    </div>
                  </div>
                  <div v-if="selectedDayAddBlock" class="notice" role="status">
                    {{ selectedDayAddBlock }}
                  </div>
                  <div v-if="!selectedShifts.length" class="empty day-empty">
                    Không có ca nào trong ngày này.
                  </div>
                  <div v-for="item in selectedShifts" :key="item.id" class="row shift-detail-row">
                    <div class="shift-timing">
                      <strong>
                        {{ timeOf(item.starts_at) }} - {{ timeOf(shiftEndFor(item)) }}
                      </strong>
                      <small v-if="localDate(new Date(item.starts_at)) !== selectedDate">
                        Bắt đầu ngày {{ localDate(new Date(item.starts_at)) }}
                      </small>
                      <small v-if="localDate(new Date(shiftEndFor(item))) !== selectedDate">
                        Kết thúc ngày {{ localDate(new Date(shiftEndFor(item))) }}
                      </small>
                      <small v-if="shiftEndFor(item) !== item.ends_at">
                        Dự kiến kết thúc {{ timeOf(item.ends_at) }}
                      </small>
                    </div>
                    <div class="shift-description">
                      <b>{{ item.title }}</b>
                      <small>
                        {{ item.location || 'Chưa cập nhật địa điểm' }}
                        <template>· {{ nameOf(item.user_id) }}</template>
                      </small>
                    </div>
                    <div class="shift-actions">
                      <span v-if="shiftEditLockLabel(item)" class="clock-locked">
                        {{ shiftEditLockLabel(item) }}
                      </span>
                      <span v-else-if="clockRecordFor(item.id)" class="clock-locked">
                        Đã chấm công vào · Không thể hủy
                      </span>
                      <button
                        v-else-if="!selectedDayHasAttendance"
                        type="button"
                        :disabled="busy"
                        @click="editShift(item)"
                      >
                        Sửa ca
                      </button>
                      <button
                        type="button"
                        class="danger-quiet"
                        :disabled="busy || !!clockRecordFor(item.id)"
                        :title="clockRecordFor(item.id) ? 'Ca đã chấm công không thể hủy' : ''"
                        :aria-label="'Hủy ca ' + item.title + ' của ' + nameOf(item.user_id)"
                        @click="removeShift(item)"
                      >
                        Hủy ca
                      </button>
                    </div>
                  </div>
                </section>
              </div>
            </template>
          </template>
          <section v-if="tab === 'notifications'" class="surface section notifications-section">
            <div class="section-title">
              <div>
                <h2>Thông báo công việc</h2>
                <p>Ca làm, chấm công và yêu cầu gia nhập theo vai trò của bạn ở từng công ty.</p>
              </div>
              <button
                type="button"
                :disabled="notificationsLoading"
                @click="w.refreshNotifications()"
              >
                Làm mới
              </button>
            </div>
            <div
              class="notification-filters"
              role="group"
              aria-label="Lọc thông báo theo thời gian"
            >
              <button
                type="button"
                :aria-pressed="notificationGroup === 'current'"
                @click="selectNotificationGroup('current')"
              >
                Hiện tại
                <span>{{ notificationGroups.current.length }}</span>
              </button>
              <button
                type="button"
                :aria-pressed="notificationGroup === 'past'"
                @click="selectNotificationGroup('past')"
              >
                Cũ hơn
                <span>{{ notificationGroups.past.length }}</span>
              </button>
            </div>
            <div v-if="notificationsError" class="alert" role="alert">{{ notificationsError }}</div>
            <div
              v-else-if="notificationsLoading && !notifications.length"
              class="empty"
              role="status"
            >
              Đang tải thông báo...
            </div>
            <div v-else-if="!visibleNotifications.length" class="empty">
              Chưa có thông báo trong mục này.
            </div>
            <div
              v-for="item in visibleNotifications"
              :key="item.id"
              class="row notification-row"
              :class="{ unread: !item.read_at }"
            >
              <div class="notification-main">
                <div class="notification-head">
                  <button
                    class="notification-title-button"
                    type="button"
                    aria-haspopup="dialog"
                    @click="openNotification(item)"
                  >
                    {{ item.title }}
                  </button>
                  <span class="badge">{{ notificationEventLabel(item.event) }}</span>
                </div>
                <small v-if="item.created_at">
                  <template v-if="item.company_id">
                    {{ directory.find((c) => c.id === item.company_id)?.name || 'Công ty' }} ·
                  </template>
                  {{ new Date(item.created_at).toLocaleString('vi-VN') }}
                </small>
                <p>{{ item.body }}</p>
              </div>
              <span class="read-label">{{ item.read_at ? 'Đã đọc' : 'Chưa đọc' }}</span>
            </div>
            <nav
              v-if="notificationPages > 1"
              class="notification-pagination"
              aria-label="Phân trang thông báo"
            >
              <button type="button" :disabled="notificationPage === 1" @click="notificationPage--">
                Trang trước
              </button>
              <span role="status">Trang {{ notificationPage }} / {{ notificationPages }}</span>
              <button
                type="button"
                :disabled="notificationPage === notificationPages"
                @click="notificationPage++"
              >
                Trang sau
              </button>
            </nav>
          </section>
          <section v-if="tab === 'payroll'" class="surface section payroll-section">
            <div class="section-title">
              <div>
                <h2>Bảng công & lương ước tính</h2>
                <p>Cast dự kiến gồm mọi ca đã phân. Cast hoàn tất chỉ tính ca đã chấm công ra.</p>
              </div>
              <div class="button-group payroll-month-controls">
                <button type="button" aria-label="Tháng trước" @click="changeReportMonth(-1)">
                  ‹
                </button>
                <b>
                  {{ reportMonth.toLocaleDateString('vi-VN', { month: 'long', year: 'numeric' }) }}
                </b>
                <button type="button" aria-label="Tháng sau" @click="changeReportMonth(1)">
                  ›
                </button>
                <button
                  type="button"
                  :disabled="payrollLoading"
                  @click="w.refreshPayroll(reportMonthText)"
                >
                  Làm mới
                </button>
              </div>
            </div>
            <div v-if="payrollError" class="alert" role="alert">{{ payrollError }}</div>
            <div v-else-if="payrollLoading" class="empty" role="status">
              Đang tải bảng công & lương...
            </div>
            <template v-else>
              <div class="payroll-summary">
                <div>
                  <span>Cast dự kiến</span>
                  <strong>{{ money(monthlyReportTotals.plannedCast) }}</strong>
                  <small>{{ monthlyReportTotals.scheduled }} ca đã phân</small>
                </div>
                <div>
                  <span>Cast hoàn tất</span>
                  <strong>{{ money(monthlyReportTotals.cast) }}</strong>
                  <small>
                    {{ monthlyReportTotals.completed }} ca ·
                    {{ formatWorkDuration(monthlyReportTotals.workedMs) }} làm việc
                  </small>
                </div>
                <div>
                  <span>Chi phí ước tính</span>
                  <strong>{{ money(monthlyReportTotals.total) }}</strong>
                  <small>Lương + phụ cấp + Cast hoàn tất</small>
                </div>
              </div>
              <div v-if="!payroll.length" class="empty">Công ty chưa có nhân sự để tính lương.</div>
              <div
                v-else
                class="payroll-table-wrap"
                role="region"
                aria-label="Chi tiết bảng công và lương theo nhân viên"
                tabindex="0"
              >
                <table class="payroll-table">
                  <thead>
                    <tr>
                      <th scope="col">Nhân viên</th>
                      <th scope="col">Cast dự kiến</th>
                      <th scope="col">Cast hoàn tất</th>
                      <th scope="col">Giờ thực tế</th>
                      <th scope="col">Lương tháng</th>
                      <th scope="col">Phụ cấp/tháng</th>
                      <th scope="col">Ước tính</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr v-for="person in payroll" :key="person.user_id">
                      <th scope="row">
                        <b>{{ person.full_name }}</b>
                        <small>
                          {{ employmentLabel(person.employment_type) }} · {{ person.email }}
                        </small>
                      </th>
                      <td>
                        {{ money(person.planned_cast_vnd) }}
                        <small>{{ person.scheduled_shifts }} ca đã phân</small>
                      </td>
                      <td>
                        {{ money(person.cast_total_vnd) }}
                        <small>{{ person.completed_shifts }} ca hoàn tất</small>
                      </td>
                      <td>{{ formatWorkDuration(person.worked_ms) }}</td>
                      <td>
                        {{
                          person.employment_type === 'employee'
                            ? money(person.monthly_base_vnd)
                            : 'Không áp dụng'
                        }}
                      </td>
                      <td>{{ money(person.monthly_allowance_vnd) }}</td>
                      <td>
                        <b>{{ money(person.estimated_total_vnd) }}</b>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </template>
            <p class="payroll-disclaimer">
              Đây là bản xem trước, không phải phiếu lương hoặc bằng chứng đã thanh toán. Thay đổi
              mức lương hiện tại có thể làm thay đổi ước tính của các tháng trước.
            </p>
          </section>
          <section v-if="tab === 'people'" class="surface section people-section">
            <div class="section-title">
              <div>
                <h2>{{ current?.name || 'Thành viên công ty' }}</h2>
                <p>Quản lý vai trò, mức lương và trạng thái làm việc của từng người.</p>
              </div>
              <button type="button" class="primary" :disabled="busy" @click="modal = 'invite'">
                + Mời nhân viên
              </button>
            </div>
            <div v-if="compensationUnavailable" class="alert" role="alert">
              Cần cài đặt bảng lương trong Supabase trước khi sửa mức lương.
            </div>
            <div class="people-toolbar">
              <label>
                Tìm nhân viên
                <input
                  v-model.trim="peopleSearch"
                  type="search"
                  placeholder="Tên hoặc email"
                  aria-label="Tìm nhân viên theo tên hoặc email"
                />
              </label>
              <label>
                Bộ lọc
                <select v-model="peopleFilter">
                  <option value="all">Tất cả nhân sự</option>
                  <option value="active">Đang làm việc</option>
                  <option value="staff">{{ roleLabel('staff') }}</option>
                  <option value="freelance">Freelance</option>
                  <option value="inactive">Đã tạm ngừng</option>
                </select>
              </label>
            </div>
            <div v-if="!members.length" class="empty">Công ty chưa có thành viên.</div>
            <div v-else-if="!filteredMembers.length" class="empty">
              Không có nhân viên phù hợp bộ lọc.
            </div>
            <div v-for="group in memberGroups" :key="group.label" class="member-group">
              <h3>
                {{ group.label }}
                <span>{{ group.items.length }}</span>
              </h3>
              <div
                v-for="person in group.items"
                :key="person.user_id"
                class="row member-row"
                :class="{ 'member-paused': !person.is_active }"
              >
                <div class="member-identity">
                  <b>{{ person.full_name }}</b>
                  <small>{{ person.email }}</small>
                  <small v-if="payFor(person.user_id)">
                    {{
                      payFor(person.user_id).employment_type === 'employee'
                        ? 'Cơ bản: ' +
                          money(payFor(person.user_id).monthly_base_vnd) +
                          ' / tháng • '
                        : ''
                    }}Phụ cấp/tháng: {{ money(payFor(person.user_id).monthly_allowance_vnd) }}
                  </small>
                  <small v-if="!person.is_active">
                    Đã tạm ngừng · Lịch cũ và chấm công vẫn được giữ
                  </small>
                </div>
                <div class="row-actions">
                  <span class="badge">{{ roleLabel(memberRole(person)) }}</span>
                  <button
                    v-if="person.role === 'staff'"
                    type="button"
                    :disabled="busy || compensationUnavailable"
                    @click="openPay(person)"
                  >
                    {{ payFor(person.user_id) ? 'Mức lương' : 'Thiết lập lương' }}
                  </button>
                  <button
                    v-if="person.role === 'staff'"
                    type="button"
                    :class="{ 'danger-quiet': person.is_active }"
                    :disabled="busy"
                    @click="toggleMember(person)"
                  >
                    {{ person.is_active ? 'Tạm ngừng' : 'Kích hoạt lại' }}
                  </button>
                </div>
              </div>
            </div>
          </section>
          <template v-if="tab === 'community'">
            <section class="surface section">
              <h2>Yêu cầu tham gia</h2>
              <div v-if="!requests.length" class="empty">Chưa có yêu cầu đang chờ.</div>
              <div v-for="r in requests" :key="r.user_id" class="row">
                <b>{{ r.full_name }}</b>
                <div class="row-actions">
                  <button
                    :disabled="busy"
                    @click="
                      perform(
                        () =>
                          repo.rpc('review_join_request', {
                            p_company: companyId,
                            p_user: r.user_id,
                            p_approve: false
                          }),
                        'Đã từ chối.'
                      )
                    "
                  >
                    Từ chối
                  </button>
                  <button
                    :disabled="busy"
                    @click="
                      perform(
                        () =>
                          repo.rpc('review_join_request', {
                            p_company: companyId,
                            p_user: r.user_id,
                            p_approve: true
                          }),
                        'Đã chấp nhận.'
                      )
                    "
                  >
                    Chấp nhận
                  </button>
                </div>
              </div>
            </section>
            <section class="surface section">
              <h2>Tuyển nhân sự Freelance</h2>
              <div v-if="!freelancers.length" class="empty">Chưa có hồ sơ công khai.</div>
              <div v-for="f in freelancers" :key="f.user_id" class="row">
                <div>
                  <b>{{ f.display_name }}</b>
                  <small>{{ f.specialty }}</small>
                </div>
                <button
                  :disabled="busy"
                  @click="
                    perform(
                      () =>
                        repo.rpc('invite_freelancer', { p_company: companyId, p_user: f.user_id }),
                      'Đã tạo lời mời.'
                    )
                  "
                >
                  Mời
                </button>
              </div>
            </section>
          </template>
        </main>
      </div>
      <div v-if="modal" class="overlay" @click.self="modal = ''" @keydown.esc="modal = ''">
        <section
          class="dialog"
          :class="{ 'shift-picker-dialog': modal === 'shift-picker' }"
          role="dialog"
          aria-modal="true"
          :aria-label="
            modal === 'shift'
              ? editingShiftId
                ? 'Cập nhật ca làm việc'
                : 'Phân ca làm việc'
              : modal === 'shift-picker'
                ? 'Quản lý ca trong ngày'
                : modal === 'pay'
                  ? 'Thiết lập lương'
                  : 'Mời nhân viên'
          "
        >
          <div class="dialog-heading">
            <h2>
              {{
                modal === 'shift'
                  ? editingShiftId
                    ? 'Cập nhật ca làm việc'
                    : 'Phân ca làm việc'
                  : modal === 'shift-picker'
                    ? 'Quản lý ca trong ngày'
                    : modal === 'pay'
                      ? 'Thiết lập lương'
                      : 'Mời nhân viên'
              }}
            </h2>
            <button ref="dialogClose" aria-label="Đóng" @click="modal = ''">×</button>
          </div>
          <div v-if="error" class="alert" role="alert">{{ error }}</div>
          <form
            v-if="modal === 'invite'"
            class="form"
            @submit.prevent="
              perform(
                () =>
                  repo.insert('company_invitations', {
                    company_id: companyId,
                    email: inviteEmail.trim().toLowerCase()
                  }),
                'Đã tạo lời mời.',
                true
              )
            "
          >
            <label>
              Email nhân viên
              <input v-model="inviteEmail" required type="email" />
            </label>
            <p>Nhân viên đăng nhập bằng email được mời để chấp nhận.</p>
            <div class="form-actions">
              <button type="button" @click="modal = ''">Hủy</button>
              <button class="primary" :disabled="busy">Gửi lời mời</button>
            </div>
          </form>
          <form v-else-if="modal === 'pay'" class="form" @submit.prevent="savePay">
            <p>Thiết lập cho {{ payForm.name }} tại {{ current?.name }}.</p>
            <label>
              Vai trò tại công ty
              <select v-model="payForm.employment_type">
                <option value="freelancer">Freelance</option>
                <option value="employee">{{ roleLabel('staff') }}</option>
              </select>
            </label>
            <label v-if="payForm.employment_type === 'employee'">
              Lương cơ bản mỗi tháng (₫)
              <input
                v-model="payForm.monthly_base_vnd"
                type="number"
                min="0"
                max="99999999999999"
                step="1"
                required
              />
            </label>
            <label>
              Phụ cấp hàng tháng (₫)
              <input
                v-model.number="payForm.monthly_allowance_vnd"
                type="number"
                min="0"
                max="99999999999999"
                step="1"
                required
              />
            </label>
            <p>
              {{ roleLabel('staff') }} có lương cơ bản hàng tháng. Cả {{ roleLabel('staff') }} và
              Freelance đều được tính phụ cấp tháng và Cast của các ca đã hoàn thành.
            </p>
            <div class="form-actions">
              <button type="button" @click="modal = ''">Hủy</button>
              <button class="primary" :disabled="busy">Lưu vai trò và lương</button>
            </div>
          </form>
          <section v-else-if="modal === 'shift-picker'" class="shift-picker">
            <p>{{ selectedDateLabel }} · {{ selectedShifts.length }} ca</p>
            <div v-for="item in selectedShifts" :key="item.id" class="row">
              <div>
                <b>{{ item.title }}</b>
                <small>
                  {{ timeOf(item.starts_at) }} - {{ timeOf(item.ends_at) }} ·
                  {{ nameOf(item.user_id) }}
                </small>
                <small v-if="item.location">{{ item.location }}</small>
              </div>
              <span v-if="shiftEditLockLabel(item)" class="clock-locked">
                {{ shiftEditLockLabel(item) }}
              </span>
              <button
                v-else-if="!selectedDayHasAttendance"
                type="button"
                :disabled="busy"
                @click="editShift(item)"
              >
                Sửa ca
              </button>
            </div>
            <p v-if="selectedDayAddBlock" class="shift-picker-lock">{{ selectedDayAddBlock }}</p>
            <div class="form-actions">
              <button
                type="button"
                class="danger-quiet"
                :disabled="busy || selectedDayHasAttendance"
                @click="removeShift()"
              >
                Xóa tất cả ca
              </button>
              <button
                type="button"
                class="primary"
                :disabled="busy || !!selectedDayAddBlock"
                @click="createShiftOnSelectedDay"
              >
                + Thêm ca mới
              </button>
            </div>
          </section>
          <form v-else class="form" @submit.prevent="saveShift">
            <label>
              Công việc / sự kiện
              <input v-model="shift.title" required maxlength="200" />
            </label>
            <div class="location-field">
              <span class="location-title">Địa điểm ca làm</span>
              <LocationPicker
                v-model="shift.location"
                required
                detail-label="Tên địa điểm / số nhà, đường (tùy chọn)"
              />
            </div>
            <div class="form-grid">
              <label>
                Ngày làm việc
                <input
                  :value="
                    new Date(shift.date + 'T12:00:00').toLocaleDateString('vi-VN', {
                      weekday: 'long',
                      day: 'numeric',
                      month: 'long'
                    })
                  "
                  readonly
                  aria-label="Ngày làm việc"
                />
              </label>
              <label>
                Buổi
                <select
                  :value="shiftPeriod"
                  :disabled="!!(editingShiftId && crewHasClocked)"
                  @change="setPeriod"
                >
                  <option value="morning">Sáng</option>
                  <option value="afternoon">Chiều</option>
                  <option value="evening">Tối</option>
                  <option value="all">Cả ngày</option>
                  <option value="custom">Tự chọn</option>
                </select>
              </label>
              <label>
                Bắt đầu
                <input
                  v-model="shift.start"
                  type="time"
                  required
                  :disabled="!!(editingShiftId && crewHasClocked)"
                />
              </label>
              <label>
                Kết thúc
                <input
                  v-model="shift.end"
                  type="time"
                  required
                  :disabled="!!(editingShiftId && crewHasClocked)"
                />
                <small v-if="shift.end_date !== shift.date">Ngày {{ shift.end_date }}</small>
              </label>
            </div>
            <label>
              Cast / thù lao ca (VNĐ)
              <input
                v-model.number="shift.cast_vnd"
                type="number"
                min="0"
                max="100000000"
                step="1000"
                inputmode="numeric"
                :disabled="!!(editingShiftId && crewHasClocked)"
                required
              />
            </label>
            <div class="cast-presets" role="group" aria-label="Chọn nhanh mức cast">
              <button
                v-for="amount in [300, 400, 500, 600, 700, 1000]"
                :key="amount"
                type="button"
                :disabled="!!(editingShiftId && crewHasClocked)"
                :class="{ selected: Number(shift.cast_vnd) === amount * 1000 }"
                :aria-pressed="Number(shift.cast_vnd) === amount * 1000"
                @click="shift.cast_vnd = amount * 1000"
              >
                {{ amount === 1000 ? '1.000' : amount }}K
              </button>
            </div>
            <fieldset>
              <legend>Phân công nhân viên</legend>
              <label v-for="m in assignableMembers" :key="m.user_id" class="check">
                <input
                  :checked="shift.user_ids.includes(m.user_id)"
                  :disabled="!!(editingShiftId && crewMemberClocked(m.user_id))"
                  :value="m.user_id"
                  type="checkbox"
                  @change="chooseShiftStaff(m.user_id, $event.target.checked)"
                />
                {{ m.full_name }} · {{ roleLabel(memberRole(m)) }} ({{ m.email }})
              </label>
              <div v-if="!assignableMembers.length" class="no-staff-hint">
                <p>
                  Công ty chưa có STAFF hoặc Freelance đang hoạt động. Bạn cần mời nhân viên và đợi
                  họ tham gia trước khi phân ca.
                </p>
                <button type="button" @click="modal = 'invite'">+ Mời nhân viên</button>
              </div>
            </fieldset>
            <div v-if="!error && editingShiftHasEnded" class="notice" role="status">
              {{ endedWorkMessage }}
            </div>
            <div v-else-if="!error && morningAssignments.length" class="notice" role="status">
              <div v-for="item in morningAssignments" :key="item.id">
                {{ assignedShiftText(item) }}.
              </div>
            </div>
            <div class="form-actions">
              <button
                v-if="editingShift && !crewHasClocked"
                type="button"
                class="danger-quiet"
                :disabled="busy"
                @click="removeShift(editingShift)"
              >
                Hủy ca
              </button>
              <span v-if="editingShift && crewHasClocked" class="clock-locked">
                Ca đã chấm công, không thể hủy, đổi giờ, nhân viên hoặc cast
              </span>
              <button type="button" @click="modal = ''">Đóng</button>
              <button
                class="primary"
                :disabled="
                  busy ||
                  !assignableMembers.length ||
                  selectedDayHasAttendance ||
                  editingShiftHasEnded
                "
              >
                {{ editingShiftId ? 'Lưu thay đổi' : 'Lưu phân ca' }}
              </button>
            </div>
          </form>
        </section>
      </div>
    </div>
  </div>
</template>

<style src="./styles/index.css"></style>
