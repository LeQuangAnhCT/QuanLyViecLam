export function formatWorkDuration(milliseconds) {
  const duration = Number(milliseconds)
  const totalMinutes = Number.isFinite(duration) ? Math.floor(Math.max(0, duration) / 60000) : 0
  if (duration > 0 && duration < 60000) return 'dưới 1 phút'
  const hours = Math.floor(totalMinutes / 60)
  const minutes = String(totalMinutes % 60).padStart(2, '0')
  return `${hours} giờ ${minutes} phút`
}
