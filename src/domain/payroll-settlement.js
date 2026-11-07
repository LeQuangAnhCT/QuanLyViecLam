const dayFormat = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Ho_Chi_Minh',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit'
})

export const RECEIPT_MAX_BYTES = 8 * 1024 * 1024
export const RECEIPT_TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }

export function vietnamToday(now = new Date()) {
  const parts = Object.fromEntries(
    dayFormat.formatToParts(now).map((part) => [part.type, part.value])
  )
  return `${parts.year}-${parts.month}-${parts.day}`
}

export function payrollMonth(value) {
  if (typeof value !== 'string' || !/^(20\d{2}|2100)-(0[1-9]|1[0-2])-01$/.test(value)) {
    throw new Error('Kỳ lương không hợp lệ.')
  }
  return value
}

export function movePayrollMonth(value, delta) {
  payrollMonth(value)
  const date = new Date(value + 'T00:00:00Z')
  date.setUTCMonth(date.getUTCMonth() + delta)
  return date.toISOString().slice(0, 10)
}

export function defaultPaymentMonth(now = new Date()) {
  return movePayrollMonth(vietnamToday(now).slice(0, 7) + '-01', -1)
}

export function payrollWindow(month) {
  const next = movePayrollMonth(month, 1).slice(0, 7)
  return { from: next + '-05', until: next + '-10' }
}

export function overtimeMilliseconds(shift, attendance) {
  const end = Date.parse(shift?.ends_at)
  const started = Date.parse(attendance?.checked_in_at)
  const finished = Date.parse(attendance?.checked_out_at)
  if (![end, started, finished].every(Number.isFinite)) return 0
  return Math.max(0, finished - Math.max(end, started))
}

export function moneyAmount(value) {
  const amount = Number(value ?? 0)
  if (!Number.isSafeInteger(amount) || amount < 0) throw new Error('Số tiền không hợp lệ.')
  return amount
}

export function paymentStatus(row, today = vietnamToday()) {
  if (row.pending_payment_id) return { key: 'prepared', label: 'Đã chốt, chưa trả' }
  if (Number(row.unreviewed_overtime) > 0) return { key: 'review', label: 'Cần duyệt quá giờ' }
  if (Number(row.remaining_vnd) <= 0) {
    return Number(row.paid_vnd) > 0
      ? { key: 'paid', label: 'Đã thanh toán' }
      : { key: 'empty', label: 'Chưa phát sinh' }
  }
  if (today < row.pay_from) return { key: 'not_due', label: 'Chưa đến kỳ trả' }
  if (today > row.pay_until) return { key: 'overdue', label: 'Quá hạn trả' }
  return Number(row.paid_vnd) > 0
    ? { key: 'supplement', label: 'Cần trả bổ sung' }
    : { key: 'ready', label: 'Chờ thanh toán' }
}

export function validateReceipt(file) {
  if (!file || !RECEIPT_TYPES[file.type] || !file.size || file.size > RECEIPT_MAX_BYTES) {
    throw new Error('Chọn ảnh chuyển khoản JPG, PNG hoặc WebP, tối đa 8 MB.')
  }
  return RECEIPT_TYPES[file.type]
}
