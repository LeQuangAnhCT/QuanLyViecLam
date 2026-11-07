<script setup>
import {
  ref,
  reactive,
  computed,
  onMounted,
  onUnmounted,
  watch,
  nextTick,
  defineAsyncComponent
} from 'vue'
import {
  localDate,
  hours,
  roleLabel,
  workerRole,
  effectiveShiftEnd,
  shortShiftTime
} from '../../../domain/calendar'
import { completedShiftCast, workedMilliseconds } from '../../../domain/payroll'
import { formatWorkDuration } from '../../formatters/work-duration'
import ToastStack from '../../ToastStack.vue'
import {
  isShiftNotification,
  noticeIsPast,
  shiftNoticeSnapshot
} from '../../../domain/notifications.js'
import { useWorkspaceContext } from '../../composables/useWorkspaceContext'

const LocationPicker = defineAsyncComponent(() => import('../../LocationPicker.vue'))

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
  applications,
  profile,
  supplementalLoading,
  supplementalError,
  restriction,
  workspaceRoles,
  notifications,
  notificationNow,
  notificationsLoading,
  notificationsError,
  clockRecords,
  clockUnavailable,
  clockError,
  busy,
  loading,
  error,
  message,
  current,
  manager,
  repo
} = w

const tab = ref('calendar')

const month = ref(new Date(new Date().getFullYear(), new Date().getMonth(), 1))

const selectedDate = ref(localDate(new Date()))

const calendarGrid = ref(null)

const freelanceDayHeading = ref(null)

const toastStack = ref(null)

watch(error, (text) => {
  if (!text) return
  toastStack.value?.show(text, { kind: 'error', title: 'Cần chú ý' })
  error.value = ''
})

watch(message, (text) => {
  if (!text) return
  toastStack.value?.show(text, { kind: 'success', title: 'Thành công' })
  message.value = ''
})

const seenNotificationIds = new Set(notifications.value.map((item) => item.id))
let notificationsPrimed = w.notificationsHydrated.value

