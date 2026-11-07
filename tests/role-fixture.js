// Local-only browser fixture. This file is not part of the production entry point.
import { createApp } from 'vue'
import { createMemoryHistory } from 'vue-router'
import WorkspaceRouter from '../src/presentation/WorkspaceRouter.vue'
import { createWorkspaceRouter } from '../src/presentation/router'
import { repository as repo } from '../src/infrastructure/repository'
import { localDate, workerRole } from '../src/domain/calendar.js'
import '../src/presentation/styles/index.css'

const options = new URLSearchParams(location.search)
const role = options.get('role') || 'staff'
const multipleCompanies = role === 'manager' || options.has('notificationUi') || options.has('multiCompany')
const user = { id: role === 'freelance' ? 'contractor' : role, email: 'me@example.test', app_metadata: role === 'admin' ? { role: 'admin' } : {}, user_metadata: { full_name: 'Nguyễn An' } }
const c = { id: 'company', name: 'Âm thanh Ánh sáng Việt', address: '12 Nguyễn Huệ, Quận 1', phone: '0912345678' }
const c2 = { id: 'company-2', name: 'Sân khấu Phương Nam', address: '24 Lê Lợi, Quận 1', phone: '0987654321' }
const roster = [{ user_id: 'manager', full_name: 'Trần Minh', email: 'manager@example.test', role: 'manager' }, { user_id: 'staff', full_name: 'Lê Mai', email: 'staff@example.test', role: 'staff' }, { user_id:'contractor',full_name:'Phạm Huy',email:'huy@example.test',role:'staff' }]
const apps = [{ id:'application', company_name:'Sân khấu Thành Công', address:'23 Lê Lợi, Quận 1', phone:'0912345678', email:'show@example.test', status:'pending', created_at:new Date().toISOString() }]
const dateText = localDate(new Date())
const at = (time) => new Date(dateText + 'T' + time + ':00').toISOString()
const schedule = [
  { id:'demo-1',company_id:'company',user_id:'staff',title:'Lắp đặt âm thanh',location:'Trung tâm hội nghị',starts_at:at('08:00'),ends_at:at('12:00'),cast_vnd:500000 },
  { id:'demo-2',company_id:'company',user_id:'contractor',title:'Vận hành ánh sáng',location:'Nhà hát thành phố',starts_at:at('13:00'),ends_at:at('18:00'),cast_vnd:400000 }
]
const attendance = options.has('checkedIn')
  ? [{shift_id:'demo-1',company_id:c.id,user_id:'staff',checked_in_at:at('08:00'),checked_out_at:null}]
  : []
