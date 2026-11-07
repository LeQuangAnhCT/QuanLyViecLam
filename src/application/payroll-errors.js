export function payrollErrorText(error) {
  if (['PGRST202', 'PGRST204', '42P01', 'PGRST205'].includes(error?.code)) {
    return 'Chức năng kết toán chưa được kích hoạt đầy đủ. Vui lòng liên hệ quản trị viên.'
  }
  const messages = {
    P4550: 'Bạn không có quyền thực hiện thao tác này.',
    P4552: 'Nhân viên này không còn tiền cần thanh toán trong kỳ.',
    P4553: 'Kiểm tra ngày chuyển khoản. Kỳ lương được trả từ ngày 5 tháng kế tiếp.',
    P4554: 'Hãy duyệt các ca quá giờ của nhân viên trước khi chốt lương.',
    P4555: 'Bảng chốt hoặc phụ cấp đã được khóa. Hãy tải lại để xem trạng thái mới nhất.',
    P4556: 'Số đã trả vừa thay đổi. Hãy tải lại và đối chiếu chứng từ trước khi tiếp tục.',
    P4557: 'Cần ảnh chuyển khoản hợp lệ của đúng bảng chốt này.',
    P4558: 'Kiểm tra số tiền và ghi chú. Khi bù 0 ₫, hãy ghi lý do.',
    P4559: 'Không tìm thấy dữ liệu kỳ lương này.'
  }
  return messages[error?.code] || error?.message || 'Không tải được dữ liệu lương. Hãy thử lại.'
}
