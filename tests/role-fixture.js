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
const pay = [{company_id:'company',user_id:'staff',employment_type:'employee',monthly_base_vnd:8000000,show_rate_vnd:500000},{company_id:'company',user_id:'contractor',employment_type:'freelancer',monthly_base_vnd:null,show_rate_vnd:700000}]
Object.assign(repo, {
  auth: { signOut: async () => {} }, restriction: async () => null,
  companies: async () => role === 'manager' ? [c,c2] : [c], memberships: async () => role === 'admin' ? [] : role === 'manager' ? [{ company_id:'company', role },{ company_id:'company-2', role:'staff' }] : [{ company_id:'company', role }], invitations: async () => [],
  roster: async id => id === 'company-2' ? [{ user_id:'other',full_name:'Võ Lan',email:'lan@example.test',role:'manager' }] : [...roster], shifts: async id => schedule.filter(s=>s.company_id===id && (role==='manager' || s.user_id===user.id)), compensation: async id => pay.filter(p=>p.company_id===id), applications: async () => role === 'manager' ? [] : [...apps],
  profile: async () => null, freelancers: async () => [{user_id:'free',display_name:'Phạm Huy',specialty:'Ánh sáng',visible:true}],
  accounts: async () => [{user_id:'staff',full_name:'Lê Mai',email:'staff@example.test',disabled:false}],
  adminCompanies: async () => [{...c, manager_name:'Trần Minh', manager_email:'manager@example.test'}],
  requests: async () => [{user_id:'request',full_name:'Nguyễn Bình'}],
  rpc: async (name, args) => { if(name === 'review_company_application') apps[0].status=args.p_approve?'approved':'rejected'; if(name === 'review_join_request') repo.requests=async()=>[] },
  insert: async (table, value) => { if(table==='company_shifts') schedule.push(...value.map((v,i)=>({...v,id:String(schedule.length+i)}))); if(table==='company_applications') apps.push({...value,id:String(apps.length),status:'pending'}) },
  deleteShift: async id => { const index=schedule.findIndex(s=>s.id===id); if(index>=0) schedule.splice(index,1) },
  upsert: async (table, value) => { if(table==='member_compensation') { const index = pay.findIndex(p=>p.company_id===value.company_id && p.user_id===value.user_id); if(index<0) pay.push(value); else pay[index]=value } }
})
createApp(Workspace, { user }).mount('#root')
