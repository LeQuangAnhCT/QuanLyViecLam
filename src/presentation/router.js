import { createRouter, createWebHistory } from 'vue-router'

export function createWorkspaceRouter(history = createWebHistory(import.meta.env.BASE_URL)) {
  return createRouter({
    history,
    scrollBehavior: (_to, _from, savedPosition) => savedPosition || { top: 0 },
    routes: [
      { path: '/', name: 'workspace', component: { render: () => null } },
      {
        path: '/admin',
        name: 'admin',
        meta: { role: 'admin' },
        component: () => import('./pages/admin/AdminPage.vue')
      },
      {
        path: '/manager',
        name: 'manager',
        meta: { role: 'manager' },
        component: () => import('./pages/manager/ManagerPage.vue')
      },
      {
        path: '/staff',
        name: 'staff',
        meta: { role: 'staff' },
        component: () => import('./pages/staff/StaffPage.vue')
      },
      {
        path: '/freelance',
        name: 'freelance',
        meta: { role: 'freelance' },
        component: () => import('./pages/freelance/FreelancePage.vue')
      },
      { path: '/:pathMatch(.*)*', redirect: '/' }
    ]
  })
}
