<script setup>
import { ref, toRef, onMounted } from 'vue'
import { useCompanyDeletion } from '../../../../application/useCompanyDeletion'

const props = defineProps({ company: { type: Object, required: true } })
const emit = defineEmits(['close', 'deleted'])
const dialog = ref(null)
const { reason, saving, error, deleted, submit } = useCompanyDeletion(
  toRef(props, 'company'),
  (result) => emit('deleted', result)
)
onMounted(() => dialog.value.showModal())
function close() {
  if (!saving.value) emit('close', deleted.value)
}
</script>

<template>
  <dialog
    ref="dialog"
    class="admin-company-delete-dialog"
    aria-labelledby="delete-company-title"
    @cancel.prevent="close"
  >
    <header>
      <div>
        <p>Quản trị công ty</p>
        <h2 id="delete-company-title">Xóa {{ company.name }}?</h2>
      </div>
      <button
        type="button"
        aria-label="Đóng xác nhận xóa công ty"
        :disabled="saving"
        @click="close"
      >
        ×
      </button>
    </header>
    <p class="company-delete-warning">
      Xóa vĩnh viễn công ty cùng ca làm, chấm công, dữ liệu lương và chứng từ. Tài khoản của các
      thành viên vẫn được giữ.
    </p>
    <form @submit.prevent="submit">
      <label for="company-delete-reason">
        Lý do xóa
        <span>(bắt buộc)</span>
      </label>
      <textarea
        id="company-delete-reason"
        v-model="reason"
        required
        maxlength="500"
        rows="4"
        autofocus
        :disabled="saving || deleted"
        placeholder="Nhập lý do xóa công ty..."
      ></textarea>
      <small>{{ reason.length }}/500 ký tự · Lý do được lưu trong nhật ký quản trị.</small>
      <p v-if="error" class="company-delete-error" role="alert">{{ error }}</p>
      <footer>
        <button type="button" :disabled="saving" @click="close">Đóng</button>
        <button class="company-delete-confirm" type="submit" :disabled="saving || !reason.trim()">
          {{ saving ? 'Đang xóa...' : deleted ? 'Thử lại' : 'Xóa công ty' }}
        </button>
      </footer>
    </form>
  </dialog>
</template>

<style src="../styles/company-deletion.css"></style>
