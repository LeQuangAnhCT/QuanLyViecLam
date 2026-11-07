<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { roleLabel } from '../../../domain/calendar'
import LocationPicker from '../../LocationPicker.vue'
import ToastStack from '../../ToastStack.vue'
import provinces from '../../../data/vietnam-locations.json'
import { useWorkspaceContext } from '../../composables/useWorkspaceContext'

const props = defineProps({ user: { type: Object, required: true } })

const w = useWorkspaceContext()

const {
  directory,
  applications,
  accounts,
  adminCompanies,
  restriction,
  workspaceRoles,
  notifications,
  notificationsLoading,
  notificationsError,
  busy,
  loading,
  error,
  message,
  repo
} = w

const tab = ref('approval')

const modal = ref('')

const dialogClose = ref(null)

const toastStack = ref(null)

watch(
  modal,
  () => {
    error.value = ''
  },
  { flush: 'sync' }
)

watch(error, (text) => {
  if (!text || modal.value) return
  toastStack.value?.show(text, { kind: 'error', title: 'Cần chú ý' })
  error.value = ''
})

watch(message, (text) => {
  if (!text) return
  toastStack.value?.show(text, { kind: 'success', title: 'Thành công' })
  message.value = ''
})

const seenNotificationIds = new Set(notifications.value.map((item) => item.id))

watch(notifications, (items) => {
  const incoming = items.filter((item) => !item.read_at && !seenNotificationIds.has(item.id))
  for (const item of items) seenNotificationIds.add(item.id)
  if (loading.value || tab.value === 'notifications' || !incoming.length) return
  if (incoming.length === 1)
    toastStack.value?.show(incoming[0].body || incoming[0].title, { title: incoming[0].title })
  else
    toastStack.value?.show(`Có ${incoming.length} thông báo mới. Mở mục Thông báo để xem chi tiết.`)
})

const notificationPage = ref(1)

const notificationPageSize = 8

const notificationPages = computed(() =>
  Math.max(1, Math.ceil(notifications.value.length / notificationPageSize))
)

const visibleNotifications = computed(() =>
  notifications.value.slice(
    (notificationPage.value - 1) * notificationPageSize,
    notificationPage.value * notificationPageSize
  )
)

watch(notificationPages, (count) => {
  notificationPage.value = Math.min(notificationPage.value, count)
})

const disableTarget = ref(null)

const disableReason = ref('')

const accountProfile = reactive({
  full_name: props.user.user_metadata?.full_name || '',
  birth_date: '',
  hometown: '',
  active_location: '',
  avatar_url: ''
})

const avatarFile = ref(null)

const defaultAvatar =
  'data:image/svg+xml,' +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#e4e6eb"/><circle cx="50" cy="38" r="19" fill="#b0b3b8"/><path d="M14 100c2-24 16-37 36-37s34 13 36 37" fill="#b0b3b8"/></svg>'
  )

const avatarPreview = ref('')

function chooseAvatar(event) {
  const file = event.target.files?.[0]
  if (!file) return
  if (
    !['image/jpeg', 'image/png', 'image/webp'].includes(file.type) ||
    file.size > 2 * 1024 * 1024
  ) {
    avatarFile.value = null
    error.value = 'Ảnh phải là JPG, PNG hoặc WebP và không quá 2 MB.'
    event.target.value = ''
    return
  }
  avatarFile.value = file
  if (avatarPreview.value) URL.revokeObjectURL(avatarPreview.value)
  avatarPreview.value = URL.createObjectURL(file)
}

