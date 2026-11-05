# SHIFTLY · Quản lý ca làm việc

Ứng dụng web/PWA Vue 3 + Vite + Supabase, giao diện đen/trắng và tối ưu sử dụng trên điện thoại.

## Vai trò và ranh giới nghiệp vụ

| Vai trò | Được phép | Không được phép |
| --- | --- | --- |
| **Admin hệ thống** (app_metadata.role = admin) | Duyệt/từ chối đăng ký công ty, xem danh sách công ty, vô hiệu hóa/khôi phục tài khoản | Phân ca, thay đổi mức lương, duyệt yêu cầu gia nhập thay cho Manager |
| **Manager công ty** (company_members.role = manager) | Xem nhân sự và toàn bộ ca trong công ty của mình, thêm/xóa ca, mời người, xét yêu cầu, cập nhật mức lương thỏa thuận | Quản trị nền tảng hoặc công ty khác |
| **Staff** (company_members.role = staff) | Xem ca cá nhân, giờ làm *dự kiến*, danh sách đồng nghiệp, xin tham gia công ty, hồ sơ freelancer | Phân ca, xóa ca, thay đổi lương/duyệt người |

Vai trò **Admin** được lấy từ **Supabase Auth app_metadata**, không lấy từ trường tự khai trong giao diện. Vai trò Manager/Staff thay đổi theo công ty được chọn. Một tài khoản có thể là Manager ở công ty A và Staff ở công ty B.

Lưu ý: nhánh này **giữ nguyên mô hình ba vai trò hiện có** của repository để tránh làm mất quy trình công ty/nhân sự. Nếu sản phẩm cuối chỉ cần một Admin và tất cả tài khoản còn lại là Staff, cần thiết kế lại quy trình đăng ký công ty và phân ca trước khi loại bỏ Manager.

## Quy tắc phân ca

- Chỉ Manager công ty có thể tạo/xóa ca của nhân viên thuộc công ty đó (kiểm soát qua Supabase RLS).
- Một ca có ngày/giờ bắt đầu, kết thúc hợp lệ, thời lượng tối đa 24 giờ. Ca qua nửa đêm được hỗ trợ và hiển thị trên cả hai ngày.
- Một nhân viên không được có hai ca trùng khoảng thời gian, **kể cả ở hai công ty khác nhau**. Kiểm tra UI giúp thông báo sớm; trigger database mới là nguồn kiểm tra cuối cùng. Hai ca kết thúc/bắt đầu đúng cùng một thời điểm được chấp nhận.
- Giờ công hiển thị được tính từ ca dự kiến, **không phải điểm danh, chấm công hay bảng lương**.
- Mức lương là thỏa thuận theo công ty và nhân viên, chưa phải chức năng thanh toán.
- Zalo/Facebook/Web Push chưa được tích hợp; không nên coi lịch đã lưu là đã được gửi nhắc việc.

## Cài đặt và kiểm tra

```bash
npm ci
npm run test:domain
npm run test:db
npm run build
npm run dev
```

Cấu hình `VITE_SUPABASE_URL` và `VITE_SUPABASE_ANON_KEY` trong `.env.local` cho dự án Supabase của bạn. Chỉ dùng **publishable / anon key** ở frontend; tuyệt đối không đưa service-role key vào web.

### Database migration

Với dự án mới, chạy trong Supabase SQL Editor theo thứ tự:

1. `supabase/multi_company.sql`
2. `supabase/company_approval.sql`
3. `supabase/account_controls.sql`
4. `supabase/admin_scope.sql`
5. `supabase/member_compensation.sql`
6. **`supabase/shift_business_rules.sql`** (mới)

Nếu database đã tồn tại và đã được tạo bởi năm file đầu, **chỉ cần chạy file số 6** (sau khi sao lưu và kiểm tra các migration trước đó đã được áp dụng). Trigger chỉ chặn thao tác ghi mới, không tự xóa dữ liệu lịch cũ. Nên kiểm tra trùng ca đã tồn tại trước khi triển khai:

```sql
select a.user_id, a.id as shift_a, b.id as shift_b, a.starts_at, a.ends_at, b.starts_at, b.ends_at
from public.company_shifts a
join public.company_shifts b on a.user_id=b.user_id and a.id < b.id
where a.starts_at < b.ends_at and b.starts_at < a.ends_at;
```

Danh sách kết quả nếu có cần được quản lý điều chỉnh thủ công. RLS và RPC phải được thực thi ở Supabase; chỉ đổi giao diện Vue **không** thay thế cho phân quyền database.

### Xem trước từng vai trò

Chạy `npm run dev`, mở trang `/tests/role.html?role=admin`, `?role=manager` hoặc `?role=staff`. Đây là dữ liệu giả lập chỉ dùng kiểm tra giao diện, không thuộc bản phát hành.

### Phần còn thiếu

- Chấm công thực tế: check-in/check-out, xác minh giờ công, xử lý đến muộn/vắng mặt.
- Thông báo nhắc lịch: push/in-app và tích hợp Zalo/Facebook nếu có quyền API hợp lệ.
- Quy trình sửa ca, hủy ca có lưu nhật ký và thông báo thay đổi.
- Màn hình báo cáo tổng hợp giờ công và xuất bảng lương.

Không nên gọi các tính năng trên là đã hoàn thành chỉ vì hiện có màn hình giờ công dự kiến.
