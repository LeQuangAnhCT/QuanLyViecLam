// Browser-only payroll fixtures. Never imported by production entry points.
import { payrollWindow, vietnamToday, validateReceipt } from '../../src/domain/payroll-settlement'

const key = 'shiftly:test:payroll-v1'
const image =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1cAAAAASUVORK5CYII='
const copy = (value) => structuredClone(value)
const fail = (code, message) => {
  throw Object.assign(new Error(message), { code })
}

export function installPayrollFixture(api, { user, role, notifications, reset = false }) {
  if (reset) localStorage.removeItem(key)
  let state
  try {
    state = JSON.parse(localStorage.getItem(key))
  } catch {
    /* Fresh fixture. */
  }
  if (!state) state = { payments: [], overtime: {}, images: {} }
  const save = () => localStorage.setItem(key, JSON.stringify(state))
  const manager = (company) => role === 'manager' && company === 'company'
  const people = (company) =>
    company === 'company-2'
      ? [
          {
            user_id: user.id,
            full_name: 'Nguyễn An',
            email: user.email,
            employment_type: 'freelancer',
            monthly_base_vnd: 0,
            monthly_allowance_vnd: 0,
            cast: 380000,
            expense: 30000
          }
        ]
      : [
          {
            user_id: 'staff',
            full_name: 'Lê Mai',
            email: 'mai@example.test',
            employment_type: 'employee',
            monthly_base_vnd: 8000000,
            monthly_allowance_vnd: 200000,
            cast: 500000,
            expense: 100000
          },
          {
            user_id: 'contractor',
            full_name: 'Trần Quỳnh Nhi',
            email: 'nhi@example.test',
            employment_type: 'freelancer',
            monthly_base_vnd: 0,
            monthly_allowance_vnd: 100000,
            cast: 400000,
            expense: 50000
          }
        ]
  function overtimeRows(company, month) {
    const id = company + '/' + month
    if (!state.overtime[id])
      state.overtime[id] = people(company).map((person, index) => ({
        shift_id: `overtime-${company}-${person.user_id}-${month}`,
        company_id: company,
        pay_month: month,
        user_id: person.user_id,
        full_name: person.full_name,
        title: index ? 'Vận hành ánh sáng' : 'Lắp đặt âm thanh',
        location: 'Trung tâm hội nghị Đà Nẵng',
        starts_at: month.slice(0, 7) + '-20T01:00:00Z',
        planned_ends_at: month.slice(0, 7) + '-20T05:00:00Z',
        checked_in_at: month.slice(0, 7) + '-20T01:00:00Z',
        checked_out_at: month.slice(0, 7) + (index ? '-20T05:45:00Z' : '-20T06:30:00Z'),
        overtime_ms: index ? 2700000 : 5400000,
        allowance_vnd: null,
        note: '',
        approved_at: null,
        locked_by_payment_id: null,
        locked_status: null
      }))
    return state.overtime[id]
  }
  function summarize(company, month) {
    const window = payrollWindow(month)
    return people(company)
      .filter((person) => manager(company) || person.user_id === user.id)
      .map((person) => {
        const records = state.payments.filter(
          (payment) =>
            payment.company_id === company &&
            payment.user_id === person.user_id &&
            payment.pay_month === month
        )
        const paid = records.filter((payment) => payment.status === 'paid')
        const prepared = records.find((payment) => payment.status === 'prepared')
        const fixed = paid[0] || prepared
        const overtime = overtimeRows(company, month).filter(
          (row) => row.user_id === person.user_id
        )
        const extra = overtime.reduce((total, row) => total + Number(row.allowance_vnd || 0), 0)
        const base = fixed?.snapshot.monthly_base_vnd ?? person.monthly_base_vnd
        const allowance = fixed?.snapshot.monthly_allowance_vnd ?? person.monthly_allowance_vnd
        const earned = base + allowance + person.cast + person.expense + extra
        const paidTotal = paid.reduce((total, payment) => total + payment.amount_vnd, 0)
        return {
          ...person,
          company_id: company,
          company_name: company === 'company' ? 'Âm thanh Ánh sáng Việt' : 'Sân khấu Phương Nam',
          pay_month: month,
          monthly_base_vnd: base,
          monthly_allowance_vnd: allowance,
          scheduled_shifts: person.user_id === 'staff' ? 2 : 1,
          completed_shifts: 1,
          worked_ms: 14400000 + (overtime[0]?.overtime_ms || 0),
          completed_shift_ms: 14400000,
          planned_cast_vnd: person.cast * 2,
          shift_cast_vnd: person.cast,
          expense_vnd: person.expense,
          overtime_ms: overtime.reduce((total, row) => total + row.overtime_ms, 0),
          overtime_allowance_vnd: extra,
          unreviewed_overtime: overtime.filter((row) => row.allowance_vnd == null).length,
          earned_vnd: earned,
          paid_vnd: paidTotal,
          remaining_vnd: Math.max(0, earned - paidTotal),
          payment_count: paid.length,
          pending_payment_id: prepared?.id || null,
          pending_amount_vnd: prepared?.amount_vnd || null,
          snapshotted: !!fixed,
          pay_from: window.from,
          pay_until: window.until,
          server_today: vietnamToday()
        }
      })
  }
  if (!state.seeded) {
    for (let index = 0; index < 12; index++) {
      const date = new Date(vietnamToday().slice(0, 7) + '-01T00:00:00Z')
      date.setUTCMonth(date.getUTCMonth() - 2 - index)
      const month = date.toISOString().slice(0, 10)
      const window = payrollWindow(month)
      const person = people('company')[0]
      const id = `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`
      const path = 'fixture-history/' + id + '.png'
      state.images[path] = image
      state.payments.push({
        id,
        company_id: 'company',
        user_id: 'staff',
        pay_month: month,
        status: 'paid',
        amount_vnd: 8850000,
        paid_before_vnd: 0,
        snapshot: {
          ...person,
          company_name: 'Âm thanh Ánh sáng Việt',
          pay_month: month,
          shift_cast_vnd: 500000,
          expense_vnd: 100000,
          overtime_allowance_vnd: 50000,
          earned_vnd: 8850000,
          pay_from: window.from,
          pay_until: window.until
        },
        receipt_path: path,
        transfer_date: window.from,
        paid_at: window.from + 'T08:30:00Z',
        created_at: window.from + 'T08:00:00Z',
        note: 'Dữ liệu kiểm thử',
        created_by: 'manager',
        paid_by: 'manager'
      })
    }
    state.seeded = true
    save()
  }
  function salaryNotice(payment) {
    return {
      id: 'salary-' + payment.id,
      user_id: payment.user_id,
      company_id: payment.company_id,
      event: 'payroll_paid',
      title: 'Đã thanh toán lương tháng ' + payment.pay_month.slice(0, 7),
      body: 'Khoản lương đã được ghi nhận kèm ảnh chuyển khoản.',
      payroll_payment_id: payment.id,
      created_at: payment.paid_at,
      read_at: null
    }
  }
  for (const payment of state.payments.filter(
    (item) => item.status === 'paid' && item.user_id === user.id && item.note !== 'Dữ liệu kiểm thử'
  )) {
    notifications.unshift(salaryNotice(payment))
  }
  Object.assign(api, {
    summary: async (company, month) => {
      if (role === 'admin') fail('P4550', 'Không có quyền')
      return copy(summarize(company, month))
    },
    overtime: async (company, month) =>
      copy(
        overtimeRows(company, month).filter((row) => manager(company) || row.user_id === user.id)
      ),
    approveOvertime: async (shift, amount, note, request) => {
      const row = Object.values(state.overtime)
        .flat()
        .find((row) => row.shift_id === shift)
      if (!row || !manager(row.company_id)) fail('P4550', 'Chỉ Manager duyệt')
      if (row.request_id === request) return copy(row)
      if (['prepared', 'paid'].includes(row.locked_status)) fail('P4555', 'Phụ cấp đã chốt')
      if (amount < 0 || (amount === 0 && note.trim().length < 3)) fail('P4558', 'Thiếu lý do')
      Object.assign(row, {
        allowance_vnd: amount,
        note,
        request_id: request,
        approved_at: new Date().toISOString()
      })
      save()
      return copy(row)
    },
    prepare: async (company, person, month, id) => {
      if (!manager(company)) fail('P4550', 'Chỉ Manager chốt')
      const previous = state.payments.find((payment) => payment.id === id)
      if (previous && previous.status !== 'cancelled') return copy(previous)
      const existing = state.payments.find(
        (payment) =>
          payment.company_id === company &&
          payment.user_id === person &&
          payment.pay_month === month &&
          payment.status === 'prepared'
      )
      if (existing) return copy(existing)
      const row = summarize(company, month).find((row) => row.user_id === person)
      if (vietnamToday() < row.pay_from) fail('P4553', 'Chưa đến ngày trả')
      if (row.unreviewed_overtime) fail('P4554', 'Chưa duyệt quá giờ')
      if (!row.remaining_vnd) fail('P4552', 'Đã trả đủ')
      const payment = {
        id,
        company_id: company,
        user_id: person,
        pay_month: month,
        status: 'prepared',
        amount_vnd: row.remaining_vnd,
        paid_before_vnd: row.paid_vnd,
        snapshot: copy(row),
        created_by: user.id,
        created_at: new Date().toISOString()
      }
      state.payments.push(payment)
      for (const extra of overtimeRows(company, month).filter(
        (extra) => extra.user_id === person && !['prepared', 'paid'].includes(extra.locked_status)
      ))
        Object.assign(extra, { locked_by_payment_id: id, locked_status: 'prepared' })
      save()
      return copy(payment)
    },
    uploadReceipt: async (payment, file, imageId) => {
      const extension = validateReceipt(file)
      const path = `${payment.company_id}/${payment.user_id}/${payment.id}/${imageId}.${extension}`
      const uri = await new Promise((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(reader.result)
        reader.onerror = reject
        reader.readAsDataURL(file)
      })
      state.images[path] = uri
      save()
      return path
    },
    finalize: async (id, path, transferDate, note) => {
      const payment = state.payments.find((payment) => payment.id === id)
      if (!payment || !manager(payment.company_id)) fail('P4550', 'Không có quyền')
      if (payment.status === 'paid') return copy(payment)
      if (payment.status !== 'prepared') fail('P4555', 'Bảng đã hủy')
      if (!state.images[path]) fail('P4557', 'Chưa có ảnh')
      if (transferDate < payment.snapshot.pay_from || transferDate > vietnamToday())
        fail('P4553', 'Ngày không hợp lệ')
      Object.assign(payment, {
        status: 'paid',
        receipt_path: path,
        transfer_date: transferDate,
        note,
        paid_by: user.id,
        paid_at: new Date().toISOString()
      })
      for (const row of Object.values(state.overtime)
        .flat()
        .filter((row) => row.locked_by_payment_id === id))
        row.locked_status = 'paid'
      notifications.unshift(salaryNotice(payment))
      save()
      return copy(payment)
    },
    cancel: async (id) => {
      const payment = state.payments.find((payment) => payment.id === id)
      if (!payment || !manager(payment.company_id)) fail('P4550', 'Không có quyền')
      if (payment.status === 'paid') fail('P4555', 'Khoản đã trả')
      payment.status = 'cancelled'
      for (const row of Object.values(state.overtime)
        .flat()
        .filter((row) => row.locked_by_payment_id === id))
        Object.assign(row, { locked_by_payment_id: null, locked_status: null })
      save()
    },
    history: async (company, month, page = 1, limit = 10) => {
      const records = state.payments
        .filter(
          (payment) =>
            payment.status === 'paid' &&
            (!company || payment.company_id === company) &&
            (!month || payment.pay_month === month) &&
            ((company && manager(company)) || payment.user_id === user.id)
        )
        .sort((a, b) => b.paid_at.localeCompare(a.paid_at))
      return copy({ rows: records.slice((page - 1) * limit, page * limit), total: records.length })
    },
    payment: async (id) => {
      const payment = state.payments.find(
        (payment) => payment.id === id && payment.status === 'paid'
      )
      return payment && (payment.user_id === user.id || manager(payment.company_id))
        ? copy(payment)
        : null
    },
    receiptUrl: async (path) => state.images[path],
    removeUnusedReceipt: async (path) => {
      if (
        !state.payments.some(
          (payment) => payment.status === 'paid' && payment.receipt_path === path
        )
      )
        delete state.images[path]
      save()
    }
  })
}
