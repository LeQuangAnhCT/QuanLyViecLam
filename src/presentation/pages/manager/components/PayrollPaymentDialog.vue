<script setup>
import { ref, watch, nextTick, onMounted } from 'vue'
import { payrollMoney, payrollMonthLabel, payrollDate } from '../../../formatters/payroll'
import { vietnamToday } from '../../../../domain/payroll-settlement'

const props = defineProps({ flow: { type: Object, required: true } })
const emit = defineEmits(['closed'])
const {
  payment,
  saving,
  error,
  file,
  preview,
  transferDate,
  note,
  chooseFile,
  confirm,
  close,
  cancel
} = props.flow
const dialog = ref(null)
const cancelQuestion = ref(false)

async function syncDialog() {
  cancelQuestion.value = false
  await nextTick()
  if (payment.value && !dialog.value.open) dialog.value.showModal()
  else if (!payment.value && dialog.value.open) dialog.value.close()
}
watch(payment, syncDialog)
onMounted(syncDialog)
function dismiss() {
  if (close()) {
    dialog.value.close()
    emit('closed')
  }
}
async function submit() {
  if (await confirm()) dialog.value.close()
}
async function discard() {
  if (await cancel()) dialog.value.close()
}
function imageChanged(event) {
  chooseFile(event.target.files?.[0])
  event.target.value = ''
}
</script>

<template>
  <dialog
    ref="dialog"
    class="salary-payment-dialog"
    aria-labelledby="salary-payment-title"
    @cancel.prevent="dismiss"
  >
    <template v-if="payment">
      <header class="salary-dialog-heading">
        <div>
          <h2 id="salary-payment-title">Thanh toán cho {{ payment.snapshot.full_name }}</h2>
          <p>{{ payrollMonthLabel(payment.pay_month) }} tại {{ payment.snapshot.company_name }}</p>
        </div>
        <button type="button" :disabled="saving" aria-label="Đóng bảng chốt" @click="dismiss">
          ×
        </button>
      </header>
      <div class="salary-payment-amount">
        <span>Số tiền cần chuyển</span>
        <strong>{{ payrollMoney(payment.amount_vnd) }}</strong>
        <small>Trả riêng cho người này</small>
      </div>
      <p v-if="transferDate > payment.snapshot.pay_until" class="salary-context-notice">
        Đã qua kỳ trả {{ payrollDate(payment.snapshot.pay_from) }} -
        {{ payrollDate(payment.snapshot.pay_until) }}. Khoản này vẫn được ghi nhận và đánh dấu trả
        muộn.
      </p>
      <p
        v-if="payment.snapshot.scheduled_shifts > payment.snapshot.completed_shifts"
        class="salary-context-notice"
      >
        Còn {{ payment.snapshot.scheduled_shifts - payment.snapshot.completed_shifts }} ca chưa hoàn
        tất. Cast của những ca đó được tính khi hoàn tất và có thể trả bổ sung.
      </p>
      <form class="salary-payment-form" @submit.prevent="submit">
        <div class="salary-payment-columns">
          <section class="salary-payment-breakdown" aria-label="Chi tiết số tiền đã chốt">
            <h3>Chi tiết tiền công</h3>
            <dl>
              <div>
                <dt>Lương cơ bản</dt>
                <dd>{{ payrollMoney(payment.snapshot.monthly_base_vnd) }}</dd>
              </div>
              <div>
                <dt>Phụ cấp tháng</dt>
                <dd>{{ payrollMoney(payment.snapshot.monthly_allowance_vnd) }}</dd>
              </div>
              <div>
                <dt>Cast hoàn tất</dt>
                <dd>{{ payrollMoney(payment.snapshot.shift_cast_vnd) }}</dd>
              </div>
              <div>
                <dt>Chi phí phát sinh</dt>
                <dd>{{ payrollMoney(payment.snapshot.expense_vnd) }}</dd>
              </div>
              <div>
                <dt>Bù quá giờ</dt>
                <dd>{{ payrollMoney(payment.snapshot.overtime_allowance_vnd) }}</dd>
              </div>
              <div>
                <dt>Đã trả trước đó</dt>
                <dd>{{ payrollMoney(payment.paid_before_vnd) }}</dd>
              </div>
            </dl>
            <p>Ca hoặc phụ cấp phát sinh sau lúc chốt được giữ lại cho lần trả bổ sung.</p>
          </section>
          <div class="salary-receipt-upload">
            <label for="salary-receipt-file">Ảnh chuyển khoản ngân hàng</label>
            <p id="salary-receipt-help">
              Sau khi chuyển đúng số tiền trên, chụp hoặc chọn ảnh giao dịch. JPG, PNG, WebP tối đa
              8 MB.
            </p>
            <input
              id="salary-receipt-file"
              type="file"
              accept="image/jpeg,image/png,image/webp"
              :disabled="saving"
              aria-describedby="salary-receipt-help"
              @change="imageChanged"
            />
            <img
              v-if="preview"
              :src="preview"
              alt="Ảnh chuyển khoản đang được kiểm tra trước khi xác nhận"
            />
            <div v-else class="salary-receipt-placeholder">Chưa có ảnh chuyển khoản</div>
            <span v-if="file" class="salary-receipt-filename">{{ file.name }}</span>
          </div>
        </div>
        <div class="salary-payment-fields">
          <label>
            Ngày chuyển khoản
            <input
              v-model="transferDate"
              type="date"
              required
              :min="payment.snapshot.pay_from"
              :max="vietnamToday()"
              :disabled="saving"
            />
          </label>
          <label>
            <span>
              Ghi chú
              <small>(không bắt buộc)</small>
            </span>
            <input
              v-model="note"
              maxlength="500"
              :disabled="saving"
              placeholder="Ví dụ: Lương tháng 10"
            />
          </label>
        </div>
        <div v-if="error" class="alert" role="alert">{{ error }}</div>
        <div v-if="cancelQuestion" class="salary-cancel-question" role="alert">
          <p>
            Chỉ hủy bảng chốt chưa trả. Số còn phải trả được giữ lại để chốt lại. Nếu đã chuyển
            tiền, hãy đính kèm ảnh và xác nhận.
          </p>
          <button type="button" :disabled="saving" @click="cancelQuestion = false">
            Giữ bảng chốt
          </button>
          <button type="button" :disabled="saving" @click="discard">Xác nhận hủy</button>
        </div>
        <footer class="salary-dialog-actions">
          <button
            type="button"
            class="salary-cancel-link"
            :disabled="saving"
            @click="cancelQuestion = true"
          >
            Hủy bảng chốt
          </button>
          <button type="submit" class="primary" :disabled="saving || !file">
            {{ saving ? 'Đang ghi nhận...' : 'Xác nhận đã chuyển' }}
          </button>
        </footer>
      </form>
    </template>
  </dialog>
</template>

<style src="../styles/payment-dialog.css"></style>
