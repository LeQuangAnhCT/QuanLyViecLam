import { supabase } from '../lib/supabase'
import { validateReceipt } from '../domain/payroll-settlement'

async function data(request) {
  const result = await request
  if (result.error) throw result.error
  return result.data
}

export const payrollRepository = {
  summary: (company, month) =>
    data(supabase.rpc('payroll_month_summary', { p_company: company, p_month: month })),
  overtime: (company, month) =>
    data(supabase.rpc('payroll_overtime', { p_company: company, p_month: month })),
  approveOvertime: (shift, amount, note, request) =>
    data(
      supabase.rpc('approve_overtime_allowance', {
        p_shift: shift,
        p_amount: amount,
        p_note: note,
        p_request: request
      })
    ),
  prepare: (company, user, month, id) =>
    data(
      supabase.rpc('prepare_payroll_payment', {
        p_company: company,
        p_user: user,
        p_month: month,
        p_id: id
      })
    ),
  finalize: (id, receipt, transferDate, note) =>
    data(
      supabase.rpc('finalize_payroll_payment', {
        p_id: id,
        p_receipt_path: receipt,
        p_transfer_date: transferDate,
        p_note: note
      })
    ),
  cancel: (id) => data(supabase.rpc('cancel_payroll_payment', { p_id: id })),
  history: (company = null, month = null, page = 1, limit = 10) =>
    data(
      supabase.rpc('payroll_payment_history', {
        p_company: company || null,
        p_month: month || null,
        p_limit: limit,
        p_offset: (page - 1) * limit
      })
    ),
  payment: (id) => data(supabase.rpc('payroll_payment_detail', { p_id: id })),
  async uploadReceipt(payment, file, imageId) {
    const extension = validateReceipt(file)
    const path = `${payment.company_id}/${payment.user_id}/${payment.id}/${imageId}.${extension}`
    const result = await supabase.storage.from('payroll-receipts').upload(path, file, {
      contentType: file.type,
      upsert: false,
      cacheControl: '300'
    })
    // An earlier attempt may have uploaded successfully before its response was lost.
    if (
      result.error &&
      Number(result.error.statusCode ?? result.error.status) !== 409 &&
      result.error.error !== 'Duplicate'
    )
      throw result.error
    return path
  },
  async receiptUrl(path) {
    const result = await data(supabase.storage.from('payroll-receipts').createSignedUrl(path, 180))
    return result.signedUrl
  },
  removeUnusedReceipt: (path) => data(supabase.storage.from('payroll-receipts').remove([path]))
}