async function saveAccountProfile() {
  const name = accountProfile.full_name.trim()
  if (!name) {
    error.value = 'Vui lòng nhập họ tên.'
    return
  }
  if (accountProfile.birth_date && new Date(accountProfile.birth_date) > new Date()) {
    error.value = 'Ngày sinh không hợp lệ.'
    return
  }
  busy.value = true
  error.value = ''
  message.value = ''
  try {
    const avatar_url = avatarFile.value
      ? await repo.uploadAvatar(props.user.id, avatarFile.value)
      : accountProfile.avatar_url
    await repo.saveAccountProfile(props.user.id, {
      full_name: name,
      birth_date: accountProfile.birth_date || null,
      hometown: accountProfile.hometown.trim() || null,
      active_location: accountProfile.active_location.trim() || null,
      avatar_url: avatar_url || null
    })
    await repo.auth.updateUser({ data: { full_name: name } })
    Object.assign(accountProfile, { full_name: name, avatar_url })
    avatarFile.value = null
    if (avatarPreview.value) {
      URL.revokeObjectURL(avatarPreview.value)
      avatarPreview.value = ''
    }
    message.value = 'Đã cập nhật hồ sơ.'
  } catch (e) {
    error.value = e?.message || 'Không thể lưu hồ sơ.'
  } finally {
    busy.value = false
  }
}

const profileRoleLabel = 'Admin'

const unreadCount = computed(() => notifications.value.filter((n) => !n.read_at).length)

const notificationEventLabel = (event) =>
  ({
    company_application: 'Chờ duyệt',
    created: 'Ca mới',
    updated: 'Thay đổi lịch',
    cancelled: 'Ca đã hủy',
    employment_changed: 'Đổi vai trò',
    attendance_in: 'Chấm công vào',
    attendance_out: 'Chấm công ra',
    join_request: 'Yêu cầu gia nhập'
  })[event] || 'Thông báo'

const pendingApplications = computed(() => applications.value.filter((a) => a.status === 'pending'))

const tabs = computed(() => [
  ['approval', 'Đơn chờ duyệt'],
  ['notifications', 'Thông báo'],
  ['companies', 'Quản lý công ty'],
  ['accounts', 'Tài khoản'],
  ['profile', 'Hồ sơ của tôi']
])

function provinceKey(value) {
  return value
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .replace(/đ/g, 'd')
    .replace(/^(?:thanh pho|tinh)\s+|^tp\.?\s*/u, '')
}

const provinceNames = new Map(provinces.map(({ name }) => [provinceKey(name), name]))

provinceNames.set('hcm', provinceNames.get('ho chi minh'))

function companyProvince(address) {
  const part = address
    ?.split(',')
    .map((value) => value.trim())
    .filter(Boolean)
    .at(-1)
  return part && provinceNames.get(provinceKey(part))
}

const accountGroups = computed(() => {
  const groups = [
    { role: 'admin', label: 'Admin', items: [] },
    { role: 'manager', label: 'Manager', items: [] },
    { role: 'staff', label: roleLabel('staff'), items: [] },
    { role: 'freelance', label: roleLabel('freelance'), items: [] },
    { role: 'unknown', label: 'Chưa xác định', items: [] }
  ]
  const managerEmails = new Set(
    adminCompanies.value.map((company) => company.manager_email?.toLowerCase()).filter(Boolean)
  )
  for (const account of accounts.value) {
    const accountRole =
      workspaceRoles.value?.[account.user_id] ||
      (account.role === 'admin' || account.user_id === props.user.id
        ? 'admin'
        : account.role === 'manager' || managerEmails.has(account.email?.toLowerCase())
          ? 'manager'
          : 'unknown')
    groups.find((group) => group.role === accountRole)?.items.push(account)
  }
  for (const group of groups) {
    group.items.sort((a, b) =>
      (a.full_name || a.email || '').localeCompare(b.full_name || b.email || '', 'vi')
    )
  }
  return groups.filter((group) => group.items.length)
})

async function perform(fn, success, close = false) {
  if ((await w.perform(fn, success)) && close) modal.value = ''
}

function refreshAccountDirectory() {
  perform(() => Promise.resolve(), 'Đã làm mới danh sách tài khoản.')
}

function openDisableAccount(account) {
  disableTarget.value = account
  disableReason.value = ''
  error.value = ''
  modal.value = 'disable-account'
}

