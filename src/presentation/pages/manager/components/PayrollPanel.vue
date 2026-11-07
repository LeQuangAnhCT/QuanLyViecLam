<script setup>
import { ref, computed, watch, defineAsyncComponent } from 'vue'
import { useWorkspaceContext } from '../../../composables/useWorkspaceContext'
import { usePayrollData } from '../../../../application/usePayrollData'
import { usePayrollPayment } from '../../../../application/usePayrollPayment'
import {
  defaultPaymentMonth,
  movePayrollMonth,
  payrollWindow,
  paymentStatus,
  vietnamToday
} from '../../../../domain/payroll-settlement'
import { roleLabel, workerRole } from '../../../../domain/calendar'
import { payrollMoney, payrollMonthLabel, payrollDate } from '../../../formatters/payroll'
import { formatWorkDuration } from '../../../formatters/work-duration'
import PayrollPaymentDialog from './PayrollPaymentDialog.vue'
import OvertimeReview from './OvertimeReview.vue'

const ReceiptDialog = defineAsyncComponent(
  () => import('../../../components/PaymentReceiptDialog.vue')
)
const w = useWorkspaceContext()
const { companyId } = w
const month = ref(defaultPaymentMonth())
const view = ref('salary')
const search = ref('')
const overtimePerson = ref('')
const receiptId = ref('')
const data = usePayrollData(companyId, month)
const {
  rows,
  overtime,
  loading,
  error,
  history,
  historyTotal,
  historyPage,
  historyLoading,
  historyError
} = data
async function refreshAll() {
  await Promise.all([data.refresh(), data.refreshHistory()])
}
const paymentFlow = usePayrollPayment(companyId, month, async () => {
  await refreshAll()
  w.refreshNotifications()
  w.message.value = 'Đã cập nhật trạng thái kết toán.'
})
const { preparing, error: paymentError } = paymentFlow
const monthInput = computed({
  get: () => month.value.slice(0, 7),
  set: (value) => {
    if (/^(20\d{2}|2100)-(0[1-9]|1[0-2])$/.test(value)) month.value = value + '-01'
  }
})
const paymentWindow = computed(() => payrollWindow(month.value))
const today = computed(() => rows.value[0]?.server_today || vietnamToday())
const filtered = computed(() =>
  rows.value.filter((row) =>
    `${row.full_name} ${row.email}`
      .toLocaleLowerCase('vi-VN')
      .includes(search.value.trim().toLocaleLowerCase('vi-VN'))
  )
)
const sum = (key) => rows.value.reduce((total, row) => total + Number(row[key] || 0), 0)
const pendingOvertime = computed(
  () => overtime.value.filter((row) => row.allowance_vnd == null).length
)
const historyPages = computed(() => Math.max(1, Math.ceil(historyTotal.value / 10)))
const status = (row) => paymentStatus(row, today.value)
function changeMonth(delta) {
  const next = movePayrollMonth(month.value, delta)
  if (next >= '2000-01-01' && next <= '2100-12-01') month.value = next
}
function reviewPerson(row) {
  overtimePerson.value = row.user_id
  view.value = 'overtime'
}
async function openPayment(row) {
  if (await paymentFlow.open(row)) data.refresh()
}
watch(month, () => {
  overtimePerson.value = ''
  receiptId.value = ''
})
watch(companyId, () => {
  overtimePerson.value = ''
  receiptId.value = ''
  search.value = ''
})
</script>

