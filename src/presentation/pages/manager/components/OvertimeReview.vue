<script setup>
import { ref, computed, watch, nextTick } from 'vue'
import { useOvertimeAllowance } from '../../../../application/useOvertimeAllowance'
import { payrollMoney, payrollDate } from '../../../formatters/payroll'
import { formatWorkDuration } from '../../../formatters/work-duration'

const props = defineProps({
  rows: { type: Array, required: true },
  context: { type: Array, required: true },
  person: { type: String, default: '' }
})
const emit = defineEmits(['changed', 'clear-person'])
const review = useOvertimeAllowance(
  () => props.context.join('|'),
  () => emit('changed')
)
const { target, amount, note, saving, error, open, close, save } = review
const dialog = ref(null)
const filter = ref('pending')
const visible = computed(() =>
  props.rows.filter(
    (row) =>
      (!props.person || row.user_id === props.person) &&
      (filter.value === 'all' ||
        (filter.value === 'pending' ? row.allowance_vnd == null : row.allowance_vnd != null))
  )
)
const pending = computed(() => props.rows.filter((row) => row.allowance_vnd == null).length)
watch(target, async (value) => {
  await nextTick()
  if (value && !dialog.value.open) dialog.value.showModal()
  else if (!value && dialog.value.open) dialog.value.close()
})
function dismiss() {
  if (close()) dialog.value.close()
}
async function submit() {
  if (await save()) dialog.value.close()
}
const time = (stamp) =>
  new Intl.DateTimeFormat('vi-VN', {
    timeZone: 'Asia/Ho_Chi_Minh',
    hour: '2-digit',
    minute: '2-digit'
  }).format(new Date(stamp))
</script>

<template>
  <section class="overtime-review" aria-labelledby="overtime-review-title">
    <div class="overtime-intro">
      <h3 id="overtime-review-title">Quá giờ và phụ cấp bù</h3>
      <p>
        Tách riêng thời gian thực sự làm sau giờ kết thúc dự kiến. Duyệt mức bù cho từng ca trước
        khi chốt lương.
      </p>
    </div>
    <div class="overtime-filters" role="group" aria-label="Lọc trạng thái duyệt quá giờ">
      <button type="button" :aria-pressed="filter === 'pending'" @click="filter = 'pending'">
        Chưa duyệt
        <span>{{ pending }}</span>
      </button>
      <button type="button" :aria-pressed="filter === 'reviewed'" @click="filter = 'reviewed'">
        Đã duyệt
      </button>
      <button type="button" :aria-pressed="filter === 'all'" @click="filter = 'all'">Tất cả</button>
      <button v-if="person" type="button" class="text-button" @click="emit('clear-person')">
        Bỏ lọc nhân viên
      </button>
    </div>
    <div v-if="!rows.length" class="salary-empty">
      <h3>Chưa có ca quá giờ</h3>
      <p>Ca đã hoàn tất và có giờ ra trễ hơn dự kiến sẽ xuất hiện ở đây.</p>
    </div>
    <p v-else-if="!visible.length" class="salary-empty">Không có ca phù hợp trong mục này.</p>
    <article v-for="row in visible" :key="row.shift_id" class="overtime-row">
      <div class="overtime-person">
        <b>{{ row.full_name }}</b>
        <span>{{ row.title }}</span>
        <small>{{ payrollDate(row.starts_at) }} tại {{ row.location }}</small>
      </div>
      <div class="overtime-timing">
        <span>Dự kiến kết thúc {{ time(row.planned_ends_at) }}</span>
        <span>Hoàn tất {{ time(row.checked_out_at) }}</span>
        <strong>Quá {{ formatWorkDuration(row.overtime_ms) }}</strong>
      </div>
      <div class="overtime-result">
        <strong v-if="row.allowance_vnd != null">{{ payrollMoney(row.allowance_vnd) }}</strong>
        <span v-else>Chờ duyệt phụ cấp</span>
        <small v-if="row.note">{{ row.note }}</small>
        <small v-if="row.locked_status === 'paid'">Đã thanh toán</small>
        <small v-else-if="row.locked_status === 'prepared'">Đã nằm trong bảng chốt</small>
      </div>
      <button
        type="button"
        :disabled="['paid', 'prepared'].includes(row.locked_status)"
        @click="open(row)"
      >
        {{ row.allowance_vnd == null ? 'Duyệt phụ cấp' : 'Sửa mức bù' }}
      </button>
    </article>
    <dialog
      ref="dialog"
      class="overtime-dialog"
      aria-labelledby="overtime-form-title"
      @cancel.prevent="dismiss"
    >
      <template v-if="target">
        <div class="overtime-dialog-heading">
          <h2 id="overtime-form-title">Phụ cấp bù quá giờ</h2>
          <button type="button" aria-label="Đóng duyệt phụ cấp" :disabled="saving" @click="dismiss">
            ×
          </button>
        </div>
        <p>{{ target.full_name }}: {{ target.title }}</p>
        <div class="overtime-form-duration">
          <span>Thời gian quá giờ</span>
          <strong>{{ formatWorkDuration(target.overtime_ms) }}</strong>
        </div>
        <form class="form" @submit.prevent="submit">
          <label>
            Phụ cấp bù cho ca này (₫)
            <input
              v-model="amount"
              type="number"
              min="0"
              max="1000000000"
              step="1"
              required
              :disabled="saving"
              autofocus
            />
          </label>
          <label>
            Ghi chú
            <input
              v-model="note"
              maxlength="500"
              :required="Number(amount) === 0"
              :minlength="Number(amount) === 0 ? 3 : undefined"
              :disabled="saving"
              placeholder="Nếu bù 0 ₫, ghi rõ lý do"
            />
          </label>
          <p class="overtime-help">
            Mức này được cộng vào phụ cấp bù quá giờ của kỳ lương, tách với phụ cấp tháng và chi phí
            phát sinh.
          </p>
          <div v-if="error" class="alert" role="alert">{{ error }}</div>
          <div class="form-actions">
            <button type="button" :disabled="saving" @click="dismiss">Đóng</button>
            <button type="submit" class="primary" :disabled="saving">
              {{ saving ? 'Đang lưu...' : 'Lưu phụ cấp' }}
            </button>
          </div>
        </form>
      </template>
    </dialog>
  </section>
</template>

<style src="../styles/overtime.css"></style>