async function confirmDisableAccount() {
  if (!disableTarget.value || busy.value) return
  const reason = disableReason.value.trim()
  if (reason.length < 5) {
    error.value = 'Lý do phải có ít nhất 5 ký tự.'
    return
  }
  await perform(
    () =>
      repo.rpc('admin_set_account_disabled', {
        p_user: disableTarget.value.user_id,
        p_disabled: true,
        p_reason: reason
      }),
    'Đã vô hiệu hóa tài khoản.',
    true
  )
}

async function openApplication(notification) {
  tab.value = 'approval'
  await nextTick()
  document.getElementById(notification.id)?.focus()
}

function onWindowFocus() {
  if (restriction.value?.disabled || document.visibilityState === 'hidden') return
  w.refreshNotifications()
}

let notificationPoll = null

watch(tabs, (available) => {
  if (!available.some((item) => item[0] === tab.value)) tab.value = 'approval'
})

watch(tab, (next) => {
  if (next === 'notifications') w.refreshNotifications()
})

onMounted(() => {
  repo
    .accountProfile(props.user.id)
    .then((p) => {
      if (p)
        Object.assign(accountProfile, {
          full_name: p.full_name || accountProfile.full_name,
          birth_date: p.birth_date || '',
          hometown: p.hometown || '',
          active_location: p.active_location || '',
          avatar_url: p.avatar_url || ''
        })
    })
    .catch((e) => {
      error.value = e?.message || 'Không tải được hồ sơ.'
    })

  window.addEventListener('focus', onWindowFocus)
  // Keep the unread badge fresh without requiring users to open the inbox.
  notificationPoll = window.setInterval(() => {
    if (!restriction.value?.disabled && document.visibilityState === 'visible')
      w.refreshNotifications()
  }, 60000)
})

onUnmounted(() => {
  if (avatarPreview.value) URL.revokeObjectURL(avatarPreview.value)
  window.removeEventListener('focus', onWindowFocus)
  if (notificationPoll) window.clearInterval(notificationPoll)
})
</script>

