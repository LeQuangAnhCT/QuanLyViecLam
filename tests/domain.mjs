import assert from 'node:assert/strict'
import { noticeHasExpired, noticeIsPast, shiftNoticeSnapshot } from '../src/domain/notifications.js'
import { effectiveShiftEnd, shortShiftTime } from '../src/domain/calendar.js'
import { legacyPayrollRows } from '../src/domain/payroll.js'
import { hours, shiftRows, roleLabel, workerRole, preferredCompanyId, shiftUpdate, shiftEditPlan, sameWorkSlot, ShiftOverlapError } from '../src/domain/calendar.js'

const input = { title: '  Lắp sân khấu  ', location: 'Nhà hát', date: '2026-11-05', end_date: '2026-11-05', start: '08:00', end: '12:00', cast_vnd: 300000, user_ids: ['one', 'two'] }
const rows = shiftRows(input, 'company')
assert.equal(rows.length, 2)
assert.equal(rows[0].title, 'Lắp sân khấu')
assert.equal(hours(rows[0]), '4.00')
assert.equal(roleLabel('admin'), 'Quản trị hệ thống')
assert.equal(roleLabel('manager'), 'Manager')
assert.equal(roleLabel(workerRole('employee')), 'STAFF')
assert.equal(roleLabel(workerRole('freelancer')), 'Freelance')
assert.equal(workerRole(), 'freelance')
assert.throws(() => shiftRows({ ...input, user_ids: [] }, 'company'), /nhân viên/)
assert.throws(() => shiftRows({ ...input, end: '07:00' }, 'company'), /kết thúc/)
assert.throws(() => shiftRows({ ...input, location: '  ' }, 'company'), /địa điểm/)
assert.throws(() => shiftRows({ ...input, cast_vnd: -1 }, 'company'), /Cast/)
assert.throws(() => shiftRows(input, ''), /công ty/)
assert.equal(shiftRows({ ...input, user_ids: ['one','one','two'] }, 'company').length, 2)
const existing = [{ ...rows[0], id: 'existing' }]
assert.throws(() => shiftRows(input, 'company', existing), error =>
  error instanceof ShiftOverlapError && error.shift === existing[0])
assert.doesNotThrow(() => shiftRows({ ...input, start: '12:00', end: '13:00' }, 'company', existing))
assert.doesNotThrow(() => shiftRows({ ...input, date: '2026-11-06', end_date: '2026-11-06', start: '02:00', end: '04:00' }, 'company', existing))
assert.equal(hours(shiftRows({ ...input, end_date: '2026-11-06', start: '22:00', end: '02:00' }, 'company')[0]), '4.00')
assert.equal(preferredCompanyId([{id:'staff-company',role:'staff'},{id:'owner-company',role:'manager'}]),'owner-company')
assert.equal(preferredCompanyId([{id:'staff-company',role:'staff'},{id:'owner-company',role:'manager'}],'staff-company'),'staff-company')
assert.equal(preferredCompanyId([]),'')
const current = { ...rows[0], id: 'one-shift' }
const changed = shiftUpdate({...input, user_ids:['one'], title:' Chương trình mới '}, 'company','one-shift',[current])
assert.equal(changed.title,'Chương trình mới')
assert.equal(changed.user_id,'one')
assert.throws(()=>shiftUpdate({...input,user_ids:['one','two']},'company','one-shift',[current]),/một nhân viên/)
assert.throws(()=>shiftUpdate({...input,user_ids:['one']},'company','one-shift',[current,{...rows[1], user_id:'one', id:'another'}]),/trùng/)
assert.equal(rows[0].cast_vnd,300000)

