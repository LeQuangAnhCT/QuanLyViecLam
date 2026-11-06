<script setup>
import { computed, ref, watch } from 'vue'
import provinces from '../data/vietnam-locations.json'

const props = defineProps({
  modelValue: { type: String, default: '' },
  required: { type: Boolean, default: false },
  detailLabel: { type: String, default: '' }
})
const emit = defineEmits(['update:modelValue'])

const provinceSearch = ref('')
const wardSearch = ref('')
const normalizeSearch = value => String(value || '').normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D').toLowerCase().trim()
const filteredProvinces = computed(() => provinces
  .filter(item => normalizeSearch(item.name).includes(normalizeSearch(provinceSearch.value))).slice(0, 12))
const filteredWards = computed(() => wards.value
  .filter(item => normalizeSearch(item.name).includes(normalizeSearch(wardSearch.value))).slice(0, 15))
const searching = ref('')
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
  provinceSearch.value = ''
  wardSearch.value = ''
  detail.value = ''
  legacyValue.value = ''
  searching.value = ''
  if (!value) return
  for (const item of provinces) {
    if (!value.endsWith(`, ${item.name}`)) continue
    const ward = item.wards.find(entry => value === `${entry.name}, ${item.name}` || value.endsWith(`, ${entry.name}, ${item.name}`))
    if (!ward) continue
    provinceCode.value = item.code
    wardCode.value = ward.code
    provinceSearch.value = item.name
    wardSearch.value = ward.name
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

function chooseProvince(item) {
  provinceCode.value = item.code
  provinceSearch.value = item.name
  wardCode.value = ''
  wardSearch.value = ''
  legacyValue.value = ''
  searching.value = ''
  publish()
}
function chooseWard(item) {
  wardCode.value = item.code
  wardSearch.value = item.name
  legacyValue.value = ''
  searching.value = ''
  publish()
}
function provinceTyped() {
  provinceCode.value = ''
  wardCode.value = ''
  wardSearch.value = ''
  legacyValue.value = ''
  searching.value = 'province'
  publish()
}
function wardTyped() {
  wardCode.value = ''
  legacyValue.value = ''
  searching.value = 'ward'
  publish()
}
function selectFirstProvince() {
  if (searching.value === 'province' && filteredProvinces.value.length) chooseProvince(filteredProvinces.value[0])
}
function selectFirstWard() {
  if (searching.value === 'ward' && filteredWards.value.length) chooseWard(filteredWards.value[0])
}
function clear() {
  provinceCode.value = ''
  wardCode.value = ''
  provinceSearch.value = ''
  wardSearch.value = ''
  detail.value = ''
  legacyValue.value = ''
  searching.value = ''
  publish()
}
</script>

<template>
  <div class="location-picker">
    <div class="form-grid">
      <div class="location-autocomplete">
        <label>Tỉnh / Thành phố
          <input v-model="provinceSearch" type="search" autocomplete="off" placeholder="Tìm tỉnh / thành phố"
            role="combobox" aria-autocomplete="list" :aria-expanded="searching === 'province'"
            :required="required && !legacyValue" @focus="searching='province'" @input="provinceTyped"
            @keydown.enter.prevent="selectFirstProvince" @keydown.esc="searching=''" @blur="searching=''">
        </label>
        <div v-if="searching === 'province' && filteredProvinces.length" class="location-suggestions" role="listbox" aria-label="Danh sách tỉnh thành">
          <button v-for="item in filteredProvinces" :key="item.code" type="button" role="option"
            :aria-selected="item.code === provinceCode" @mousedown.prevent @click="chooseProvince(item)">{{ item.name }}</button>
        </div>
      </div>
      <div class="location-autocomplete">
        <label>Phường / Xã / Đặc khu
          <input v-model="wardSearch" type="search" autocomplete="off" placeholder="Tìm phường / xã" :disabled="!provinceCode"
            role="combobox" aria-autocomplete="list" :aria-expanded="searching === 'ward'"
            :required="required && !legacyValue" @focus="searching='ward'" @input="wardTyped"
            @keydown.enter.prevent="selectFirstWard" @keydown.esc="searching=''" @blur="searching=''">
        </label>
        <div v-if="searching === 'ward' && filteredWards.length" class="location-suggestions" role="listbox" aria-label="Danh sách phường xã">
          <button v-for="item in filteredWards" :key="item.code" type="button" role="option"
            :aria-selected="item.code === wardCode" @mousedown.prevent @click="chooseWard(item)">{{ item.name }}</button>
        </div>
      </div>
    </div>
    <label v-if="detailLabel && wardCode">{{ detailLabel }}
      <input v-model="detail" maxlength="120" placeholder="Có thể bổ sung sau" @input="publish">
    </label>
    <p v-if="legacyValue" class="location-current">Địa điểm hiện tại: {{ legacyValue }}. Chọn tỉnh/thành và phường/xã để thay đổi.</p>
    <button v-if="!required && modelValue" type="button" class="text-button location-clear" @click="clear">Xóa lựa chọn</button>
  </div>
</template>
