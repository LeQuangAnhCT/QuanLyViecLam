import { ref, watch, onScopeDispose } from 'vue'
import { payrollRepository } from '../infrastructure/payrollRepository'
import { payrollErrorText } from './payroll-errors'

export function usePaymentReceipt(paymentId) {
  const payment = ref(null)
  const imageUrl = ref('')
  const loading = ref(false)
  const error = ref('')
  let request = 0,
    disposed = false
  async function reload() {
    const current = ++request,
      id = paymentId.value
    imageUrl.value = ''
    error.value = ''
    payment.value = null
    if (!id) return
    loading.value = true
    try {
      const result = await payrollRepository.payment(id)
      if (!result || result.status !== 'paid')
        throw new Error('Chứng từ không còn khả dụng hoặc bạn không có quyền xem.')
      if (disposed || current !== request) return
      payment.value = result
      const url = await payrollRepository.receiptUrl(result.receipt_path)
      if (!disposed && current === request) imageUrl.value = url
    } catch (failure) {
      if (!disposed && current === request) error.value = payrollErrorText(failure)
    } finally {
      if (!disposed && current === request) loading.value = false
    }
  }
  watch(paymentId, reload, { immediate: true })
  onScopeDispose(() => {
    disposed = true
    request++
  })
  return { payment, imageUrl, loading, error, reload }
}