<template>
  <section class="surface section settlement-workspace" aria-labelledby="settlement-title">
    <header class="settlement-heading">
      <div>
        <h2 id="settlement-title">Lương và thanh toán</h2>
        <p>
          Kỳ trả {{ payrollDate(paymentWindow.from) }} - {{ payrollDate(paymentWindow.until) }} cho
          {{ payrollMonthLabel(month) }}.
        </p>
      </div>
      <div class="settlement-month-controls">
        <button type="button" aria-label="Kỳ trước" @click="changeMonth(-1)">‹</button>
        <label class="sr-only" for="settlement-month">Tháng lương</label>
        <input
          id="settlement-month"
          v-model="monthInput"
          type="month"
          min="2000-01"
          max="2100-12"
        />
        <button type="button" aria-label="Kỳ sau" @click="changeMonth(1)">›</button>
        <button type="button" :disabled="loading || historyLoading" @click="refreshAll">
          Làm mới
        </button>
      </div>
    </header>
    <nav class="settlement-tabs" aria-label="Các mục kết toán lương">
      <button
        type="button"
        :aria-current="view === 'salary' ? 'page' : undefined"
        @click="view = 'salary'"
      >
        Bảng lương
      </button>
      <button
        type="button"
        :aria-current="view === 'overtime' ? 'page' : undefined"
        @click="view = 'overtime'"
      >
        Quá giờ
        <span v-if="pendingOvertime">{{ pendingOvertime }}</span>
      </button>
      <button
        type="button"
        :aria-current="view === 'history' ? 'page' : undefined"
        @click="view = 'history'"
      >
        Lịch sử thanh toán
      </button>
    </nav>
    <div v-if="error" class="alert" role="alert">{{ error }}</div>
    <div v-if="paymentError && !paymentFlow.payment.value" class="alert" role="alert">
      {{ paymentError }}
    </div>
    <div v-if="loading && view !== 'history'" class="settlement-skeleton" role="status">
      <span>Đang tải kỳ lương...</span>
      <i></i>
      <i></i>
      <i></i>
    </div>
    <template v-else-if="!error && view === 'salary'">
      <div class="settlement-balances">
        <div>
          <span>Còn phải trả</span>
          <strong>{{ payrollMoney(sum('remaining_vnd')) }}</strong>
          <small>{{ rows.filter((row) => row.remaining_vnd > 0).length }} nhân viên trong kỳ</small>
        </div>
        <div class="settlement-paid">
          <span>Đã thanh toán</span>
          <strong>{{ payrollMoney(sum('paid_vnd')) }}</strong>
          <small>
            {{ rows.filter((row) => row.paid_vnd > 0).length }} người đã được ghi nhận trả
          </small>
        </div>
      </div>
      <div class="settlement-work-summary">
        <span>
          Cast dự kiến
          <b>{{ payrollMoney(sum('planned_cast_vnd')) }}</b>
        </span>
        <span>
          Cast hoàn tất
          <b>{{ payrollMoney(sum('shift_cast_vnd')) }}</b>
        </span>
        <span>
          Quá giờ
          <b>{{ formatWorkDuration(sum('overtime_ms')) }}</b>
        </span>
      </div>
      <div class="settlement-toolbar">
        <label>
          Tìm nhân viên
          <input v-model="search" type="search" placeholder="Tên hoặc email" />
        </label>
        <p v-if="today < paymentWindow.from">
          Kỳ này được trả từ {{ payrollDate(paymentWindow.from) }}. Bạn có thể duyệt phụ cấp quá giờ
          trước.
        </p>
        <p v-else-if="today > paymentWindow.until">
          Đã qua kỳ trả. Các khoản còn thiếu vẫn có thể thanh toán.
        </p>
      </div>
      <div v-if="!rows.length" class="salary-empty">
        <h3>Chưa có nhân sự trong kỳ này</h3>
        <p>Chọn tháng có ca làm hoặc chuyển sang kỳ hiện tại để xem tiền công đang phát sinh.</p>
        <button type="button" @click="month = vietnamToday().slice(0, 7) + '-01'">
          Xem tháng hiện tại
        </button>
      </div>
      <div v-else-if="!filtered.length" class="salary-empty">Không tìm thấy nhân viên phù hợp.</div>
      <div
        v-else
        class="settlement-table-wrap"
        tabindex="0"
        role="region"
        aria-label="Bảng thanh toán theo từng nhân viên"
      >
        <table class="settlement-table">
          <thead>
            <tr>
              <th scope="col">Nhân viên</th>
              <th scope="col">Ca / giờ tính công</th>
              <th scope="col">Thu nhập đã tính</th>
              <th scope="col">Đã trả</th>
              <th scope="col">Còn trả</th>
              <th scope="col"><span class="sr-only">Thao tác</span></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in filtered" :key="row.user_id">
              <th scope="row">
                <div class="salary-person-name">
                  <b :title="row.full_name">{{ row.full_name }}</b>
                  <span>{{ roleLabel(workerRole(row.employment_type)) }}</span>
                </div>
                <small>{{ row.email }}</small>
                <span class="salary-state" :class="'salary-state-' + status(row).key">
                  {{ status(row).label }}
                </span>
              </th>
              <td>
                <b>{{ row.completed_shifts }}/{{ row.scheduled_shifts }} ca</b>
                <small title="Tổng thời lượng ca đã hoàn tất">
                  {{ formatWorkDuration(row.completed_shift_ms) }}
                </small>
                <small v-if="row.overtime_ms">Quá {{ formatWorkDuration(row.overtime_ms) }}</small>
              </td>
              <td>
                {{ payrollMoney(row.earned_vnd) }}
                <small v-if="row.overtime_allowance_vnd">
                  Bù quá giờ {{ payrollMoney(row.overtime_allowance_vnd) }}
                </small>
              </td>
              <td class="salary-money-paid">{{ payrollMoney(row.paid_vnd) }}</td>
              <td class="salary-money-due">
                <strong>{{ payrollMoney(row.remaining_vnd) }}</strong>
                <small v-if="row.pending_payment_id">
                  Đã chốt {{ payrollMoney(row.pending_amount_vnd) }}
                </small>
              </td>
              <td class="salary-row-action">
                <button
                  v-if="status(row).key === 'review'"
                  type="button"
                  @click="reviewPerson(row)"
                >
                  Duyệt quá giờ
                </button>
                <button
                  v-else-if="row.pending_payment_id || row.remaining_vnd > 0"
                  type="button"
                  class="primary"
                  :disabled="!!preparing || status(row).key === 'not_due'"
                  @click="openPayment(row)"
                >
                  {{
                    preparing === row.user_id
                      ? 'Đang chốt...'
                      : row.pending_payment_id
                        ? 'Tiếp tục'
                        : row.paid_vnd > 0
                          ? 'Trả bổ sung'
                          : 'Thanh toán'
                  }}
                </button>
                <span v-else class="salary-row-done">
                  {{ row.paid_vnd > 0 ? 'Đã trả đủ' : 'Chưa có khoản trả' }}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="settlement-footnote">
        Thanh toán riêng từng người bằng ảnh chuyển khoản. Ca và chấm công được giữ nguyên để đối
        chiếu; khoản phát sinh sau lúc chốt được trả bổ sung.
      </p>
    </template>
    <OvertimeReview
      v-else-if="!error && view === 'overtime'"
      :rows="overtime"
      :context="[companyId, month]"
      :person="overtimePerson"
      @clear-person="overtimePerson = ''"
      @changed="refreshAll"
    />
    <section
      v-if="view === 'history'"
      class="salary-history"
      aria-labelledby="salary-history-title"
    >
      <div class="salary-history-intro">
        <h3 id="salary-history-title">Các khoản đã thanh toán</h3>
        <p>Chứng từ và số tiền tại thời điểm chốt được giữ nguyên theo từng người.</p>
      </div>
      <div v-if="historyError" class="alert" role="alert">
        {{ historyError }}
        <button type="button" @click="data.refreshHistory">Thử lại</button>
      </div>
      <div v-else-if="historyLoading" class="salary-empty" role="status">Đang tải lịch sử...</div>
      <div v-else-if="!history.length" class="salary-empty">
        <h3>Chưa có khoản đã trả trong tháng</h3>
        <p>Sau khi xác nhận ảnh chuyển khoản, khoản lương sẽ xuất hiện ở đây.</p>
      </div>
      <ol v-else class="salary-history-list">
        <li v-for="item in history" :key="item.id">
          <div>
            <b>{{ item.snapshot.full_name }}</b>
            <span>{{ payrollMonthLabel(item.pay_month) }}</span>
          </div>
          <div>
            <strong>{{ payrollMoney(item.amount_vnd) }}</strong>
            <small>
              {{ payrollDate(item.transfer_date) }}
              <span v-if="item.transfer_date > item.snapshot.pay_until">, trả muộn</span>
            </small>
          </div>
          <span class="salary-state salary-state-paid">Đã thanh toán</span>
          <button type="button" @click="receiptId = item.id">Xem chứng từ</button>
        </li>
      </ol>
      <nav
        v-if="historyPages > 1"
        class="salary-pagination"
        aria-label="Phân trang lịch sử thanh toán"
      >
        <button type="button" :disabled="historyLoading || historyPage <= 1" @click="historyPage--">
          Trang trước
        </button>
        <span>Trang {{ historyPage }} / {{ historyPages }}</span>
        <button
          type="button"
          :disabled="historyLoading || historyPage >= historyPages"
          @click="historyPage++"
        >
          Trang sau
        </button>
      </nav>
    </section>
    <PayrollPaymentDialog :flow="paymentFlow" @closed="refreshAll" />
    <ReceiptDialog v-if="receiptId" :payment-id="receiptId" @close="receiptId = ''" />
  </section>
</template>

<style src="../styles/settlement.css"></style>
<style src="../styles/salary-history.css"></style>
