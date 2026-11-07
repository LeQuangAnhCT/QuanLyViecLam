import { ref, watch, onScopeDispose } from 'vue'
import { payrollRepository } from '../infrastructure/payrollRepository'
import { payrollErrorText } from './payroll-errors'
import { moneyAmount } from '../domain/payroll-settlement'

export function useOvertimeAllowance(context, onChanged) {
  const target = ref(null)
  const amount = ref('')
  const note = ref('')
  const saving = ref(false)
  const error = ref('')
  let request = null
  let generation = 0
  let disposed = false

  function open(row) {
    if (saving.value || ['prepared', 'paid'].includes(row.locked_status)) return
    target.value = row
    amount.value = row.allowance_vnd ?? ''
    note.value = row.note || ''
    error.value = ''
    request = null
  }
  function close() {
    if (saving.value) return false
    target.value = null
    error.value = ''
    return true
  }
  async function save() {
    if (saving.value || !target.value) return false
    const current = generation,
      shift = target.value.shift_id,
      text = note.value.trim()
    let value
    try {
      if (amount.value === '') throw new Error('Nhập số tiền phụ cấp bù quá giờ.')
      value = moneyAmount(amount.value)
      if (value > 1000000000) throw new Error('Phụ cấp mỗi ca không vượt quá 1.000.000.000 ₫.')
      if (text.length > 500 || (value === 0 && text.length < 3))
        throw new Error('Nếu bù 0 ₫, hãy ghi rõ lý do (ít nhất 3 ký tự).')
    } catch (failure) {
      error.value = failure.message
      return false
    }
    if (!request || request.shift !== shift || request.amount !== value || request.note !== text) {
      request = { shift, amount: value, note: text, id: crypto.randomUUID() }
    }
    saving.value = true
    error.value = ''
    try {
      await payrollRepository.approveOvertime(shift, value, text, request.id)
      if (disposed || generation !== current) return true
      target.value = null
      request = null
      await onChanged()
      return true
    } catch (failure) {
      if (!disposed && generation === current) error.value = payrollErrorText(failure)
      return false
    } finally {
      if (!disposed && generation === current) saving.value = false
    }
  }
  watch(
    context,
    () => {
      generation++
      target.value = null
      saving.value = false
      error.value = ''
      request = null
    },
    { flush: 'sync' }
  )
  onScopeDispose(() => {
    disposed = true
    generation++
  })
  return { target, amount, note, saving, error, open, close, save }
}