<template>
  <div class="role-page role-admin">
    <ToastStack ref="toastStack" />
    <div class="app-shell">
      <aside class="sidebar">
        <div class="brand">
          <span class="brand-mark">S</span>
          <div>
            <strong>SHIFTLY</strong>
            <small>Quản lý nhân sự sự kiện</small>
          </div>
        </div>
        <div class="workspace-profile">
          <img
            class="profile-avatar"
            :src="avatarPreview || accountProfile.avatar_url || defaultAvatar"
            alt="Ảnh đại diện"
          />
          <div class="profile-details">
            <div class="profile-name-row">
              <b class="profile-name" :title="accountProfile.full_name || 'Tài khoản'">
                {{ accountProfile.full_name || 'Tài khoản' }}
              </b>
              <span class="profile-role" :title="roleLabel('admin')">{{ profileRoleLabel }}</span>
            </div>
            <small class="profile-email" :title="user.email">{{ user.email }}</small>
          </div>
        </div>
        <div class="side-label">QUẢN TRỊ HỆ THỐNG</div>
        <nav aria-label="Điều hướng chính">
          <button
            v-for="item in tabs"
            :key="item[0]"
            :class="{ selected: tab === item[0] }"
            :aria-current="tab === item[0] ? 'page' : undefined"
            @click="tab = item[0]"
          >
            {{ item[1] }}
            <span v-if="item[0] === 'notifications' && unreadCount" class="nav-unread">
              {{ unreadCount }}
            </span>
          </button>
          <button type="button" class="nav-sign-out" @click="repo.auth.signOut()">Đăng xuất</button>
        </nav>
      </aside>
      <div class="main-area">
        <header class="mobile-header">
          <div class="brand">
            <span class="brand-mark">S</span>
            <div>
              <strong>SHIFTLY</strong>
              <small>Quản lý nhân sự sự kiện</small>
            </div>
          </div>
          <div class="workspace-profile">
            <img
              class="profile-avatar"
              :src="avatarPreview || accountProfile.avatar_url || defaultAvatar"
              alt="Ảnh đại diện"
            />
            <div class="profile-details">
              <div class="profile-name-row">
                <b class="profile-name" :title="accountProfile.full_name || 'Tài khoản'">
                  {{ accountProfile.full_name || 'Tài khoản' }}
                </b>
                <span class="profile-role" :title="roleLabel('admin')">{{ profileRoleLabel }}</span>
              </div>
              <small class="profile-email" :title="user.email">{{ user.email }}</small>
            </div>
          </div>
        </header>
        <nav class="mobile-nav" aria-label="Điều hướng trên điện thoại">
          <button
            v-for="item in tabs"
            :key="item[0]"
            :class="{ selected: tab === item[0] }"
            :aria-current="tab === item[0] ? 'page' : undefined"
            @click="tab = item[0]"
          >
            {{ item[1] }}
            <span v-if="item[0] === 'notifications' && unreadCount" class="nav-unread">
              {{ unreadCount }}
            </span>
          </button>
          <button type="button" class="nav-sign-out" @click="repo.auth.signOut()">Đăng xuất</button>
        </nav>
        <main class="content">
          <div class="page-heading">
            <div>
              <p class="eyebrow">{{ roleLabel('admin') }}</p>
              <h1>{{ tabs.find((t) => t[0] === tab)?.[1] }}</h1>
              <p>Phê duyệt công ty và kiểm soát tài khoản trên toàn hệ thống.</p>
            </div>
          </div>
          <section v-if="tab === 'profile'" class="surface section">
            <h2>Hồ sơ của tôi</h2>
            <p>
              Áp dụng cho tài khoản {{ roleLabel('admin') }}. Cập nhật quê quán, khu vực hoạt động
              và ảnh đại diện.
            </p>
            <form class="form" @submit.prevent="saveAccountProfile">
              <img
                class="profile-avatar profile-avatar-large"
                :src="avatarPreview || accountProfile.avatar_url || defaultAvatar"
                alt="Ảnh đại diện"
              />
              <label>
                Ảnh đại diện
                <input
                  type="file"
                  accept="image/jpeg,image/png,image/webp"
                  @change="chooseAvatar"
                />
              </label>
              <label>
                Họ và tên
                <input v-model="accountProfile.full_name" required maxlength="120" />
              </label>
              <label>
                Ngày sinh
                <input v-model="accountProfile.birth_date" type="date" />
              </label>
              <div class="location-field">
                <span class="location-title">Quê quán</span>
                <LocationPicker v-model="accountProfile.hometown" />
              </div>
              <div class="location-field">
                <span class="location-title">Khu vực đang hoạt động</span>
                <LocationPicker v-model="accountProfile.active_location" />
              </div>
              <button class="primary" :disabled="busy">Lưu hồ sơ</button>
            </form>
          </section>
          <section v-if="tab === 'approval'" class="overview-grid" aria-label="Tổng quan quản trị">
            <div class="overview-tile">
              <span>Đơn đang chờ</span>
              <strong>{{ applications.filter((a) => a.status === 'pending').length }}</strong>
              <small>Cần quản trị viên xét duyệt</small>
            </div>
            <div class="overview-tile">
              <span>Công ty đã duyệt</span>
              <strong>{{ adminCompanies.length }}</strong>
              <small>Đang hoạt động trên hệ thống</small>
            </div>
            <div class="overview-tile">
              <span>Tài khoản</span>
              <strong>{{ accounts.length }}</strong>
              <small>Đã từng đăng nhập</small>
            </div>
          </section>
          <section v-if="tab === 'notifications'" class="surface section notifications-section">
            <div class="section-title">
              <div>
                <h2>Thông báo Admin</h2>
                <p>Đơn đăng ký công ty đang chờ xử lý.</p>
              </div>
              <button
                type="button"
                :disabled="notificationsLoading"
                @click="w.refreshNotifications()"
              >
                Làm mới
              </button>
            </div>
            <div v-if="notificationsError" class="alert" role="alert">{{ notificationsError }}</div>
            <div
              v-else-if="notificationsLoading && !notifications.length"
              class="empty"
              role="status"
            >
              Đang tải thông báo...
            </div>
            <div v-else-if="!visibleNotifications.length" class="empty">
              Không có đơn đăng ký công ty chờ duyệt.
            </div>
            <div
              v-for="item in visibleNotifications"
              :key="item.id"
              class="row notification-row"
              :class="{ unread: !item.read_at }"
            >
              <div class="notification-main">
                <div class="notification-head">
                  <b>{{ item.title }}</b>
                  <span class="badge">{{ notificationEventLabel(item.event) }}</span>
                </div>
                <small v-if="item.created_at">
                  <template v-if="item.company_id">
                    {{ directory.find((c) => c.id === item.company_id)?.name || 'Công ty' }} ·
                  </template>
                  {{ new Date(item.created_at).toLocaleString('vi-VN') }}
                </small>
                <p>{{ item.body }}</p>
              </div>
              <button type="button" @click="openApplication(item)">Xem đơn</button>
            </div>
            <nav
              v-if="notificationPages > 1"
              class="notification-pagination"
              aria-label="Phân trang thông báo"
            >
              <button type="button" :disabled="notificationPage === 1" @click="notificationPage--">
                Trang trước
              </button>
              <span role="status">Trang {{ notificationPage }} / {{ notificationPages }}</span>
              <button
                type="button"
                :disabled="notificationPage === notificationPages"
                @click="notificationPage++"
              >
                Trang sau
              </button>
            </nav>
          </section>
          <section
            v-if="tab === 'companies'"
            class="surface section company-directory"
            aria-labelledby="company-directory-title"
          >
            <div class="company-directory-heading">
              <h2 id="company-directory-title">Danh sách công ty</h2>
              <span class="badge">{{ adminCompanies.length }} công ty</span>
            </div>
            <p v-if="!adminCompanies.length" class="empty">Chưa có công ty trong danh sách.</p>
            <article
              v-for="company in adminCompanies"
              :key="company.id"
              class="company-directory-row"
            >
              <div class="company-directory-name">
                <h3>{{ company.name }}</h3>
                <small v-if="company.contact_email">{{ company.contact_email }}</small>
                <small v-if="company.phone">{{ company.phone }}</small>
              </div>
              <dl class="company-directory-fields">
                <div>
                  <dt>Tỉnh / Thành phố</dt>
                  <dd>{{ companyProvince(company.address) || 'Chưa xác định' }}</dd>
                </div>
                <div>
                  <dt>Địa chỉ</dt>
                  <dd>{{ company.address?.trim() || 'Chưa cập nhật' }}</dd>
                </div>
                <div>
                  <dt>Người quản lý</dt>
                  <dd>
                    {{ company.manager_name?.trim() || company.manager_email || 'Chưa có quản lý' }}
                    <small
                      v-if="
                        company.manager_email &&
                        company.manager_email !==
                          (company.manager_name?.trim() || company.manager_email)
                      "
                    >
                      {{ company.manager_email }}
                    </small>
                  </dd>
                </div>
              </dl>
            </article>
          </section>
          <section v-if="tab === 'approval'" class="surface section">
            <h2>Đơn đăng ký công ty</h2>
            <p>Kiểm tra thông tin trước khi duyệt.</p>
            <div v-if="notificationsError" class="alert" role="alert">{{ notificationsError }}</div>
            <div v-else-if="!pendingApplications.length" class="empty">
              Không có đơn đang chờ duyệt.
            </div>
            <div
              v-for="a in pendingApplications"
              :id="'application-' + a.id"
              :key="a.id"
              class="row"
              tabindex="-1"
            >
              <div>
                <b>{{ a.company_name }}</b>
                <small>{{ a.address }} | {{ a.phone }} | {{ a.email }}</small>
              </div>
              <div class="row-actions">
                <button
                  :disabled="busy"
                  @click="
                    perform(
                      () =>
                        repo.rpc('review_company_application', { p_id: a.id, p_approve: false }),
                      'Đã từ chối đơn.'
                    )
                  "
                >
                  Từ chối
                </button>
                <button
                  class="primary"
                  :disabled="busy"
                  @click="
                    perform(
                      () => repo.rpc('review_company_application', { p_id: a.id, p_approve: true }),
                      'Đã duyệt công ty.'
                    )
                  "
                >
                  Duyệt
                </button>
              </div>
            </div>
          </section>
          <section v-if="tab === 'accounts'" class="surface section account-directory">
            <div class="section-title">
              <div>
                <h2>Quản lý tài khoản</h2>
                <p>Thông tin hồ sơ và trạng thái truy cập theo vai trò.</p>
              </div>
              <button type="button" :disabled="busy" @click="refreshAccountDirectory">
                Làm mới
              </button>
            </div>
            <div v-if="!accountGroups.length" class="empty">Chưa có tài khoản để hiển thị.</div>
            <section
              v-for="group in accountGroups"
              :key="group.role"
              class="account-group"
              :aria-labelledby="'accounts-' + group.role"
            >
              <h3 :id="'accounts-' + group.role">
                {{ group.label }}
                <span class="badge">{{ group.items.length }}</span>
              </h3>
              <ul class="account-list">
                <li v-for="a in group.items" :key="a.user_id" class="row account-row">
                  <div class="account-identity">
                    <b>{{ a.full_name || a.email }}</b>
                    <small v-if="a.email">{{ a.email }}</small>
                    <small>
                      {{
                        a.disabled
                          ? a.reason
                            ? 'Đã vô hiệu hóa · ' + a.reason
                            : 'Đã vô hiệu hóa'
                          : 'Được phép truy cập'
                      }}
                    </small>
                  </div>
                  <dl class="account-fields">
                    <div>
                      <dt>Tuổi</dt>
                      <dd>{{ a.age == null ? 'Chưa cập nhật' : a.age + ' tuổi' }}</dd>
                    </div>
                    <div>
                      <dt>Quê quán</dt>
                      <dd>{{ a.hometown || 'Chưa cập nhật' }}</dd>
                    </div>
                    <div>
                      <dt>Khu vực hoạt động</dt>
                      <dd>{{ a.active_location || 'Chưa cập nhật' }}</dd>
                    </div>
                  </dl>
                  <div v-if="group.role !== 'admin'" class="account-actions">
                    <button
                      v-if="a.disabled"
                      type="button"
                      :disabled="busy"
                      @click="
                        perform(
                          () =>
                            repo.rpc('admin_set_account_disabled', {
                              p_user: a.user_id,
                              p_disabled: false,
                              p_reason: a.reason
                            }),
                          'Đã kích hoạt tài khoản.'
                        )
                      "
                    >
                      Kích hoạt
                    </button>
                    <button v-else type="button" :disabled="busy" @click="openDisableAccount(a)">
                      Vô hiệu hóa
                    </button>
                  </div>
                  <div v-else-if="a.user_id === user.id" class="account-actions">
                    <span class="badge">Tài khoản của bạn</span>
                  </div>
                </li>
              </ul>
            </section>
          </section>
        </main>
      </div>
      <div v-if="modal" class="overlay" @click.self="modal = ''" @keydown.esc="modal = ''">
        <section
          class="dialog dialog-small"
          role="dialog"
          aria-modal="true"
          aria-label="Vô hiệu hóa tài khoản"
        >
          <div class="dialog-heading">
            <h2>Vô hiệu hóa tài khoản</h2>
            <button ref="dialogClose" aria-label="Đóng" @click="modal = ''">×</button>
          </div>
          <div v-if="error" class="alert" role="alert">{{ error }}</div>
          <form class="form" @submit.prevent="confirmDisableAccount">
            <p>
              Nhập lý do vô hiệu hóa tài khoản
              {{ disableTarget?.full_name || disableTarget?.email }}.
            </p>
            <label>
              Lý do
              <input
                v-model="disableReason"
                required
                minlength="5"
                maxlength="500"
                placeholder="Ít nhất 5 ký tự"
                autofocus
              />
            </label>
            <div class="form-actions">
              <button type="button" @click="modal = ''">Hủy</button>
              <button class="primary" :disabled="busy">Xác nhận</button>
            </div>
          </form>
        </section>
      </div>
    </div>
  </div>
</template>

<style src="./styles/index.css"></style>
