export function completedShiftCast(shift, attendance) {
  return Number(shift.cast_vnd ?? 0) + Number(attendance?.expense_total_vnd ?? 0)
}

export function legacyPayrollRows(rows, assignments, compensation) {
  const totals = new Map(rows.map(row => [row.user_id, {
    scheduled: 0, completed: 0, workedMs: 0, plannedCast: 0, completedCast: 0
  }]))
  const payByUser = new Map(compensation.map(pay => [pay.user_id, pay]))

  for (const assignment of assignments) {
    const total = totals.get(assignment.user_id)
    if (!total) continue
    const cast = Number(assignment.cast_vnd ?? 0)
    total.scheduled++
    total.plannedCast += cast
    const attendance = assignment.shift_attendance
    if (attendance?.checked_out_at) {
      total.completed++
      total.completedCast += completedShiftCast(assignment, attendance)
      total.workedMs += Date.parse(attendance.checked_out_at) - Date.parse(attendance.checked_in_at)
    }
  }

  return rows.map(row => {
    const total = totals.get(row.user_id)
    const pay = payByUser.get(row.user_id)
    const base = pay ? pay.monthly_base_vnd : row.monthly_base_vnd
    const allowance = Number(pay?.monthly_allowance_vnd ?? row.monthly_allowance_vnd ?? 0)
    return {
      ...row,
      monthly_base_vnd: base,
      monthly_allowance_vnd: allowance,
      scheduled_shifts: total.scheduled,
      completed_shifts: total.completed,
      worked_hours: Math.round(total.workedMs / 36000) / 100,
      planned_cast_vnd: total.plannedCast,
      cast_total_vnd: total.completedCast,
      estimated_total_vnd: Number(base ?? 0) + allowance + total.completedCast
    }
  })
}
