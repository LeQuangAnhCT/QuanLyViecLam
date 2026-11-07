<script setup>
import { ref, computed, watch, defineAsyncComponent } from 'vue'
import { useWorkspaceContext } from '../../../composables/useWorkspaceContext'
import { usePayrollData } from '../../../../application/usePayrollData'
import {
  movePayrollMonth,
  payrollWindow,
  paymentStatus,
  vietnamToday
} from '../../../../domain/payroll-settlement'
import { payrollMoney, payrollMonthLabel, payrollDate } from '../../../formatters/payroll'
import { formatWorkDuration } from '../../../formatters/work-duration'

const ReceiptDialog = defineAsyncComponent(
  () => import('../../../components/PaymentReceiptDialog.vue')
)
const w = useWorkspaceContext()
const { companyId, current } = w
const month = ref(vietnamToday().slice(0, 7) + '-01')
const view = ref('income')
const receiptId = ref('')
const data = usePayrollData(companyId, month, { ownHistory: true, notifications: w.notifications })
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
const own = computed(() => rows.value.find((row) => row.user_id === w.userId) || null)
const ownOvertime = computed(() => overtime.value.filter((row) => row.user_id === w.userId))
const paymentWindow = computed(() => payrollWindow(month.value))
const monthInput = computed({
  get: () => month.value.slice(0, 7),
  set: (value) => {
    if (/^(20\d{2}|2100)-(0[1-9]|1[0-2])$/.test(value)) month.value = value + '-01'
  }
})
const pages = computed(() => Math.max(1, Math.ceil(historyTotal.value / 10)))
const status = computed(() =>
  own.value ? paymentStatus(own.value, own.value.server_today || vietnamToday()) : null
)
const dateTime = (stamp) =>
  new Intl.DateTimeFormat('vi-VN', {
    timeZone: 'Asia/Ho_Chi_Minh',
    dateStyle: 'short',
    timeStyle: 'short'
  }).format(new Date(stamp))
function changeMonth(delta) {
  const next = movePayrollMonth(month.value, delta)
  if (next >= '2000-01-01' && next <= '2100-12-01') month.value = next
}
async function refresh() {
  await Promise.all([data.refresh(), data.refreshHistory()])
}
watch(companyId, () => {
  receiptId.value = ''
})
</script>