watch(notifications, (items) => {
  const incoming = notificationsPrimed
    ? items.filter((item) => !item.read_at && !seenNotificationIds.has(item.id))
    : []
  notificationsPrimed = true
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

const form = reactive({ company_name: '', address: '', phone: '', email: '' })

const freelancer = reactive({
  display_name: props.user.user_metadata?.full_name || '',
  specialty: '',
  visible: false
})

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

const reportMonth = ref(new Date(new Date().getFullYear(), new Date().getMonth(), 1))

const reportMonthText = computed(() => localDate(reportMonth.value))

function changeReportMonth(delta) {
  reportMonth.value = new Date(
    reportMonth.value.getFullYear(),
    reportMonth.value.getMonth() + delta,
    1
  )
}

const ownCompensation = computed(() => compensation.value.find((p) => p.user_id === props.user.id))

const ownScheduled = computed(() =>
  shifts.value.filter(
    (s) => localDate(new Date(s.starts_at)).slice(0, 7) === reportMonthText.value.slice(0, 7)
  )
)

const ownCompleted = computed(() =>
  ownScheduled.value.filter((s) =>
    clockRecords.value.some((a) => a.shift_id === s.id && a.checked_out_at)
  )
)

const ownWorkedMs = computed(() =>
  ownCompleted.value.reduce(
    (total, shift) => total + workedMilliseconds(clockRecordFor(shift.id)),
    0
  )
)

const ownCastTotal = computed(() =>
  ownCompleted.value.reduce((total, s) => total + completedShiftCast(s, clockRecordFor(s.id)), 0)
)

const ownIncomeEstimate = computed(
  () =>
    Number(ownCompensation.value?.monthly_base_vnd || 0) +
    Number(ownCompensation.value?.monthly_allowance_vnd || 0) +
    ownCastTotal.value
)

const profileRoleLabel = roleLabel('freelance')

const selectableCompanies = computed(() => companies.value)

const unreadCount = computed(() => notifications.value.filter((n) => !n.read_at).length)

const attendanceByShift = computed(
  () => new Map(clockRecords.value.map((record) => [record.shift_id, record]))
)

const clockRecordFor = (shiftId) => attendanceByShift.value.get(shiftId)

const shiftEndFor = (item) => effectiveShiftEnd(item, clockRecordFor(item.id))

const expenseDialog = ref(null)

const expenseShiftId = ref('')

const expenseShift = computed(() => shifts.value.find((item) => item.id === expenseShiftId.value))

const expenseAttendance = computed(() => clockRecordFor(expenseShiftId.value))

const expenseForm = reactive({ note: '', amount: '' })

const expenseError = ref('')

const expenseSaving = ref(false)

let pendingExpense

async function openExpenses(item) {
  if (!clockRecordFor(item.id) || busy.value) return
  expenseShiftId.value = item.id
  Object.assign(expenseForm, { note: '', amount: '' })
  expenseError.value = ''
  await nextTick()
  expenseDialog.value?.showModal()
}

async function saveExpense() {
  if (expenseSaving.value || !expenseAttendance.value || expenseAttendance.value.checked_out_at)
    return
  const shiftId = expenseShiftId.value
  const note = expenseForm.note.trim()
  const amount = Number(expenseForm.amount)
  if (
    !note ||
    note.length > 160 ||
    !Number.isSafeInteger(amount) ||
    amount < 1 ||
    amount > 100000000
  ) {
    expenseError.value = 'Nhập nội dung và số tiền từ 1 đến 100.000.000 ₫.'
    return
  }
  if (
    pendingExpense?.shiftId !== shiftId ||
    pendingExpense.note !== note ||
    pendingExpense.amount !== amount
  ) {
    pendingExpense = { shiftId, note, amount, id: crypto.randomUUID() }
  }
  expenseSaving.value = true
  expenseError.value = ''
  try {
    const saved = await repo.addShiftExpense(shiftId, pendingExpense.id, note, amount)
    const record = clockRecordFor(shiftId)
    if (record) Object.assign(record, saved)
    pendingExpense = undefined
    if (expenseShiftId.value === shiftId) Object.assign(expenseForm, { note: '', amount: '' })
  } catch (error) {
    if (expenseShiftId.value === shiftId) {
      expenseError.value =
        error?.code === 'PGRST202'
          ? 'Supabase chưa được cập nhật để lưu chi phí phát sinh.'
          : error?.message || 'Không thể lưu chi phí phát sinh.'
    }
  } finally {
    expenseSaving.value = false
  }
}

const canClockIn = (item) => {
  if (clockUnavailable.value || clockRecordFor(item.id)) return false
  const now = Date.now()
  return (
    now >= new Date(item.starts_at).getTime() - 3600000 &&
    now <= new Date(item.ends_at).getTime() + 12 * 3600000
  )
}

const clockStatus = (item) => {
  const row = clockRecordFor(item.id)
  return row ? (row.checked_out_at ? 'Đã hoàn thành ca' : 'Đã chấm công') : 'Chưa chấm công'
}

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

const hasManagedCompany = computed(() => companies.value.some((c) => c.role === 'manager'))

const activeApplication = computed(() =>
  applications.value.some((a) => a.status === 'pending' || a.status === 'approved')
)

const tabs = computed(() => {
  const items = [
    ['calendar', 'Lịch của tôi'],
    ['attendance', 'Chấm công'],
    ['income', 'Thu nhập'],
    ['notifications', 'Thông báo'],
    ['people', 'Đồng nghiệp'],
    ['community', 'Cộng đồng']
  ]
  if (!hasManagedCompany.value)
    items.push(['registration', activeApplication.value ? 'Đơn đăng ký' : 'Đăng ký công ty'])
  items.push(['profile', 'Hồ sơ của tôi'])
  return items
})

const days = computed(() => {
  const year = month.value.getFullYear(),
    m = month.value.getMonth(),
    offset = (new Date(year, m, 1).getDay() + 6) % 7,
    count = new Date(year, m + 1, 0).getDate()
  return [...Array(offset).fill(null), ...Array.from({ length: count }, (_, i) => i + 1)]
})

const payFor = (id) => compensation.value.find((p) => p.user_id === id)

function memberRole(member) {
  if (member.role === 'manager') return 'manager'
  if (member.user_id === props.user.id) return workerRole(payFor(member.user_id)?.employment_type)
  return workspaceRoles.value?.[member.user_id]
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

const memberGroups = computed(() => [{ label: 'Thành viên công ty', items: filteredMembers.value }])

const vndFormat = new Intl.NumberFormat('vi-VN')

const money = (value) =>
  value != null && Number.isFinite(Number(value))
    ? `${vndFormat.format(Number(value))} ₫`
    : 'Chưa có'

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

const plannedHours = computed(() =>
  monthShifts.value.reduce((sum, s) => sum + Number(hours(s)), 0).toFixed(1)
)

const upcomingCount = computed(
  () => shifts.value.filter((s) => new Date(s.starts_at) > new Date()).length
)

const selectedShifts = computed(() =>
  shiftsForDate(selectedDate.value).sort((a, b) => new Date(a.starts_at) - new Date(b.starts_at))
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

const dateForDay = (day) =>
  localDate(new Date(month.value.getFullYear(), month.value.getMonth(), day))

const isToday = (day) => dateForDay(day) === localDate(new Date())

const dayAction = () => 'Xem các ca trong ngày'

async function clickCalendarCell(day) {
  selectedDate.value = dateForDay(day)
  await nextTick()
  freelanceDayHeading.value?.scrollIntoView({
    block: window.matchMedia('(max-width: 1050px)').matches ? 'start' : 'nearest'
  })
  freelanceDayHeading.value?.focus({ preventScroll: true })
}

function focusCalendarDay() {
  calendarGrid.value?.querySelector('[aria-pressed="true"]')?.focus()
}

function goToToday() {
  month.value = new Date(new Date().getFullYear(), new Date().getMonth(), 1)
  selectedDate.value = localDate(new Date())
}

const statusText = (status) =>
  ({ pending: 'Đang chờ duyệt', approved: 'Đã duyệt', rejected: 'Đã từ chối' })[status] || status

function changeMonth(delta) {
  month.value = new Date(month.value.getFullYear(), month.value.getMonth() + delta, 1)
  selectedDate.value = localDate(month.value)
}

async function perform(fn, success) {
  return w.perform(fn, success)
}

async function clockAction(item, action) {
  if (isAdmin || manager.value || busy.value || clockUnavailable.value) return
  busy.value = true
  error.value = ''
  message.value = ''
  try {
    if (action === 'in') await repo.clockIn(item.id)
    else await repo.clockOut(item.id)
    message.value = action === 'in' ? 'Đã chấm công.' : 'Đã xác nhận hoàn thành ca.'
    try {
      await w.refreshCompany()
    } catch {
      error.value = 'Đã lưu thao tác nhưng chưa tải lại được dữ liệu. Hãy làm mới trang.'
    }
  } catch (e) {
    const messages = {
      P4520: 'Chỉ người được phân ca mới có thể chấm công.',
      P4521: 'Chỉ chấm công từ 1 giờ trước ca đến 12 giờ sau khi ca kết thúc.',
      P4522: 'Ca chưa chấm công hoặc đã được xác nhận hoàn thành.',
      PGRST202: 'Supabase chưa có hàm chấm công. Hãy chạy shift_attendance.sql.'
    }
    error.value = messages[e?.code] || e?.message || 'Không thể chấm công.'
  } finally {
    busy.value = false
  }
}

function saveApplication() {
  if (busy.value || supplementalLoading.value || supplementalError.value || activeApplication.value)
    return
  perform(
    () => repo.insert('company_applications', { ...form, applicant_id: props.user.id }),
    'Đã gửi đăng ký công ty.'
  )
}

function saveProfile() {
  if (busy.value || supplementalLoading.value || supplementalError.value) return
  perform(
    () => repo.upsert('freelancer_profiles', { user_id: props.user.id, ...freelancer }),
    'Đã lưu hồ sơ freelancer.'
  )
}

function onWindowFocus() {
  if (restriction.value?.disabled || document.visibilityState === 'hidden') return
  w.refreshNotifications()
  if (tab.value === 'calendar' || tab.value === 'attendance') w.refreshCompany().catch(() => {})
}

let notificationPoll = null

function changeCompany(id) {
  if (id === companyId.value || busy.value) return
  companyId.value = id
  error.value = ''
  message.value = ''
  w.refreshCompany().catch((failure) => {
    if (companyId.value === id) error.value = failure?.message || 'Không tải được công ty.'
  })
}

watch(
  profile,
  (p) => {
    if (p)
      Object.assign(freelancer, {
        display_name: p.display_name,
        specialty: p.specialty,
        visible: p.visible
      })
  },
  { immediate: true }
)

watch(tabs, (available) => {
  if (!available.some((item) => item[0] === tab.value)) tab.value = 'calendar'
})

watch(tab, (next) => {
  if (next === 'notifications') w.refreshNotifications()
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
  <div class="role-page role-freelance">
    <ToastStack ref="toastStack" />
    <dialog
      ref="expenseDialog"
      class="shift-notice-dialog"
      aria-labelledby="expense-title"
      @close="expenseShiftId = ''"
    >
      <template v-if="expenseShift">
        <div class="shift-notice-header">
          <div>
            <p>{{ expenseShift.title }}</p>
            <h2 id="expense-title">Chi phí phát sinh</h2>
          </div>
          <form method="dialog"><button type="submit">Đóng</button></form>
        </div>
        <dl class="expense-summary">
          <div>
            <dt>Cast gốc</dt>
            <dd>{{ money(expenseShift.cast_vnd ?? 0) }}</dd>
          </div>
          <div>
            <dt>Phát sinh</dt>
            <dd>{{ money(expenseAttendance?.expense_total_vnd ?? 0) }}</dd>
          </div>
          <div>
            <dt>Tổng Cast</dt>
            <dd>{{ money(completedShiftCast(expenseShift, expenseAttendance)) }}</dd>
          </div>
        </dl>
        <ul v-if="expenseAttendance?.expenses?.length" class="expense-list">
          <li v-for="expense in expenseAttendance.expenses" :key="expense.id">
            <span>{{ expense.note }}</span>
            <strong>{{ money(expense.amount_vnd) }}</strong>
          </li>
        </ul>
        <p v-if="expenseAttendance?.checked_out_at" class="notice">
          Ca đã hoàn thành. Chi phí đã được chốt.
        </p>
        <p v-if="expenseError" class="alert" role="alert">{{ expenseError }}</p>
        <form
          v-if="expenseAttendance && !expenseAttendance.checked_out_at"
          class="form"
          @submit.prevent="saveExpense"
        >
          <label>
            Nội dung khoản chi
            <input
              v-model="expenseForm.note"
              required
              maxlength="160"
              placeholder="Ví dụ: Đồ ăn cho đội"
              :disabled="expenseSaving"
            />
          </label>
          <label>
            Số tiền (₫)
            <input
              v-model="expenseForm.amount"
              required
              type="number"
              inputmode="numeric"
              min="1"
              max="100000000"
              step="1"
              :disabled="expenseSaving"
            />
          </label>
          <div class="form-actions">
            <button type="submit" class="primary" :disabled="expenseSaving">Thêm khoản chi</button>
          </div>
        </form>
      </template>
    </dialog>
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
              <span class="profile-role" :title="roleLabel('freelance')">
                {{ profileRoleLabel }}
              </span>
            </div>
            <small class="profile-email" :title="user.email">{{ user.email }}</small>
          </div>
        </div>
        <div class="side-label">KHÔNG GIAN CỦA TÔI</div>
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
                <span class="profile-role" :title="roleLabel('freelance')">
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
          <div v-if="supplementalError" class="alert" role="alert">
            {{ supplementalError }}
            <button type="button" :disabled="supplementalLoading" @click="w.refreshSupplemental()">
              Thử lại
            </button>
          </div>
          <div class="page-heading">
            <div>
              <p class="eyebrow">{{ roleLabel('freelance') }}</p>
              <h1>{{ tabs.find((t) => t[0] === tab)?.[1] }}</h1>
              <p v-if="tab !== 'people'">
                {{
                  tab === 'notifications'
                    ? 'Theo dõi ca làm và thay đổi ở các công ty bạn tham gia.'
                    : 'Chỉ hiển thị các ca đã được giao cho bạn.'
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
              Áp dụng cho tài khoản {{ roleLabel('freelance') }}. Cập nhật quê quán, khu vực hoạt
              động và ảnh đại diện.
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
                <span class="location-title">Khu vực đang hoạt động</span>
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
              <section
                class="overview-grid freelance-calendar-summary"
                aria-label="Tổng quan lịch làm việc"
              >
                <div class="overview-tile">
                  <span>Ca của tôi</span>
                  <strong>{{ monthShifts.length }}</strong>
                  <small>Trong tháng đang xem</small>
                </div>
                <div class="overview-tile">
                  <span>Giờ dự kiến</span>
                  <strong>{{ plannedHours }}</strong>
                  <small>Giờ được phân trong tháng</small>
                </div>
                <div class="overview-tile">
                  <span>Ca sắp tới</span>
                  <strong>{{ upcomingCount }}</strong>
                  <small>Ca đã giao cho bạn</small>
                </div>
              </section>
              <div class="freelance-calendar-layout">
                <div>
                  <div class="calendar-controls">
                    <div>
                      <h2>
                        {{ month.toLocaleDateString('vi-VN', { month: 'long', year: 'numeric' }) }}
                      </h2>
                      <p>Bấm vào một ngày để xem các ca làm.</p>
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
                    </div>
                  </div>
                  <div ref="calendarGrid" class="calendar-wrap">
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
                          aria-controls="freelance-day-detail"
                          :aria-current="isToday(day) ? 'date' : undefined"
                          :aria-pressed="selectedDate === dateForDay(day)"
                          @click="clickCalendarCell(day)"
                        >
                          <span class="day-number">{{ day }}</span>
                          <span v-if="shiftsOn(day).length" class="day-shift-count">
                            {{ shiftsOn(day).length }} ca
                          </span>
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
                <section
                  id="freelance-day-detail"
                  class="surface section day-detail freelance-day-detail"
                  aria-label="Chi tiết ca theo ngày"
                >
                  <div class="section-title">
                    <div>
                      <h2 ref="freelanceDayHeading" tabindex="-1">Ca làm trong ngày</h2>
                      <p>{{ selectedDateLabel }} · {{ selectedShifts.length }} ca</p>
                    </div>
                    <button
                      type="button"
                      class="freelance-return-calendar"
                      @click="focusCalendarDay"
                    >
                      Về lịch tháng
                    </button>
                  </div>
                  <div v-if="clockError" class="notice" role="status">{{ clockError }}</div>
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
                      <small>{{ item.location || 'Chưa cập nhật địa điểm' }}</small>
                    </div>
                    <div class="shift-actions clock-actions">
                      <span class="clock-status">{{ clockStatus(item) }}</span>
                      <button
                        v-if="!clockRecordFor(item.id)"
                        type="button"
                        class="primary"
                        :disabled="busy || !canClockIn(item)"
                        @click="clockAction(item, 'in')"
                      >
                        Chấm công
                      </button>
                      <button
                        v-else-if="!clockRecordFor(item.id).checked_out_at"
                        type="button"
                        :disabled="busy"
                        @click="clockAction(item, 'out')"
                      >
                        Xác nhận hoàn thành ca
                      </button>
                      <button
                        v-if="
                          !clockRecordFor(item.id)?.checked_out_at ||
                          clockRecordFor(item.id).expenses?.length
                        "
                        type="button"
                        :disabled="busy || !clockRecordFor(item.id)"
                        :title="
                          clockRecordFor(item.id) ? undefined : 'Chấm công trước khi nhập chi phí'
                        "
                        @click="openExpenses(item)"
                      >
                        Chi phí phát sinh
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
                <p>
                  Tin phân ca mới hiển thị trong 7 ngày. Tin cập nhật, hủy ca và đổi vai trò được
                  lưu để tra cứu.
                </p>
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
          <section v-if="tab === 'attendance'" class="surface section">
            <div class="section-title">
              <div>
                <h2>Chấm công thực tế</h2>
                <p>Chấm công cho ca được giao. Bạn có thể xác nhận hoàn thành sau khi làm xong.</p>
              </div>
            </div>
            <div v-if="clockError" class="alert" role="alert">{{ clockError }}</div>
            <div v-if="!shifts.length" class="empty">Bạn chưa được phân ca làm việc.</div>
            <div v-for="s in shifts" :key="s.id" class="row attendance-row">
              <div class="attendance-summary">
                <b>{{ s.title }}</b>
                <small>
                  <time
                    :datetime="s.starts_at"
                    :title="noticeDateFormat.format(new Date(s.starts_at))"
                  >
                    {{ shortShiftTime(s.starts_at) }}
                  </time>
                  · {{ s.location }}
                </small>
                <small>Dự kiến: {{ hours(s) }} giờ · {{ clockStatus(s) }}</small>
                <small v-if="clockRecordFor(s.id)">
                  Chấm công {{ shortShiftTime(clockRecordFor(s.id).checked_in_at) }}
                  <template v-if="clockRecordFor(s.id).checked_out_at">
                    · Hoàn thành {{ shortShiftTime(clockRecordFor(s.id).checked_out_at) }}
                  </template>
                </small>
                <small v-if="shiftEndFor(s) !== s.ends_at">
                  Kết thúc muộn · {{ shortShiftTime(shiftEndFor(s)) }}
                </small>
                <small v-if="clockRecordFor(s.id)?.expense_total_vnd">
                  Tổng Cast gồm phát sinh: {{ money(completedShiftCast(s, clockRecordFor(s.id))) }}
                </small>
              </div>
              <div class="shift-actions clock-actions">
                <button
                  v-if="!clockRecordFor(s.id)"
                  class="primary"
                  type="button"
                  :disabled="busy || !canClockIn(s)"
                  @click="clockAction(s, 'in')"
                >
                  Chấm công
                </button>
                <button
                  v-else-if="!clockRecordFor(s.id).checked_out_at"
                  type="button"
                  :disabled="busy"
                  @click="clockAction(s, 'out')"
                >
                  Xác nhận hoàn thành ca
                </button>
                <span v-else class="clock-locked">Đã hoàn tất</span>
                <button
                  v-if="
                    !clockRecordFor(s.id)?.checked_out_at || clockRecordFor(s.id).expenses?.length
                  "
                  type="button"
                  :disabled="busy || !clockRecordFor(s.id)"
                  :title="clockRecordFor(s.id) ? undefined : 'Chấm công trước khi nhập chi phí'"
                  @click="openExpenses(s)"
                >
                  Chi phí phát sinh
                </button>
              </div>
            </div>
          </section>
          <section v-if="tab === 'income'" class="surface section income-section">
            <div class="section-title">
              <div>
                <h2>Thu nhập dự kiến của tôi</h2>
                <p>Chỉ hiển thị thông tin lương cá nhân trong công ty đang tham gia.</p>
              </div>
              <div class="button-group payroll-month-controls">
                <button type="button" @click="changeReportMonth(-1)">‹</button>
                <b>
                  {{ reportMonth.toLocaleDateString('vi-VN', { month: 'long', year: 'numeric' }) }}
                </b>
                <button type="button" @click="changeReportMonth(1)">›</button>
              </div>
            </div>
            <div v-if="compensationUnavailable" class="alert" role="alert">
              Chưa thể tải thỏa thuận lương từ Supabase.
            </div>
            <div v-else-if="!ownCompensation" class="empty">
              Manager chưa thiết lập thông tin lương cho bạn.
            </div>
            <template v-else>
              <div class="overview-grid payroll-kpis">
                <div class="overview-tile">
                  <span>Vai trò tại công ty</span>
                  <strong class="payroll-type">{{ roleLabel('freelance') }}</strong>
                </div>
                <div class="overview-tile">
                  <span>Ca đã hoàn tất</span>
                  <strong>{{ ownCompleted.length }}/{{ ownScheduled.length }}</strong>
                  <small>Đã xác nhận / đã phân</small>
                </div>
                <div class="overview-tile">
                  <span>Giờ thực tế</span>
                  <strong class="worked-duration">{{ formatWorkDuration(ownWorkedMs) }}</strong>
                  <small>Từ chấm công đến hoàn thành ca</small>
                </div>
                <div class="overview-tile">
                  <span>Thu nhập ước tính</span>
                  <strong class="payroll-money">{{ money(ownIncomeEstimate) }}</strong>
                  <small>Không phải tiền đã thanh toán</small>
                </div>
              </div>
              <div class="income-rates">
                <p v-if="ownCompensation.employment_type === 'employee'">
                  Lương cơ bản thỏa thuận:
                  <b>{{ money(ownCompensation.monthly_base_vnd) }}/tháng</b>
                  .
                </p>
                <p>
                  Phụ cấp hàng tháng:
                  <b>{{ money(ownCompensation.monthly_allowance_vnd) }}/tháng</b>
                  .
                </p>
                <p>
                  Cast từ ca đã hoàn tất (gồm phát sinh):
                  <b>{{ money(ownCastTotal) }}</b>
                  .
                </p>
              </div>
            </template>
            <p class="payroll-disclaimer">
              Ước tính gồm lương cơ bản, phụ cấp tháng và Cast của các ca đã xác nhận hoàn thành.
              Giờ thực tế không đồng nghĩa tiền theo giờ. Chưa trừ thuế, bảo hiểm, tạm ứng hoặc nghỉ
              phép.
            </p>
          </section>
          <section v-if="tab === 'people'" class="surface section people-section">
            <div class="section-title">
              <div>
                <h2>{{ current?.name || 'Thành viên công ty' }}</h2>
                <p>Danh sách đồng nghiệp trong công ty đang chọn.</p>
              </div>
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
                  <small v-if="!person.is_active">
                    Đã tạm ngừng · Lịch cũ và chấm công vẫn được giữ
                  </small>
                </div>
                <div class="row-actions">
                  <span class="badge">{{ roleLabel(memberRole(person)) }}</span>
                </div>
              </div>
            </div>
          </section>
          <template v-if="tab === 'community'">
            <section class="surface section">
              <h2>Công ty</h2>
              <p>Tìm công ty và gửi yêu cầu tham gia.</p>
              <div v-if="!directory.length" class="empty">Chưa có công ty.</div>
              <div v-for="c in directory" :key="c.id" class="row">
                <div>
                  <b>{{ c.name }}</b>
                  <small>{{ c.address }} | {{ c.phone }}</small>
                </div>
                <button
                  v-if="!companies.some((x) => x.id === c.id)"
                  :disabled="busy"
                  @click="
                    perform(
                      () => repo.rpc('request_company_membership', { p_company: c.id }),
                      'Đã gửi yêu cầu tham gia.'
                    )
                  "
                >
                  Xin tham gia
                </button>
                <span v-else class="badge">Đã tham gia</span>
              </div>
            </section>
            <section class="surface section">
              <h2>Hồ sơ việc làm Freelance</h2>
              <p v-if="supplementalLoading" role="status">Đang tải hồ sơ việc làm...</p>
              <form v-else-if="!supplementalError" class="form" @submit.prevent="saveProfile">
                <label>
                  Tên hiển thị
                  <input v-model="freelancer.display_name" required minlength="2" maxlength="100" />
                </label>
                <label>
                  Chuyên môn
                  <input
                    v-model="freelancer.specialty"
                    required
                    minlength="2"
                    maxlength="200"
                    placeholder="Âm thanh, ánh sáng..."
                  />
                </label>
                <label class="check">
                  <input v-model="freelancer.visible" type="checkbox" />
                  Cho Manager tìm thấy hồ sơ của tôi
                </label>
                <div><button class="primary" :disabled="busy">Lưu hồ sơ</button></div>
              </form>
            </section>
          </template>
          <section
            v-if="tab === 'registration' && !hasManagedCompany"
            class="surface section form-section"
          >
            <h2>{{ activeApplication ? 'Đơn đăng ký công ty' : 'Đăng ký công ty' }}</h2>
            <p>
              {{
                activeApplication
                  ? 'Theo dõi trạng thái đơn đăng ký của bạn.'
                  : 'Thông tin sẽ được gửi quản trị viên duyệt. Sau khi duyệt bạn là quản lý công ty.'
              }}
            </p>
            <p v-if="supplementalLoading" role="status">Đang tải thông tin đăng ký...</p>
            <form
              v-else-if="!supplementalError && !activeApplication"
              class="form"
              @submit.prevent="saveApplication"
            >
              <label>
                Tên công ty
                <input
                  v-model.trim="form.company_name"
                  required
                  minlength="3"
                  maxlength="120"
                  pattern=".*[\p{L}].*"
                  title="Tên phải có chữ"
                />
              </label>
              <div class="location-field">
                <span class="location-title">Địa chỉ công ty</span>
                <LocationPicker
                  v-model="form.address"
                  required
                  detail-label="Số nhà, đường (tùy chọn)"
                />
              </div>
              <div class="form-grid">
                <label>
                  Số điện thoại Việt Nam
                  <input
                    v-model="form.phone"
                    required
                    inputmode="numeric"
                    pattern="0[0-9]{9}"
                    title="10 chữ số, bắt đầu bằng 0"
                  />
                </label>
                <label>
                  Email công ty
                  <input v-model.trim="form.email" required type="email" maxlength="254" />
                </label>
              </div>
              <div><button class="primary" :disabled="busy">Gửi duyệt</button></div>
            </form>
            <div v-for="a in applications" :key="a.id" class="row">
              <b>{{ a.company_name }}</b>
              <span class="badge">{{ statusText(a.status) }}</span>
            </div>
          </section>
        </main>
      </div>
    </div>
  </div>
</template>

<style src="./styles/index.css"></style>
