import { supabase } from '../lib/supabase'

const data = async (request) => { const result = await request; if (result.error) throw result.error; return result.data }
export const repository = {
  auth: supabase.auth,
  restriction: id => data(supabase.from('account_restrictions').select('disabled,reason').eq('user_id', id).maybeSingle()),
  companies: () => data(supabase.from('companies').select('id,name,address,phone,contact_email').order('name')),
  memberships: id => data(supabase.from('company_members').select('company_id,role').eq('user_id', id)),
  invitations: () => data(supabase.from('company_invitations').select('id,company_id,email,status').eq('status', 'pending')),
  roster: id => data(supabase.rpc('company_roster', { p_company: id })),
  shifts: id => data(supabase.from('company_shifts').select('*').eq('company_id', id).order('starts_at')),
  applications: () => data(supabase.from('company_applications').select('*').order('created_at', { ascending: false })),
  freelancers: () => data(supabase.from('freelancer_profiles').select('*')),
  profile: id => data(supabase.from('freelancer_profiles').select('*').eq('user_id', id).maybeSingle()),
  accounts: () => data(supabase.rpc('admin_list_accounts')),
  requests: id => data(supabase.rpc('list_join_requests', { p_company: id })),
  rpc: (name, args) => data(supabase.rpc(name, args)),
  insert: (table, values) => data(supabase.from(table).insert(values)),
  upsert: (table, values) => data(supabase.from(table).upsert(values))
}
