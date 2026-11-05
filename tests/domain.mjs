import assert from 'node:assert/strict'
import { hours, shiftRows } from '../src/domain/calendar.js'

const input = { title: '  Lắp sân khấu  ', location: 'Nhà hát', date: '2026-11-05', end_date: '2026-11-06', start: '22:00', end: '02:00', user_ids: ['one', 'two'] }
const rows = shiftRows(input, 'company')
assert.equal(rows.length, 2)
assert.equal(rows[0].title, 'Lắp sân khấu')
assert.equal(hours(rows[0]), '4.00')
assert.throws(() => shiftRows({ ...input, user_ids: [] }, 'company'), /nhân viên/)
assert.throws(() => shiftRows({ ...input, end_date: input.date }, 'company'), /kết thúc/)
assert.throws(() => shiftRows({ ...input, location: '  ' }, 'company'), /địa điểm/)
console.log('Shift validation, multiple staff and overnight planned hours: OK')
