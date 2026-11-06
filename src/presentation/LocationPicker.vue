<script setup>
import { computed, ref, watch } from 'vue'
import provinces from '../data/vietnam-locations.json'

const props = defineProps({
  modelValue: { type: String, default: '' },
  required: { type: Boolean, default: false },
  detailLabel: { type: String, default: '' }
})
const emit = defineEmits(['update:modelValue'])

const provinceCode = ref('')
const wardCode = ref('')
const detail = ref('')
const legacyValue = ref('')
const province = computed(() => provinces.find(item => item.code === provinceCode.value))
const wards = computed(() => province.value?.wards || [])
let lastEmitted

watch(() => props.modelValue, value => {
  if (value === lastEmitted) return
  provinceCode.value = ''
  wardCode.value = ''
  detail.value = ''
  legacyValue.value = ''
  if (!value) return
  for (const item of provinces) {
    if (!value.endsWith(`, ${item.name}`)) continue
    const ward = item.wards.find(entry => value === `${entry.name}, ${item.name}` || value.endsWith(`, ${entry.name}, ${item.name}`))
    if (!ward) continue
    provinceCode.value = item.code
    wardCode.value = ward.code
    detail.value = value.slice(0, value.length - `${ward.name}, ${item.name}`.length).replace(/,\s*$/, '')
    return
  }
  legacyValue.value = value
}, { immediate: true })

function publish() {
  const ward = wards.value.find(item => item.code === wardCode.value)
  const value = province.value && ward
    ? [detail.value.trim(), ward.name, province.value.name].filter(Boolean).join(', ')
    : ''
  lastEmitted = value
  emit('update:modelValue', value)
}

function changeProvince() {
  wardCode.value = ''
  legacyValue.value = ''
  publish()
}

function clear() {
  provinceCode.value = ''
  wardCode.value = ''
  detail.value = ''
  legacyValue.value = ''
  publish()
}
</script>

<template>
  <div class="location-picker">
    <div class="form-grid">
      <label>Tỉnh / Thành phố
        <select v-model="provinceCode" :required="required && !legacyValue" @change="changeProvince">
          <option value="">Chọn tỉnh / thành phố</option>
          <option v-for="item in provinces" :key="item.code" :value="item.code">{{ item.name }}</option>
        </select>
      </label>
      <label>Phường / Xã / Đặc khu
        <select v-model="wardCode" :disabled="!provinceCode" :required="required && !legacyValue" @change="publish">
          <option value="">Chọn phường / xã</option>
          <option v-for="item in wards" :key="item.code" :value="item.code">{{ item.name }}</option>
        </select>
      </label>
    </div>
    <label v-if="detailLabel && wardCode">{{ detailLabel }}
      <input v-model="detail" maxlength="120" placeholder="Có thể bổ sung sau" @input="publish">
    </label>
    <p v-if="legacyValue" class="location-current">Địa điểm hiện tại: {{ legacyValue }}. Chọn tỉnh/thành và phường/xã để thay đổi.</p>
    <button v-if="!required && modelValue" type="button" class="text-button location-clear" @click="clear">Xóa lựa chọn</button>
  </div>
</template>