<template>
  <section class="surface section income-workspace" aria-labelledby="income-statement-title">
    <header class="income-heading">
      <div>
        <h2 id="income-statement-title">Thu nhập và lương đã nhận</h2>
        <p v-if="view === 'history'">
          Các khoản đã trả từ những công ty bạn tham gia, kèm ảnh chuyển khoản.
        </p>
        <p v-else>
          {{ current?.name || 'Công ty đang tham gia' }}. Kỳ trả
          {{ payrollDate(paymentWindow.from) }} - {{ payrollDate(paymentWindow.until) }}.
        </p>
      </div>
      <div class="income-controls">
        <template v-if="view !== 'history'">
          <button type="button" aria-label="Tháng trước" @click="changeMonth(-1)">‹</button>
          <label class="income-sr-only" for="freelance-income-month">Tháng lương</label>
          <input
            id="freelance-income-month"
            v-model="monthInput"
            type="month"
            min="2000-01"
            max="2100-12"
          />
          <button type="button" aria-label="Tháng sau" @click="changeMonth(1)">›</button>
        </template>
        <button type="button" :disabled="loading || historyLoading" @click="refresh">
          Làm mới
        </button>
      </div>
    </header>
    <nav class="income-tabs" aria-label="Thông tin thu nhập cá nhân">
      <button
        type="button"
        :aria-current="view === 'income' ? 'page' : undefined"
        @click="view = 'income'"
      >
        Kỳ lương
      </button>
      <button
        type="button"
        :aria-current="view === 'overtime' ? 'page' : undefined"
        @click="view = 'overtime'"
      >
        Quá giờ
      </button>
      <button
        type="button"
        :aria-current="view === 'history' ? 'page' : undefined"
        @click="view = 'history'"
      >
        Lịch sử nhận lương
      </button>
    </nav>
    <template v-if="view !== 'history'">
      <div v-if="error" class="alert" role="alert">{{ error }}</div>
      <div v-else-if="loading" class="income-skeleton" role="status">
        <span>Đang tải kỳ lương...</span>
        <i></i>
        <i></i>
      </div>
      <div v-else-if="!own" class="income-empty">
        <h3>Chưa có tiền công trong kỳ này</h3>
        <p v-if="!companyId">Bạn vẫn có thể xem các khoản đã nhận trong Lịch sử nhận lương.</p>
        <p v-else>Chọn kỳ có ca làm hoặc chờ Manager thiết lập thỏa thuận lương.</p>
      </div>
      <template v-else-if="view === 'income'">
        <div class="income-period-line">
          <h3>{{ payrollMonthLabel(month) }}</h3>
          <span class="income-payment-state" :class="'income-state-' + status.key">
            {{ status.label }}
          </span>
        </div>
        <div class="income-balances">
          <div>
            <span>Còn chờ thanh toán</span>
            <strong>{{ payrollMoney(own.remaining_vnd) }}</strong>
            <small>Từ tiền công đã tính của kỳ này</small>
          </div>
          <div class="income-paid">
            <span>Đã nhận trong kỳ</span>
            <strong>{{ payrollMoney(own.paid_vnd) }}</strong>
            <small>{{ own.payment_count }} lần chuyển khoản được ghi nhận</small>
          </div>
        </div>
        <div class="income-work-facts">
          <span>
            <b>{{ own.completed_shifts }}/{{ own.scheduled_shifts }}</b>
            ca hoàn tất
          </span>
          <span>
            <b>{{ formatWorkDuration(own.completed_shift_ms) }}</b>
            giờ tính công
          </span>
          <button v-if="own.overtime_ms" type="button" @click="view = 'overtime'">
            Quá {{ formatWorkDuration(own.overtime_ms) }}
          </button>
        </div>
        <div class="income-calculation">
          <div>
            <h3>Chi tiết thu nhập</h3>
            <p>
              Cast chỉ tính ca đã xác nhận hoàn tất. Phụ cấp bù quá giờ được Manager duyệt riêng.
            </p>
            <p v-if="own.snapshotted" class="income-fixed-note">
              Mức lương của kỳ này đã được giữ theo bảng chốt.
            </p>
          </div>
          <dl>
            <div>
              <dt>Lương cơ bản</dt>
              <dd>{{ payrollMoney(own.monthly_base_vnd) }}</dd>
            </div>
            <div>
              <dt>Phụ cấp tháng</dt>
              <dd>{{ payrollMoney(own.monthly_allowance_vnd) }}</dd>
            </div>
            <div>
              <dt>Cast ca hoàn tất</dt>
              <dd>{{ payrollMoney(own.shift_cast_vnd) }}</dd>
            </div>
            <div>
              <dt>Chi phí phát sinh</dt>
              <dd>{{ payrollMoney(own.expense_vnd) }}</dd>
            </div>
            <div>
              <dt>Phụ cấp bù quá giờ</dt>
              <dd>{{ payrollMoney(own.overtime_allowance_vnd) }}</dd>
            </div>
            <div class="income-calculation-total">
              <dt>Tổng thu nhập đã tính</dt>
              <dd>{{ payrollMoney(own.earned_vnd) }}</dd>
            </div>
          </dl>
        </div>
        <p v-if="own.unreviewed_overtime" class="income-pending-note">
          Còn {{ own.unreviewed_overtime }} ca quá giờ chờ Manager duyệt mức bù. Phần này chưa được
          cộng vào phụ cấp.
        </p>
        <p class="income-footnote">
          Cast dự kiến của toàn bộ ca đã phân: {{ payrollMoney(own.planned_cast_vnd) }}. Ca hoặc phụ
          cấp phát sinh sau lúc chốt có thể được trả bổ sung.
        </p>
      </template>
      <section v-else class="income-overtime" aria-labelledby="freelance-overtime-title">
        <h3 id="freelance-overtime-title">Quá giờ của tôi</h3>
        <p>Thời gian thực sự làm sau giờ kết thúc dự kiến. Mức phụ cấp do Manager quyết định.</p>
        <div v-if="!ownOvertime.length" class="income-empty">
          Chưa có ca hoàn tất quá giờ trong tháng này.
        </div>
        <article v-for="row in ownOvertime" :key="row.shift_id" class="income-overtime-row">
          <div>
            <b>{{ row.title }}</b>
            <small>{{ payrollDate(row.starts_at) }} tại {{ row.location }}</small>
            <small>Dự kiến kết thúc {{ dateTime(row.planned_ends_at) }}</small>
            <small>Hoàn tất {{ dateTime(row.checked_out_at) }}</small>
          </div>
          <div>
            <strong>{{ formatWorkDuration(row.overtime_ms) }}</strong>
            <span>Quá giờ</span>
          </div>
          <div>
            <strong v-if="row.allowance_vnd != null">{{ payrollMoney(row.allowance_vnd) }}</strong>
            <span v-else>Chờ duyệt phụ cấp</span>
            <small v-if="row.note">{{ row.note }}</small>
            <small v-if="row.locked_status === 'paid'">Đã nằm trong khoản thanh toán</small>
          </div>
        </article>
      </section>
    </template>
    <section v-else class="income-history" aria-labelledby="freelance-history-title">
      <h3 id="freelance-history-title">Lịch sử lương từng tháng</h3>
      <p>Lịch sử cá nhân ở tất cả công ty, kể cả nơi đã ngừng tham gia.</p>
      <div v-if="historyError" class="alert" role="alert">
        {{ historyError }}
        <button type="button" @click="data.refreshHistory">Thử lại</button>
      </div>
      <div v-else-if="historyLoading" class="income-empty" role="status">Đang tải lịch sử...</div>
      <div v-else-if="!history.length" class="income-empty">
        <h3>Chưa có khoản đã nhận</h3>
        <p>Khi Manager xác nhận ảnh chuyển khoản, thông tin sẽ được lưu tại đây.</p>
      </div>
      <ol v-else class="income-history-list">
        <li v-for="item in history" :key="item.id">
          <div>
            <b>{{ payrollMonthLabel(item.pay_month) }}</b>
            <span>{{ item.snapshot.company_name }}</span>
          </div>
          <div>
            <strong>{{ payrollMoney(item.amount_vnd) }}</strong>
            <small>Chuyển khoản {{ payrollDate(item.transfer_date) }}</small>
          </div>
          <button type="button" @click="receiptId = item.id">Xem chứng từ</button>
        </li>
      </ol>
      <nav v-if="pages > 1" class="income-pagination" aria-label="Phân trang lịch sử lương">
        <button type="button" :disabled="historyLoading || historyPage <= 1" @click="historyPage--">
          Trang trước
        </button>
        <span>Trang {{ historyPage }} / {{ pages }}</span>
        <button
          type="button"
          :disabled="historyLoading || historyPage >= pages"
          @click="historyPage++"
        >
          Trang sau
        </button>
      </nav>
    </section>
    <ReceiptDialog v-if="receiptId" :payment-id="receiptId" @close="receiptId = ''" />
  </section>
</template>

<style src="../styles/income.css"></style>