if (options.has('payroll')) {
  attendance.push({shift_id:'demo-1',company_id:c.id,user_id:'staff',checked_in_at:at('08:00'),checked_out_at:at('12:00')})
}
const notifications = schedule.map((shift, index) => ({
  id:`notice-${index + 1}`, user_id:shift.user_id, company_id:shift.company_id, shift_id:shift.id,
  event:'created', title:'Bạn có ca làm mới', body:`${shift.title} · ${shift.location}`,
  created_at:new Date().toISOString(), read_at:null
}))
if (options.has('notificationUi') && (role === 'staff' || role === 'freelance')) {
  const assignment = schedule.find(shift => shift.user_id === user.id) || schedule[0]
  const future = new Date(assignment.starts_at)
  future.setDate(future.getDate() + 1)
  assignment.starts_at = future.toISOString()
  assignment.ends_at = new Date(future.getTime() + 4 * 3600000).toISOString()
  const stamp = value => {
    const parts = Object.fromEntries(new Intl.DateTimeFormat('vi-VN', {
      timeZone:'Asia/Ho_Chi_Minh', day:'2-digit', month:'2-digit', year:'numeric',
      hour:'2-digit', minute:'2-digit', hourCycle:'h23'
    }).formatToParts(new Date(value)).map(part => [part.type,part.value]))
    return `${parts.day}/${parts.month}/${parts.year} ${parts.hour}:${parts.minute}`
  }
  const body = `${assignment.title} · ${assignment.location} · ${stamp(assignment.starts_at)} đến ${stamp(assignment.ends_at)}`
  const ownNotice = notifications.find(notice => notice.user_id === user.id)
  Object.assign(ownNotice, {body, created_at:new Date(Date.now() - 180000).toISOString()})
  notifications.push({...ownNotice, id:'read-notice', read_at:new Date().toISOString()})
  const notice = {user_id:user.id, company_id:c.id, shift_id:null, created_at:new Date().toISOString(), read_at:null}
  notifications.push(
    {...notice, id:'promoted', event:'employment_changed', title:'Bạn đã được chuyển thành STAFF', body:`Manager của ${c.name} đã chuyển vai trò của bạn từ Freelance sang STAFF.`},
    {...notice, id:'demoted', event:'employment_changed', title:'Bạn đã được chuyển thành Freelance', body:`Manager của ${c.name} đã chuyển vai trò của bạn từ STAFF sang Freelance.`, created_at:new Date(Date.now() - 60000).toISOString()},
    {...notice, id:'cancelled', shift_id:'removed-shift', event:'cancelled', title:'Ca làm việc đã bị hủy', body, created_at:new Date(Date.now() - 120000).toISOString()},
    {...notice, id:'old-cancellation', event:'cancelled', title:'Ca làm việc đã bị hủy', body, created_at:new Date(Date.now() - 8 * 86400000).toISOString()},
    {...notice, id:'old-role', event:'employment_changed', title:'Bạn đã được chuyển thành STAFF', body:'Lịch sử thay đổi vai trò tại công ty.', created_at:new Date(Date.now() - 8 * 86400000).toISOString()},
    ...Array.from({length:8}, (_, index) => ({...ownNotice, id:`updated-${index}`, event:'updated', title:'Lịch làm việc đã thay đổi', created_at:new Date(Date.now() - 240000 - index * 1000).toISOString()}))
  )
}
if (options.has('notificationTest')) {
  const events = [
    ['manager', c.id, 'attendance_in', 'Nhân viên đã chấm công vào'],
    ['manager', c.id, 'join_request', 'Có yêu cầu gia nhập công ty'],
    ['manager', c2.id, 'created', 'Bạn có ca ở công ty thứ hai'],
    ['manager', c.id, 'created', 'Sự kiện STAFF sai vai trò'],
    ['manager', c2.id, 'attendance_out', 'Sự kiện Manager sai công ty'],
    ['staff', c.id, 'attendance_in', 'Sự kiện Manager gửi nhầm cho STAFF'],
    ['admin', c.id, 'attendance_in', 'Sự kiện nội bộ gửi nhầm cho Admin']
  ]
  notifications.push(...events.map(([user_id, company_id, event, title], index) => ({
    id:`role-notice-${index}`, user_id, company_id, event, title, body:title,
    created_at:new Date().toISOString(), read_at:null
  })))
  apps.push({...apps[0], id:'resolved', company_name:'Công ty đã duyệt', status:'approved'})
}
const emit = (event,item) => notifications.unshift({id:String(notifications.length+1),user_id:item.user_id,company_id:item.company_id,shift_id:item.id,event,title:({created:'Bạn có ca làm mới',updated:'Lịch làm việc đã thay đổi',cancelled:'Ca làm việc đã bị hủy'})[event],body:item.title+' · '+item.location,created_at:new Date().toISOString(),read_at:null})
const pay = [{company_id:'company',user_id:'staff',employment_type:'employee',monthly_base_vnd:8000000,show_rate_vnd:500000},{company_id:'company',user_id:'contractor',employment_type:'freelancer',monthly_base_vnd:null,show_rate_vnd:700000}]
if (multipleCompanies && role !== 'admin') {
  pay.push({company_id:c2.id,user_id:user.id,employment_type:'freelancer',monthly_base_vnd:null,monthly_allowance_vnd:0,show_rate_vnd:0})
}
Object.assign(repo, {
  auth: { signOut: async () => {} }, restriction: async () => null,
  accountProfile: async () => null,
  memberStatuses: async id => id === c.id ? roster.map(({ user_id }) => ({ user_id, is_active: true })) : [],
  companies: async () => multipleCompanies ? [c,c2] : [c],
  memberships: async () => role === 'admin' ? [] : [
    {company_id:c.id,role:role === 'manager' ? 'manager' : 'staff'},
    ...(multipleCompanies ? [{company_id:c2.id,role:'staff'}] : [])
  ], invitations: async () => [],
  roster: async id => id === c2.id ? [{ user_id:'other',full_name:'Võ Lan',email:'lan@example.test',role:'manager' }, { ...roster.find(person => person.user_id === user.id), role:'staff' }] : [...roster], shifts: async id => schedule.filter(s=>s.company_id===id && (role==='manager' || s.user_id===user.id)), attendance: async id=>attendance.filter(a=>a.company_id===id && (role==='manager'||a.user_id===user.id)), clockIn: async id=>{ const shift=schedule.find(s=>s.id===id);attendance.push({shift_id:id,company_id:shift.company_id,user_id:shift.user_id,checked_in_at:new Date().toISOString(),checked_out_at:null}) }, clockOut: async id=>{const a=attendance.find(a=>a.shift_id===id); if(a)a.checked_out_at=new Date().toISOString()},
  compensation: async id => pay.filter(p => p.company_id === id && (role === 'manager' && id === c.id || p.user_id === user.id)),
  workspaceRoles: async id => {
    const people = await repo.roster(id)
    const roles = Object.fromEntries(people.map(person => [person.user_id, person.role === 'manager'
      ? 'manager' : workerRole(pay.find(p => p.user_id === person.user_id && p.company_id === (id || c.id))?.employment_type)]))
    return id ? roles : { ...roles, admin:'admin' }
  },
  payrollShifts: async (id, month) => schedule
    .filter(shift => shift.company_id === id && shift.starts_at.slice(0,7) === month.slice(0,7))
    .map(shift => ({...shift, shift_attendance: attendance.find(record => record.shift_id === shift.id) || null})),
  addShiftExpense: async (id, expenseId, note, amount) => {
    const record = attendance.find(entry => entry.shift_id === id && entry.user_id === user.id)
    if (!record || record.checked_out_at) throw new Error('Ca không còn nhận chi phí phát sinh.')
    const expenses = record.expenses || []
    if (!expenses.some(expense => expense.id === expenseId)) expenses.push({id:expenseId, note, amount_vnd:amount})
    record.expenses = expenses
    record.expense_total_vnd = expenses.reduce((total, expense) => total + expense.amount_vnd, 0)
    return {...record}
  },
  staffSummary: async (id, month) => pay.filter(p=>p.company_id===id).map(p=>{
    const userRow=roster.find(m=>m.user_id===p.user_id)
    if (options.has('legacyPayroll')) {
      return { user_id:p.user_id, full_name:userRow.full_name, email:userRow.email,
        employment_type:p.employment_type, monthly_base_vnd:p.monthly_base_vnd }
    }
    const assigned=schedule.filter(sh=>sh.user_id===p.user_id && sh.company_id===id && sh.starts_at.slice(0,7)===month.slice(0,7))
    const completed=assigned.filter(sh=>attendance.some(a=>a.shift_id===sh.id && a.checked_out_at))
    const castTotal = completed.reduce((total, shift) => total + (shift.cast_vnd || 0), 0)
    const workedHours = completed.reduce((total, shift) => {
      const entry = attendance.find(a => a.shift_id === shift.id)
      return total + (new Date(entry.checked_out_at) - new Date(entry.checked_in_at)) / 3600000
    }, 0)
    return {user_id:p.user_id,full_name:userRow?.full_name||'Nhân viên',email:userRow?.email||'',employment_type:p.employment_type,
      monthly_base_vnd:p.monthly_base_vnd,monthly_allowance_vnd:p.monthly_allowance_vnd || 0,
      scheduled_shifts:assigned.length,completed_shifts:completed.length,worked_hours:workedHours,
      planned_cast_vnd:assigned.reduce((total, shift) => total + (shift.cast_vnd || 0), 0),
      cast_total_vnd:castTotal,estimated_total_vnd:(p.monthly_base_vnd || 0)+(p.monthly_allowance_vnd || 0)+castTotal}
  }), applications: async () => role === 'manager' ? [] : [...apps],
  profile: async () => null, notifications: async id => notifications.filter(n=>n.user_id===id).sort((a,b) => b.created_at.localeCompare(a.created_at) || a.id.localeCompare(b.id)), markNotificationRead: async id => { const n=notifications.find(x=>x.id===id); if(n)n.read_at=new Date().toISOString(); return n }, freelancers: async () => [{user_id:'free',display_name:'Phạm Huy',specialty:'Ánh sáng',visible:true}],
  accounts: async () => [
    {user_id:'staff',full_name:'Lê Mai',email:'staff@example.test',disabled:false,role:'staff',age:24,hometown:'Thành phố Huế',active_location:null},
    {user_id:'contractor',full_name:'Phạm Huy',email:'huy@example.test',disabled:false,role:'staff',age:null,hometown:null,active_location:null},
    {user_id:'manager',full_name:'Trần Minh',email:'manager@example.test',disabled:false,role:'manager',age:34,hometown:'Thành phố Đà Nẵng',active_location:'Phường Ngũ Hành Sơn, Thành phố Đà Nẵng'},
    {user_id:'admin',full_name:'Nguyễn An',email:'admin@example.test',disabled:false,role:'admin',age:null,hometown:null,active_location:null}
  ],
  adminCompanies: async () => [{...c, manager_name:'Trần Minh', manager_email:'manager@example.test'}],
  requests: async () => [{user_id:'request',full_name:'Nguyễn Bình'}],
  rpc: async (name, args) => { if(name === 'review_company_application') apps[0].status=args.p_approve?'approved':'rejected'; if(name === 'review_join_request') repo.requests=async()=>[] },
  insert: async (table, value) => { if(table==='company_shifts') { const added = value.map((v,i)=>({...v,id:String(schedule.length+i)})); schedule.push(...added); added.forEach(x=>emit('created',x)) } if(table==='company_applications') apps.push({...value,id:String(apps.length),status:'pending'}) },
  updateShift: async (id, companyId, change) => { const row = schedule.find(s=>s.id===id && s.company_id===companyId); if(!row) throw new Error('Không tìm thấy ca'); const old={...row}; Object.assign(row,change); if(old.user_id!==row.user_id) {emit('cancelled',old);emit('created',row)} else emit('updated',row); return row },
  deleteShifts: async (ids, companyId) => {
    const items = schedule.filter(shift => shift.company_id === companyId && ids.includes(shift.id))
    if (items.some(shift => attendance.some(record => record.shift_id === shift.id))) {
      throw Object.assign(new Error('Không thể hủy ca đã chấm công'), {code:'P4510'})
    }
    for (const shift of items) {
      schedule.splice(schedule.indexOf(shift), 1)
      emit('cancelled', shift)
    }
    return items.map(({ id }) => ({ id }))
  },
  upsert: async (table, value) => { if(table==='member_compensation') { const index = pay.findIndex(p=>p.company_id===value.company_id && p.user_id===value.user_id); if(index<0) pay.push(value); else pay[index]=value } }
})
const startupDelay = Math.min(Math.max(Number(options.get('startupDelay')) || 0, 0), 10000)
if (startupDelay) {
  for (const name of ['profile', 'notifications']) {
    const original = repo[name]
    repo[name] = async (...args) => {
      await new Promise(resolve => setTimeout(resolve, startupDelay))
      return original(...args)
    }
  }
}
const router = createWorkspaceRouter(createMemoryHistory())
const app = createApp(WorkspaceRouter, { user })
app.use(router)
router.push('/').then(() => app.mount('#root'))
