export const localDate = (date) => [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0')].join('-')
export const hours = (shift) => ((new Date(shift.ends_at) - new Date(shift.starts_at)) / 3600000).toFixed(2)
export const roleLabel = (role) => ({ admin: 'Quản trị hệ thống', manager: 'Manager', staff: 'Nhân viên' })[role] || 'Nhân viên'

export function shiftRows(values, companyId, existingShifts = []) {
  const users = [...new Set((values.user_ids || []).filter(Boolean))]
  if (!companyId) throw new Error('Hãy chọn công ty trước khi phân ca.')
  if (!users.length) throw new Error('Hãy chọn ít nhất một nhân viên.')
  if (!values.date || !values.start || !values.end) throw new Error('Hãy nhập đầy đủ ngày và giờ làm.')
  const start = new Date(`${values.date}T${values.start}`)
  const end = new Date(`${values.date}T${values.end}`)
  const duration = end - start
  if (!Number.isFinite(duration) || duration <= 0) throw new Error('Thời gian kết thúc phải sau thời gian bắt đầu.')
  if (duration > 24 * 3600000) throw new Error('Một ca không được dài hơn 24 giờ. Hãy chia thành nhiều ca.')
  if (!values.title?.trim() || !values.location?.trim()) throw new Error('Hãy nhập công việc và địa điểm.')
  const cast = Number(values.cast_vnd ?? 0)
  if (!Number.isInteger(cast) || cast < 0 || cast > 100000000) throw new Error('Cast phải là số tiền hợp lệ.')
  const conflict = existingShifts.find(s => users.includes(s.user_id) && start < new Date(s.ends_at) && end > new Date(s.starts_at))
  if (conflict) throw new Error('Một nhân viên đã có ca làm trùng khoảng thời gian này.')
  return users.map(user_id => ({
    company_id: companyId, user_id, title: values.title.trim(), location: values.location.trim(),
    starts_at: start.toISOString(), ends_at: end.toISOString(), cast_vnd: cast
  }))
}

// Prefer the company a person owns/manages over secondary staff memberships.
export function preferredCompanyId(companies, previousId = '') {
  const owned = companies.filter(c => c.role === 'manager')
  if (owned.length) return owned.find(c => c.id === previousId)?.id || owned[0].id
  return companies.find(c => c.id === previousId)?.id || companies[0]?.id || ''
}

/** Validate an edit without detecting the original row as an overlap. */
export function shiftUpdate(values, companyId, shiftId, existingShifts = []) {
  if (!shiftId) throw new Error('Không tìm thấy ca làm cần sửa.')
  const rows = shiftRows(values, companyId, existingShifts.filter(s => s.id !== shiftId))
  if (rows.length !== 1) throw new Error('Mỗi lần cập nhật chỉ chọn một nhân viên.')
  const { company_id, ...changes } = rows[0]
  return changes
}

/**
 * Editing one shift may also assign the same work to more employees.
 * One original row is updated (preserving its id/attendance), and each
 * additional employee receives an independent new shift row.
 * If that row has attendance, its existing employee must remain selected.
 */
export function shiftEditPlan(values, companyId, shiftId, existingShifts = [], checkedIn = false) {
  const previous = existingShifts.find(item => item.id === shiftId && item.company_id === companyId)
  if (!previous) throw new Error('Không tìm thấy ca làm cần sửa.')
  const users = [...new Set((values.user_ids || []).filter(Boolean))]
  if (!users.length) throw new Error('Hãy chọn ít nhất một nhân viên.')
  if (checkedIn && !users.includes(previous.user_id)) {
    throw new Error('Ca đã chấm công, không thể bỏ nhân viên đã được phân ca.')
  }
  const primaryUser = users.includes(previous.user_id) ? previous.user_id : users[0]
  const changes = shiftUpdate({ ...values, user_ids: [primaryUser] }, companyId, shiftId, existingShifts)
  if (checkedIn && Number(changes.cast_vnd) !== Number(previous.cast_vnd ?? 0)) {
    throw new Error('Ca đã chấm công, không thể thay đổi cast / thù lao.')
  }
  const additionalUsers = users.filter(id => id !== primaryUser)
  const addedRows = additionalUsers.length
    ? shiftRows({ ...values, user_ids: additionalUsers }, companyId, [
        ...existingShifts.filter(item => item.id !== shiftId),
        { ...previous, ...changes }
      ])
    : []
  return { changes, addedRows }
}
