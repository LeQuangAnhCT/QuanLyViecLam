export const localDate = (date) => [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0')].join('-')
export const hours = (shift) => ((new Date(shift.ends_at) - new Date(shift.starts_at)) / 3600000).toFixed(2)
export const roleLabel = (role) => ({ admin: 'Quản trị hệ thống', manager: 'Quản lý công ty', staff: 'Nhân viên' })[role] || 'Nhân viên'

export function shiftRows(values, companyId, existingShifts = []) {
  const users = [...new Set((values.user_ids || []).filter(Boolean))]
  if (!companyId) throw new Error('Hãy chọn công ty trước khi phân ca.')
  if (!users.length) throw new Error('Hãy chọn ít nhất một nhân viên.')
  if (!values.date || !values.end_date || !values.start || !values.end) throw new Error('Hãy nhập đầy đủ ngày và giờ làm.')
  const start = new Date(`${values.date}T${values.start}`)
  const end = new Date(`${values.end_date}T${values.end}`)
  const duration = end - start
  if (!Number.isFinite(duration) || duration <= 0) throw new Error('Thời gian kết thúc phải sau thời gian bắt đầu.')
  if (duration > 24 * 3600000) throw new Error('Một ca không được dài hơn 24 giờ. Hãy chia thành nhiều ca.')
  if (!values.title?.trim() || !values.location?.trim()) throw new Error('Hãy nhập công việc và địa điểm.')
  const conflict = existingShifts.find(s => users.includes(s.user_id) && start < new Date(s.ends_at) && end > new Date(s.starts_at))
  if (conflict) throw new Error('Một nhân viên đã có ca làm trùng khoảng thời gian này.')
  return users.map(user_id => ({
    company_id: companyId, user_id, title: values.title.trim(), location: values.location.trim(),
    starts_at: start.toISOString(), ends_at: end.toISOString()
  }))
}

// Prefer the company a person owns/manages over secondary staff memberships.
export function preferredCompanyId(companies, previousId = '') {
  if (companies.some(c => c.id === previousId)) return previousId
  return companies.find(c => c.role === 'manager')?.id || companies[0]?.id || ''
}
