<script setup>
import { ref, toRef, onMounted, watch } from 'vue'
import { usePaymentReceipt } from '../../application/usePaymentReceipt'
import { payrollMoney, payrollMonthLabel, payrollDate } from '../formatters/payroll'

const props = defineProps({ paymentId: { type: String, required: true } })
const emit = defineEmits(['close'])
const dialog = ref(null)
const imageFailed = ref(false)
const { payment, imageUrl, loading, error, reload } = usePaymentReceipt(toRef(props, 'paymentId'))
watch(imageUrl, () => {
  imageFailed.value = false
})
onMounted(() => dialog.value?.showModal())
</script>

<template>
  <dialog
    ref="dialog"
    class="payment-receipt-dialog"
    aria-labelledby="payment-receipt-title"
    @close="emit('close')"
  >
    <header class="receipt-heading">
      <div>
        <h2 id="payment-receipt-title">Chứng từ thanh toán</h2>
        <p v-if="payment">{{ payrollMonthLabel(payment.pay_month) }}</p>
      </div>
      <button type="button" autofocus aria-label="Đóng chứng từ" @click="dialog.close()">×</button>
    </header>
    <div v-if="loading" class="receipt-loading" role="status">Đang tải chứng từ...</div>
    <div v-if="error" class="receipt-error" role="alert">
      {{ error }}
      <button type="button" @click="reload">Thử lại</button>
    </div>
    <template v-if="payment">
      <div class="receipt-amount">
        <span>Đã thanh toán</span>
        <strong>{{ payrollMoney(payment.amount_vnd) }}</strong>
      </div>
      <dl class="receipt-details">
        <div>
          <dt>Người nhận</dt>
          <dd>{{ payment.snapshot.full_name }}</dd>
        </div>
        <div>
          <dt>Công ty</dt>
          <dd>{{ payment.snapshot.company_name }}</dd>
        </div>
        <div>
          <dt>Ngày chuyển khoản</dt>
          <dd>{{ payrollDate(payment.transfer_date) }}</dd>
        </div>
        <div>
          <dt>Ngày ghi nhận</dt>
          <dd>{{ payrollDate(payment.paid_at) }}</dd>
        </div>
      </dl>
      <details class="receipt-breakdown">
        <summary>Chi tiết bảng chốt</summary>
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
            <dt>Cast ca hoàn tất</dt>
            <dd>{{ payrollMoney(payment.snapshot.shift_cast_vnd) }}</dd>
          </div>
          <div>
            <dt>Chi phí phát sinh</dt>
            <dd>{{ payrollMoney(payment.snapshot.expense_vnd) }}</dd>
          </div>
          <div>
            <dt>Phụ cấp bù quá giờ</dt>
            <dd>{{ payrollMoney(payment.snapshot.overtime_allowance_vnd) }}</dd>
          </div>
          <div>
            <dt>Đã trả trước lần này</dt>
            <dd>{{ payrollMoney(payment.paid_before_vnd) }}</dd>
          </div>
        </dl>
      </details>
      <p v-if="payment.note" class="receipt-note">{{ payment.note }}</p>
      <div v-if="imageUrl" class="receipt-image-area">
        <img
          v-if="!imageFailed"
          :src="imageUrl"
          alt="Ảnh chuyển khoản lương do Manager cung cấp"
          @error="imageFailed = true"
        />
        <p v-else role="alert">Ảnh chưa tải được. Hãy tải lại ảnh để xem chứng từ.</p>
      </div>
      <footer v-if="imageUrl" class="receipt-actions">
        <button type="button" :disabled="loading" @click="reload">Tải lại ảnh</button>
        <a :href="imageUrl" target="_blank" rel="noopener noreferrer">Mở ảnh gốc</a>
      </footer>
    </template>
  </dialog>
</template>

<style scoped src="./payment-receipt.css"></style>
