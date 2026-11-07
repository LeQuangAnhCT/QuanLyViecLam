<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { useWorkspace } from '../application/useWorkspace'
import { localDate, hours, roleLabel, workerRole, shiftRows, shiftEditPlan, sameWorkSlot, ShiftOverlapError, effectiveShiftEnd, shortShiftTime } from '../domain/calendar'
import { completedShiftCast } from '../domain/payroll'
import LocationPicker from './LocationPicker.vue'
import ToastStack from './ToastStack.vue'
import provinces from '../data/vietnam-locations.json'
import { isShiftNotification, noticeIsPast, shiftNoticeSnapshot } from '../domain/notifications.js'

const props = defineProps({ user: { type: Object, required: true } })
const w = useWorkspace(props.user)
const { isAdmin, companies, directory, invitations, companyId, members, shifts, compensation, compensationUnavailable, applications, freelancers, profile, accounts, adminCompanies, requests, restriction, workspaceRoles, notifications, notificationNow, notificationsLoading, notificationsError, clockRecords, clockUnavailable, clockError, payroll, payrollLoading, payrollError, busy, loading, error, message, current, manager, canSchedule, repo } = w
const tab = ref(isAdmin ? 'approval' : 'calendar'), month = ref(new Date(new Date().getFullYear(), new Date().getMonth(), 1)), selectedDate = ref(localDate(new Date())), modal = ref('')
const dialogClose = ref(null)
const calendarGrid = ref(null)
const staffDayHeading = ref(null)
const toastStack = ref(null)
watch(modal, () => { error.value = '' }, { flush: 'sync' })
watch(modal, next => { if (next === 'shift-picker') dialogClose.value?.focus() }, { flush: 'post' })
watch(error, text => {
  if (!text || modal.value) return
  toastStack.value?.show(text, { kind:'error', title:'Cần chú ý' })
  error.value = ''
})
watch(message, text => {
  if (!text) return
  toastStack.value?.show(text, { kind:'success', title:'Thành công' })
  message.value = ''
})
const seenNotificationIds = new Set()
watch(notifications, items => {
  const incoming = items.filter(item => !item.read_at && !seenNotificationIds.has(item.id))
  for (const item of items) seenNotificationIds.add(item.id)
  if (loading.value || tab.value === 'notifications' || !incoming.length) return
  if (incoming.length === 1) {
    const item = incoming[0]
    toastStack.value?.show(item.body || item.title, {
      title:item.title,
      action:isShiftNotification(item) ? () => openShiftNotification(item) : undefined
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
  const live = new Map(shifts.value.map(shift => [shift.id, shift]))
  return new Map(notifications.value.filter(isShiftNotification).map(item => [
    item.id, shiftNoticeSnapshot(item) || live.get(item.shift_id) || null
  ]))
})
const notificationGroups = computed(() => {
  const groups = { current: [], past: [] }
  for (const item of notifications.value) {
    const past = noticeIsPast(item, notificationShifts.value.get(item.id), notificationNow.value)
    groups[past ? 'past' : 'current'].push(item)
  }
  return groups
})
const notificationPages = computed(() => Math.max(1, Math.ceil(notificationGroups.value[notificationGroup.value].length / notificationPageSize)))
const visibleNotifications = computed(() => {
  const offset = (notificationPage.value - 1) * notificationPageSize
  return notificationGroups.value[notificationGroup.value].slice(offset, offset + notificationPageSize)
})
watch(notificationPages, count => { notificationPage.value = Math.min(notificationPage.value, count) })
function selectNotificationGroup(group) {
  notificationGroup.value = group
  notificationPage.value = 1
}
const noticeDateFormat = new Intl.DateTimeFormat('vi-VN', {
  timeZone:'Asia/Ho_Chi_Minh', dateStyle:'short', timeStyle:'short'
})
async function openShiftNotification(item) {
  const request = { ...item }
  activeNotification.value = request
  notificationReadError.value = ''
  notificationDetail.value = notificationShifts.value.get(item.id) || null
  notificationDetailLoading.value = !notificationDetail.value && !!item.shift_id && item.event !== 'cancelled'
  await nextTick()
  if (!notificationDialog.value?.open) notificationDialog.value?.showModal()
  if (!item.read_at) {
    w.markNotificationRead(item.id).catch(() => {
      if (activeNotification.value?.id === item.id) notificationReadError.value = 'Chưa thể đánh dấu đã đọc. Hãy thử mở lại thông báo.'
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
const form = reactive({ company_name: '', address: '', phone: '', email: '' }), freelancer = reactive({ display_name: props.user.user_metadata?.full_name || '', specialty: '', visible: false })
const inviteEmail = ref(''), disableTarget = ref(null), disableReason = ref(''), editingShiftId = ref('')
const peopleSearch = ref(''), peopleFilter = ref('all')
const accountProfile = reactive({full_name:props.user.user_metadata?.full_name || '',birth_date:'',hometown:'',active_location:'',avatar_url:''})
const avatarFile = ref(null)
const defaultAvatar = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#e4e6eb"/><circle cx="50" cy="38" r="19" fill="#b0b3b8"/><path d="M14 100c2-24 16-37 36-37s34 13 36 37" fill="#b0b3b8"/></svg>')
const avatarPreview = ref('')
function chooseAvatar(event) {
  const file = event.target.files?.[0]
  if (!file) return
  if (!['image/jpeg','image/png','image/webp'].includes(file.type) || file.size > 2*1024*1024) { avatarFile.value=null; error.value='Ảnh phải là JPG, PNG hoặc WebP và không quá 2 MB.'; event.target.value=''; return }
  avatarFile.value=file
  if (avatarPreview.value) URL.revokeObjectURL(avatarPreview.value)
  avatarPreview.value=URL.createObjectURL(file)
}
async function saveAccountProfile() {
  const name=accountProfile.full_name.trim()
  if (!name) { error.value='Vui lòng nhập họ tên.'; return }
  if (accountProfile.birth_date && new Date(accountProfile.birth_date)>new Date()) { error.value='Ngày sinh không hợp lệ.'; return }
  busy.value=true; error.value=''; message.value=''
  try {
    const avatar_url=avatarFile.value ? await repo.uploadAvatar(props.user.id,avatarFile.value) : accountProfile.avatar_url
    await repo.saveAccountProfile(props.user.id,{full_name:name,birth_date:accountProfile.birth_date || null,hometown:accountProfile.hometown.trim() || null,active_location:accountProfile.active_location.trim() || null,avatar_url:avatar_url || null})
    await repo.auth.updateUser({data:{full_name:name}})
    Object.assign(accountProfile,{full_name:name,avatar_url})
    avatarFile.value=null
    if (avatarPreview.value) { URL.revokeObjectURL(avatarPreview.value); avatarPreview.value='' }
    message.value='Đã cập nhật hồ sơ.'
  } catch(e) { error.value=e?.message || 'Không thể lưu hồ sơ.' }
  finally { busy.value=false }
}
const shift = reactive({ title: '', location: '', date: localDate(new Date()), end_date: localDate(new Date()), start: '08:00', end: '12:00', cast_vnd: 300000, user_ids: [] })
const payForm = reactive({ user_id:'', name:'', employment_type:'freelancer', monthly_base_vnd:'', monthly_allowance_vnd:0 })
const reportMonth = ref(new Date(new Date().getFullYear(),new Date().getMonth(),1))
const reportMonthText = computed(() => localDate(reportMonth.value))
const monthlyReportTotals = computed(() => ({
  scheduled: payroll.value.reduce((a,row)=>a+Number(row.scheduled_shifts||0),0),
  completed: payroll.value.reduce((a,row)=>a+Number(row.completed_shifts||0),0),
  hours: payroll.value.reduce((a,row)=>a+Number(row.worked_hours||0),0).toFixed(2),
  plannedCast: payroll.value.reduce((a,row)=>a+Number(row.planned_cast_vnd||0),0),
  cast: payroll.value.reduce((a,row)=>a+Number(row.cast_total_vnd||0),0),
  total: payroll.value.reduce((a,row)=>a+Number(row.estimated_total_vnd||0),0)
}))
function changeReportMonth(delta) { reportMonth.value = new Date(reportMonth.value.getFullYear(),reportMonth.value.getMonth()+delta,1) }
const employmentLabel = type => roleLabel(workerRole(type))
const ownCompensation = computed(() => compensation.value.find(p=>p.user_id===props.user.id))
const ownScheduled = computed(() => shifts.value.filter(s => localDate(new Date(s.starts_at)).slice(0,7)===reportMonthText.value.slice(0,7)))
const ownCompleted = computed(() => ownScheduled.value.filter(s => clockRecords.value.some(a=>a.shift_id===s.id && a.checked_out_at)))
const ownActualHours = computed(() => ownCompleted.value.reduce((total,s) => {
  const record=clockRecords.value.find(a=>a.shift_id===s.id && a.checked_out_at)
  return total+(record? Math.max(0,(new Date(record.checked_out_at)-new Date(record.checked_in_at))/3600000):0)
},0).toFixed(2))
const ownCastTotal = computed(() => ownCompleted.value.reduce((total,s)=>total+completedShiftCast(s, clockRecordFor(s.id)),0))
const ownIncomeEstimate = computed(() => Number(ownCompensation.value?.monthly_base_vnd||0) +
  Number(ownCompensation.value?.monthly_allowance_vnd||0) + ownCastTotal.value)
const role = computed(() => isAdmin ? 'admin' : manager.value ? 'manager' : workerRole(ownCompensation.value?.employment_type))
const ownedCompanies = computed(() => companies.value.filter(c => c.role === 'manager'))
const selectableCompanies = computed(() => companies.value)
const assignableMembers = computed(() => members.value.filter(m => m.role === 'staff' && m.is_active))
const unreadCount = computed(() => notifications.value.filter(n => !n.read_at).length)
const attendanceByShift = computed(() => new Map(clockRecords.value.map(record => [record.shift_id, record])))
const clockRecordFor = shiftId => attendanceByShift.value.get(shiftId)
const shiftEndFor = item => effectiveShiftEnd(item, clockRecordFor(item.id))
const expenseDialog = ref(null)
const expenseShiftId = ref('')
const expenseShift = computed(() => shifts.value.find(item => item.id === expenseShiftId.value))
const expenseAttendance = computed(() => clockRecordFor(expenseShiftId.value))
const expenseForm = reactive({ note:'', amount:'' })
const expenseError = ref('')
const expenseSaving = ref(false)
let pendingExpense

async function openExpenses(item) {
  if (!clockRecordFor(item.id) || busy.value) return
  expenseShiftId.value = item.id
  Object.assign(expenseForm, { note:'', amount:'' })
  expenseError.value = ''
  await nextTick()
  expenseDialog.value?.showModal()
}

async function saveExpense() {
  if (expenseSaving.value || !expenseAttendance.value || expenseAttendance.value.checked_out_at) return
  const shiftId = expenseShiftId.value
  const note = expenseForm.note.trim()
  const amount = Number(expenseForm.amount)
  if (!note || note.length > 160 || !Number.isSafeInteger(amount) || amount < 1 || amount > 100000000) {
    expenseError.value = 'Nhập nội dung và số tiền từ 1 đến 100.000.000 ₫.'
    return
  }
  if (pendingExpense?.shiftId !== shiftId || pendingExpense.note !== note || pendingExpense.amount !== amount) {
    pendingExpense = { shiftId, note, amount, id: crypto.randomUUID() }
  }
  expenseSaving.value = true
  expenseError.value = ''
  try {
    const saved = await repo.addShiftExpense(shiftId, pendingExpense.id, note, amount)
    const record = clockRecordFor(shiftId)
    if (record) Object.assign(record, saved)
    pendingExpense = undefined
    if (expenseShiftId.value === shiftId) Object.assign(expenseForm, { note:'', amount:'' })
  } catch (error) {
    if (expenseShiftId.value === shiftId) {
      expenseError.value = error?.code === 'PGRST202'
        ? 'Supabase chưa được cập nhật để lưu chi phí phát sinh.'
        : error?.message || 'Không thể lưu chi phí phát sinh.'
    }
  } finally {
    expenseSaving.value = false
  }
}
const editingShift = computed(() => shifts.value.find(s => s.id === editingShiftId.value))
const editingCrew = computed(() => editingShift.value
  ? shifts.value.filter(s=>sameWorkSlot(s,editingShift.value)) : [])
const crewHasClocked = computed(() => editingCrew.value.some(s=>clockRecordFor(s.id)))
const completedShiftIds = computed(() => new Set(clockRecords.value.filter(record => record.checked_out_at).map(record => record.shift_id)))
const workIsCompleted = item => shifts.value.some(shift => completedShiftIds.value.has(shift.id) && sameWorkSlot(shift, item))
const completedWorkMessage = 'Ca đã hoàn tất chấm công nên không thể cập nhật.'
const endedWorkMessage = 'Ca đã qua giờ kết thúc nên không thể sửa.'
const scheduleNow = ref(Date.now())
const shiftHasEnded = (item, now = Date.now()) => Date.parse(item.ends_at) <= now
const editingShiftHasEnded = computed(() => !!editingShift.value && shiftHasEnded(editingShift.value, scheduleNow.value))
function shiftEditLockLabel(item) {
  if (workIsCompleted(item)) return 'Đã hoàn tất · Không thể sửa'
  return shiftHasEnded(item, scheduleNow.value) ? 'Đã qua giờ kết thúc · Không thể sửa' : ''
}
const crewMemberClocked = userId => editingCrew.value.some(s=>s.user_id===userId && clockRecordFor(s.id))
const canClockIn = item => {
  if (clockUnavailable.value || clockRecordFor(item.id)) return false
  const now=Date.now()
  return now >= new Date(item.starts_at).getTime()-3600000 && now<=new Date(item.ends_at).getTime()+12*3600000
}
const clockStatus = item => {
  const row=clockRecordFor(item.id)
  return row ? (row.checked_out_at ? 'Đã hoàn thành ca' : 'Đã chấm công') : 'Chưa chấm công'
}
const notificationEventLabel = event => ({company_application:'Chờ duyệt', created:'Ca mới', updated:'Thay đổi lịch', cancelled:'Ca đã hủy', attendance_in:'Chấm công vào', attendance_out:'Chấm công ra', join_request:'Yêu cầu gia nhập'})[event] || 'Thông báo'
const hasManagedCompany = computed(() => companies.value.some(c => c.role === 'manager'))
const activeApplication = computed(() => applications.value.some(a => a.status === 'pending' || a.status === 'approved'))
const pendingApplications = computed(() => applications.value.filter(a => a.status === 'pending'))
const tabs = computed(() => {
  if (isAdmin) return [['approval','Đơn chờ duyệt'],['notifications','Thông báo'],['companies','Quản lý công ty'],['accounts','Tài khoản'],['profile','Hồ sơ của tôi']]
  const result = [['calendar',manager.value ? 'Phân ca' : 'Lịch của tôi']]
  if (!manager.value) result.push(['attendance','Chấm công'], ['income','Thu nhập'])
  else result.push(['payroll','Bảng công & lương'])
  result.push(['notifications','Thông báo'])
  result.push(['people',manager.value ? 'Quản lý nhân sự' : 'Đồng nghiệp'],['community', manager.value ? 'Tuyển nhân sự' : 'Cộng đồng'])
  if (!hasManagedCompany.value) result.push(['registration', activeApplication.value ? 'Đơn đăng ký' : 'Đăng ký công ty'])
  result.push(['profile','Hồ sơ của tôi'])
  return result
})
function provinceKey(value) {
  return value.trim().toLowerCase().normalize('NFD').replace(/\p{Diacritic}/gu, '').replace(/đ/g, 'd')
    .replace(/^(?:thanh pho|tinh)\s+|^tp\.?\s*/u, '')
}
const provinceNames = new Map(provinces.map(({ name }) => [provinceKey(name), name]))
provinceNames.set('hcm', provinceNames.get('ho chi minh'))
function companyProvince(address) {
  const part = address?.split(',').map(value => value.trim()).filter(Boolean).at(-1)
  return part && provinceNames.get(provinceKey(part))
}
const accountGroups = computed(() => {
  const groups = [
    { role:'admin', label:'Admin', items:[] },
    { role:'manager', label:'Manager', items:[] },
    { role:'staff', label:roleLabel('staff'), items:[] },
    { role:'freelance', label:roleLabel('freelance'), items:[] },
    { role:'unknown', label:'Chưa xác định', items:[] }
  ]
  const managerEmails = new Set(adminCompanies.value.map(company => company.manager_email?.toLowerCase()).filter(Boolean))
  for (const account of accounts.value) {
    const accountRole = workspaceRoles.value?.[account.user_id] || (
      account.role === 'admin' || account.user_id === props.user.id ? 'admin'
        : account.role === 'manager' || managerEmails.has(account.email?.toLowerCase()) ? 'manager' : 'unknown'
    )
    groups.find(group => group.role === accountRole)?.items.push(account)
  }
  for (const group of groups) {
    group.items.sort((a, b) => (a.full_name || a.email || '').localeCompare(b.full_name || b.email || '', 'vi'))
  }
  return groups.filter(group => group.items.length)
})
const days = computed(() => { const year = month.value.getFullYear(), m = month.value.getMonth(), offset = (new Date(year,m,1).getDay()+6)%7, count = new Date(year,m+1,0).getDate(); return [...Array(offset).fill(null), ...Array.from({length:count},(_,i)=>i+1)] })
const nameOf = id => members.value.find(m => m.user_id === id)?.full_name || 'Nhân viên'
const payFor = id => compensation.value.find(p => p.user_id === id)
function memberRole(member) {
  if (member.role === 'manager') return 'manager'
  if (manager.value || member.user_id === props.user.id) return workerRole(payFor(member.user_id)?.employment_type)
  return workspaceRoles.value?.[member.user_id]
}
const filteredMembers = computed(() => members.value.filter(person => {
  const query = peopleSearch.value.trim().toLocaleLowerCase('vi-VN')
  if (query && !`${person.full_name} ${person.email}`.toLocaleLowerCase('vi-VN').includes(query)) return false
  if (peopleFilter.value === 'active') return person.is_active
  if (peopleFilter.value === 'inactive') return !person.is_active
  if (peopleFilter.value === 'staff' || peopleFilter.value === 'freelance') return person.is_active && memberRole(person) === peopleFilter.value
  return true
}))
const memberGroups = computed(() => {
  const list = filteredMembers.value
  if (!manager.value) return [{ label: 'Thành viên công ty', items: list }]
  return [
    { label:roleLabel('manager'), items:list.filter(m=>m.role==='manager') },
    { label:roleLabel('staff'), items:list.filter(m=>m.is_active && memberRole(m)==='staff') },
    { label:roleLabel('freelance'), items:list.filter(m=>m.is_active && memberRole(m)==='freelance') },
    { label:'Đã tạm ngừng làm việc', items:list.filter(m=>m.role!=='manager' && !m.is_active) }
  ].filter(group=>group.items.length)
})
async function toggleMember(person) {
  const active = !person.is_active
  const prompt = active
    ? `Kích hoạt lại ${person.full_name}?`
    : `Tạm ngừng hợp tác với ${person.full_name}? Các ca trong tương lai chưa chấm công sẽ được hủy và nhân viên nhận thông báo.`
  if (!window.confirm(prompt)) return
  await perform(() => repo.rpc('manager_set_staff_active', {
    p_company: companyId.value, p_user: person.user_id, p_active: active
  }), active ? 'Đã kích hoạt lại nhân viên.' : 'Đã tạm ngừng nhân viên; các ca tương lai chưa chấm công đã được hủy.')
}
const vndFormat = new Intl.NumberFormat('vi-VN')
const money = value => value != null && Number.isFinite(Number(value)) ? `${vndFormat.format(Number(value))} ₫` : 'Chưa có'
function openPay(member) {
  if (isAdmin || !manager.value || member.role !== 'staff' || busy.value || compensationUnavailable.value) return
  const pay = payFor(member.user_id)
  Object.assign(payForm,{user_id:member.user_id,name:member.full_name,employment_type:pay?.employment_type || 'freelancer',monthly_base_vnd:pay?.monthly_base_vnd ?? '',monthly_allowance_vnd:pay?.monthly_allowance_vnd ?? 0})
  error.value = ''
  modal.value='pay'
}
function savePay() {
  if (isAdmin || !manager.value || busy.value || compensationUnavailable.value ||
      !members.value.some(member => member.user_id === payForm.user_id && member.role === 'staff')) return
  const base = payForm.employment_type === 'freelancer' ? null : Number(payForm.monthly_base_vnd)
  const allowance = Number(payForm.monthly_allowance_vnd)
  if (payForm.monthly_allowance_vnd === '' || (base !== null && payForm.monthly_base_vnd === '') ||
      !Number.isSafeInteger(allowance) || allowance < 0 || allowance > 99999999999999 ||
      (base !== null && (!Number.isSafeInteger(base) || base < 0 || base > 99999999999999))) {
    error.value='Hãy nhập số tiền hợp lệ, không âm.'; return
  }
  perform(()=>repo.saveCompensation({
    company_id:companyId.value,user_id:payForm.user_id,employment_type:payForm.employment_type,
    monthly_base_vnd:base,monthly_allowance_vnd:allowance,updated_at:new Date().toISOString()
  }),'Đã lưu vai trò và lương.',true)
}
function shiftsForDate(dateText, schedule = shifts.value) {
  const start = new Date(dateText + 'T00:00:00')
  const end = new Date(start)
  end.setDate(end.getDate() + 1)
  return schedule.filter(s => new Date(s.starts_at) < end && new Date(shiftEndFor(s)) > start)
}
const shiftsOn = day => shiftsForDate(localDate(new Date(month.value.getFullYear(),month.value.getMonth(),day)))
const monthShifts = computed(() => shifts.value.filter(s => { const d = new Date(s.starts_at); return d.getFullYear() === month.value.getFullYear() && d.getMonth() === month.value.getMonth() }))
const plannedHours = computed(() => monthShifts.value.reduce((sum, s) => sum + Number(hours(s)), 0).toFixed(1))
const upcomingCount = computed(() => shifts.value.filter(s => new Date(s.starts_at) > new Date()).length)
const selectedShifts = computed(() => shiftsForDate(selectedDate.value).sort((a,b) => new Date(a.starts_at) - new Date(b.starts_at)))
watch([canSchedule, selectedShifts], ([allowed, items], _, onCleanup) => {
  if (!allowed || !items.length) return
  const endTimes = items.map(item => Date.parse(item.ends_at))
  let timer
  function refreshScheduleTime() {
    const now = Date.now()
    scheduleNow.value = now
    const nextEnd = Math.min(...endTimes.filter(end => end > now))
    if (Number.isFinite(nextEnd)) {
      timer = window.setTimeout(refreshScheduleTime, Math.min(nextEnd - now, 2 ** 31 - 1))
    }
  }
  onCleanup(() => window.clearTimeout(timer))
  refreshScheduleTime()
}, { immediate: true })
const selectedDayHasAttendance = computed(() => selectedShifts.value.some(item => clockRecordFor(item.id)))
const attendedDayMessage = 'Ngày này đã có chấm công nên không thể thêm hoặc sửa ca.'
const selectedDayAddBlock = computed(() => selectedDayHasAttendance.value ? attendedDayMessage
  : selectedDate.value < localDate(new Date()) ? 'Chỉ có thể phân ca với giờ bắt đầu trong tương lai.' : '')
const selectedDateLabel = computed(() => new Date(selectedDate.value + 'T12:00:00').toLocaleDateString('vi-VN', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }))
const timeOf = stamp => new Date(stamp).toLocaleTimeString('vi-VN', { hour: '2-digit', minute: '2-digit' })
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
  const editingIds = new Set(editingCrew.value.map(item => item.id))
  return shifts.value.filter(item => {
    if (!shift.user_ids.includes(item.user_id) || editingIds.has(item.id)) return false
    const assignedStart = new Date(item.starts_at)
    return localDate(assignedStart) === shift.date && isMorningShift(assignedStart, new Date(item.ends_at))
  })
})
const dateForDay = day => localDate(new Date(month.value.getFullYear(), month.value.getMonth(), day))
const isToday = day => dateForDay(day) === localDate(new Date())
const dayAction = day => canSchedule.value
  ? (shiftsOn(day).length ? 'Quản lý ca trong ngày' : 'Phân ca mới')
  : 'Xem các ca trong ngày'
async function clickCalendarCell(day) {
  selectedDate.value = dateForDay(day)
  if (!canSchedule.value) {
    await nextTick()
    staffDayHeading.value?.scrollIntoView({ block: window.matchMedia('(max-width: 1050px)').matches ? 'start' : 'nearest' })
    staffDayHeading.value?.focus({ preventScroll: true })
    return
  }
  if (busy.value) return
  if (selectedShifts.value.length) {
    error.value = ''
    modal.value = 'shift-picker'
  } else {
    openShift(day)
  }
}
function focusCalendarDay() {
  calendarGrid.value?.querySelector('[aria-pressed="true"]')?.focus()
}
function chooseShiftStaff(userId, checked) {
  if (editingShiftId.value && crewMemberClocked(userId) && !checked) return
  shift.user_ids = checked
    ? [...new Set([...shift.user_ids, userId])]
    : shift.user_ids.filter(id => id !== userId)
}
function editShift(item) {
  if (!canSchedule.value || busy.value || selectedDayHasAttendance.value || workIsCompleted(item)) return
  scheduleNow.value = Date.now()
  if (shiftHasEnded(item, scheduleNow.value)) return
  const start = new Date(item.starts_at), end = new Date(item.ends_at)
  selectedDate.value = localDate(start)
  month.value = new Date(start.getFullYear(),start.getMonth(),1)
  editingShiftId.value = item.id
  Object.assign(shift, {
    title: item.title, location: item.location || '',
    date: localDate(start), end_date: localDate(end),
    start: inputTime(start), end: inputTime(end), cast_vnd: Number(item.cast_vnd || 0),
    user_ids: shifts.value.filter(s=>sameWorkSlot(s,item)).map(s=>s.user_id)
  })
  error.value = ''
  modal.value = 'shift'
}
function goToToday() { month.value = new Date(new Date().getFullYear(),new Date().getMonth(),1); selectedDate.value = localDate(new Date()) }
function createShiftOnSelectedDay() {
  if (!canSchedule.value) return
  const [y,m,d] = selectedDate.value.split('-').map(Number)
  month.value = new Date(y,m-1,1)
  openShift(d)
}
const statusText = status => ({pending:'Đang chờ duyệt', approved:'Đã duyệt', rejected:'Đã từ chối'})[status] || status
function changeMonth(delta) { month.value = new Date(month.value.getFullYear(), month.value.getMonth() + delta, 1); selectedDate.value = localDate(month.value) }
function openShift(day) {
  if (!canSchedule.value || busy.value) return
  if (selectedDayAddBlock.value) { error.value = selectedDayAddBlock.value; return }
  error.value = ''
  editingShiftId.value = ''
  const date = dateForDay(day)
  Object.assign(shift, {title:'',location:accountProfile.active_location || '',date,end_date:date,start:'08:00',end:'12:00',cast_vnd:300000,user_ids:[]})
  modal.value = 'shift'
}
const inputTime = date => [date.getHours(), date.getMinutes()].map(value => String(value).padStart(2, '0')).join(':')
const shiftPeriods = { morning:['08:00','12:00'], afternoon:['13:00','17:00'], evening:['18:00','23:00'], all:['08:00','23:00'] }
const shiftPeriod = computed(() => Object.keys(shiftPeriods).find(key => {
  const [start, end] = shiftPeriods[key]
  return start === shift.start && end === shift.end
}) || 'custom')
function setPeriod(event) {
  const times = shiftPeriods[event.target.value]
  if (times) [shift.start, shift.end] = times
}
async function perform(fn, success, close = false) { if (await w.perform(fn,success) && close) modal.value='' }
function refreshAccountDirectory() {
  perform(() => Promise.resolve(), 'Đã làm mới danh sách tài khoản.')
}
function openDisableAccount(account) {
  disableTarget.value = account
  disableReason.value = ''
  error.value = ''
  modal.value = 'disable-account'
}
async function confirmDisableAccount() {
  if (!disableTarget.value || busy.value) return
  const reason = disableReason.value.trim()
  if (reason.length < 5) { error.value = 'Lý do phải có ít nhất 5 ký tự.'; return }
  await perform(() => repo.rpc('admin_set_account_disabled', {
    p_user: disableTarget.value.user_id, p_disabled: true, p_reason: reason
  }), 'Đã vô hiệu hóa tài khoản.', true)
}
async function saveShift() {
  if (busy.value) return
  if (!canSchedule.value) { error.value = 'Chỉ Manager mới được phân ca.'; return }
  if (editingShift.value && workIsCompleted(editingShift.value)) { error.value = completedWorkMessage; return }
  scheduleNow.value = Date.now()
  if (editingShiftHasEnded.value) { error.value = endedWorkMessage; return }
  let rows = [], plan = null
  try {
    const eligible = new Set(assignableMembers.value.map(m => m.user_id))
    if (!shift.user_ids.every(id => eligible.has(id))) throw new Error('Chỉ được phân ca cho nhân viên thuộc công ty.')
    if (editingShiftId.value) {
      plan = shiftEditPlan(shift,companyId.value,editingShiftId.value,shifts.value,clockRecords.value.map(c=>c.shift_id))
    } else rows = shiftRows(shift,companyId.value,shifts.value)
  } catch(e) {
    error.value = e instanceof ShiftOverlapError
      ? `${assignedShiftText(e.shift)}, trùng giờ với ca này.`
      : e?.message || 'Ca làm việc chưa hợp lệ.'
    return
  }
  busy.value=true; error.value=''; message.value=''
  try {
    const company = companyId.value
    const shiftId = editingShiftId.value
    const original = editingShift.value
    const date = shift.date
    const work = plan ? (plan.updates[0]?.changes || plan.addedRows[0]) : rows[0]
    const userIds = [...shift.user_ids]
    const changesTime = !original || new Date(work.starts_at).getTime() !== new Date(original.starts_at).getTime()
      || new Date(work.ends_at).getTime() !== new Date(original.ends_at).getTime()
    if (changesTime && Date.parse(work.starts_at) <= Date.now()) {
      throw new Error('Giờ bắt đầu ca phải ở tương lai.')
    }
    const [attendance, schedule] = await Promise.all([repo.attendance(company), repo.shifts(company)])
    if (companyId.value !== company || editingShiftId.value !== shiftId || modal.value !== 'shift') {
      busy.value = false
      return
    }
    clockRecords.value = attendance || []
    const attendedIds = new Set(clockRecords.value.map(record => record.shift_id))
    const workEndDate = localDate(new Date(Date.parse(work.ends_at) - 1))
    if ([date, workEndDate].some(day => shiftsForDate(day, schedule).some(item => attendedIds.has(item.id)))) {
      throw new Error(attendedDayMessage)
    }
    if (changesTime && Date.parse(work.starts_at) <= Date.now()) {
      throw new Error('Giờ bắt đầu ca phải ở tương lai.')
    }
    if (shiftId) {
      const latestShift = schedule.find(item => item.id === shiftId)
      if (!latestShift) throw new Error('Không tìm thấy ca làm cần sửa. Hãy tải lại lịch.')
      if (shiftHasEnded(original) || shiftHasEnded(latestShift)) {
        shifts.value = schedule
        scheduleNow.value = Date.now()
        throw new Error(endedWorkMessage)
      }
      await repo.updateWorkAssignments(shiftId,work,userIds)
    } else {
      await repo.insert('company_shifts', rows)
    }
  } catch (e) {
    const errors = {
      '23P01':'Nhân viên bị trùng ca, có thể ở công ty khác. Hãy chọn giờ khác.',
      '23503':'Nhân viên không thuộc công ty này.',
      '23514':'Thời lượng ca không hợp lệ.',
      '42501':'Tài khoản chưa được cấp quyền phân ca.',
      'P4510':'Ca đã chấm công, không được hủy.',
      'P4511':'Ca đã chấm công, không được đổi nhân viên hoặc giờ làm.',
      'P4512':'Ca đã chấm công, không được thay đổi Cast hoặc bỏ nhân viên đã chấm công.',
      'P4561':'Chỉ Manager mới được cập nhật phân công.',
      'PGRST202':'Cần chạy supabase/multi_staff_assignment.sql trong Supabase.',
      'P4562':'Danh sách phân công hoặc dữ liệu ca chưa hợp lệ.',
      'PGRST205':'Bảng lịch chưa tồn tại trong Supabase.'
    }
    error.value=errors[e?.code] || e?.message || 'Không thể lưu ca. Vui lòng thử lại.'
    busy.value=false
    return
  }
  modal.value=''
  message.value=editingShiftId.value ? `Đã cập nhật phân công cho ${shift.user_ids.length} nhân viên.` : `Đã lưu ${rows.length} ca làm việc thành công.`
  editingShiftId.value=''
  try { await w.refreshCompany() } catch(e) {
    error.value='Ca đã lưu thành công, nhưng chưa tải lại được lịch. Vui lòng tải lại trang.'
  } finally { busy.value=false }
}
async function removeShift(item) {
  const items = item ? [item] : selectedShifts.value
  if (!canSchedule.value || busy.value || !items.length) return
  if (items.some(shift => clockRecordFor(shift.id))) {
    error.value = 'Có ca đã chấm công nên không thể xóa.'
    return
  }
  const confirmation = item
    ? `Hủy ca "${item.title}" của ${nameOf(item.user_id)}?`
    : `Xóa tất cả ${items.length} ca hiển thị vào ${selectedDateLabel.value}? Ca qua đêm cũng sẽ bị xóa khỏi những ngày liên quan.`
  if (!window.confirm(confirmation)) return
  busy.value=true; error.value=''; message.value=''
  try {
    const removed = await repo.deleteShifts(items.map(shift => shift.id), companyId.value)
    modal.value=''
    message.value = item ? 'Đã hủy ca làm việc.' : `Đã xóa ${removed.length} ca làm việc.`
    try { await w.refreshCompany() }
    catch { error.value='Đã hủy ca nhưng chưa tải lại được lịch. Hãy làm mới trang.' }
  } catch(e) {
    error.value=e?.code==='P4510' || e?.code==='23503'
      ? 'Có ca đã chấm công nên không thể xóa. Vui lòng tải lại lịch.'
      : (e?.message || 'Không thể hủy ca này.')
  } finally { busy.value=false }
}
async function clockAction(item, action) {
  if (isAdmin || manager.value || busy.value || clockUnavailable.value) return
  busy.value=true; error.value=''; message.value=''
  try {
    if (action==='in') await repo.clockIn(item.id)
    else await repo.clockOut(item.id)
    message.value=action==='in'?'Đã chấm công.':'Đã xác nhận hoàn thành ca.'
    try { await w.refreshCompany() }
    catch { error.value='Đã lưu thao tác nhưng chưa tải lại được dữ liệu. Hãy làm mới trang.' }
  } catch(e) {
    const messages={
      P4520:'Chỉ người được phân ca mới có thể chấm công.',
      P4521:'Chỉ chấm công từ 1 giờ trước ca đến 12 giờ sau khi ca kết thúc.',
      P4522:'Ca chưa chấm công hoặc đã được xác nhận hoàn thành.',
      PGRST202:'Supabase chưa có hàm chấm công. Hãy chạy shift_attendance.sql.'
    }
    error.value=messages[e?.code] || e?.message || 'Không thể chấm công.'
  } finally { busy.value=false }
}
function saveApplication() { perform(() => repo.insert('company_applications',{...form, applicant_id:props.user.id}), 'Đã gửi đăng ký công ty.') }
function saveProfile() { perform(() => repo.upsert('freelancer_profiles',{user_id:props.user.id,...freelancer}), 'Đã lưu hồ sơ freelancer.') }
async function markRead(notification) {
  if (notification.read_at) return
  try {
    await w.markNotificationRead(notification.id)
  } catch(e) { error.value = e?.message || 'Không thể đánh dấu thông báo đã đọc.' }
}
async function openApplication(notification) {
  tab.value = 'approval'
  await nextTick()
  document.getElementById(notification.id)?.focus()
}
function onWindowFocus() {
  if (restriction.value?.disabled || document.visibilityState==='hidden') return
  w.refreshNotifications()
  if (!isAdmin && (tab.value==='calendar' || tab.value==='attendance')) w.refreshCompany().catch(()=>{})
}
let notificationPoll = null
function changeCompany() { modal.value=''; error.value=''; message.value=''; w.refreshCompany().catch(e => { error.value = e?.message || 'Không tải được công ty.' }) }
watch(profile, p => { if(p) Object.assign(freelancer, {display_name:p.display_name,specialty:p.specialty,visible:p.visible}) })
watch(tabs, available => { if (!available.some(item => item[0] === tab.value)) tab.value = isAdmin ? 'approval' : 'calendar' })
watch(tab, next => {
  if (next === 'notifications') w.refreshNotifications()
  if (next === 'payroll') w.refreshPayroll(reportMonthText.value)
})
watch(reportMonth, () => { if (tab.value === 'payroll') w.refreshPayroll(reportMonthText.value) })
watch(companyId, () => { if (tab.value === 'payroll') w.refreshPayroll(reportMonthText.value) })
onMounted(() => {
  repo.accountProfile(props.user.id).then(p=>{ if(p) Object.assign(accountProfile,{full_name:p.full_name || accountProfile.full_name,birth_date:p.birth_date || '',hometown:p.hometown || '',active_location:p.active_location || '',avatar_url:p.avatar_url || ''}) }).catch(e=>{ error.value=e?.message || 'Không tải được hồ sơ.' })
  w.perform(() => Promise.resolve(), '')
  window.addEventListener('focus',onWindowFocus)
  // Keep the unread badge fresh without requiring users to open the inbox.
  notificationPoll = window.setInterval(() => {
    if (!restriction.value?.disabled && document.visibilityState==='visible') w.refreshNotifications()
  },60000)
})
onUnmounted(() => {
  if (avatarPreview.value) URL.revokeObjectURL(avatarPreview.value)
  window.removeEventListener('focus',onWindowFocus)
  if (notificationPoll) window.clearInterval(notificationPoll)
})
</script>

<template>
  <ToastStack ref="toastStack" />
  <dialog ref="expenseDialog" class="shift-notice-dialog" aria-labelledby="expense-title" @close="expenseShiftId = ''">
    <template v-if="expenseShift">
      <div class="shift-notice-header">
        <div><p>{{ expenseShift.title }}</p><h2 id="expense-title">Chi phí phát sinh</h2></div>
        <form method="dialog"><button type="submit">Đóng</button></form>
      </div>
      <dl class="expense-summary">
        <div><dt>Cast gốc</dt><dd>{{ money(expenseShift.cast_vnd ?? 0) }}</dd></div>
        <div><dt>Phát sinh</dt><dd>{{ money(expenseAttendance?.expense_total_vnd ?? 0) }}</dd></div>
        <div><dt>Tổng Cast</dt><dd>{{ money(completedShiftCast(expenseShift, expenseAttendance)) }}</dd></div>
      </dl>
      <ul v-if="expenseAttendance?.expenses?.length" class="expense-list">
        <li v-for="expense in expenseAttendance.expenses" :key="expense.id">
          <span>{{ expense.note }}</span><strong>{{ money(expense.amount_vnd) }}</strong>
        </li>
      </ul>
      <p v-if="expenseAttendance?.checked_out_at" class="notice">Ca đã hoàn thành. Chi phí đã được chốt.</p>
      <p v-if="expenseError" class="alert" role="alert">{{ expenseError }}</p>
      <form v-if="expenseAttendance && !expenseAttendance.checked_out_at" class="form" @submit.prevent="saveExpense">
        <label>Nội dung khoản chi<input v-model="expenseForm.note" required maxlength="160" placeholder="Ví dụ: Đồ ăn cho đội" :disabled="expenseSaving"></label>
        <label>Số tiền (₫)<input v-model="expenseForm.amount" required type="number" inputmode="numeric" min="1" max="100000000" step="1" :disabled="expenseSaving"></label>
        <div class="form-actions"><button type="submit" class="primary" :disabled="expenseSaving">Thêm khoản chi</button></div>
      </form>
    </template>
  </dialog>
  <dialog ref="notificationDialog" class="shift-notice-dialog" aria-labelledby="shift-notice-title" @close="activeNotification = null">
    <template v-if="activeNotification">
      <div class="shift-notice-header">
        <div><p>{{ notificationEventLabel(activeNotification.event) }}</p><h2 id="shift-notice-title">{{ notificationDetail?.title || activeNotification.title }}</h2></div>
        <form method="dialog"><button type="submit" autofocus>Đóng</button></form>
      </div>
      <p v-if="activeNotification.event === 'cancelled'" class="notice">Ca này đã bị hủy. Thông tin dưới đây là lịch trước khi hủy.</p>
      <p v-if="notificationReadError" class="alert" role="alert">{{ notificationReadError }}</p>
      <dl v-if="notificationDetail" class="shift-notice-fields">
        <div><dt>Công ty</dt><dd>{{ directory.find(c => c.id === activeNotification.company_id)?.name || 'Công ty phân ca' }}</dd></div>
        <div><dt>Địa điểm</dt><dd>{{ notificationDetail.location || 'Chưa cập nhật' }}</dd></div>
        <div><dt>Bắt đầu</dt><dd>{{ noticeDateFormat.format(new Date(notificationDetail.starts_at)) }}</dd></div>
        <div><dt>Kết thúc</dt><dd>{{ noticeDateFormat.format(new Date(notificationDetail.ends_at)) }}</dd></div>
      </dl>
      <p v-else-if="notificationDetailLoading" role="status">Đang tải chi tiết ca...</p>
      <p v-else>{{ activeNotification.body }}</p>
    </template>
  </dialog>
  <main v-if="loading" class="auth-screen" aria-live="polite">Đang tải dữ liệu...</main>
  <main v-else-if="restriction?.disabled" class="auth-screen"><section class="auth-box"><h1>Tài khoản đã bị vô hiệu hóa</h1><p>Lý do: {{ restriction.reason }}</p><button @click="repo.auth.signOut()">Đăng xuất</button></section></main>
  <div v-else class="app-shell">
    <aside class="sidebar">
      <div class="brand"><span class="brand-mark">S</span><div><strong>SHIFTLY</strong><small>Quản lý nhân sự sự kiện</small></div></div>
      <div class="workspace-profile"><img class="profile-avatar" :src="avatarPreview || accountProfile.avatar_url || defaultAvatar" alt="Ảnh đại diện"><div><b>{{ accountProfile.full_name || roleLabel(role) }}</b><small>{{ roleLabel(role) }} · {{ user.email }}</small></div></div>
      <div class="side-label">{{ isAdmin ? 'QUẢN TRỊ HỆ THỐNG' : manager ? 'QUẢN LÝ CÔNG TY' : 'KHÔNG GIAN CỦA TÔI' }}</div>
      <nav aria-label="Điều hướng chính">
        <button v-for="item in tabs" :key="item[0]" :class="{selected:tab===item[0]}" :aria-current="tab===item[0] ? 'page' : undefined" @click="tab=item[0]">{{ item[1] }}<span v-if="item[0]==='notifications' && unreadCount" class="nav-unread">{{ unreadCount }}</span></button>
        <button type="button" class="nav-sign-out" @click="repo.auth.signOut()">Đăng xuất</button>
      </nav>
    </aside>
    <div class="main-area">
      <header class="mobile-header">
        <div class="brand"><span class="brand-mark">S</span><div><strong>SHIFTLY</strong><small>Quản lý nhân sự sự kiện</small></div></div>
        <div class="workspace-profile"><img class="profile-avatar" :src="avatarPreview || accountProfile.avatar_url || defaultAvatar" alt="Ảnh đại diện"><div><b>{{ accountProfile.full_name || roleLabel(role) }}</b><small>{{ roleLabel(role) }} · {{ user.email }}</small></div></div>
      </header>
      <nav class="mobile-nav" aria-label="Điều hướng trên điện thoại">
        <button v-for="item in tabs" :key="item[0]" :class="{selected:tab===item[0]}" :aria-current="tab===item[0] ? 'page' : undefined" @click="tab=item[0]">{{ item[1] }}<span v-if="item[0]==='notifications' && unreadCount" class="nav-unread">{{ unreadCount }}</span></button>
        <button type="button" class="nav-sign-out" @click="repo.auth.signOut()">Đăng xuất</button>
      </nav>
      <main class="content">
        <div class="page-heading"><div><p class="eyebrow">{{ roleLabel(role) }}</p><h1>{{ tabs.find(t => t[0]===tab)?.[1] }}</h1><p v-if="tab!=='people'">{{ isAdmin ? 'Phê duyệt công ty và kiểm soát tài khoản trên toàn hệ thống.' : manager ? 'Điều phối ca làm việc và nhân sự của công ty đang chọn.' : 'Chỉ hiển thị các ca đã được giao cho bạn.' }}</p></div><div v-if="!isAdmin && current" class="company-context">
          <label v-if="selectableCompanies.length>1" class="company-select">Công ty của bạn<select v-model="companyId" @change="changeCompany"><option v-for="c in selectableCompanies" :key="c.id" :value="c.id">{{ c.name }}</option></select></label>
          <div v-else class="company-identity"><span>{{ manager ? 'CÔNG TY ĐANG QUẢN LÝ' : 'CÔNG TY CỦA BẠN' }}</span><strong>{{ current.name }}</strong></div>
        </div></div>
        <section v-if="tab==='profile'" class="surface section"><h2>Hồ sơ của tôi</h2><p>Áp dụng cho tài khoản {{ roleLabel(role) }}. Cập nhật quê quán, khu vực hoạt động và ảnh đại diện.</p><form class="form" @submit.prevent="saveAccountProfile"><img class="profile-avatar profile-avatar-large" :src="avatarPreview || accountProfile.avatar_url || defaultAvatar" alt="Ảnh đại diện"><label>Ảnh đại diện<input type="file" accept="image/jpeg,image/png,image/webp" @change="chooseAvatar"></label><label>Họ và tên<input v-model="accountProfile.full_name" required maxlength="120"></label><label>Ngày sinh<input v-model="accountProfile.birth_date" type="date"></label><div class="location-field"><span class="location-title">Quê quán</span><LocationPicker v-model="accountProfile.hometown" /></div><div class="location-field"><span class="location-title">{{ manager ? 'Khu vực đang hoạt động (mặc định khi phân ca)' : 'Khu vực đang hoạt động' }}</span><LocationPicker v-model="accountProfile.active_location" /></div><button class="primary" :disabled="busy">Lưu hồ sơ</button></form></section>
        <section v-if="!isAdmin && invitations.length" class="surface section"><h2>Lời mời tham gia</h2><div v-for="i in invitations" :key="i.id" class="row"><span>{{ directory.find(c=>c.id===i.company_id)?.name || 'Công ty' }}</span><button :disabled="busy" @click="perform(()=>repo.rpc('accept_company_invitation',{p_invitation:i.id}),'Đã tham gia công ty.')">Chấp nhận</button></div></section>

        <section v-if="isAdmin && tab==='approval'" class="overview-grid" aria-label="Tổng quan quản trị">
          <div class="overview-tile"><span>Đơn đang chờ</span><strong>{{ applications.filter(a => a.status==='pending').length }}</strong><small>Cần quản trị viên xét duyệt</small></div>
          <div class="overview-tile"><span>Công ty đã duyệt</span><strong>{{ adminCompanies.length }}</strong><small>Đang hoạt động trên hệ thống</small></div>
          <div class="overview-tile"><span>Tài khoản</span><strong>{{ accounts.length }}</strong><small>Đã từng đăng nhập</small></div>
        </section>

        <template v-if="tab==='calendar' && !isAdmin">
          <section v-if="!companyId" class="surface empty">
            <h2>Bạn chưa tham gia công ty nào</h2>
            <p>Hãy vào mục Cộng đồng để gửi yêu cầu tham gia hoặc chấp nhận lời mời phía trên.</p>
          </section>
          <template v-else>
            <section class="overview-grid" :class="{'staff-calendar-summary': !canSchedule}" aria-label="Tổng quan lịch làm việc">
              <div class="overview-tile"><span>{{ canSchedule ? 'Nhân sự' : 'Ca của tôi' }}</span><strong>{{ canSchedule ? members.length : monthShifts.length }}</strong><small>{{ canSchedule ? 'Thành viên của công ty' : 'Trong tháng đang xem' }}</small></div>
              <div class="overview-tile"><span>{{ canSchedule ? 'Ca trong tháng' : 'Giờ dự kiến' }}</span><strong>{{ canSchedule ? monthShifts.length : plannedHours }}</strong><small>{{ canSchedule ? 'Tất cả ca được phân' : 'Giờ được phân trong tháng' }}</small></div>
              <div class="overview-tile"><span>Ca sắp tới</span><strong>{{ upcomingCount }}</strong><small>{{ canSchedule ? 'Ca của đội ngũ' : 'Ca đã giao cho bạn' }}</small></div>
            </section>
            <div :class="{'staff-calendar-layout': !canSchedule}">
              <div>
                <div class="calendar-controls">
                  <div><h2>{{ month.toLocaleDateString('vi-VN',{month:'long',year:'numeric'}) }}</h2><p>{{ canSchedule ? 'Nhấn ô trống để phân ca. Nhấn ô có ca để mở menu quản lý.' : 'Bấm vào một ngày để xem các ca làm.' }}</p></div>
                  <div class="calendar-tools"><div class="button-group"><button type="button" aria-label="Tháng trước" @click="changeMonth(-1)">‹</button><button type="button" @click="goToToday">Hôm nay</button><button type="button" aria-label="Tháng sau" @click="changeMonth(1)">›</button></div><button v-if="canSchedule" type="button" class="primary add-shift-button" :disabled="busy || !!selectedDayAddBlock" :title="selectedDayAddBlock" @click="createShiftOnSelectedDay">+ Phân ca mới</button></div>
                </div>
                <div ref="calendarGrid" class="calendar-wrap">
                  <div class="calendar">
                    <div v-for="name in ['T2','T3','T4','T5','T6','T7','CN']" :key="name" class="weekday">{{ name }}</div>
                    <div v-for="(day,index) in days" :key="index" class="day" :class="{blank:!day, active:day && selectedDate===dateForDay(day), 'has-shifts':day && shiftsOn(day).length}">
                      <button v-if="day" type="button" class="day-button" :aria-description="dayAction(day)" :aria-controls="canSchedule ? undefined : 'staff-day-detail'" :aria-current="isToday(day) ? 'date' : undefined" :aria-pressed="selectedDate===dateForDay(day)" @click="clickCalendarCell(day)">
                        <span class="day-number">{{ day }}</span>
                        <span v-if="shiftsOn(day).length" class="day-shift-count">{{ shiftsOn(day).length }} ca</span>
                        <template v-if="canSchedule">
                          <span v-for="s in shiftsOn(day)" :key="s.id" class="shift-chip">{{ timeOf(s.starts_at) }} {{ s.title }}<small>{{ nameOf(s.user_id) }}</small></span>
                        </template>
                      </button>
                    </div>
                  </div>
                </div>
              </div>
              <section :id="canSchedule ? undefined : 'staff-day-detail'" class="surface section day-detail" :class="{'staff-day-detail': !canSchedule}" aria-label="Chi tiết ca theo ngày">
                <div class="section-title">
                  <div v-if="canSchedule"><h2>Ca làm · {{ selectedDateLabel }}</h2><p>Lịch phân công của công ty.</p></div>
                  <div v-else><h2 ref="staffDayHeading" tabindex="-1">Ca làm trong ngày</h2><p>{{ selectedDateLabel }} · {{ selectedShifts.length }} ca</p></div>
                  <button v-if="!canSchedule" type="button" class="staff-return-calendar" @click="focusCalendarDay">Về lịch tháng</button>
                </div>
                <div v-if="canSchedule && selectedDayAddBlock" class="notice" role="status">{{ selectedDayAddBlock }}</div>
                <div v-if="!canSchedule && clockError" class="notice" role="status">{{ clockError }}</div>
                <div v-if="!selectedShifts.length" class="empty day-empty">Không có ca nào trong ngày này.</div>
                <div v-for="item in selectedShifts" :key="item.id" class="row shift-detail-row">
                  <div class="shift-timing"><strong>{{ timeOf(item.starts_at) }} - {{ timeOf(shiftEndFor(item)) }}</strong><small v-if="localDate(new Date(item.starts_at))!==selectedDate">Bắt đầu ngày {{ localDate(new Date(item.starts_at)) }}</small><small v-if="localDate(new Date(shiftEndFor(item)))!==selectedDate">Kết thúc ngày {{ localDate(new Date(shiftEndFor(item))) }}</small><small v-if="shiftEndFor(item) !== item.ends_at">Dự kiến kết thúc {{ timeOf(item.ends_at) }}</small></div>
                  <div class="shift-description"><b>{{ item.title }}</b><small>{{ item.location || 'Chưa cập nhật địa điểm' }}<template v-if="canSchedule"> · {{ nameOf(item.user_id) }}</template></small></div>
                  <div v-if="canSchedule" class="shift-actions">
                    <span v-if="shiftEditLockLabel(item)" class="clock-locked">{{ shiftEditLockLabel(item) }}</span>
                    <span v-else-if="clockRecordFor(item.id)" class="clock-locked">Đã chấm công vào · Không thể hủy</span>
                    <button v-else-if="!selectedDayHasAttendance" type="button" :disabled="busy" @click="editShift(item)">Sửa ca</button>
                    <button type="button" class="danger-quiet" :disabled="busy || !!clockRecordFor(item.id)" :title="clockRecordFor(item.id)?'Ca đã chấm công không thể hủy':''" :aria-label="'Hủy ca '+item.title+' của '+nameOf(item.user_id)" @click="removeShift(item)">Hủy ca</button>
                  </div>
                  <div v-else class="shift-actions clock-actions">
                    <span class="clock-status">{{ clockStatus(item) }}</span>
                    <button v-if="!clockRecordFor(item.id)" type="button" class="primary" :disabled="busy || !canClockIn(item)" @click="clockAction(item,'in')">Chấm công</button>
                    <button v-else-if="!clockRecordFor(item.id).checked_out_at" type="button" :disabled="busy" @click="clockAction(item,'out')">Xác nhận hoàn thành ca</button>
                    <button v-if="!clockRecordFor(item.id)?.checked_out_at || clockRecordFor(item.id).expenses?.length" type="button" :disabled="busy || !clockRecordFor(item.id)" :title="clockRecordFor(item.id) ? undefined : 'Chấm công trước khi nhập chi phí'" @click="openExpenses(item)">Chi phí phát sinh</button>
                  </div>
                </div>
              </section>
            </div>
          </template>
        </template>

        <section v-if="tab==='notifications'" class="surface section notifications-section">
          <div class="section-title">
            <div><h2>{{ isAdmin ? 'Thông báo Admin' : 'Thông báo công việc' }}</h2>
              <p>{{ isAdmin ? 'Đơn đăng ký công ty đang chờ xử lý.' : manager ? 'Ca làm, chấm công và yêu cầu gia nhập theo vai trò của bạn ở từng công ty.' : 'Tin phân ca mới hiển thị trong 7 ngày. Tin đổi và hủy ca được giữ lại để tra cứu.' }}</p>
            </div>
            <button type="button" :disabled="notificationsLoading" @click="w.refreshNotifications()">Làm mới</button>
          </div>
          <div v-if="!isAdmin" class="notification-filters" role="group" aria-label="Lọc thông báo theo thời gian">
            <button type="button" :aria-pressed="notificationGroup === 'current'" @click="selectNotificationGroup('current')">Hiện tại <span>{{ notificationGroups.current.length }}</span></button>
            <button type="button" :aria-pressed="notificationGroup === 'past'" @click="selectNotificationGroup('past')">Quá khứ <span>{{ notificationGroups.past.length }}</span></button>
          </div>
          <div v-if="notificationsError" class="alert" role="alert">{{ notificationsError }}</div>
          <div v-else-if="notificationsLoading && !notifications.length" class="empty" role="status">Đang tải thông báo...</div>
          <div v-else-if="!visibleNotifications.length" class="empty">{{ isAdmin ? 'Không có đơn đăng ký công ty chờ duyệt.' : 'Chưa có thông báo trong mục này.' }}</div>
          <div v-for="item in visibleNotifications" :key="item.id" class="row notification-row" :class="{unread:!item.read_at}">
            <div class="notification-main"><div class="notification-head">
              <button v-if="isShiftNotification(item)" class="notification-title-button" type="button" aria-haspopup="dialog" @click="openShiftNotification(item)">{{ item.title }}</button>
              <b v-else>{{ item.title }}</b><span class="badge">{{ notificationEventLabel(item.event) }}</span>
            </div>
              <small v-if="item.created_at"><template v-if="item.company_id">{{ directory.find(c=>c.id===item.company_id)?.name || 'Công ty' }} · </template>{{ new Date(item.created_at).toLocaleString('vi-VN') }}</small>
              <p>{{ item.body }}</p></div>
            <button v-if="isAdmin" type="button" @click="openApplication(item)">Xem đơn</button>
            <span v-else-if="isShiftNotification(item) || item.read_at" class="read-label">{{ item.read_at ? 'Đã đọc' : 'Chưa đọc' }}</span>
            <button v-else type="button" @click="markRead(item)">Đánh dấu đã đọc</button>
          </div>
          <nav v-if="notificationPages > 1" class="notification-pagination" aria-label="Phân trang thông báo">
            <button type="button" :disabled="notificationPage === 1" @click="notificationPage--">Trang trước</button>
            <span role="status">Trang {{ notificationPage }} / {{ notificationPages }}</span>
            <button type="button" :disabled="notificationPage === notificationPages" @click="notificationPage++">Trang sau</button>
          </nav>
        </section>
        <section v-if="tab==='attendance' && !manager && !isAdmin" class="surface section">
          <div class="section-title"><div><h2>Chấm công thực tế</h2><p>Chấm công cho ca được giao. Bạn có thể xác nhận hoàn thành sau khi làm xong.</p></div></div>
          <div v-if="clockError" class="alert" role="alert">{{ clockError }}</div>
          <div v-if="!shifts.length" class="empty">Bạn chưa được phân ca làm việc.</div>
          <div v-for="s in shifts" :key="s.id" class="row attendance-row">
            <div class="attendance-summary"><b>{{ s.title }}</b><small><time :datetime="s.starts_at" :title="noticeDateFormat.format(new Date(s.starts_at))">{{ shortShiftTime(s.starts_at) }}</time> · {{ s.location }}</small>
              <small>Dự kiến: {{ hours(s) }} giờ · {{ clockStatus(s) }}</small>
              <small v-if="clockRecordFor(s.id)">Chấm công {{ shortShiftTime(clockRecordFor(s.id).checked_in_at) }}<template v-if="clockRecordFor(s.id).checked_out_at"> · Hoàn thành {{ shortShiftTime(clockRecordFor(s.id).checked_out_at) }}</template></small>
              <small v-if="shiftEndFor(s) !== s.ends_at">Kết thúc muộn · {{ shortShiftTime(shiftEndFor(s)) }}</small>
              <small v-if="clockRecordFor(s.id)?.expense_total_vnd">Tổng Cast gồm phát sinh: {{ money(completedShiftCast(s, clockRecordFor(s.id))) }}</small>
            </div>
            <div class="shift-actions clock-actions">
              <button v-if="!clockRecordFor(s.id)" class="primary" type="button" :disabled="busy || !canClockIn(s)" @click="clockAction(s,'in')">Chấm công</button>
              <button v-else-if="!clockRecordFor(s.id).checked_out_at" type="button" :disabled="busy" @click="clockAction(s,'out')">Xác nhận hoàn thành ca</button>
              <span v-else class="clock-locked">Đã hoàn tất</span>
              <button v-if="!clockRecordFor(s.id)?.checked_out_at || clockRecordFor(s.id).expenses?.length" type="button" :disabled="busy || !clockRecordFor(s.id)" :title="clockRecordFor(s.id) ? undefined : 'Chấm công trước khi nhập chi phí'" @click="openExpenses(s)">Chi phí phát sinh</button>
            </div>
          </div>
        </section>

        <section v-if="tab==='payroll' && manager" class="surface section payroll-section">
          <div class="section-title">
            <div><h2>Bảng công & lương ước tính</h2><p>Cast dự kiến gồm mọi ca đã phân. Cast hoàn tất chỉ tính ca đã chấm công ra.</p></div>
            <div class="button-group payroll-month-controls">
              <button type="button" aria-label="Tháng trước" @click="changeReportMonth(-1)">‹</button>
              <b>{{ reportMonth.toLocaleDateString('vi-VN',{month:'long',year:'numeric'}) }}</b>
              <button type="button" aria-label="Tháng sau" @click="changeReportMonth(1)">›</button>
              <button type="button" :disabled="payrollLoading" @click="w.refreshPayroll(reportMonthText)">Làm mới</button>
            </div>
          </div>
          <div v-if="payrollError" class="alert" role="alert">{{ payrollError }}</div>
          <div v-else-if="payrollLoading" class="empty" role="status">Đang tải bảng công & lương...</div>
          <template v-else>
            <div class="payroll-summary">
              <div><span>Cast dự kiến</span><strong>{{ money(monthlyReportTotals.plannedCast) }}</strong><small>{{ monthlyReportTotals.scheduled }} ca đã phân</small></div>
              <div><span>Cast hoàn tất</span><strong>{{ money(monthlyReportTotals.cast) }}</strong><small>{{ monthlyReportTotals.completed }} ca · {{ monthlyReportTotals.hours }} giờ thực tế</small></div>
              <div><span>Chi phí ước tính</span><strong>{{ money(monthlyReportTotals.total) }}</strong><small>Lương + phụ cấp + Cast hoàn tất</small></div>
            </div>
            <div v-if="!payroll.length" class="empty">Công ty chưa có nhân sự để tính lương.</div>
            <div v-else class="payroll-table-wrap" role="region" aria-label="Chi tiết bảng công và lương theo nhân viên" tabindex="0">
              <table class="payroll-table">
                <thead><tr><th scope="col">Nhân viên</th><th scope="col">Cast dự kiến</th><th scope="col">Cast hoàn tất</th><th scope="col">Giờ thực tế</th><th scope="col">Lương tháng</th><th scope="col">Phụ cấp/tháng</th><th scope="col">Ước tính</th></tr></thead>
                <tbody><tr v-for="person in payroll" :key="person.user_id">
                  <th scope="row"><b>{{ person.full_name }}</b><small>{{ employmentLabel(person.employment_type) }} · {{ person.email }}</small></th>
                  <td>{{ money(person.planned_cast_vnd) }}<small>{{ person.scheduled_shifts }} ca đã phân</small></td>
                  <td>{{ money(person.cast_total_vnd) }}<small>{{ person.completed_shifts }} ca hoàn tất</small></td>
                  <td>{{ person.worked_hours }} giờ</td>
                  <td>{{ person.employment_type==='employee' ? money(person.monthly_base_vnd) : 'Không áp dụng' }}</td>
                  <td>{{ money(person.monthly_allowance_vnd) }}</td>
                  <td><b>{{ money(person.estimated_total_vnd) }}</b></td>
                </tr></tbody>
              </table>
            </div>
          </template>
          <p class="payroll-disclaimer">Đây là bản xem trước, không phải phiếu lương hoặc bằng chứng đã thanh toán. Thay đổi mức lương hiện tại có thể làm thay đổi ước tính của các tháng trước.</p>
        </section>

        <section v-if="tab==='income' && !manager && !isAdmin" class="surface section income-section">
          <div class="section-title">
            <div><h2>Thu nhập dự kiến của tôi</h2><p>Chỉ hiển thị thông tin lương cá nhân trong công ty đang tham gia.</p></div>
            <div class="button-group payroll-month-controls">
              <button type="button" @click="changeReportMonth(-1)">‹</button>
              <b>{{ reportMonth.toLocaleDateString('vi-VN',{month:'long',year:'numeric'}) }}</b>
              <button type="button" @click="changeReportMonth(1)">›</button>
            </div>
          </div>
          <div v-if="compensationUnavailable" class="alert" role="alert">Chưa thể tải thỏa thuận lương từ Supabase.</div>
          <div v-else-if="!ownCompensation" class="empty">Manager chưa thiết lập thông tin lương cho bạn.</div>
          <template v-else>
            <div class="overview-grid payroll-kpis">
              <div class="overview-tile"><span>Vai trò tại công ty</span><strong class="payroll-type">{{ roleLabel(role) }}</strong></div>
              <div class="overview-tile"><span>Ca đã hoàn tất</span><strong>{{ ownCompleted.length }}/{{ ownScheduled.length }}</strong><small>Đã xác nhận / đã phân</small></div><div class="overview-tile"><span>Giờ thực tế</span><strong>{{ ownActualHours }}</strong><small>Từ chấm công đến xác nhận</small></div>
              <div class="overview-tile"><span>Thu nhập ước tính</span><strong class="payroll-money">{{ money(ownIncomeEstimate) }}</strong><small>Không phải tiền đã thanh toán</small></div>
            </div>
            <div class="income-rates"><p v-if="ownCompensation.employment_type==='employee'">Lương cơ bản thỏa thuận: <b>{{ money(ownCompensation.monthly_base_vnd) }}/tháng</b>.</p><p>Phụ cấp hàng tháng: <b>{{ money(ownCompensation.monthly_allowance_vnd) }}/tháng</b>.</p><p>Cast từ ca đã hoàn tất (gồm phát sinh): <b>{{ money(ownCastTotal) }}</b>.</p></div>
          </template>
          <p class="payroll-disclaimer">Ước tính gồm lương cơ bản, phụ cấp tháng và Cast của các ca đã xác nhận hoàn thành. Giờ thực tế không đồng nghĩa tiền theo giờ. Chưa trừ thuế, bảo hiểm, tạm ứng hoặc nghỉ phép.</p>
        </section>

        <section v-if="tab==='people'" class="surface section people-section">
          <div class="section-title">
            <div><h2>{{ current?.name || 'Thành viên công ty' }}</h2><p>{{ manager ? 'Quản lý vai trò, mức lương và trạng thái làm việc của từng người.' : 'Danh sách đồng nghiệp trong công ty đang chọn.' }}</p></div>
            <button v-if="manager" type="button" class="primary" :disabled="busy" @click="modal='invite'">+ Mời nhân viên</button>
          </div>
          <div v-if="manager && compensationUnavailable" class="alert" role="alert">Cần cài đặt bảng lương trong Supabase trước khi sửa mức lương.</div>
          <div class="people-toolbar">
            <label>Tìm nhân viên
              <input v-model.trim="peopleSearch" type="search" placeholder="Tên hoặc email" aria-label="Tìm nhân viên theo tên hoặc email">
            </label>
            <label>Bộ lọc
              <select v-model="peopleFilter">
                <option value="all">Tất cả nhân sự</option>
                <option value="active">Đang làm việc</option>
                <option value="staff">Staff chính thức</option>
                <option value="freelance">Freelance</option>
                <option value="inactive">Đã tạm ngừng</option>
              </select>
            </label>
          </div>
          <div v-if="!members.length" class="empty">Công ty chưa có thành viên.</div>
          <div v-else-if="!filteredMembers.length" class="empty">Không có nhân viên phù hợp bộ lọc.</div>
          <div v-for="group in memberGroups" :key="group.label" class="member-group">
            <h3>{{ group.label }} <span>{{ group.items.length }}</span></h3>
            <div v-for="person in group.items" :key="person.user_id" class="row member-row" :class="{'member-paused': !person.is_active}">
              <div class="member-identity">
                <b>{{ person.full_name }}</b><small>{{ person.email }}</small>
                <small v-if="manager && payFor(person.user_id)">{{ payFor(person.user_id).employment_type==='employee' ? 'Cơ bản: '+money(payFor(person.user_id).monthly_base_vnd)+' / tháng • ' : '' }}Phụ cấp/tháng: {{ money(payFor(person.user_id).monthly_allowance_vnd) }}</small>
                <small v-if="!person.is_active">Đã tạm ngừng · Lịch cũ và chấm công vẫn được giữ</small>
              </div>
              <div class="row-actions">
                <span class="badge">{{ roleLabel(memberRole(person)) }}</span>
                <button v-if="manager && person.role==='staff'" type="button" :disabled="busy || compensationUnavailable" @click="openPay(person)">{{ payFor(person.user_id) ? 'Mức lương' : 'Thiết lập lương' }}</button>
                <button v-if="manager && person.role==='staff'" type="button" :class="{'danger-quiet':person.is_active}" :disabled="busy" @click="toggleMember(person)">{{ person.is_active ? 'Tạm ngừng' : 'Kích hoạt lại' }}</button>
              </div>
            </div>
          </div>
        </section>

        <section v-if="isAdmin && tab==='companies'" class="surface section company-directory" aria-labelledby="company-directory-title">
          <div class="company-directory-heading">
            <h2 id="company-directory-title">Danh sách công ty</h2>
            <span class="badge">{{ adminCompanies.length }} công ty</span>
          </div>
          <p v-if="!adminCompanies.length" class="empty">Chưa có công ty trong danh sách.</p>
          <article v-for="company in adminCompanies" :key="company.id" class="company-directory-row">
            <div class="company-directory-name">
              <h3>{{ company.name }}</h3>
              <small v-if="company.contact_email">{{ company.contact_email }}</small>
              <small v-if="company.phone">{{ company.phone }}</small>
            </div>
            <dl class="company-directory-fields">
              <div><dt>Tỉnh / Thành phố</dt><dd>{{ companyProvince(company.address) || 'Chưa xác định' }}</dd></div>
              <div><dt>Địa chỉ</dt><dd>{{ company.address?.trim() || 'Chưa cập nhật' }}</dd></div>
              <div><dt>Người quản lý</dt><dd>{{ company.manager_name?.trim() || company.manager_email || 'Chưa có quản lý' }}
                <small v-if="company.manager_email && company.manager_email !== (company.manager_name?.trim() || company.manager_email)">{{ company.manager_email }}</small>
              </dd></div>
            </dl>
          </article>
        </section>

        <section v-if="isAdmin && tab==='approval'" class="surface section">
          <h2>Đơn đăng ký công ty</h2>
          <p>Kiểm tra thông tin trước khi duyệt.</p>
          <div v-if="notificationsError" class="alert" role="alert">{{ notificationsError }}</div>
          <div v-else-if="!pendingApplications.length" class="empty">Không có đơn đang chờ duyệt.</div>
          <div v-for="a in pendingApplications" :id="'application-'+a.id" :key="a.id" class="row" tabindex="-1">
            <div><b>{{ a.company_name }}</b><small>{{ a.address }} | {{ a.phone }} | {{ a.email }}</small></div>
            <div class="row-actions">
              <button :disabled="busy" @click="perform(()=>repo.rpc('review_company_application',{p_id:a.id,p_approve:false}),'Đã từ chối đơn.')">Từ chối</button>
              <button class="primary" :disabled="busy" @click="perform(()=>repo.rpc('review_company_application',{p_id:a.id,p_approve:true}),'Đã duyệt công ty.')">Duyệt</button>
            </div>
          </div>
        </section>

        <section v-if="isAdmin && tab==='accounts'" class="surface section account-directory">
          <div class="section-title">
            <div><h2>Quản lý tài khoản</h2><p>Thông tin hồ sơ và trạng thái truy cập theo vai trò.</p></div>
            <button type="button" :disabled="busy" @click="refreshAccountDirectory">Làm mới</button>
          </div>
          <div v-if="!accountGroups.length" class="empty">Chưa có tài khoản để hiển thị.</div>
          <section v-for="group in accountGroups" :key="group.role" class="account-group" :aria-labelledby="'accounts-'+group.role">
            <h3 :id="'accounts-'+group.role">{{ group.label }} <span class="badge">{{ group.items.length }}</span></h3>
            <ul class="account-list">
              <li v-for="a in group.items" :key="a.user_id" class="row account-row">
                <div class="account-identity">
                  <b>{{ a.full_name || a.email }}</b>
                  <small v-if="a.email">{{ a.email }}</small>
                  <small>{{ a.disabled ? (a.reason ? 'Đã vô hiệu hóa · '+a.reason : 'Đã vô hiệu hóa') : 'Được phép truy cập' }}</small>
                </div>
                <dl class="account-fields">
                  <div><dt>Tuổi</dt><dd>{{ a.age == null ? 'Chưa cập nhật' : a.age+' tuổi' }}</dd></div>
                  <div><dt>Quê quán</dt><dd>{{ a.hometown || 'Chưa cập nhật' }}</dd></div>
                  <div><dt>Khu vực hoạt động</dt><dd>{{ a.active_location || 'Chưa cập nhật' }}</dd></div>
                </dl>
                <div v-if="group.role !== 'admin'" class="account-actions">
                  <button v-if="a.disabled" type="button" :disabled="busy" @click="perform(()=>repo.rpc('admin_set_account_disabled',{p_user:a.user_id,p_disabled:false,p_reason:a.reason}),'Đã kích hoạt tài khoản.')">Kích hoạt</button>
                  <button v-else type="button" :disabled="busy" @click="openDisableAccount(a)">Vô hiệu hóa</button>
                </div>
                <div v-else-if="a.user_id === user.id" class="account-actions"><span class="badge">Tài khoản của bạn</span></div>
              </li>
            </ul>
          </section>
        </section>

        <template v-if="tab==='community'"><section v-if="!manager" class="surface section"><h2>Công ty</h2><p>Tìm công ty và gửi yêu cầu tham gia.</p><div v-if="!directory.length" class="empty">Chưa có công ty.</div><div v-for="c in directory" :key="c.id" class="row"><div><b>{{ c.name }}</b><small>{{ c.address }} | {{ c.phone }}</small></div><button v-if="!companies.some(x=>x.id===c.id)" :disabled="busy" @click="perform(()=>repo.rpc('request_company_membership',{p_company:c.id}),'Đã gửi yêu cầu tham gia.')">Xin tham gia</button><span v-else class="badge">Đã tham gia</span></div></section>
          <section v-if="manager" class="surface section"><h2>Yêu cầu tham gia</h2><div v-if="!requests.length" class="empty">Chưa có yêu cầu đang chờ.</div><div v-for="r in requests" :key="r.user_id" class="row"><b>{{ r.full_name }}</b><div class="row-actions"><button :disabled="busy" @click="perform(()=>repo.rpc('review_join_request',{p_company:companyId,p_user:r.user_id,p_approve:false}),'Đã từ chối.')">Từ chối</button><button :disabled="busy" @click="perform(()=>repo.rpc('review_join_request',{p_company:companyId,p_user:r.user_id,p_approve:true}),'Đã chấp nhận.')">Chấp nhận</button></div></div></section>
          <section v-if="manager" class="surface section"><h2>Tuyển nhân sự Freelance</h2><div v-if="!freelancers.length" class="empty">Chưa có hồ sơ công khai.</div><div v-for="f in freelancers" :key="f.user_id" class="row"><div><b>{{ f.display_name }}</b><small>{{ f.specialty }}</small></div><button :disabled="busy" @click="perform(()=>repo.rpc('invite_freelancer',{p_company:companyId,p_user:f.user_id}),'Đã tạo lời mời.')">Mời</button></div></section>
          <section v-if="!manager" class="surface section"><h2>Hồ sơ việc làm Freelance</h2><form class="form" @submit.prevent="saveProfile"><label>Tên hiển thị<input v-model="freelancer.display_name" required minlength="2" maxlength="100"></label><label>Chuyên môn<input v-model="freelancer.specialty" required minlength="2" maxlength="200" placeholder="Âm thanh, ánh sáng..."></label><label class="check"><input v-model="freelancer.visible" type="checkbox"> Cho Manager tìm thấy hồ sơ của tôi</label><div><button class="primary" :disabled="busy">Lưu hồ sơ</button></div></form></section></template>

        <section v-if="tab==='registration' && !hasManagedCompany" class="surface section form-section"><h2>{{ activeApplication ? 'Đơn đăng ký công ty' : 'Đăng ký công ty' }}</h2><p>{{ activeApplication ? 'Theo dõi trạng thái đơn đăng ký của bạn.' : 'Thông tin sẽ được gửi quản trị viên duyệt. Sau khi duyệt bạn là quản lý công ty.' }}</p><form v-if="!activeApplication" class="form" @submit.prevent="saveApplication"><label>Tên công ty<input v-model.trim="form.company_name" required minlength="3" maxlength="120" pattern=".*[\p{L}].*" title="Tên phải có chữ"></label><div class="location-field"><span class="location-title">Địa chỉ công ty</span><LocationPicker v-model="form.address" required detail-label="Số nhà, đường (tùy chọn)" /></div><div class="form-grid"><label>Số điện thoại Việt Nam<input v-model="form.phone" required inputmode="numeric" pattern="0[0-9]{9}" title="10 chữ số, bắt đầu bằng 0"></label><label>Email công ty<input v-model.trim="form.email" required type="email" maxlength="254"></label></div><div><button class="primary" :disabled="busy">Gửi duyệt</button></div></form><div v-for="a in applications" :key="a.id" class="row"><b>{{ a.company_name }}</b><span class="badge">{{ statusText(a.status) }}</span></div></section>
      </main>
    </div>
    <div v-if="modal" class="overlay" @click.self="modal=''" @keydown.esc="modal=''"><section class="dialog" :class="{'dialog-small':modal==='disable-account', 'shift-picker-dialog':modal==='shift-picker'}" role="dialog" aria-modal="true" :aria-label="modal==='disable-account'?'Vô hiệu hóa tài khoản':modal==='shift'?(editingShiftId?'Cập nhật ca làm việc':'Phân ca làm việc'):modal==='shift-picker'?'Quản lý ca trong ngày':modal==='pay'?'Thiết lập lương':'Mời nhân viên'"><div class="dialog-heading"><h2>{{ modal==='disable-account'?'Vô hiệu hóa tài khoản':modal==='shift'?(editingShiftId?'Cập nhật ca làm việc':'Phân ca làm việc'):modal==='shift-picker'?'Quản lý ca trong ngày':modal==='pay'?'Thiết lập lương':'Mời nhân viên' }}</h2><button ref="dialogClose" aria-label="Đóng" @click="modal=''">×</button></div><div v-if="error" class="alert" role="alert">{{ error }}</div><form v-if="modal==='disable-account'" class="form" @submit.prevent="confirmDisableAccount"><p>Nhập lý do vô hiệu hóa tài khoản {{ disableTarget?.full_name || disableTarget?.email }}.</p><label>Lý do<input v-model="disableReason" required minlength="5" maxlength="500" placeholder="Ít nhất 5 ký tự" autofocus></label><div class="form-actions"><button type="button" @click="modal=''">Hủy</button><button class="primary" :disabled="busy">Xác nhận</button></div></form><form v-else-if="modal==='invite'" class="form" @submit.prevent="perform(()=>repo.insert('company_invitations',{company_id:companyId,email:inviteEmail.trim().toLowerCase()}),'Đã tạo lời mời.',true)"><label>Email nhân viên<input v-model="inviteEmail" required type="email"></label><p>Nhân viên đăng nhập bằng email được mời để chấp nhận.</p><div class="form-actions"><button type="button" @click="modal=''">Hủy</button><button class="primary" :disabled="busy">Gửi lời mời</button></div></form>
      <form v-else-if="modal==='pay'" class="form" @submit.prevent="savePay">
        <p>Thiết lập cho {{ payForm.name }} tại {{ current?.name }}.</p>
        <label>Vai trò tại công ty
          <select v-model="payForm.employment_type">
            <option value="freelancer">Freelance</option>
            <option value="employee">Staff chính thức</option>
          </select>
        </label>
        <label v-if="payForm.employment_type==='employee'">Lương cơ bản mỗi tháng (₫)
          <input v-model="payForm.monthly_base_vnd" type="number" min="0" max="99999999999999" step="1" required>
        </label>
        <label>Phụ cấp hàng tháng (₫)
          <input v-model.number="payForm.monthly_allowance_vnd" type="number" min="0" max="99999999999999" step="1" required>
        </label>
        <p>Staff chính thức có lương cơ bản hàng tháng. Cả Staff và Freelance đều được tính phụ cấp tháng và Cast của các ca đã hoàn thành.</p>
        <div class="form-actions"><button type="button" @click="modal=''">Hủy</button><button class="primary" :disabled="busy">Lưu vai trò và lương</button></div>
      </form>
      <section v-else-if="modal==='shift-picker'" class="shift-picker">
        <p>{{ selectedDateLabel }} · {{ selectedShifts.length }} ca</p>
        <div v-for="item in selectedShifts" :key="item.id" class="row">
          <div><b>{{ item.title }}</b><small>{{ timeOf(item.starts_at) }} - {{ timeOf(item.ends_at) }} · {{ nameOf(item.user_id) }}</small><small v-if="item.location">{{ item.location }}</small></div>
          <span v-if="shiftEditLockLabel(item)" class="clock-locked">{{ shiftEditLockLabel(item) }}</span>
          <button v-else-if="!selectedDayHasAttendance" type="button" :disabled="busy" @click="editShift(item)">Sửa ca</button>
        </div>
        <p v-if="selectedDayAddBlock" class="shift-picker-lock">{{ selectedDayAddBlock }}</p>
        <div class="form-actions">
          <button type="button" class="danger-quiet" :disabled="busy || selectedDayHasAttendance" @click="removeShift()">Xóa tất cả ca</button>
          <button type="button" class="primary" :disabled="busy || !!selectedDayAddBlock" @click="createShiftOnSelectedDay">+ Thêm ca mới</button>
        </div>
      </section>
      <form v-else class="form" @submit.prevent="saveShift"><label>Công việc / sự kiện<input v-model="shift.title" required maxlength="200"></label><div class="location-field"><span class="location-title">Địa điểm ca làm</span><LocationPicker v-model="shift.location" required detail-label="Tên địa điểm / số nhà, đường (tùy chọn)" /></div><div class="form-grid"><label>Ngày làm việc<input :value="new Date(shift.date + 'T12:00:00').toLocaleDateString('vi-VN',{weekday:'long',day:'numeric',month:'long'})" readonly aria-label="Ngày làm việc"></label><label>Buổi<select :value="shiftPeriod" :disabled="!!(editingShiftId && crewHasClocked)" @change="setPeriod"><option value="morning">Sáng</option><option value="afternoon">Chiều</option><option value="evening">Tối</option><option value="all">Cả ngày</option><option value="custom">Tự chọn</option></select></label><label>Bắt đầu<input v-model="shift.start" type="time" required :disabled="!!(editingShiftId && crewHasClocked)"></label><label>Kết thúc<input v-model="shift.end" type="time" required :disabled="!!(editingShiftId && crewHasClocked)"><small v-if="shift.end_date !== shift.date">Ngày {{ shift.end_date }}</small></label></div><label>Cast / thù lao ca (VNĐ)<input v-model.number="shift.cast_vnd" type="number" min="0" max="100000000" step="1000" inputmode="numeric" :disabled="!!(editingShiftId && crewHasClocked)" required></label><div class="cast-presets" role="group" aria-label="Chọn nhanh mức cast"><button v-for="amount in [300,400,500,600,700,1000]" :key="amount" type="button" :disabled="!!(editingShiftId && crewHasClocked)" :class="{selected: Number(shift.cast_vnd) === amount*1000}" :aria-pressed="Number(shift.cast_vnd) === amount*1000" @click="shift.cast_vnd=amount*1000">{{ amount === 1000 ? '1.000' : amount }}K</button></div><fieldset><legend>Phân công nhân viên</legend><label v-for="m in assignableMembers" :key="m.user_id" class="check"><input :checked="shift.user_ids.includes(m.user_id)" :disabled="!!(editingShiftId && crewMemberClocked(m.user_id))" :value="m.user_id" type="checkbox" @change="chooseShiftStaff(m.user_id, $event.target.checked)">{{ m.full_name }} · {{ roleLabel(memberRole(m)) }} ({{ m.email }})</label><div v-if="!assignableMembers.length" class="no-staff-hint"><p>Công ty chưa có Staff hoặc Freelance đang hoạt động. Bạn cần mời nhân viên và đợi họ tham gia trước khi phân ca.</p><button type="button" @click="modal='invite'">+ Mời nhân viên</button></div></fieldset>
        <div v-if="!error && editingShiftHasEnded" class="notice" role="status">{{ endedWorkMessage }}</div>
        <div v-else-if="!error && morningAssignments.length" class="notice" role="status">
          <div v-for="item in morningAssignments" :key="item.id">{{ assignedShiftText(item) }}.</div>
        </div>
        <div class="form-actions">
          <button v-if="editingShift && !crewHasClocked" type="button" class="danger-quiet" :disabled="busy" @click="removeShift(editingShift)">Hủy ca</button>
          <span v-if="editingShift && crewHasClocked" class="clock-locked">Ca đã chấm công, không thể hủy, đổi giờ, nhân viên hoặc cast</span>
          <button type="button" @click="modal=''">Đóng</button>
          <button class="primary" :disabled="busy || !assignableMembers.length || selectedDayHasAttendance || editingShiftHasEnded"> {{ editingShiftId ? 'Lưu thay đổi' : 'Lưu phân ca' }}</button>
        </div></form>
    </section></div>
  </div>
</template>
