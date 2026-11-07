import { ref, onScopeDispose, watch } from 'vue'
import { payrollRepository } from '../infrastructure/payrollRepository'
import { validateReceipt, vietnamToday } from '../domain/payroll-settlement'
import { payrollErrorText } from './payroll-errors'

export function usePayrollPayment(companyId, month, onPaid) {
  const payment = ref(null)
  const preparing = ref('')
  const saving = ref(false)
  const error = ref('')
  const file = ref(null)
  const preview = ref('')
  const transferDate = ref(vietnamToday())
  const note = ref('')
  let imageId = ''
  let uploadedPath = ''
  let generation = 0
  let disposed = false
  let prepareKey = null

  function clearImage() {
    if (preview.value) URL.revokeObjectURL(preview.value)
    preview.value = ''
    file.value = null
    imageId = ''
    uploadedPath = ''
  }

  async function open(person) {
    if (preparing.value || saving.value) return false
    const current = ++generation
    const id = companyId.value,
      period = month.value
    preparing.value = person.user_id
    error.value = ''
    clearImage()
    if (
      !prepareKey ||
      prepareKey.company !== id ||
      prepareKey.month !== period ||
      prepareKey.user !== person.user_id
    ) {
      prepareKey = { company: id, month: period, user: person.user_id, id: crypto.randomUUID() }
    }
    try {
      const result = await payrollRepository.prepare(id, person.user_id, period, prepareKey.id)
      if (disposed || generation !== current || id !== companyId.value || period !== month.value)
        return false
      if (result.status === 'paid') {
        prepareKey = null
        await onPaid()
        return false
      }
      payment.value = result
      transferDate.value = vietnamToday()
      note.value = ''
      return true
    } catch (failure) {
      if (!disposed && generation === current) error.value = payrollErrorText(failure)
      return false
    } finally {
      if (!disposed && generation === current) preparing.value = ''
    }
  }

  function chooseFile(selected) {
    if (saving.value) return
    error.value = ''
    if (!selected) return
    try {
      validateReceipt(selected)
    } catch (failure) {
      error.value = failure.message
      return
    }
    const unused = uploadedPath
    clearImage()
    file.value = selected
    imageId = crypto.randomUUID()
    preview.value = URL.createObjectURL(selected)
    if (unused) payrollRepository.removeUnusedReceipt(unused).catch(() => {})
  }

  function close() {
    if (saving.value) return false
    const unused = uploadedPath
    payment.value = null
    error.value = ''
    clearImage()
    if (unused) payrollRepository.removeUnusedReceipt(unused).catch(() => {})
    return true
  }

  async function confirm() {
    if (saving.value || !payment.value) return false
    if (!file.value) {
      error.value = 'Thêm ảnh chuyển khoản trước khi xác nhận.'
      return false
    }
    const current = generation,
      target = payment.value,
      selectedFile = file.value,
      selectedImageId = imageId
    const selectedDate = transferDate.value,
      selectedNote = note.value.trim()
    let path = uploadedPath
    saving.value = true
    error.value = ''
    try {
      path ||= await payrollRepository.uploadReceipt(target, selectedFile, selectedImageId)
      if (!disposed && generation === current) uploadedPath = path
      const result = await payrollRepository.finalize(target.id, path, selectedDate, selectedNote)
      if (disposed || generation !== current) return true
      if (result.receipt_path !== path) payrollRepository.removeUnusedReceipt(path).catch(() => {})
      payment.value = null
      prepareKey = null
      clearImage()
      await onPaid()
      return true
    } catch (failure) {
      if (!disposed && generation === current) error.value = payrollErrorText(failure)
      return false
    } finally {
      if (!disposed && generation === current) saving.value = false
    }
  }

  async function cancel() {
    if (saving.value || !payment.value) return false
    const current = generation,
      target = payment.value,
      unused = uploadedPath
    saving.value = true
    error.value = ''
    try {
      await payrollRepository.cancel(target.id)
      if (disposed || current !== generation) return true
      if (unused) payrollRepository.removeUnusedReceipt(unused).catch(() => {})
      payment.value = null
      prepareKey = null
      clearImage()
      await onPaid()
      return true
    } catch (failure) {
      if (!disposed && current === generation) error.value = payrollErrorText(failure)
      return false
    } finally {
      if (!disposed && current === generation) saving.value = false
    }
  }

  watch(
    [companyId, month],
    () => {
      generation++
      payment.value = null
      preparing.value = ''
      saving.value = false
      error.value = ''
      prepareKey = null
      clearImage()
    },
    { flush: 'sync' }
  )
  onScopeDispose(() => {
    disposed = true
    generation++
    clearImage()
  })
  return {
    payment,
    preparing,
    saving,
    error,
    file,
    preview,
    transferDate,
    note,
    open,
    chooseFile,
    close,
    confirm,
    cancel
  }
}
