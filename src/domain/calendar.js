export const localDate = (date) => [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0')].join('-')
export const hours = (shift) => ((new Date(shift.ends_at) - new Date(shift.starts_at)) / 3600000).toFixed(2)
export const effectiveShiftEnd = (shift, attendance) =>
  Date.parse(attendance?.checked_out_at) > Date.parse(shift.ends_at) ? attendance.checked_out_at : shift.ends_at

const shiftTimeFormatter = new Intl.DateTimeFormat('vi-VN', {
  timeZone: 'Asia/Ho_Chi_Minh', weekday: 'short', hour: 'numeric', minute: '2-digit', hourCycle: 'h23'
})

export function shortShiftTime(stamp) {
  const { weekday, hour, minute } = Object.fromEntries(
    shiftTimeFormatter.formatToParts(new Date(stamp)).map(({ type, value }) => [type, value])
  )
  const day = weekday.match(/\d+/)?.[0]
  const h = Number(hour)
  const period = h < 12 ? 'Sáng' : h < 18 ? 'Chiều' : 'Tối'
  return `${period} ${day ? 'T' + day : 'CN'}, ${h}h${minute === '00' ? '' : minute}`
}
export const workerRole = employmentType => employmentType === 'employee' ? 'staff' : 'freelance'
export const roleLabel = (role) => ({ admin: 'Quản trị hệ thống', manager: 'Manager', staff: 'STAFF', freelance: 'Freelance' })[role] || 'Nhân sự'

export class ShiftOverlapError extends Error {
  constructor(shift) {
    super('Một nhân viên đã có ca làm trùng khoảng thời gian này.')
    this.shift = shift
  }
}

export function shiftRows(values, companyId, existingShifts = []) {
  const users = [...new Set((values.user_ids || []).filter(Boolean))]
  if (!companyId) throw new Error('Hãy chọn công ty trước khi phân ca.')
  if (!users.length) throw new Error('Hãy chọn ít nhất một nhân viên.')
  if (!values.date || !values.start || !values.end) throw new Error('Hãy nhập đầy đủ ngày và giờ làm.')
  const start = new Date(`${values.date}T${values.start}`)
  const end = new Date(`${values.end_date || values.date}T${values.end}`)
  const duration = end - start
  if (!Number.isFinite(duration) || duration <= 0) throw new Error('Thời gian kết thúc phải sau thời gian bắt đầu.')
  if (duration > 24 * 3600000) throw new Error('Một ca không được dài hơn 24 giờ. Hãy chia thành nhiều ca.')
  if (!values.title?.trim() || !values.location?.trim()) throw new Error('Hãy nhập công việc và địa điểm.')
  const cast = Number(values.cast_vnd ?? 0)
  if (!Number.isInteger(cast) || cast < 0 || cast > 100000000) throw new Error('Cast phải là số tiền hợp lệ.')
  const conflict = existingShifts.find(s => users.includes(s.user_id) && start < new Date(s.ends_at) && end > new Date(s.starts_at))
  if (conflict) throw new ShiftOverlapError(conflict)
  return users.map(user_id => ({
    company_id: companyId, user_id, title: values.title.trim(), location: values.location.trim(),
    starts_at: start.toISOString(), ends_at: end.toISOString(), cast_vnd: cast
  }))
}

// Prefer the company a person owns/manages over secondary staff memberships.
export function preferredCompanyId(companies, previousId = '') {
  return companies.find(c => c.id === previousId)?.id
    || companies.find(c => c.role === 'manager')?.id || companies[0]?.id || ''
}

/** Validate an edit without detecting the original row as an overlap. */
export function shiftUpdate(values, companyId, shiftId, existingShifts = []) {
  if (!shiftId) throw new Error('Không tìm thấy ca làm cần sửa.')
  const rows = shiftRows(values, companyId, existingShifts.filter(s => s.id !== shiftId))
  if (rows.length !== 1) throw new Error('Mỗi lần cập nhật chỉ chọn một nhân viên.')
  const { company_id, ...changes } = rows[0]
  return changes
}

/** Existing assignment rows share a work slot until grouped IDs are introduced. */
export function sameWorkSlot(a,b) {
  return a.company_id===b.company_id && a.title===b.title &&
    (a.location || '')===(b.location || '') &&
    a.starts_at===b.starts_at && a.ends_at===b.ends_at &&
    Number(a.cast_vnd || 0)===Number(b.cast_vnd || 0)
}
export function shiftEditPlan(values, companyId, shiftId, existingShifts = [], clockedShiftIds = []) {
  const original = existingShifts.find(s=>s.id===shiftId && s.company_id===companyId)
  if (!original) throw new Error('Không tìm thấy ca làm cần sửa.')
  const group=existingShifts.filter(s=>sameWorkSlot(s,original))
  const groupedIds=new Set(group.map(s=>s.id))
  const selectedIds=[...new Set((values.user_ids || []).filter(Boolean))]
  if (!selectedIds.length) throw new Error('Hãy chọn ít nhất một nhân viên.')
  const clocked=new Set(clockedShiftIds)
  if(group.some(s=>clocked.has(s.id)&&!selectedIds.includes(s.user_id))) {
    throw new Error('Không thể bỏ nhân viên đã chấm công khỏi công việc.')
  }
  const targetRows=shiftRows(values,companyId,existingShifts.filter(s=>!groupedIds.has(s.id)))
  if(group.some(s=>clocked.has(s.id)&&(
     s.starts_at!==targetRows[0].starts_at ||
     s.ends_at!==targetRows[0].ends_at ||
     Number(s.cast_vnd || 0)!==Number(targetRows[0].cast_vnd || 0)))) {
    throw new Error('Ca đã chấm công, không thể thay giờ hoặc Cast.')
  }
  const updates=[],addedRows=[]
  for(const row of targetRows){
    const old=group.find(s=>s.user_id===row.user_id)
    if(old){ const {company_id,...changes}=row; updates.push({id:old.id,changes}) }
    else addedRows.push(row)
  }
  const removedIds=group.filter(s=>!selectedIds.includes(s.user_id)).map(s=>s.id)
  return {updates,addedRows,removedIds,group}
}
