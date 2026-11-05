// Local-only browser fixture. This file is not part of the production entry point.
import { createApp } from 'vue'
import Workspace from '../src/presentation/Workspace.vue'
import { repository as repo } from '../src/infrastructure/repository'
import '../src/presentation/app.css'

const role = new URLSearchParams(location.search).get('role') || 'staff'
const user = { id: 'me', email: 'me@example.test', app_metadata: role === 'admin' ? { role: 'admin' } : {}, user_metadata: { full_name: 'Nguyễn An' } }
const c = { id: 'company', name: 'Âm thanh Ánh sáng Việt', address: '12 Nguyễn Huệ, Quận 1', phone: '0912345678' }
const roster = [{ user_id: 'manager', full_name: 'Trần Minh', email: 'manager@example.test', role: 'manager' }, { user_id: 'staff', full_name: 'Lê Mai', email: 'staff@example.test', role: 'staff' }]
const apps = [{ id:'application', company_name:'Sân khấu Thành Công', address:'23 Lê Lợi, Quận 1', phone:'0912345678', email:'show@example.test', status:'pending' }]
const schedule = []
Object.assign(repo, {
  auth: { signOut: async () => {} }, restriction: async () => null,
  companies: async () => [c], memberships: async () => role === 'admin' ? [] : [{ company_id:'company', role }], invitations: async () => [],
  roster: async () => [...roster], shifts: async () => [...schedule], applications: async () => [...apps],
  profile: async () => null, freelancers: async () => [{user_id:'free',display_name:'Phạm Huy',specialty:'Ánh sáng',visible:true}],
  accounts: async () => [{user_id:'staff',full_name:'Lê Mai',email:'staff@example.test',disabled:false}],
  requests: async () => [{user_id:'request',full_name:'Nguyễn Bình'}],
  rpc: async (name, args) => { if(name === 'review_company_application') apps[0].status=args.p_approve?'approved':'rejected'; if(name === 'review_join_request') repo.requests=async()=>[] },
  insert: async (table, value) => { if(table==='company_shifts') schedule.push(...value.map((v,i)=>({...v,id:String(schedule.length+i)}))); if(table==='company_applications') apps.push({...value,id:String(apps.length),status:'pending'}) },
  upsert: async () => {}
})
createApp(Workspace, { user }).mount('#root')
