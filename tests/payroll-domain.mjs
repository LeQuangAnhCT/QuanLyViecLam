import assert from 'node:assert/strict'
import {
  payrollMonth,
  movePayrollMonth,
  defaultPaymentMonth,
  payrollWindow,
  overtimeMilliseconds,
  moneyAmount,
  paymentStatus,
  validateReceipt
} from '../src/domain/payroll-settlement.js'

assert.equal(payrollMonth('2026-10-01'), '2026-10-01')
for (const bad of ['2026-10-07', '2026-13-01', '1999-12-01', 'October 2026', ''])
  assert.throws(() => payrollMonth(bad))
assert.equal(movePayrollMonth('2026-01-01', -1), '2025-12-01')
assert.equal(movePayrollMonth('2026-12-01', 1), '2027-01-01')
assert.deepEqual(payrollWindow('2026-12-01'), { from: '2027-01-05', until: '2027-01-10' })
assert.equal(defaultPaymentMonth(new Date('2026-11-01T00:00:00+07:00')), '2026-10-01')
assert.equal(
  overtimeMilliseconds(
    { ends_at: '2026-11-07T12:00:00+07:00' },
    { checked_in_at: '2026-11-07T08:00:00+07:00', checked_out_at: '2026-11-07T13:30:00+07:00' }
  ),
  5400000
)
assert.equal(
  overtimeMilliseconds(
    { ends_at: '2026-11-07T12:00:00+07:00' },
    { checked_in_at: '2026-11-07T13:00:00+07:00', checked_out_at: '2026-11-07T13:30:00+07:00' }
  ),
  1800000
)
assert.equal(
  overtimeMilliseconds(
    { ends_at: '2026-11-07T12:00:00+07:00' },
    { checked_in_at: '2026-11-07T08:00:00+07:00', checked_out_at: null }
  ),
  0
)
assert.equal(
  overtimeMilliseconds(
    { ends_at: '2026-11-07T12:00:00+07:00' },
    { checked_in_at: '2026-11-07T08:00:00+07:00', checked_out_at: '2026-11-07T11:30:00+07:00' }
  ),
  0
)
for (const bad of [-1, 'NaN', Infinity, 0.1, Number.MAX_SAFE_INTEGER + 1])
  assert.throws(() => moneyAmount(bad))
assert.equal(moneyAmount('9100000'), 9100000)
const row = {
  remaining_vnd: 9100000,
  paid_vnd: 0,
  pay_from: '2026-11-05',
  pay_until: '2026-11-10',
  unreviewed_overtime: 0
}
assert.equal(paymentStatus(row, '2026-11-04').key, 'not_due')
assert.equal(paymentStatus(row, '2026-11-05').key, 'ready')
assert.equal(paymentStatus(row, '2026-11-11').key, 'overdue')
assert.equal(paymentStatus({ ...row, unreviewed_overtime: 1 }, '2026-11-07').key, 'review')
assert.equal(
  paymentStatus(
    { ...row, remaining_vnd: 0, paid_vnd: 9100000, unreviewed_overtime: 1 },
    '2026-11-07'
  ).key,
  'review'
)
assert.equal(
  paymentStatus({ ...row, pending_payment_id: 'pending', unreviewed_overtime: 1 }, '2026-11-07')
    .key,
  'prepared'
)
assert.equal(
  paymentStatus({ ...row, remaining_vnd: 0, paid_vnd: 9100000 }, '2026-11-07').key,
  'paid'
)
assert.equal(validateReceipt({ type: 'image/png', size: 50000 }), 'png')
assert.throws(() => validateReceipt({ type: 'image/svg+xml', size: 50000 }))
assert.throws(() => validateReceipt({ type: 'image/png', size: 9 * 1024 * 1024 }))
console.log('Payroll dates, real overtime intervals, currency safety and settlement states: OK')
