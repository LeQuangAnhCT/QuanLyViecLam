const moneyFormat = new Intl.NumberFormat('vi-VN')
const monthFormat = new Intl.DateTimeFormat('vi-VN', {
  timeZone: 'UTC',
  month: 'long',
  year: 'numeric'
})
const dateFormat = new Intl.DateTimeFormat('vi-VN', {
  timeZone: 'Asia/Ho_Chi_Minh',
  dateStyle: 'short'
})

export const payrollMoney = (value) =>
  Number.isFinite(Number(value)) ? `${moneyFormat.format(Number(value))} ₫` : 'Chưa có'
export const payrollMonthLabel = (month) => monthFormat.format(new Date(month + 'T00:00:00Z'))
export const payrollDate = (stamp) =>
  stamp ? dateFormat.format(new Date(stamp.length === 10 ? stamp + 'T12:00:00+07:00' : stamp)) : ''