const group = [{...rows[0],id:'shift-a'},{...rows[1],id:'shift-b'}]
assert.equal(sameWorkSlot(group[0],group[1]),true)
const crewPlan = shiftEditPlan({...input,user_ids:['one','two','three']},'company','shift-a',group)
assert.equal(crewPlan.updates.length,2)
assert.deepEqual(crewPlan.addedRows.map(x=>x.user_id),['three'])
assert.deepEqual(crewPlan.removedIds,[])
const clockedPlan = shiftEditPlan({...input,user_ids:['one','two','three']},'company','shift-a',group,['shift-a'])
assert.equal(clockedPlan.addedRows.length,1)
assert.throws(()=>shiftEditPlan({...input,user_ids:['two']},'company','shift-a',group,['shift-a']),/đã chấm công/)
assert.throws(()=>shiftEditPlan({...input,cast_vnd:400000},'company','shift-a',group,['shift-a']),/Cast/)
const removedPlan = shiftEditPlan({...input,user_ids:['one']},'company','shift-a',group)
assert.deepEqual(removedPlan.removedIds,['shift-b'])

const [legacyRow] = legacyPayrollRows(
  [{ user_id: 'one', monthly_base_vnd: '5000000', estimated_total_vnd: 5000000 }],
  [
    { user_id: 'one', cast_vnd: '500000', shift_attendance: { checked_in_at: '2026-11-06T01:00:00Z', checked_out_at: '2026-11-06T05:00:00Z' } },
    { user_id: 'one', cast_vnd: 400000, shift_attendance: { checked_in_at: '2026-11-06T06:00:00Z', checked_out_at: null } },
    { user_id: 'other', cast_vnd: 300000, shift_attendance: null }
  ],
  [{ user_id: 'one', monthly_base_vnd: '5000000' }]
)
assert.equal(legacyRow.planned_cast_vnd, 900000)
assert.equal(legacyRow.cast_total_vnd, 500000)
assert.equal(legacyRow.completed_shifts, 1)
assert.equal(legacyRow.worked_hours, 4)
assert.equal(legacyRow.monthly_allowance_vnd, 0)
assert.equal(legacyRow.estimated_total_vnd, 5500000)

const now = Date.parse('2026-11-06T12:00:00+07:00')
assert.equal(shortShiftTime('2026-11-07T08:00:00+07:00'), 'Sáng T7, 8h')
assert.equal(shortShiftTime('2026-11-07T19:30:00+07:00'), 'Tối T7, 19h30')
const plannedEnd = { ends_at: '2026-11-07T12:00:00+07:00' }
assert.equal(effectiveShiftEnd(plannedEnd, { checked_out_at:'2026-11-07T11:00:00+07:00' }), plannedEnd.ends_at)
assert.equal(effectiveShiftEnd(plannedEnd, { checked_out_at:'2026-11-08T01:00:00+07:00' }), '2026-11-08T01:00:00+07:00')
const oldNotice = { event: 'created', created_at: '2026-10-30T12:00:00+07:00' }
assert.equal(noticeHasExpired(oldNotice, now), true)
assert.equal(noticeHasExpired({ ...oldNotice, event: 'cancelled' }, now), false)
assert.equal(noticeHasExpired({ ...oldNotice, event: 'updated' }, now), false)
assert.equal(noticeHasExpired({ ...oldNotice, event: 'employment_changed' }, now), false)
assert.equal(noticeIsPast({ event:'cancelled', created_at:new Date(now).toISOString() }, null, now), false)
assert.equal(noticeIsPast({ event:'employment_changed', created_at:new Date(now).toISOString() }, null, now), false)
assert.equal(noticeIsPast({ ...oldNotice, event:'employment_changed' }, null, now), true)
const nightShift = shiftNoticeSnapshot({ body: 'Vận hành âm thanh · Hội trường · Sảnh A · 06/11/2026 22:00 đến 07/11/2026 02:00' })
assert.equal(nightShift.location, 'Hội trường · Sảnh A')
assert.equal(nightShift.ends_at, '2026-11-07T02:00:00+07:00')
assert.equal(noticeIsPast(oldNotice, nightShift, now), false)
assert.equal(noticeIsPast({ ...oldNotice, event: 'cancelled' }, nightShift, now), true)
assert.equal(noticeIsPast(oldNotice, nightShift, Date.parse(nightShift.ends_at)), true)

console.log('Shift rules, roles, legacy payroll and notification retention: OK')
