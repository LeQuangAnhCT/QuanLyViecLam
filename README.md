# SHIFTLY · Quản lý ca làm việc

Ứng dụng web/PWA Vue 3 + Vite + Supabase, giao diện đen/trắng và tối ưu sử dụng trên điện thoại.

## Vai trò và ranh giới nghiệp vụ

| Vai trò | Được phép | Không được phép |
| --- | --- | --- |
| **Admin hệ thống** (app_metadata.role = admin) | Duyệt/từ chối đăng ký công ty, xem danh sách công ty, vô hiệu hóa/khôi phục tài khoản | Phân ca, thay đổi mức lương, duyệt yêu cầu gia nhập thay cho Manager |
| **Manager** (company_members.role = manager) | Xem ca của công ty, tạo/sửa/hủy ca **chưa chấm công**, quản lý nhân viên và mức lương | Quản trị nền tảng; hủy ca đã được nhân viên chấm công |
| **Staff** (company_members.role = staff) | Xem lịch được giao, chấm công vào/ra thực tế, giờ dự kiến và thông báo thay đổi ca | Tạo/sửa/hủy ca hoặc chấm công thay người khác |

Vai trò **Admin** được lấy từ **Supabase Auth app_metadata**, không lấy từ trường tự khai trong giao diện. Vai trò Manager/Staff thay đổi theo công ty được chọn. Một tài khoản có thể là Manager ở công ty A và Staff ở công ty B.

Lưu ý: nhánh này **giữ nguyên mô hình ba vai trò hiện có** của repository để tránh làm mất quy trình công ty/nhân sự. Nếu sản phẩm cuối chỉ cần một Admin và tất cả tài khoản còn lại là Staff, cần thiết kế lại quy trình đăng ký công ty và phân ca trước khi loại bỏ Manager.

## Quy tắc phân ca

- Chỉ Manager được tạo/sửa/hủy ca của Staff thuộc công ty đó. Nhấn ô ngày trống để tạo; ô có một ca để sửa; ô có nhiều ca để chọn ca. Có nút **Hủy ca** trong hộp sửa ca, với xác nhận trước khi hủy. Khi hủy thành công, Staff nhận thông báo từ database trigger.
- Một ca có ngày/giờ bắt đầu, kết thúc hợp lệ, thời lượng tối đa 24 giờ. Ca qua nửa đêm được hỗ trợ và hiển thị trên cả hai ngày.
- Một nhân viên không được có hai ca trùng khoảng thời gian, **kể cả ở hai công ty khác nhau**. Kiểm tra UI giúp thông báo sớm; trigger database mới là nguồn kiểm tra cuối cùng. Hai ca kết thúc/bắt đầu đúng cùng một thời điểm được chấp nhận.
- `planned_attendance` vẫn chỉ là **giờ dự kiến**, tách biệt với bảng `shift_attendance` chứa thời điểm Staff thực tế chấm công vào/ra.
- Staff chỉ chấm công cho ca của chính mình, từ **1 giờ trước giờ bắt đầu tới 12 giờ sau khi ca kết thúc**. Staff đã chấm công vào thì Manager **không được hủy ca hoặc thay nhân viên/đổi giờ**, kể cả gọi API trực tiếp. Có thể cập nhật tên công việc và địa điểm; dữ liệu đã chấm công được giữ nguyên.
- Không cho Staff chấm công lần thứ hai hay chấm công ra nhiều lần. Xác nhận tại Supabase bằng hàm `clock_in_shift`/`clock_out_shift`, không tin thời gian do trình duyệt gửi.
- Mức lương là thỏa thuận theo công ty và nhân viên, chưa phải chức năng thanh toán.
- Supabase trigger ghi thông báo **trong ứng dụng** cho Staff khi ca được tạo, sửa hoặc hủy, kể cả khi Staff đang không mở app. Thông báo có nút đánh dấu đã đọc và chỉ người nhận xem được. **Chỉ có hiệu lực sau khi chạy migration `shift_notifications.sql`.**
- Zalo/Facebook/Web Push chưa được tích hợp. Thông báo trong ứng dụng không có nghĩa là tin nhắn hoặc push đã được gửi.

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
6. **`supabase/shift_business_rules.sql`**
7. **`supabase/shift_notifications.sql`** (thông báo tạo/sửa/hủy ca)
8. **`supabase/shift_attendance.sql`** (**mới**: chấm công vào/ra và khóa hủy ca đã chấm công)

Nếu database đã tồn tại, hãy **sao lưu trước** và kiểm tra các migration đã áp dụng. Chạy các file còn thiếu theo thứ tự 6 → 7 → **8**. Chạy file mới số 8 để kích hoạt chấm công và bảo vệ ca đã chấm công. Không cần xóa dữ liệu lịch cũ. **Merge GitHub/Vercel không tự chạy SQL trên Supabase.** Trigger chỉ chặn thao tác ghi mới, không tự xóa dữ liệu lịch cũ. Nên kiểm tra trùng ca đã tồn tại trước khi triển khai:

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

- Quy trình duyệt/điều chỉnh sai sót chấm công, xử lý đến muộn/vắng mặt, và quy đổi thành bảng lương thực lĩnh.
- Thông báo nhắc lịch qua push/Zalo/Facebook hoặc tự gửi nhắc trước giờ làm (hiện mới có thông báo trong ứng dụng cho các sự kiện thay đổi ca).
- Nhật ký kiểm toán thay đổi chi tiết (ai sửa và giá trị trước/sau), ngoài thông báo đã gửi cho nhân viên.
- Màn hình báo cáo tổng hợp giờ công và xuất bảng lương.

Không nên gọi các tính năng trên là đã hoàn thành chỉ vì hiện có màn hình giờ công dự kiến.
