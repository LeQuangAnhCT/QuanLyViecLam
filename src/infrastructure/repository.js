import { supabase } from '../lib/supabase'
import { shiftNoticeCutoff } from '../domain/notifications.js'

const data = async (request) => { const result = await request; if (result.error) throw result.error; return result.data }
const vietnamDate = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Ho_Chi_Minh', year: 'numeric', month: '2-digit', day: '2-digit'
})
function profileAge(birthDate, today) {
  if (typeof birthDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(birthDate) || birthDate > today) return null
  const years = Number(today.slice(0, 4)) - Number(birthDate.slice(0, 4))
  return years - Number(today.slice(5) < birthDate.slice(5))
}
export const repository = {
  auth: supabase.auth,
  accountProfile: id => data(supabase.from('profiles').select('id,full_name,birth_date,hometown,active_location,avatar_url').eq('id',id).maybeSingle()),
  saveAccountProfile: (id, values) => data(supabase.from('profiles').upsert({id,...values},{onConflict:'id'}).select().single()),
  async uploadAvatar(id, file) {
    const path = `${id}/avatar-${Date.now()}.${file.name.split('.').pop()?.toLowerCase() || 'jpg'}`
    await data(supabase.storage.from('avatars').upload(path,file,{contentType:file.type,upsert:false}))
    return supabase.storage.from('avatars').getPublicUrl(path).data.publicUrl
  },
  restriction: id => data(supabase.from('account_restrictions').select('disabled,reason').eq('user_id', id).maybeSingle()),
  companies: () => data(supabase.from('companies').select('id,name,address,phone,contact_email').order('name')),
  memberships: id => data(supabase.from('company_members').select('company_id,role').eq('user_id', id)),
  invitations: () => data(supabase.from('company_invitations').select('id,company_id,email,status').eq('status', 'pending')),
  roster: id => data(supabase.rpc('company_roster', { p_company: id })),
  memberStatuses: id => data(supabase.from('company_members').select('user_id,is_active').eq('company_id',id)),
  compensation: id => data(supabase.from('member_compensation').select('*').eq('company_id', id)),
  async workspaceRoles(companyId = null) {
    const result = await supabase.rpc('workspace_roles', { p_company: companyId })
    if (result.error?.code === 'PGRST202') return null
    if (result.error) throw result.error
    return result.data
  },
  async saveCompensation(values) {
    const table = 'member_compensation'
    try {
      await repository.upsert(table, values)
      return
    } catch (error) {
      if (error?.code !== 'PGRST204' || !error.message?.includes("'monthly_allowance_vnd'")) throw error
    }

    const { company_id, user_id, monthly_allowance_vnd, ...changes } = values
    if (monthly_allowance_vnd !== 0) {
      throw new Error('Supabase chưa hỗ trợ phụ cấp tháng. Nhập 0 ₫ để lưu loại nhân sự và lương cơ bản.')
    }

    // Existing rows keep their legacy per-show rate. Only a new row needs a rate.
    const updated = await data(supabase.from(table).update(changes)
      .eq('company_id', company_id).eq('user_id', user_id).select('user_id'))
    if (!updated?.length) {
      await repository.insert(table, { company_id, user_id, ...changes, show_rate_vnd: 0 })
    }
  },
  staffSummary: (companyId, monthDate) => data(supabase.rpc('company_staff_summary',{p_company:companyId,p_month:monthDate})),
  async payrollShifts(companyId, monthDate) {
    const monthStart = `${monthDate.slice(0, 7)}-01`
    const nextMonth = new Date(`${monthStart}T00:00:00Z`)
    nextMonth.setUTCMonth(nextMonth.getUTCMonth() + 1)
    const nextMonthStart = nextMonth.toISOString().slice(0, 10)
    const shifts = []
    const pageSize = 500
    for (let offset = 0; ; offset += pageSize) {
      const page = await data(supabase.from('company_shifts')
        .select('id,user_id,cast_vnd,shift_attendance(*)')
        .eq('company_id', companyId)
        .gte('starts_at', `${monthStart}T00:00:00+07:00`)
        .lt('starts_at', `${nextMonthStart}T00:00:00+07:00`)
        .order('id').range(offset, offset + pageSize - 1))
      shifts.push(...page)
      if (page.length < pageSize) return shifts
    }
  },
  updateWorkAssignments: (shiftId, changes, userIds) => data(supabase.rpc('manager_update_work_assignments', {
    p_shift: shiftId, p_users: userIds, p_title: changes.title, p_location: changes.location,
    p_starts_at: changes.starts_at, p_ends_at: changes.ends_at, p_cast_vnd: changes.cast_vnd
  })),
  shifts: id => data(supabase.from('company_shifts').select('*').eq('company_id', id).order('starts_at')),
  attendance: id => data(supabase.from('shift_attendance').select('*').eq('company_id',id)),
  addShiftExpense: (shiftId, expenseId, note, amount) => data(supabase.rpc('add_shift_expense', {
    p_shift: shiftId, p_id: expenseId, p_note: note, p_amount: amount
  })),
  clockIn: shiftId => data(supabase.rpc('clock_in_shift',{p_shift:shiftId})),
  clockOut: shiftId => data(supabase.rpc('clock_out_shift',{p_shift:shiftId})),
  async updateShift(id, companyId, changes) {
    const changed = await data(supabase.from('company_shifts').update(changes)
      .eq('id', id).eq('company_id', companyId).select('*'))
    if (changed?.length !== 1) throw new Error('Không thể cập nhật ca. Hãy kiểm tra quyền Manager và trạng thái chấm công.')
    return changed[0]
  },
  async notifications(userId) {
    const rows = []
    const pageSize = 200
    const cutoff = shiftNoticeCutoff(Date.now())
    for (let offset = 0; ; offset += pageSize) {
      const page = await data(supabase.from('shift_notifications')
        .select('*')
        .eq('user_id', userId).or(`event.neq.created,created_at.gt.${cutoff}`)
        .order('created_at', { ascending: false }).order('id').range(offset, offset + pageSize - 1))
      rows.push(...page)
      if (page.length < pageSize) return rows
    }
  },
  notificationShift: (item, userId) => data(supabase.from('company_shifts')
    .select('id,title,location,starts_at,ends_at')
    .eq('id', item.shift_id).eq('company_id', item.company_id).eq('user_id', userId).maybeSingle()),
  async markNotificationRead(id, userId) {
    return data(supabase.from('shift_notifications').update({read_at:new Date().toISOString()})
      .eq('id', id).eq('user_id', userId).is('read_at', null).select('id,read_at'))
  },
  async deleteShifts(ids, companyId) {
    const removed = await data(supabase.from('company_shifts').delete()
      .eq('company_id', companyId).in('id', ids).select('id'))
    if (!removed?.length) throw new Error('Không thể hủy ca. Hãy kiểm tra quyền Manager hoặc tình trạng chấm công.')
    return removed
  },
  applications: () => data(supabase.from('company_applications').select('*').order('created_at', { ascending: false })),
  freelancers: () => data(supabase.from('freelancer_profiles').select('*')),
  profile: id => data(supabase.from('freelancer_profiles').select('*').eq('user_id', id).maybeSingle()),
  async accounts() {
    const result = await supabase.rpc('admin_account_directory')
    if (!result.error) return result.data
    if (result.error.code !== 'PGRST202') throw result.error

    const accounts = await data(supabase.rpc('admin_list_accounts')) || []
    const profilesById = new Map()
    for (let offset = 0; offset < accounts.length; offset += 100) {
      const ids = accounts.slice(offset, offset + 100).map(account => account.user_id)
      let profiles = await supabase.from('profiles').select('id,full_name,birth_date,hometown,active_location').in('id', ids)
      if (['42703', 'PGRST204'].includes(profiles.error?.code)) {
        profiles = await supabase.from('profiles').select('id,full_name,hometown').in('id', ids)
      }
      if (profiles.error) throw profiles.error
      for (const profile of profiles.data || []) profilesById.set(profile.id, profile)
    }
    const dateParts = Object.fromEntries(vietnamDate.formatToParts().map(({ type, value }) => [type, value]))
    const today = `${dateParts.year}-${dateParts.month}-${dateParts.day}`
    return accounts.map(account => {
      const profile = profilesById.get(account.user_id)
      return {
        ...account,
        full_name: profile?.full_name?.trim() || account.full_name,
        age: profileAge(profile?.birth_date, today),
        hometown: profile?.hometown?.trim() || null,
        active_location: profile?.active_location?.trim() || null
      }
    })
  },
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
