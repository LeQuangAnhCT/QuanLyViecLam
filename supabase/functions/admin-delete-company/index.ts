import { createClient } from 'npm:@supabase/supabase-js@2.119.0'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' }
  })
const uuid = (value: unknown): value is string =>
  typeof value === 'string' &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)

// Authentication is verified with Auth.getUser before any privileged Storage operation.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Phương thức không hỗ trợ.' }, 405)
  const authorization = req.headers.get('Authorization') || ''
  if (!authorization.startsWith('Bearer ')) return json({ error: 'Vui lòng đăng nhập lại.' }, 401)
  const url = Deno.env.get('SUPABASE_URL')!
  const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false }
  })
  const {
    data: { user },
    error: authError
  } = await userClient.auth.getUser(authorization.slice(7))
  if (authError || !user) return json({ error: 'Phiên đăng nhập hết hạn.' }, 401)
  if (user.app_metadata?.role !== 'admin')
    return json({ error: 'Chỉ Admin được xóa công ty.' }, 403)
  let body
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Dữ liệu không hợp lệ.' }, 400)
  }
  if (
    !uuid(body?.company_id) ||
    !uuid(body?.request_id) ||
    typeof body?.reason !== 'string' ||
    !body.reason.trim() ||
    body.reason.trim().length > 500
  ) {
    return json({ error: 'Chọn công ty và nhập lý do xóa, tối đa 500 ký tự.' }, 400)
  }
  const { data: entry, error } = await userClient.rpc('admin_delete_company', {
    p_company: body.company_id,
    p_reason: body.reason.trim(),
    p_request: body.request_id
  })
  if (error)
    return json(
      {
        error: /^P456[0-3]$/.test(error.code)
          ? error.message
          : 'Không thể xóa công ty. Hãy thử lại.'
      },
      error.code === 'P4560' ? 403 : 400
    )
  if (!entry?.id) return json({ error: 'Chưa thể ghi nhận thao tác xóa.' }, 500)
  let cleanupComplete = !!entry.files_deleted_at
  const paths: string[] = Array.isArray(entry.receipt_paths) ? entry.receipt_paths : []
  if (
    !cleanupComplete &&
    paths.every((path) => typeof path === 'string' && path.startsWith(entry.company_id + '/'))
  ) {
    try {
      const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
        auth: { persistSession: false, autoRefreshToken: false }
      })
      for (let index = 0; index < paths.length; index += 100) {
        const { error: removeError } = await service.storage
          .from('payroll-receipts')
          .remove(paths.slice(index, index + 100))
        if (removeError) throw removeError
      }
      const { error: logError } = await service
        .from('company_deletion_log')
        .update({ files_deleted_at: new Date().toISOString() })
        .eq('id', entry.id)
      if (logError) throw logError
      cleanupComplete = true
    } catch {
      // The private audit retains the exact paths for an idempotent cleanup retry.
    }
  }
  return json({
    success: true,
    id: entry.id,
    company_id: entry.company_id,
    company_name: entry.company_name,
    cleanup_complete: cleanupComplete
  })
})
