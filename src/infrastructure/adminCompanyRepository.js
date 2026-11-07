import { supabase } from '../lib/supabase'

export const adminCompanyRepository = {
  async deleteCompany(company, reason, request) {
    const { data, error } = await supabase.functions.invoke('admin-delete-company', {
      body: { company_id: company, reason, request_id: request }
    })
    if (error) {
      let detail
      try {
        detail = await error.context?.json()
      } catch {
        /* Network failure has no response. */
      }
      throw new Error(detail?.error || 'Không thể xóa công ty. Hãy thử lại.')
    }
    if (!data?.success) throw new Error(data?.error || 'Chưa thể xóa công ty.')
    return data
  }
}
