import { ref, watch, onScopeDispose } from 'vue'
import { payrollRepository } from '../infrastructure/payrollRepository'
import { payrollErrorText } from './payroll-errors'
import { moneyAmount } from '../domain/payroll-settlement'

export function usePayrollData(
  companyId,
  month,
  { ownHistory = false, notifications = null } = {}
) {
  const rows = ref([])
  const overtime = ref([])
  const loading = ref(false)
  const error = ref('')
  const history = ref([])
  const historyTotal = ref(0)
  const historyPage = ref(1)
  const historyLoading = ref(false)
  const historyError = ref('')
  let request = 0
  let historyRequest = 0
  let disposed = false

  async function refreshHistory() {
    const current = ++historyRequest
    historyLoading.value = true
    historyError.value = ''
    try {
      const result = await payrollRepository.history(
        ownHistory ? null : companyId.value,
        ownHistory ? null : month.value,
        historyPage.value
      )
      if (disposed || current !== historyRequest) return
      history.value = result?.rows || []
      historyTotal.value = Number(result?.total || 0)
    } catch (failure) {
      if (!disposed && current === historyRequest) historyError.value = payrollErrorText(failure)
    } finally {
      if (!disposed && current === historyRequest) historyLoading.value = false
    }
  }

  async function refresh() {
    const current = ++request
    const id = companyId.value,
      period = month.value
    error.value = ''
    loading.value = !!id
    if (!id) {
      rows.value = []
      overtime.value = []
      return
    }
    try {
      const [summary, extra] = await Promise.all([
        payrollRepository.summary(id, period),
        payrollRepository.overtime(id, period)
      ])
      if (disposed || current !== request || id !== companyId.value || period !== month.value)
        return
      const amounts = [
        'monthly_base_vnd',
        'monthly_allowance_vnd',
        'planned_cast_vnd',
        'shift_cast_vnd',
        'expense_vnd',
        'overtime_allowance_vnd',
        'earned_vnd',
        'paid_vnd',
        'remaining_vnd'
      ]
      rows.value = (summary || []).map((row) => ({
        ...row,
        ...Object.fromEntries(amounts.map((key) => [key, moneyAmount(row[key])]))
      }))
      overtime.value = extra || []
    } catch (failure) {
      if (!disposed && current === request) {
        rows.value = []
        overtime.value = []
        error.value = payrollErrorText(failure)
      }
    } finally {
      if (!disposed && current === request) loading.value = false
    }
  }

  watch(
    [companyId, month],
    () => {
      rows.value = []
      overtime.value = []
      if (!ownHistory) {
        history.value = []
        historyPage.value = 1
      }
      refresh()
    },
    { immediate: true }
  )
  watch(ownHistory ? [historyPage] : [companyId, month, historyPage], refreshHistory, {
    immediate: true
  })
  if (notifications)
    watch(
      () =>
        notifications.value
          .filter((item) => item.event === 'payroll_paid')
          .map((item) => item.id)
          .join('|'),
      () => {
        refresh()
        refreshHistory()
      }
    )
  onScopeDispose(() => {
    disposed = true
    request++
    historyRequest++
  })
  return {
    rows,
    overtime,
    loading,
    error,
    refresh,
    history,
    historyTotal,
    historyPage,
    historyLoading,
    historyError,
    refreshHistory
  }
}
