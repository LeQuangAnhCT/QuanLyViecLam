import { supabase } from '../lib/supabase'

const data = async (request) => { const result = await request; if (result.error) throw result.error; return result.data }
export const repository = {
  auth: supabase.auth,
  restriction: id => data(supabase.from('account_restrictions').select('disabled,reason').eq('user_id', id).maybeSingle()),
  companies: () => data(supabase.from('companies').select('id,name,address,phone,contact_email').order('name')),
  memberships: id => data(supabase.from('company_members').select('company_id,role').eq('user_id', id)),
  invitations: () => data(supabase.from('company_invitations').select('id,company_id,email,status').eq('status', 'pending')),
  roster: id => data(supabase.rpc('company_roster', { p_company: id })),
  compensation: id => data(supabase.from('member_compensation').select('*').eq('company_id', id)),
  shifts: id => data(supabase.from('company_shifts').select('*').eq('company_id', id).order('starts_at')),
  async updateShift(id, companyId, changes) {
    const changed = await data(supabase.from('company_shifts').update(changes)
      .eq('id', id).eq('company_id', companyId).select('*'))
    if (changed?.length !== 1) throw new Error('Không thể cập nhật ca. Hãy kiểm tra quyền của chủ công ty.')
    return changed[0]
  },
  notifications: userId => data(supabase.from('shift_notifications')
    .select('id,company_id,shift_id,event,title,body,created_at,read_at')
    .eq('user_id', userId).order('created_at', { ascending: false }).limit(80)),
  async markNotificationRead(id, userId) {
    return data(supabase.from('shift_notifications').update({read_at:new Date().toISOString()})
      .eq('id', id).eq('user_id', userId).is('read_at', null).select('id,read_at'))
  },
  async deleteShift(id, companyId) {
    const removed = await data(supabase.from('company_shifts').delete().eq('id', id).eq('company_id', companyId).select('id'))
    if (!removed?.length) throw new Error('Không thể xóa ca này. Hãy kiểm tra quyền quản lý.')
    return removed
  },
  applications: () => data(supabase.from('company_applications').select('*').order('created_at', { ascending: false })),
  freelancers: () => data(supabase.from('freelancer_profiles').select('*')),
  profile: id => data(supabase.from('freelancer_profiles').select('*').eq('user_id', id).maybeSingle()),
  accounts: () => data(supabase.rpc('admin_list_accounts')),
  async adminCompanies() {
    const result = await supabase.rpc('admin_company_directory')
    if (!result.error) return result.data
    if (result.error.code !== 'PGRST202') throw result.error
    // Compatibility while the new directory function is awaiting deployment.
    const companies = await data(supabase.from('companies').select('id,name,address,phone,contact_email').order('name'))
    return Promise.all((companies || []).map(async company => {
      const members = await data(supabase.rpc('company_roster', { p_company: company.id }))
      const manager = (members || []).find(member => member.role === 'manager')
      return { ...company, manager_name: manager?.full_name, manager_email: manager?.email }
    }))
  },
  requests: id => data(supabase.rpc('list_join_requests', { p_company: id })),
  rpc: (name, args) => data(supabase.rpc(name, args)),
  insert: (table, values) => data(supabase.from(table).insert(values)),
  upsert: (table, values) => data(supabase.from(table).upsert(values))
}
