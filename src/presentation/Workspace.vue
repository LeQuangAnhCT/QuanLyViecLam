<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch } from 'vue'
import { useWorkspace } from '../application/useWorkspace'
import { localDate, hours, roleLabel, shiftRows, shiftUpdate } from '../domain/calendar'

const props = defineProps({ user: { type: Object, required: true } })
const w = useWorkspace(props.user)
const { isAdmin, companies, directory, invitations, companyId, members, shifts, compensation, compensationUnavailable, applications, freelancers, profile, accounts, adminCompanies, requests, restriction, notifications, notificationsUnavailable, notificationsError, clockRecords, clockUnavailable, clockError, payroll, payrollUnavailable, payrollError, busy, loading, error, message, current, manager, canSchedule, repo } = w
const tab = ref(isAdmin ? 'approval' : 'calendar'), month = ref(new Date(new Date().getFullYear(), new Date().getMonth(), 1)), selectedDate = ref(localDate(new Date())), modal = ref('')
const form = reactive({ company_name: '', address: '', phone: '', email: '' }), freelancer = reactive({ display_name: props.user.user_metadata?.full_name || '', specialty: '', visible: false })
const inviteEmail = ref(''), reasons = reactive({}), editingShiftId = ref('')
const shift = reactive({ title: '', location: '', date: localDate(new Date()), end_date: localDate(new Date()), start: '08:00', end: '12:00', user_ids: [] })
const payForm = reactive({ user_id:'', name:'', employment_type:'employee', monthly_base_vnd:'', show_rate_vnd:'' })
const reportMonth = ref(new Date(new Date().getFullYear(),new Date().getMonth(),1))
const reportMonthText = computed(() => localDate(reportMonth.value))
const monthlyReportTotals = computed(() => ({
  scheduled: payroll.value.reduce((a,row)=>a+Number(row.scheduled_shifts||0),0),
  completed: payroll.value.reduce((a,row)=>a+Number(row.completed_shifts||0),0),
  total: payroll.value.reduce((a,row)=>a+Number(row.estimated_total_vnd||0),0)
}))
function changeReportMonth(delta) { reportMonth.value = new Date(reportMonth.value.getFullYear(),reportMonth.value.getMonth()+delta,1) }
const typeName = type => type==='employee' ? 'Nhân viên chính thức' : type==='freelancer' ? 'Nhân viên thời vụ' : 'Chưa thiết lập'
const typeShort = type => type==='employee' ? 'Chính thức' : type==='freelancer' ? 'Thời vụ' : 'Chưa thiết lập'
const ownCompensation = computed(() => compensation.value.find(p=>p.user_id===props.user.id))
const ownScheduled = computed(() => shifts.value.filter(s => localDate(new Date(s.starts_at)).slice(0,7)===reportMonthText.value.slice(0,7)))
const ownCompleted = computed(() => ownScheduled.value.filter(s => clockRecords.value.some(a=>a.shift_id===s.id && a.checked_out_at)))
const ownIncomeEstimate = computed(() => Number(ownCompensation.value?.monthly_base_vnd||0) + Number(ownCompensation.value?.show_rate_vnd||0)*ownCompleted.value.length)
const role = computed(() => isAdmin ? 'admin' : manager.value ? 'manager' : 'staff')
const ownedCompanies = computed(() => companies.value.filter(c => c.role === 'manager'))
const selectableCompanies = computed(() => ownedCompanies.value.length ? ownedCompanies.value : companies.value)
const staffMembers = computed(() => members.value.filter(m => m.role === 'staff'))
const unreadCount = computed(() => notifications.value.filter(n => !n.read_at).length)
const clockRecordFor = shiftId => clockRecords.value.find(r => r.shift_id === shiftId)
const editingShift = computed(() => shifts.value.find(s => s.id === editingShiftId.value))
const canClockIn = item => {
  if (clockUnavailable.value || clockRecordFor(item.id)) return false
  const now=Date.now()
  return now >= new Date(item.starts_at).getTime()-3600000 && now<=new Date(item.ends_at).getTime()+12*3600000
}
const clockStatus = item => {
  const row=clockRecordFor(item.id)
  return row ? (row.checked_out_at ? 'Đã chấm công ra' : 'Đã chấm công vào') : 'Chưa chấm công'
}
const clockDisplay = stamp => stamp ? new Date(stamp).toLocaleString('vi-VN',{hour:'2-digit',minute:'2-digit',day:'2-digit',month:'2-digit'}) : ''
const notificationEventLabel = event => ({created:'Ca mới', updated:'Thay đổi lịch', cancelled:'Ca đã hủy'})[event] || 'Thông báo'
const hasManagedCompany = computed(() => companies.value.some(c => c.role === 'manager'))
const activeApplication = computed(() => applications.value.some(a => a.status === 'pending' || a.status === 'approved'))
const tabs = computed(() => {
  if (isAdmin) return [['approval','Đơn chờ duyệt'],['companies','Công ty'],['accounts','Tài khoản']]
  const result = [['calendar',manager.value ? 'Phân ca' : 'Lịch của tôi']]
  if (!manager.value) result.push(['attendance','Chấm công'], ['income','Thu nhập'], ['notifications','Thông báo'])
  else result.push(['payroll','Bảng công & lương'])
  result.push(['people',manager.value ? 'Quản lý nhân sự' : 'Đồng nghiệp'],['community', manager.value ? 'Tuyển nhân sự' : 'Cộng đồng'])
  if (!hasManagedCompany.value) result.push(['registration', activeApplication.value ? 'Đơn đăng ký' : 'Đăng ký công ty'])
  return result
})
const days = computed(() => { const year = month.value.getFullYear(), m = month.value.getMonth(), offset = (new Date(year,m,1).getDay()+6)%7, count = new Date(year,m+1,0).getDate(); return [...Array(offset).fill(null), ...Array.from({length:count},(_,i)=>i+1)] })
const nameOf = id => members.value.find(m => m.user_id === id)?.full_name || 'Nhân viên'
const payFor = id => compensation.value.find(p => p.user_id === id)
const memberGroups = computed(() => {
  if (!manager.value) return [{ label: 'Thành viên công ty', items: members.value }]
  return [
    { label:'Quản lý', items:members.value.filter(m=>m.role==='manager') },
    { label:'Nhân viên chính thức', items:members.value.filter(m=>m.role!=='manager' && payFor(m.user_id)?.employment_type==='employee') },
    { label:'Nhân viên thời vụ', items:members.value.filter(m=>m.role!=='manager' && payFor(m.user_id)?.employment_type==='freelancer') },
    { label:'Chưa thiết lập loại nhân sự', items:members.value.filter(m=>m.role!=='manager' && !payFor(m.user_id)) }
  ].filter(group=>group.items.length)
})
const money = value => `${new Intl.NumberFormat('vi-VN').format(Number(value))} ₫`
function openPay(member) {
  const pay = payFor(member.user_id)
  Object.assign(payForm,{user_id:member.user_id,name:member.full_name,employment_type:pay?.employment_type || 'employee',monthly_base_vnd:pay?.monthly_base_vnd ?? '',show_rate_vnd:pay?.show_rate_vnd ?? ''})
  modal.value='pay'
}
function savePay() {
  const base = payForm.employment_type === 'freelancer' ? null : Number(payForm.monthly_base_vnd)
  const rate = Number(payForm.show_rate_vnd)
  if (payForm.show_rate_vnd === '' || (base !== null && payForm.monthly_base_vnd === '') || !Number.isSafeInteger(rate) || rate < 0 || (base !== null && (!Number.isSafeInteger(base) || base < 0))) { error.value='Hãy nhập số tiền hợp lệ, không âm.'; return }
  perform(()=>repo.upsert('member_compensation',{company_id:companyId.value,user_id:payForm.user_id,employment_type:payForm.employment_type,monthly_base_vnd:base,show_rate_vnd:rate,updated_at:new Date().toISOString()}),'Đã lưu thông tin lương.',true)
}
function shiftsForDate(dateText) {
  const start = new Date(dateText + 'T00:00:00')
  const end = new Date(start)
  end.setDate(end.getDate() + 1)
  return shifts.value.filter(s => new Date(s.starts_at) < end && new Date(s.ends_at) > start)
}
const shiftsOn = day => shiftsForDate(localDate(new Date(month.value.getFullYear(),month.value.getMonth(),day)))
const monthShifts = computed(() => shifts.value.filter(s => { const d = new Date(s.starts_at); return d.getFullYear() === month.value.getFullYear() && d.getMonth() === month.value.getMonth() }))
const plannedHours = computed(() => monthShifts.value.reduce((sum, s) => sum + Number(hours(s)), 0).toFixed(1))
const upcomingCount = computed(() => shifts.value.filter(s => new Date(s.starts_at) > new Date()).length)
const selectedShifts = computed(() => shiftsForDate(selectedDate.value).sort((a,b) => new Date(a.starts_at) - new Date(b.starts_at)))
const selectedDateLabel = computed(() => new Date(selectedDate.value + 'T12:00:00').toLocaleDateString('vi-VN', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }))
const timeOf = stamp => new Date(stamp).toLocaleTimeString('vi-VN', { hour: '2-digit', minute: '2-digit' })
const dayLabel = day => `Ngày ${day}: ${shiftsOn(day).length} ca làm việc. Chọn để xem chi tiết.`
function chooseDay(day) { selectedDate.value = localDate(new Date(month.value.getFullYear(), month.value.getMonth(), day)) }
function clickCalendarCell(day) {
  chooseDay(day)
  if (!canSchedule.value) return
  const items = shiftsForDate(selectedDate.value)
  if (items.length === 0) openShift(day)
  else if (items.length === 1) editShift(items[0])
  else { error.value = ''; modal.value = 'shift-picker' }
}
function editShift(item) {
  if (!canSchedule.value) return
  const start = new Date(item.starts_at), end = new Date(item.ends_at)
  selectedDate.value = localDate(start)
  month.value = new Date(start.getFullYear(),start.getMonth(),1)
  editingShiftId.value = item.id
  Object.assign(shift, {
    title: item.title, location: item.location || '',
    date: localDate(start), end_date: localDate(end),
    start: timeOf(start), end: timeOf(end), user_ids: [item.user_id]
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
function openShift(day) { if (!canSchedule.value) return; error.value=''; editingShiftId.value=''; const date = localDate(new Date(month.value.getFullYear(),month.value.getMonth(),day)); Object.assign(shift,{title:'',location:'',date,end_date:date,start:'08:00',end:'12:00',user_ids:[]}); modal.value='shift' }
function setPeriod(event) { const t = {morning:['08:00','12:00'],afternoon:['13:00','17:00'],evening:['18:00','23:00'],all:['08:00','23:00']}[event.target.value]; if(t) [shift.start,shift.end]=t }
async function perform(fn, success, close = false) { if (await w.perform(fn,success) && close) modal.value='' }
async function saveShift() {
  if (!canSchedule.value) { error.value = 'Chỉ Manager mới được phân ca.'; return }
  let rows
  try {
    const eligible = new Set(staffMembers.value.map(m => m.user_id))
    if (!shift.user_ids.every(id => eligible.has(id))) throw new Error('Chỉ được phân ca cho nhân viên thuộc công ty.')
    rows = editingShiftId.value ? shiftUpdate(shift, companyId.value, editingShiftId.value, shifts.value) : shiftRows(shift, companyId.value, shifts.value)
  } catch (e) { error.value = e?.message || 'Ca làm việc chưa hợp lệ.'; return }
  busy.value = true
  error.value = ''
  message.value = ''
  try {
    if (editingShiftId.value) await repo.updateShift(editingShiftId.value, companyId.value, rows)
    else await repo.insert('company_shifts', rows)
  } catch (e) {
    const errors = {
      '23P01': 'Nhân viên bị trùng ca, có thể với ca ở công ty khác. Hãy chọn giờ khác.',
      '23503': 'Nhân viên không thuộc công ty này. Hãy tải lại danh sách thành viên.',
      '23514': 'Thời lượng ca không hợp lệ (tối đa 24 giờ).',
      '42501': 'Tài khoản chưa được cấp quyền phân ca của công ty này.',
      'P4511': 'Ca đã chấm công, không được đổi nhân viên hoặc giờ làm.',
      'PGRST205': 'Bảng lịch chưa tồn tại trong Supabase. Hãy kiểm tra triển khai cơ sở dữ liệu.'
    }
    error.value = errors[e?.code] || e?.message || 'Không thể lưu ca. Vui lòng thử lại.'
    busy.value = false
    return
  }
  modal.value = ''
  message.value = editingShiftId.value ? 'Đã cập nhật ca làm việc.' : `Đã lưu ${rows.length} ca làm việc thành công.`
  editingShiftId.value = ''
  try {
    await w.refreshCompany()
  } catch (e) {
    error.value = 'Ca đã lưu thành công, nhưng chưa tải lại được lịch. Vui lòng tải lại trang.'
  } finally { busy.value = false }
}
async function removeShift(item) {
  if (!canSchedule.value || busy.value) return
  if (clockRecordFor(item.id)) { error.value='Ca đã được chấm công nên không thể hủy.'; return }
  if (!window.confirm(`Hủy ca "${item.title}" của ${nameOf(item.user_id)}? Nhân viên sẽ nhận thông báo nếu Supabase đã kích hoạt thông báo.`)) return
  busy.value=true; error.value=''; message.value=''
  try {
    await repo.deleteShift(item.id,companyId.value)
    modal.value=''
    message.value='Đã hủy ca làm việc.'
    try { await w.refreshCompany() }
    catch { error.value='Đã hủy ca nhưng chưa tải lại được lịch. Hãy làm mới trang.' }
  } catch(e) {
    error.value=e?.code==='P4510' || e?.code==='23503'
      ? 'Ca đã được chấm công nên không thể hủy.'
      : (e?.message || 'Không thể hủy ca này.')
  } finally { busy.value=false }
}
async function clockAction(item, action) {
  if (isAdmin || manager.value || busy.value || clockUnavailable.value) return
  busy.value=true; error.value=''; message.value=''
  try {
    if (action==='in') await repo.clockIn(item.id)
    else await repo.clockOut(item.id)
    message.value=action==='in'?'Chấm công vào thành công.':'Chấm công ra thành công.'
    try { await w.refreshCompany() }
    catch { error.value='Đã ghi nhận chấm công nhưng chưa tải lại được dữ liệu. Hãy làm mới trang.' }
  } catch(e) {
    const messages={
      P4520:'Chỉ Staff được phân ca mới có thể chấm công.',
      P4521:'Chỉ chấm công từ 1 giờ trước ca đến 12 giờ sau khi ca kết thúc.',
      P4522:'Ca chưa chấm công vào, hoặc thao tác này đã được thực hiện.',
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
    await repo.markNotificationRead(notification.id, props.user.id)
    notification.read_at = new Date().toISOString()
  } catch(e) { error.value = e?.message || 'Không thể đánh dấu thông báo đã đọc.' }
}
function onWindowFocus() {
  if (isAdmin || document.visibilityState==='hidden') return
  w.refreshNotifications()
  if (tab.value==='calendar' || tab.value==='attendance') w.refreshCompany().catch(()=>{})
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
  w.perform(() => Promise.resolve(), '')
  window.addEventListener('focus',onWindowFocus)
  // Keep the unread badge fresh without requiring users to open the inbox.
  notificationPoll = window.setInterval(() => {
    if (!isAdmin && document.visibilityState==='visible') w.refreshNotifications()
  },60000)
})
onUnmounted(() => {
  window.removeEventListener('focus',onWindowFocus)
  if (notificationPoll) window.clearInterval(notificationPoll)
})
</script>

<template>
  <main v-if="loading" class="auth-screen" aria-live="polite">Đang tải dữ liệu...</main>
  <main v-else-if="restriction?.disabled" class="auth-screen"><section class="auth-box"><h1>Tài khoản đã bị vô hiệu hóa</h1><p>Lý do: {{ restriction.reason }}</p><button @click="repo.auth.signOut()">Đăng xuất</button></section></main>
  <div v-else class="app-shell">
    <aside class="sidebar">
      <div class="brand"><span class="brand-mark">S</span><div><strong>SHIFTLY</strong><small>Quản lý nhân sự sự kiện</small></div></div>
      <div class="side-label">{{ isAdmin ? 'QUẢN TRỊ HỆ THỐNG' : manager ? 'QUẢN LÝ CÔNG TY' : 'KHÔNG GIAN CỦA TÔI' }}</div>
      <nav aria-label="Điều hướng chính"><button v-for="item in tabs" :key="item[0]" :class="{selected:tab===item[0]}" @click="tab=item[0]">{{ item[1] }}<span v-if="item[0]==='notifications' && unreadCount" class="nav-unread">{{ unreadCount }}</span></button></nav>
      <div class="side-bottom"><div class="initial">{{ (user.user_metadata?.full_name || user.email || 'S').slice(0,1).toUpperCase() }}</div><div><b>{{ user.user_metadata?.full_name || roleLabel(role) }}</b><small>{{ roleLabel(role) }} · {{ user.email }}</small></div></div>
    </aside>
    <div class="main-area">
      <header class="topbar"><div><span class="top-brand">SHIFTLY</span><span class="top-title">{{ tabs.find(t => t[0]===tab)?.[1] }}</span></div><button class="text-button" @click="repo.auth.signOut()">Đăng xuất</button></header>
      <nav class="mobile-nav" aria-label="Điều hướng trên điện thoại"><button v-for="item in tabs" :key="item[0]" :class="{selected:tab===item[0]}" @click="tab=item[0]">{{ item[1] }}<span v-if="item[0]==='notifications' && unreadCount" class="nav-unread">{{ unreadCount }}</span></button></nav>
      <main class="content">
        <div class="page-heading"><div><p class="eyebrow">{{ roleLabel(role) }}</p><h1>{{ tabs.find(t => t[0]===tab)?.[1] }}</h1><p v-if="tab!=='people'">{{ isAdmin ? 'Phê duyệt công ty và kiểm soát tài khoản trên toàn hệ thống.' : manager ? 'Điều phối ca làm việc và nhân sự của công ty đang chọn.' : 'Chỉ hiển thị các ca đã được giao cho bạn.' }}</p></div><div v-if="!isAdmin && current" class="company-context">
          <label v-if="selectableCompanies.length>1" class="company-select">Công ty của bạn<select v-model="companyId" @change="changeCompany"><option v-for="c in selectableCompanies" :key="c.id" :value="c.id">{{ c.name }}</option></select></label>
          <div v-else class="company-identity"><span>{{ manager ? 'CÔNG TY ĐANG QUẢN LÝ' : 'CÔNG TY CỦA BẠN' }}</span><strong>{{ current.name }}</strong></div>
        </div></div>
        <div v-if="error" class="alert" role="alert">{{ error }}</div><div v-if="message" class="notice" role="status">{{ message }}</div>
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
            <section class="overview-grid" aria-label="Tổng quan lịch làm việc">
              <div class="overview-tile"><span>{{ canSchedule ? 'Nhân sự' : 'Ca của tôi' }}</span><strong>{{ canSchedule ? members.length : monthShifts.length }}</strong><small>{{ canSchedule ? 'Thành viên của công ty' : 'Trong tháng đang xem' }}</small></div>
              <div class="overview-tile"><span>{{ canSchedule ? 'Ca trong tháng' : 'Giờ dự kiến' }}</span><strong>{{ canSchedule ? monthShifts.length : plannedHours }}</strong><small>{{ canSchedule ? 'Tất cả ca được phân' : 'Giờ được phân trong tháng' }}</small></div>
              <div class="overview-tile"><span>Ca sắp tới</span><strong>{{ upcomingCount }}</strong><small>{{ canSchedule ? 'Ca của đội ngũ' : 'Ca đã giao cho bạn' }}</small></div>
            </section>
            <div class="calendar-controls">
              <div><h2>{{ month.toLocaleDateString('vi-VN',{month:'long',year:'numeric'}) }}</h2><p>{{ canSchedule ? 'Nhấn ô trống để phân ca; nhấn ô có ca để chỉnh sửa.' : 'Chọn ngày để xem giờ và địa điểm làm việc của bạn.' }}</p></div>
              <div class="calendar-tools"><div class="button-group"><button type="button" aria-label="Tháng trước" @click="changeMonth(-1)">‹</button><button type="button" @click="goToToday">Hôm nay</button><button type="button" aria-label="Tháng sau" @click="changeMonth(1)">›</button></div><button v-if="canSchedule" type="button" class="primary add-shift-button" :disabled="busy" @click="createShiftOnSelectedDay">+ Phân ca mới</button></div>
            </div>
            <div class="calendar-wrap">
              <div class="calendar">
                <div v-for="name in ['T2','T3','T4','T5','T6','T7','CN']" :key="name" class="weekday">{{ name }}</div>
                <div v-for="(day,index) in days" :key="index" class="day" :class="{blank:!day, active:day && selectedDate===localDate(new Date(month.getFullYear(),month.getMonth(),day))}">
                  <button v-if="day" type="button" class="day-button" :aria-label="dayLabel(day)" :aria-pressed="selectedDate===localDate(new Date(month.getFullYear(),month.getMonth(),day))" @click="clickCalendarCell(day)">
                    <span class="day-number">{{ day }}</span>
                    <span v-if="shiftsOn(day).length" class="day-shift-count">{{ shiftsOn(day).length }} ca</span>
                    <span v-for="s in shiftsOn(day)" :key="s.id" class="shift-chip">{{ timeOf(s.starts_at) }} {{ s.title }}<small>{{ canSchedule ? nameOf(s.user_id) : s.location }}</small></span>
                  </button>
                </div>
              </div>
            </div>
            <section class="surface section day-detail" aria-label="Chi tiết ca theo ngày">
              <div class="section-title">
                <div><h2>Ca làm · {{ selectedDateLabel }}</h2><p>{{ canSchedule ? 'Lịch phân công của công ty.' : 'Các ca của chính bạn, không phải toàn bộ lịch công ty.' }}</p></div>
                <button v-if="canSchedule" type="button" class="primary" :disabled="busy" @click="createShiftOnSelectedDay">+ Thêm ca</button>
              </div>
              <div v-if="!canSchedule && clockError" class="notice" role="status">{{ clockError }}</div>
              <div v-if="!selectedShifts.length" class="empty day-empty">Không có ca nào trong ngày này.</div>
              <div v-for="item in selectedShifts" :key="item.id" class="row shift-detail-row">
                <div class="shift-timing"><strong>{{ timeOf(item.starts_at) }} – {{ timeOf(item.ends_at) }}</strong><small v-if="localDate(new Date(item.starts_at))!==selectedDate">Bắt đầu ngày {{ localDate(new Date(item.starts_at)) }}</small><small v-if="localDate(new Date(item.ends_at))!==selectedDate">Kết thúc ngày {{ localDate(new Date(item.ends_at)) }}</small></div>
                <div class="shift-description"><b>{{ item.title }}</b><small>{{ item.location || 'Chưa cập nhật địa điểm' }}<template v-if="canSchedule"> · {{ nameOf(item.user_id) }}</template></small></div>
                <div v-if="canSchedule" class="shift-actions">
                  <span v-if="clockRecordFor(item.id)" class="clock-locked" :title="'Ca đã chấm công: '+clockDisplay(clockRecordFor(item.id).checked_in_at)">Đã chấm công · Không thể hủy</span>
                  <button type="button" :disabled="busy" @click="editShift(item)">Sửa ca</button>
                  <button type="button" class="danger-quiet" :disabled="busy || !!clockRecordFor(item.id)" :title="clockRecordFor(item.id)?'Ca đã chấm công không thể hủy':''" :aria-label="'Hủy ca '+item.title+' của '+nameOf(item.user_id)" @click="removeShift(item)">Hủy ca</button>
                </div>
                <div v-else class="shift-actions clock-actions">
                  <span class="clock-status">{{ clockStatus(item) }}</span>
                  <button v-if="!clockRecordFor(item.id)" type="button" class="primary" :disabled="busy || !canClockIn(item)" @click="clockAction(item,'in')">Chấm công vào</button>
                  <button v-else-if="!clockRecordFor(item.id).checked_out_at" type="button" class="primary" :disabled="busy" @click="clockAction(item,'out')">Chấm công ra</button>
                </div>
              </div>
            </section>
          </template>
        </template>

        <section v-if="tab==='notifications' && !manager && !isAdmin" class="surface section notifications-section">
          <div class="section-title"><div><h2>Thông báo lịch làm việc</h2><p>Ca mới, thay đổi lịch hoặc hủy ca đều được lưu để bạn xem lại.</p></div><button type="button" :disabled="busy" @click="w.refreshNotifications()">Làm mới</button></div>
          <div v-if="notificationsError" class="alert" role="alert">{{ notificationsError }}</div>
          <div v-if="!notificationsUnavailable && !notifications.length" class="empty">Bạn chưa có thông báo nào.</div>
          <div v-for="item in notifications" :key="item.id" class="row notification-row" :class="{unread:!item.read_at}">
            <div class="notification-main"><div class="notification-head"><b>{{ item.title }}</b><span class="badge">{{ notificationEventLabel(item.event) }}</span></div>
              <small>{{ directory.find(c=>c.id===item.company_id)?.name || 'Công ty' }} · {{ new Date(item.created_at).toLocaleString('vi-VN') }}</small>
              <p>{{ item.body }}</p></div>
            <button v-if="!item.read_at" type="button" @click="markRead(item)">Đánh dấu đã đọc</button><span v-else class="read-label">Đã đọc</span>
          </div>
        </section>
        <section v-if="tab==='attendance' && !manager && !isAdmin" class="surface section">
          <div class="section-title"><div><h2>Chấm công thực tế</h2><p>Chấm công vào/ra ca được giao. Giờ dự kiến và giờ chấm công được hiển thị riêng.</p></div></div>
          <div v-if="clockError" class="alert" role="alert">{{ clockError }}</div>
          <div v-if="!shifts.length" class="empty">Bạn chưa được phân ca làm việc.</div>
          <div v-for="s in shifts" :key="s.id" class="row attendance-row">
            <div class="attendance-summary"><b>{{ s.title }}</b><small>{{ new Date(s.starts_at).toLocaleString('vi-VN') }} · {{ s.location }}</small>
              <small>Dự kiến: {{ hours(s) }} giờ · {{ clockStatus(s) }}</small>
              <small v-if="clockRecordFor(s.id)">Vào: {{ clockDisplay(clockRecordFor(s.id).checked_in_at) }}<template v-if="clockRecordFor(s.id).checked_out_at"> · Ra: {{ clockDisplay(clockRecordFor(s.id).checked_out_at) }}</template></small>
            </div>
            <div class="shift-actions clock-actions">
              <button v-if="!clockRecordFor(s.id)" class="primary" type="button" :disabled="busy || !canClockIn(s)" @click="clockAction(s,'in')">Chấm công vào</button>
              <button v-else-if="!clockRecordFor(s.id).checked_out_at" class="primary" type="button" :disabled="busy" @click="clockAction(s,'out')">Chấm công ra</button>
              <span v-else class="clock-locked">Đã hoàn tất</span>
            </div>
          </div>
        </section>

        <section v-if="tab==='payroll' && manager" class="surface section payroll-section">
          <div class="section-title">
            <div><h2>Bảng công & lương ước tính</h2><p>Phân biệt nhân viên chính thức và thời vụ. Chỉ cộng tiền theo show đã chấm công ra; lương tháng là số thỏa thuận, chưa tính nghỉ phép hay khấu trừ.</p></div>
            <div class="button-group payroll-month-controls">
              <button type="button" aria-label="Tháng trước" @click="changeReportMonth(-1)">‹</button>
              <b>{{ reportMonth.toLocaleDateString('vi-VN',{month:'long',year:'numeric'}) }}</b>
              <button type="button" aria-label="Tháng sau" @click="changeReportMonth(1)">›</button>
              <button type="button" @click="w.refreshPayroll(reportMonthText)">Làm mới</button>
            </div>
          </div>
          <div v-if="payrollError" class="alert" role="alert">{{ payrollError }}</div>
          <template v-if="!payrollUnavailable">
            <div class="overview-grid payroll-kpis">
              <div class="overview-tile"><span>Ca đã phân</span><strong>{{ monthlyReportTotals.scheduled }}</strong><small>Trong tháng</small></div>
              <div class="overview-tile"><span>Ca hoàn thành</span><strong>{{ monthlyReportTotals.completed }}</strong><small>Đã chấm công ra</small></div>
              <div class="overview-tile"><span>Chi phí ước tính</span><strong class="payroll-money">{{ money(monthlyReportTotals.total) }}</strong><small>Theo mức hiện tại</small></div>
            </div>
            <div v-if="!payroll.length" class="empty">Chưa có nhân viên Staff trong công ty.</div>
            <div v-else class="payroll-table-wrap">
              <table class="payroll-table">
                <thead><tr><th>Nhân viên</th><th>Loại</th><th>Ca phân</th><th>Ca hoàn tất</th><th>Giờ thực tế</th><th>Lương tháng</th><th>Tiền/show</th><th>Ước tính</th></tr></thead>
                <tbody><tr v-for="person in payroll" :key="person.user_id">
                  <td><b>{{ person.full_name }}</b><small>{{ person.email }}</small></td>
                  <td>{{ typeShort(person.employment_type) }}</td>
                  <td>{{ person.scheduled_shifts }}</td>
                  <td>{{ person.completed_shifts }}</td>
                  <td>{{ person.worked_hours }} giờ</td>
                  <td>{{ person.employment_type==='employee' ? money(person.monthly_base_vnd) : '—' }}</td>
                  <td>{{ money(person.show_rate_vnd) }}</td>
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
              <div class="overview-tile"><span>Loại nhân sự</span><strong class="payroll-type">{{ typeShort(ownCompensation.employment_type) }}</strong><small>{{ typeName(ownCompensation.employment_type) }}</small></div>
              <div class="overview-tile"><span>Ca đã hoàn tất</span><strong>{{ ownCompleted.length }}/{{ ownScheduled.length }}</strong><small>Đã chấm công ra / đã phân</small></div>
              <div class="overview-tile"><span>Thu nhập ước tính</span><strong class="payroll-money">{{ money(ownIncomeEstimate) }}</strong><small>Không phải tiền đã thanh toán</small></div>
            </div>
            <div class="income-rates"><p v-if="ownCompensation.employment_type==='employee'">Lương cơ bản thỏa thuận: <b>{{ money(ownCompensation.monthly_base_vnd) }}/tháng</b>.</p><p>Mức theo show hoàn tất: <b>{{ money(ownCompensation.show_rate_vnd) }}/show</b>.</p></div>
          </template>
          <p class="payroll-disclaimer">Ước tính dùng mức lương hiện tại và chỉ tính ca đã chấm công ra. Chưa trừ tạm ứng, bảo hiểm, thuế hoặc xử lý nghỉ phép.</p>
        </section>

        <section v-if="tab==='people'" class="surface section people-section"><div class="section-title"><div><h2>{{ current?.name || 'Thành viên công ty' }}</h2><p>{{ manager ? 'Phân loại nhân sự và thiết lập mức lương.' : 'Danh sách thành viên của công ty đang chọn.' }}</p></div><button v-if="manager" class="primary" @click="modal='invite'">Mời nhân viên</button></div><div v-if="manager && compensationUnavailable" class="notice" role="status">Phần lương đang chờ cập nhật cơ sở dữ liệu.</div><div v-if="!members.length" class="empty">Chưa có thành viên để hiển thị.</div><div v-for="group in memberGroups" :key="group.label" class="member-group"><h3>{{ group.label }} <span>{{ group.items.length }}</span></h3><div v-for="m in group.items" :key="m.user_id" class="row member-row"><div class="member-identity"><b>{{ m.full_name }}</b><small>{{ m.email }}</small><small v-if="manager && payFor(m.user_id)">{{ payFor(m.user_id).employment_type==='employee' ? 'Cơ bản: '+money(payFor(m.user_id).monthly_base_vnd)+' / tháng • ' : '' }}Theo show: {{ money(payFor(m.user_id).show_rate_vnd) }}</small><small v-if="!manager && m.user_id===user.id && payFor(m.user_id)">{{ typeName(payFor(m.user_id).employment_type) }}</small></div><div class="row-actions"><span class="badge">{{ m.role==='manager' ? roleLabel(m.role) : typeShort(payFor(m.user_id)?.employment_type) }}</span><button v-if="manager && m.role!=='manager'" :disabled="busy || compensationUnavailable" @click="openPay(m)">{{ payFor(m.user_id) ? 'Sửa mức lương' : 'Thiết lập' }}</button></div></div></div></section>

        <section v-if="isAdmin && tab==='companies'" class="surface section"><h2>Công ty trên hệ thống</h2><p>Mỗi công ty có một quản lý đứng tên.</p><div v-if="!adminCompanies.length" class="empty">Chưa có công ty được duyệt.</div><div v-for="c in adminCompanies" :key="c.id" class="row"><div><b>{{ c.name }}</b><small>{{ c.address }} | {{ c.phone }} | {{ c.contact_email }}</small></div><div><b>{{ c.manager_name || 'Chưa có quản lý' }}</b><small>{{ c.manager_email }}</small></div></div></section>

        <section v-if="isAdmin && tab==='approval'" class="surface section"><h2>Đơn đăng ký công ty</h2><p>Kiểm tra thông tin trước khi duyệt.</p><div v-if="!applications.filter(a=>a.status==='pending').length" class="empty">Không có đơn đang chờ duyệt.</div><div v-for="a in applications.filter(a=>a.status==='pending')" :key="a.id" class="row"><div><b>{{ a.company_name }}</b><small>{{ a.address }} | {{ a.phone }} | {{ a.email }}</small></div><div class="row-actions"><button :disabled="busy" @click="perform(()=>repo.rpc('review_company_application',{p_id:a.id,p_approve:false}),'Đã từ chối đơn.')">Từ chối</button><button class="primary" :disabled="busy" @click="perform(()=>repo.rpc('review_company_application',{p_id:a.id,p_approve:true}),'Đã duyệt công ty.')">Duyệt</button></div></div></section>

        <section v-if="isAdmin && tab==='accounts'" class="surface section"><h2>Quản lý tài khoản</h2><p>Tài khoản Google đã đăng nhập. Có thể vô hiệu hóa hoặc khôi phục quyền sử dụng, không thay đổi role tại đây.</p><div v-for="a in accounts" :key="a.user_id" class="row account-row"><div><b>{{ a.full_name }}</b><small>{{ a.email }} | {{ a.disabled ? 'Đã vô hiệu hóa: '+a.reason : 'Được phép truy cập' }}</small></div><template v-if="a.user_id!==user.id"><label>Lý do<input v-model="reasons[a.user_id]" minlength="5" maxlength="500" placeholder="Ít nhất 5 ký tự"></label><button :disabled="busy" @click="perform(()=>repo.rpc('admin_set_account_disabled',{p_user:a.user_id,p_disabled:!a.disabled,p_reason:reasons[a.user_id]||''}),a.disabled?'Đã kích hoạt tài khoản.':'Đã vô hiệu hóa tài khoản.')">{{ a.disabled?'Kích hoạt':'Vô hiệu hóa' }}</button></template><span v-else class="badge">Tài khoản của bạn</span></div></section>

        <template v-if="tab==='community'"><section v-if="!manager" class="surface section"><h2>Công ty</h2><p>Tìm công ty và gửi yêu cầu tham gia.</p><div v-if="!directory.length" class="empty">Chưa có công ty.</div><div v-for="c in directory" :key="c.id" class="row"><div><b>{{ c.name }}</b><small>{{ c.address }} | {{ c.phone }}</small></div><button v-if="!companies.some(x=>x.id===c.id)" :disabled="busy" @click="perform(()=>repo.rpc('request_company_membership',{p_company:c.id}),'Đã gửi yêu cầu tham gia.')">Xin tham gia</button><span v-else class="badge">Đã tham gia</span></div></section>
          <section v-if="manager" class="surface section"><h2>Yêu cầu tham gia</h2><div v-if="!requests.length" class="empty">Chưa có yêu cầu đang chờ.</div><div v-for="r in requests" :key="r.user_id" class="row"><b>{{ r.full_name }}</b><div class="row-actions"><button :disabled="busy" @click="perform(()=>repo.rpc('review_join_request',{p_company:companyId,p_user:r.user_id,p_approve:false}),'Đã từ chối.')">Từ chối</button><button :disabled="busy" @click="perform(()=>repo.rpc('review_join_request',{p_company:companyId,p_user:r.user_id,p_approve:true}),'Đã chấp nhận.')">Chấp nhận</button></div></div></section>
          <section v-if="manager" class="surface section"><h2>Tuyển nhân viên thời vụ</h2><div v-if="!freelancers.length" class="empty">Chưa có hồ sơ công khai.</div><div v-for="f in freelancers" :key="f.user_id" class="row"><div><b>{{ f.display_name }}</b><small>{{ f.specialty }}</small></div><button :disabled="busy" @click="perform(()=>repo.rpc('invite_freelancer',{p_company:companyId,p_user:f.user_id}),'Đã tạo lời mời.')">Mời</button></div></section>
          <section v-if="!manager" class="surface section"><h2>Hồ sơ việc làm thời vụ</h2><form class="form" @submit.prevent="saveProfile"><label>Tên hiển thị<input v-model="freelancer.display_name" required minlength="2" maxlength="100"></label><label>Chuyên môn<input v-model="freelancer.specialty" required minlength="2" maxlength="200" placeholder="Âm thanh, ánh sáng..."></label><label class="check"><input v-model="freelancer.visible" type="checkbox"> Cho Manager tìm thấy hồ sơ của tôi</label><div><button class="primary" :disabled="busy">Lưu hồ sơ</button></div></form></section></template>

        <section v-if="tab==='registration' && !hasManagedCompany" class="surface section form-section"><h2>{{ activeApplication ? 'Đơn đăng ký công ty' : 'Đăng ký công ty' }}</h2><p>{{ activeApplication ? 'Theo dõi trạng thái đơn đăng ký của bạn.' : 'Thông tin sẽ được gửi quản trị viên duyệt. Sau khi duyệt bạn là quản lý công ty.' }}</p><form v-if="!activeApplication" class="form" @submit.prevent="saveApplication"><label>Tên công ty<input v-model.trim="form.company_name" required minlength="3" maxlength="120" pattern=".*[\p{L}].*" title="Tên phải có chữ"></label><label>Địa chỉ<input v-model.trim="form.address" required minlength="8" maxlength="250" pattern=".*[\p{L}].*" title="Địa chỉ phải có chữ"></label><div class="form-grid"><label>Số điện thoại Việt Nam<input v-model="form.phone" required inputmode="numeric" pattern="0[0-9]{9}" title="10 chữ số, bắt đầu bằng 0"></label><label>Email công ty<input v-model.trim="form.email" required type="email" maxlength="254"></label></div><div><button class="primary" :disabled="busy">Gửi duyệt</button></div></form><div v-for="a in applications" :key="a.id" class="row"><b>{{ a.company_name }}</b><span class="badge">{{ statusText(a.status) }}</span></div></section>
      </main>
    </div>
    <div v-if="modal" class="overlay" @click.self="modal=''" @keydown.esc="modal=''"><section class="dialog" role="dialog" aria-modal="true" :aria-label="modal==='shift'?(editingShiftId?'Cập nhật ca làm việc':'Phân ca làm việc'):modal==='shift-picker'?'Chọn ca để sửa':modal==='pay'?'Thiết lập lương':'Mời nhân viên'"><div class="dialog-heading"><h2>{{ modal==='shift'?(editingShiftId?'Cập nhật ca làm việc':'Phân ca làm việc'):modal==='shift-picker'?'Chọn ca để sửa':modal==='pay'?'Thiết lập lương':'Mời nhân viên' }}</h2><button aria-label="Đóng" @click="modal=''">×</button></div><div v-if="error" class="alert" role="alert">{{ error }}</div><form v-if="modal==='invite'" class="form" @submit.prevent="perform(()=>repo.insert('company_invitations',{company_id:companyId,email:inviteEmail.trim().toLowerCase()}),'Đã tạo lời mời.',true)"><label>Email nhân viên<input v-model="inviteEmail" required type="email"></label><p>Nhân viên đăng nhập bằng email được mời để chấp nhận.</p><div class="form-actions"><button type="button" @click="modal=''">Hủy</button><button class="primary" :disabled="busy">Gửi lời mời</button></div></form>
      <form v-else-if="modal==='pay'" class="form" @submit.prevent="savePay"><p>Thiết lập cho {{ payForm.name }} tại {{ current?.name }}.</p><label>Loại nhân sự<select v-model="payForm.employment_type"><option value="employee">Nhân viên chính thức</option><option value="freelancer">Nhân viên thời vụ</option></select></label><label v-if="payForm.employment_type==='employee'">Lương cơ bản mỗi tháng (₫)<input v-model="payForm.monthly_base_vnd" type="number" min="0" max="99999999999999" step="1" required></label><label>{{ payForm.employment_type==='employee' ? 'Phụ cấp mỗi show hoàn tất (₫)' : 'Tiền công mỗi show hoàn tất (₫)' }}<input v-model="payForm.show_rate_vnd" type="number" min="0" max="99999999999999" step="1" required></label><p>Nhân viên chính thức: lương cơ bản theo tháng + phụ cấp show nếu có. Nhân viên thời vụ: chỉ nhận tiền theo show hoàn tất. Đây là mức thỏa thuận hiện tại, không phải bảng lương đã thanh toán.</p><div class="form-actions"><button type="button" @click="modal=''">Hủy</button><button class="primary" :disabled="busy">Lưu mức lương</button></div></form>
      <section v-else-if="modal==='shift-picker'" class="shift-picker">
        <p>Ngày {{ selectedDateLabel }} có nhiều ca. Chọn ca cần sửa hoặc tạo ca mới.</p>
        <div v-for="item in selectedShifts" :key="item.id" class="row">
          <div><b>{{ timeOf(item.starts_at) }} · {{ item.title }}</b><small>{{ nameOf(item.user_id) }} · {{ item.location }}</small></div>
          <button type="button" @click="editShift(item)">Sửa ca</button>
        </div>
        <div class="form-actions"><button type="button" @click="modal=''">Đóng</button><button type="button" class="primary" @click="createShiftOnSelectedDay">+ Thêm ca khác</button></div>
      </section>
      <form v-else class="form" @submit.prevent="saveShift"><label>Công việc / sự kiện<input v-model="shift.title" required maxlength="200"></label><label>Địa điểm<input v-model="shift.location" required maxlength="250"></label><div class="form-grid"><label>Ngày bắt đầu<input v-model="shift.date" type="date" required :disabled="!!(editingShiftId && clockRecordFor(editingShiftId))" @change="shift.end_date=shift.date"></label><label>Buổi<select :disabled="!!(editingShiftId && clockRecordFor(editingShiftId))" @change="setPeriod"><option value="morning">Sáng</option><option value="afternoon">Chiều</option><option value="evening">Tối</option><option value="all">Cả ngày</option><option value="custom">Tự chọn</option></select></label><label>Bắt đầu<input v-model="shift.start" type="time" required :disabled="!!(editingShiftId && clockRecordFor(editingShiftId))"></label><label>Kết thúc<input v-model="shift.end" type="time" required :disabled="!!(editingShiftId && clockRecordFor(editingShiftId))"></label></div><label>Ngày kết thúc<input v-model="shift.end_date" type="date" required :disabled="!!(editingShiftId && clockRecordFor(editingShiftId))"></label><fieldset><legend>Phân công nhân viên</legend><label v-if="editingShiftId">Nhân viên được giao<select :value="shift.user_ids[0]" required :disabled="!!(editingShiftId && clockRecordFor(editingShiftId))" @change="shift.user_ids=[$event.target.value]"><option value="" disabled>Chọn nhân viên</option><option v-for="m in staffMembers" :key="m.user_id" :value="m.user_id">{{ m.full_name }} · {{ typeShort(payFor(m.user_id)?.employment_type) }} ({{ m.email }})</option></select></label><template v-else><label v-for="m in staffMembers" :key="m.user_id" class="check"><input v-model="shift.user_ids" :value="m.user_id" type="checkbox">{{ m.full_name }} · {{ typeShort(payFor(m.user_id)?.employment_type) }} ({{ m.email }})</label></template><div v-if="!staffMembers.length" class="no-staff-hint"><p>Chưa có nhân viên Staff thuộc công ty này. Bạn cần mời nhân viên và đợi họ tham gia trước khi phân ca.</p><button type="button" @click="modal='invite'">+ Mời nhân viên</button></div></fieldset><div class="form-actions">
          <button v-if="editingShift && !clockRecordFor(editingShiftId)" type="button" class="danger-quiet" :disabled="busy" @click="removeShift(editingShift)">Hủy ca</button>
          <span v-if="editingShift && clockRecordFor(editingShiftId)" class="clock-locked">Ca đã chấm công, không thể hủy hoặc đổi giờ</span>
          <button type="button" @click="modal=''">Đóng</button>
          <button class="primary" :disabled="busy || !staffMembers.length"> {{ editingShiftId ? 'Lưu thay đổi' : 'Lưu phân ca' }}</button>
        </div></form>
    </section></div>
  </div>
</template>
