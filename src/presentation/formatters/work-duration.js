export function formatWorkDuration(milliseconds) {
  const totalSeconds = Number.isFinite(milliseconds) ? Math.floor(Math.max(0, milliseconds) / 1000) : 0
  const units = [
    [Math.floor(totalSeconds / 3600), 'giờ'],
    [Math.floor(totalSeconds % 3600 / 60), 'phút'],
    [totalSeconds % 60, 'giây']
  ]
  return units.filter(([value]) => value > 0).map(([value, unit]) => `${value} ${unit}`).join(' ') || '0 phút'
}
