const sevenDaysMs = 7 * 24 * 60 * 60 * 1000
const shiftEvents = new Set(['created', 'updated', 'cancelled'])

export const isShiftNotification = item => shiftEvents.has(item.event)
export const shiftNoticeCutoff = now => new Date(now - sevenDaysMs).toISOString()
export const noticeHasExpired = (item, now) => item.event === 'created'
  && Date.parse(item.created_at) <= now - sevenDaysMs

function vietnamTimestamp(date, time) {
  const [day, month, year] = date.split('/')
  return `${year}-${month}-${day}T${time}:00+07:00`
}

export function shiftNoticeSnapshot(item) {
  const parts = item.body?.split(' · ')
  if (!parts || parts.length < 3) return null
  const range = parts.pop().match(/^(\d{2}\/\d{2}\/\d{4}) (\d{2}:\d{2}) đến (\d{2}\/\d{2}\/\d{4}) (\d{2}:\d{2})$/)
  if (!range) return null
  const starts_at = vietnamTimestamp(range[1], range[2])
  const ends_at = vietnamTimestamp(range[3], range[4])
  if (!Number.isFinite(Date.parse(starts_at)) || !Number.isFinite(Date.parse(ends_at))) return null
  return { title: parts.shift(), location: parts.join(' · '), starts_at, ends_at }
}

export function noticeIsPast(item, shift, now) {
  if (item.event === 'company_application') return false
  if (item.event === 'cancelled' || item.event === 'employment_changed') {
    return Date.parse(item.created_at) <= now - sevenDaysMs
  }
  return shift ? Date.parse(shift.ends_at) <= now : Date.parse(item.created_at) <= now - sevenDaysMs
}
