import { inject } from 'vue'

export const workspaceKey = Symbol('workspace')

export function useWorkspaceContext() {
  const workspace = inject(workspaceKey)
  if (!workspace) throw new Error('Trang cần được mở qua bộ điều hướng tài khoản.')
  return workspace
}
