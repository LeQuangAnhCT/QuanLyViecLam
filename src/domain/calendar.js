export const localDate = (date) => [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0')].join('-')
export const hours = (shift) => ((new Date(shift.ends_at) - new Date(shift.starts_at)) / 3600000).toFixed(2)
export const roleLabel = (role) => ({ admin: 'Quản trị viên', manager: 'Quản lý', staff: 'Nhân viên' })[role] || 'Nhân viên'
export function shiftRows(values, companyId) {
  if (!values.user_ids.length) throw new Error('Hãy chọn ít nhất một nhân viên.')
  const start = new Date(`${values.date}T${values.start}`)
  const end = new Date(`${values.end_date}T${values.end}`)
  if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || end <= start) throw new Error('Thời gian kết thúc phải sau thời gian bắt đầu.')
  if (!values.title.trim() || !values.location.trim()) throw new Error('Hãy nhập công việc và địa điểm.')
  return values.user_ids.map(user_id => ({ company_id: companyId, user_id, title: values.title.trim(), location: values.location.trim(), starts_at: start.toISOString(), ends_at: end.toISOString() }))
}
