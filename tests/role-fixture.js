// Local-only browser fixture. This file is not part of the production entry point.
import { createApp } from 'vue'
import Workspace from '../src/presentation/Workspace.vue'
import { repository as repo } from '../src/infrastructure/repository'
import '../src/presentation/app.css'

const role = new URLSearchParams(location.search).get('role') || 'staff'
const user = { id: role === 'admin' ? 'admin' : role === 'manager' ? 'manager' : 'staff', email: 'me@example.test', app_metadata: role === 'admin' ? { role: 'admin' } : {}, user_metadata: { full_name: 'Nguyễn An' } }
const c = { id: 'company', name: 'Âm thanh Ánh sáng Việt', address: '12 Nguyễn Huệ, Quận 1', phone: '0912345678' }
const c2 = { id: 'company-2', name: 'Sân khấu Phương Nam', address: '24 Lê Lợi, Quận 1', phone: '0987654321' }
const roster = [{ user_id: 'manager', full_name: 'Trần Minh', email: 'manager@example.test', role: 'manager' }, { user_id: 'staff', full_name: 'Lê Mai', email: 'staff@example.test', role: 'staff' }, { user_id:'contractor',full_name:'Phạm Huy',email:'huy@example.test',role:'staff' }]
const apps = [{ id:'application', company_name:'Sân khấu Thành Công', address:'23 Lê Lợi, Quận 1', phone:'0912345678', email:'show@example.test', status:'pending' }]
const dateText = new Date().toISOString().slice(0,10)
const at = (time) => new Date(dateText + 'T' + time + ':00').toISOString()
const schedule = [
  { id:'demo-1',company_id:'company',user_id:'staff',title:'Lắp đặt âm thanh',location:'Trung tâm hội nghị',starts_at:at('08:00'),ends_at:at('12:00') },
  { id:'demo-2',company_id:'company',user_id:'contractor',title:'Vận hành ánh sáng',location:'Nhà hát thành phố',starts_at:at('13:00'),ends_at:at('18:00') }
]
const attendance = []
const notifications = [{id:'notice-1',user_id:'staff',company_id:'company',shift_id:'demo-1',event:'created',title:'Bạn có ca làm mới',body:'Lắp đặt âm thanh · Trung tâm hội nghị · 08:00 đến 12:00',created_at:new Date().toISOString(),read_at:null}]
const emit = (event,item) => notifications.unshift({id:String(notifications.length+1),user_id:item.user_id,company_id:item.company_id,shift_id:item.id,event,title:({created:'Bạn có ca làm mới',updated:'Lịch làm việc đã thay đổi',cancelled:'Ca làm việc đã bị hủy'})[event],body:item.title+' · '+item.location,created_at:new Date().toISOString(),read_at:null})
const pay = [{company_id:'company',user_id:'staff',employment_type:'employee',monthly_base_vnd:8000000,show_rate_vnd:500000},{company_id:'company',user_id:'contractor',employment_type:'freelancer',monthly_base_vnd:null,show_rate_vnd:700000}]
Object.assign(repo, {
  auth: { signOut: async () => {} }, restriction: async () => null,
  companies: async () => role === 'manager' ? [c,c2] : [c], memberships: async () => role === 'admin' ? [] : role === 'manager' ? [{ company_id:'company', role },{ company_id:'company-2', role:'staff' }] : [{ company_id:'company', role }], invitations: async () => [],
  roster: async id => id === 'company-2' ? [{ user_id:'other',full_name:'Võ Lan',email:'lan@example.test',role:'manager' }] : [...roster], shifts: async id => schedule.filter(s=>s.company_id===id && (role==='manager' || s.user_id===user.id)), attendance: async id=>attendance.filter(a=>a.company_id===id && (role==='manager'||a.user_id===user.id)), clockIn: async id=>{ const shift=schedule.find(s=>s.id===id);attendance.push({shift_id:id,company_id:shift.company_id,user_id:shift.user_id,checked_in_at:new Date().toISOString(),checked_out_at:null}) }, clockOut: async id=>{const a=attendance.find(a=>a.shift_id===id); if(a)a.checked_out_at=new Date().toISOString()}, compensation: async id => pay.filter(p=>p.company_id===id),
  staffSummary: async (id, month) => pay.filter(p=>p.company_id===id).map(p=>{
    const userRow=roster.find(m=>m.user_id===p.user_id)
    const assigned=schedule.filter(sh=>sh.user_id===p.user_id && sh.company_id===id && sh.starts_at.slice(0,7)===month.slice(0,7))
    const completed=assigned.filter(sh=>attendance.some(a=>a.shift_id===sh.id && a.checked_out_at))
    return {user_id:p.user_id,full_name:userRow?.full_name||'Nhân viên',email:userRow?.email||'',employment_type:p.employment_type,
      monthly_base_vnd:p.monthly_base_vnd,show_rate_vnd:p.show_rate_vnd,
      scheduled_shifts:assigned.length,completed_shifts:completed.length,worked_hours:0,
      estimated_total_vnd:Number(p.monthly_base_vnd||0)+Number(p.show_rate_vnd)*completed.length}
  }), applications: async () => role === 'manager' ? [] : [...apps],
  profile: async () => null, notifications: async id => notifications.filter(n=>n.user_id===id), markNotificationRead: async id => { const n=notifications.find(x=>x.id===id); if(n)n.read_at=new Date().toISOString(); return n }, freelancers: async () => [{user_id:'free',display_name:'Phạm Huy',specialty:'Ánh sáng',visible:true}],
  accounts: async () => [{user_id:'staff',full_name:'Lê Mai',email:'staff@example.test',disabled:false}],
  adminCompanies: async () => [{...c, manager_name:'Trần Minh', manager_email:'manager@example.test'}],
  requests: async () => [{user_id:'request',full_name:'Nguyễn Bình'}],
  rpc: async (name, args) => { if(name === 'review_company_application') apps[0].status=args.p_approve?'approved':'rejected'; if(name === 'review_join_request') repo.requests=async()=>[] },
  insert: async (table, value) => { if(table==='company_shifts') { const added = value.map((v,i)=>({...v,id:String(schedule.length+i)})); schedule.push(...added); added.forEach(x=>emit('created',x)) } if(table==='company_applications') apps.push({...value,id:String(apps.length),status:'pending'}) },
  updateShift: async (id, companyId, change) => { const row = schedule.find(s=>s.id===id && s.company_id===companyId); if(!row) throw new Error('Không tìm thấy ca'); const old={...row}; Object.assign(row,change); if(old.user_id!==row.user_id) {emit('cancelled',old);emit('created',row)} else emit('updated',row); return row },
  deleteShift: async id => { if(attendance.some(a=>a.shift_id===id)) throw Object.assign(new Error('Không thể hủy ca đã chấm công'),{code:'P4510'}); const index=schedule.findIndex(s=>s.id===id); if(index>=0) { const [removed]=schedule.splice(index,1);emit('cancelled',removed) } },
  upsert: async (table, value) => { if(table==='member_compensation') { const index = pay.findIndex(p=>p.company_id===value.company_id && p.user_id===value.user_id); if(index<0) pay.push(value); else pay[index]=value } }
})
createApp(Workspace, { user }).mount('#root')
