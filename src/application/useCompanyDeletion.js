import { ref } from 'vue'
import { adminCompanyRepository } from '../infrastructure/adminCompanyRepository'

export function useCompanyDeletion(company, onDeleted) {
  const reason = ref('')
  const saving = ref(false)
  const error = ref('')
  const deleted = ref(false)
  const request = crypto.randomUUID()
  let submittedReason = ''

  async function submit() {
    if (saving.value) return
    const text = deleted.value ? submittedReason : reason.value.trim()
    if (!text || text.length > 500) {
      error.value = 'Nhập lý do xóa công ty, tối đa 500 ký tự.'
      return
    }
    saving.value = true
    error.value = ''
    try {
      submittedReason = text
      const result = await adminCompanyRepository.deleteCompany(company.value.id, text, request)
      deleted.value = true
      if (!result.cleanup_complete) {
        error.value = 'Công ty đã được xóa. Chưa xóa hết ảnh chứng từ, hãy nhấn Thử lại.'
        return
      }
      onDeleted(result)
    } catch (failure) {
      error.value = failure.message
    } finally {
      saving.value = false
    }
  }
  return { reason, saving, error, deleted, submit }
}
