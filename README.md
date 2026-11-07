# SHIFTLY · Quản lý ca làm việc

Ứng dụng web/PWA Vue 3 + Vite + Supabase, giao diện đen/trắng và tối ưu sử dụng trên điện thoại.

## Cài Supabase mới từ đầu (SQL đầy đủ 1 lần dán)

1. Tạo **project Supabase mới**, mở **SQL Editor**. Dán toàn bộ nội dung `supabase/FULL_SETUP_FROM_SCRATCH.sql` và bấm **Run**. File này bao gồm bảng, RLS, RPC, trigger, chấm công, lương, thông báo và bucket ảnh đại diện. Không dùng file này để nâng cấp database đang có dữ liệu.
2. Nếu **cố ý xóa toàn bộ dữ liệu Shiftly trên project cũ**, sao lưu trước, chạy `supabase/RESET_SHIFTLY_ONLY.sql` rồi mới chạy `supabase/FULL_SETUP_FROM_SCRATCH.sql`. Reset không xóa `auth.users`, OAuth settings và file ảnh trên Storage; **không thể khôi phục ca, lương, chấm công bằng script**.
3. Vào **Authentication → Providers → Google** để cấu hình Google OAuth, và **URL Configuration** để thêm URL frontend/redirect. Đăng nhập Google ít nhất một lần để tạo `auth.users`.
4. Chỉ định **Admin hệ thống** một lần trong SQL Editor bằng email của tài khoản đã đăng nhập, thay email ví dụ bằng email thực tế:

   ```sql
   update auth.users
      set raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb)
        || '{"role":"admin"}'::jsonb
    where lower(email) = lower('admin@example.com');
   ```

   Đăng xuất rồi đăng nhập lại để JWT nhận quyền Admin mới. **Không** chạy lệnh này bằng frontend và không đặt service-role key ở client.
5. Tạo `.env.local` chứa `VITE_SUPABASE_URL=...` và `VITE_SUPABASE_ANON_KEY=...` (publishable/anon key từ Supabase Dashboard → Project Settings → API). Khởi chạy `npm ci && npm run dev`.

**Cập nhật database đang sử dụng**: `supabase/production_upgrade.sql` nâng cấp không xóa dữ liệu; `supabase/account_profile_upgrade.sql` bổ sung hồ sơ và avatar. Nếu database ban đầu chưa có bảng cốt lõi, dùng full-install mới hoặc chạy các migration nền tảng đúng thứ tự; không chạy upgrade đơn lẻ trên database trống.

**Trạng thái nhân viên.** Manager có thể tạm ngừng hoặc kích hoạt lại STAFF và Freelance. Khi tạm ngừng, hệ thống hủy các ca tương lai chưa chấm công và lưu lịch sử chấm công, lương. Nhân viên cần hoàn tất ca đang làm trước khi Manager tạm ngừng.

## Vai trò và ranh giới nghiệp vụ

| Vai trò | Phạm vi |
| --- | --- |
| **Admin** | Duyệt đăng ký công ty, xem danh sách công ty và quản lý quyền truy cập tài khoản trên toàn hệ thống. |
| **Manager** | Phân ca, quản lý nhân sự, xem bảng công và thiết lập vai trò, mức lương trong công ty mình quản lý. |
| **STAFF** | Xem lịch được giao, chấm công, nhập chi phí phát sinh, xem thông báo và thu nhập cá nhân. |
| **Freelance** | Có cùng quyền làm ca và xem thông tin cá nhân như STAFF. |

Supabase Auth xác định Admin qua `app_metadata.role`. Các vai trò còn lại áp dụng theo công ty được chọn. Một người có thể là Manager ở công ty A và Freelance ở công ty B. Danh sách tài khoản toàn hệ thống xếp theo vai trò cao nhất của mỗi người theo thứ tự Admin, Manager, STAFF, Freelance.

Giao diện được tách thành bốn trang độc lập: `/admin`, `/manager`, `/staff`, `/freelance`, tương ứng các thư mục `src/presentation/pages/admin`, `manager`, `staff`, `freelance`. Mỗi thư mục sở hữu page, menu, popup và `styles/` riêng; CSS chia tiếp theo chức năng hiển thị. `WorkspaceRouter.vue` chỉ tải dữ liệu tài khoản và điều hướng đến đúng trang theo quyền tại công ty đang chọn. Nghiệp vụ dùng tầng `application`/`domain`, truy cập Supabase qua `infrastructure`.

## Phân loại nhân viên và nghiệp vụ tiền công

Chỉ **Manager** của công ty được chuyển Freelance thành STAFF trong **Quản lý nhân sự → Mức lương → Vai trò tại công ty**. Trong Supabase, cả hai dùng quyền làm ca `company_members.role = 'staff'`. Loại nhân sự nằm trong `member_compensation.employment_type` của từng công ty.

| Loại hiển thị | Mã lưu DB | Cách tính ước tính |
| --- | --- | --- |
| **STAFF** | `employee` | Lương cơ bản/tháng + phụ cấp hàng tháng + tổng Cast của các ca đã hoàn tất |
| **Freelance** | `freelancer` | Phụ cấp hàng tháng (nếu có) + tổng Cast của các ca đã hoàn tất |

Nhân viên mới gia nhập mặc định là **Freelance**. STAFF và Freelance chỉ xem được mức lương và thu nhập ước tính của chính họ.

Menu **Bảng công & lương** của Manager xem theo tháng, phân biệt ca đã phân và ca
hoàn tất chấm công. Menu **Thu nhập** có thống kê cá nhân cho STAFF và Freelance.
**Các con số chỉ là ước tính theo lương cơ bản, phụ cấp tháng và Cast của ca đã hoàn tất**, không phải bảng lương,
quyết toán hay tiền đã trả: chưa áp dụng thuế, bảo hiểm, tạm ứng, nghỉ phép,
quy tắc làm thêm hoặc lịch sử điều chỉnh đơn giá. Lương tháng chưa được tính
theo tỷ lệ ngày công hoặc số ngày bắt đầu hợp đồng.

Mục tuyển nhân sự Freelance hiển thị hồ sơ công khai của những người chưa gia nhập công ty đang chọn.

## Quy tắc phân ca

- Chỉ Manager được tạo, sửa hoặc hủy ca của STAFF và Freelance thuộc công ty đó. Nhấn ô ngày trống để tạo ca. Nhấn ô đã có ca để mở **Quản lý ca trong ngày**, nơi có thể sửa từng ca, thêm ca mới hoặc xóa tất cả ca sau khi xác nhận. Nếu có ca đã chấm công, thao tác xóa tất cả bị chặn. Khi hủy thành công, người được phân ca nhận thông báo trong ứng dụng.
- Một ca có ngày/giờ bắt đầu, kết thúc hợp lệ, thời lượng tối đa 24 giờ. Ca qua nửa đêm được hỗ trợ và hiển thị trên cả hai ngày.
- Một nhân viên không được có hai ca trùng khoảng thời gian, **kể cả ở hai công ty khác nhau**. Kiểm tra UI giúp thông báo sớm; trigger database mới là nguồn kiểm tra cuối cùng. Hai ca kết thúc/bắt đầu đúng cùng một thời điểm được chấp nhận.
- `planned_attendance` vẫn chỉ là **giờ dự kiến**, tách biệt với bảng `shift_attendance` chứa thời điểm STAFF thực tế chấm công vào/ra.
- STAFF chỉ chấm công cho ca của chính mình, từ **1 giờ trước giờ bắt đầu tới 12 giờ sau khi ca kết thúc**. STAFF đã chấm công vào thì Manager **không được hủy ca hoặc thay nhân viên/đổi giờ**, kể cả gọi API trực tiếp. Có thể cập nhật tên công việc và địa điểm; dữ liệu đã chấm công được giữ nguyên.
- Không cho STAFF chấm công lần thứ hai hay chấm công ra nhiều lần. Xác nhận tại Supabase bằng hàm `clock_in_shift`/`clock_out_shift`, không tin thời gian do trình duyệt gửi.
- Mức lương là thỏa thuận theo công ty và nhân viên, chưa phải chức năng thanh toán.
- Supabase trigger ghi thông báo **trong ứng dụng** cho STAFF khi ca được tạo, sửa hoặc hủy, kể cả khi STAFF đang không mở app. Thông báo có nút đánh dấu đã đọc và chỉ người nhận xem được. **Chỉ có hiệu lực sau khi chạy migration `shift_notifications.sql`.**
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

Với dự án mới, ưu tiên chạy **một lần** `supabase/FULL_SETUP_FROM_SCRATCH.sql`. Các file migration nền tảng bên dưới được giữ lại để tham chiếu hoặc nâng cấp thủ công theo thứ tự:

1. `supabase/multi_company.sql`
2. `supabase/company_approval.sql`
3. `supabase/account_controls.sql`
4. `supabase/admin_scope.sql`
5. `supabase/member_compensation.sql`
6. **`supabase/shift_business_rules.sql`**
7. **`supabase/shift_notifications.sql`** (thông báo tạo/sửa/hủy ca)
8. **`supabase/shift_attendance.sql`** (chấm công vào/ra và khóa hủy ca đã chấm công)
9. **`supabase/staff_business.sql`** (phân loại nhân sự, báo cáo lương và quy tắc phân ca)
10. **`supabase/staff_roles.sql`** (vai trò trong danh sách tài khoản và đồng nghiệp)
11. **`supabase/staff_role_notifications.sql`** (thông báo khi Manager chuyển nhân sự sang STAFF hoặc Freelance, chạy sau `manager_notifications.sql`)

Nếu database đã tồn tại, hãy **sao lưu trước** và kiểm tra các migration đã áp dụng. Bạn có thể chạy script nâng cấp tổng hợp ở phần dưới hoặc các file còn thiếu theo thứ tự 6 → 7 → 8 → **9**. Chạy file mới số 8 để kích hoạt chấm công và bảo vệ ca đã chấm công. Không cần xóa dữ liệu lịch cũ. **Merge GitHub/Vercel không tự chạy SQL trên Supabase.** Trigger chỉ chặn thao tác ghi mới, không tự xóa dữ liệu lịch cũ. Nên kiểm tra trùng ca đã tồn tại trước khi triển khai:

```sql
select a.user_id, a.id as shift_a, b.id as shift_b, a.starts_at, a.ends_at, b.starts_at, b.ends_at
from public.company_shifts a
join public.company_shifts b on a.user_id=b.user_id and a.id < b.id
where a.starts_at < b.ends_at and b.starts_at < a.ends_at;
```

Danh sách kết quả nếu có cần được quản lý điều chỉnh thủ công. RLS và RPC phải được thực thi ở Supabase; chỉ đổi giao diện Vue **không** thay thế cho phân quyền database.

### Cài đặt Supabase bằng một script (production)

**Dự án Supabase đang chạy phải có các bảng nền từ**
`multi_company.sql`, `company_approval.sql`, `account_controls.sql`,
`admin_scope.sql`. Hãy sao lưu DB trước khi chạy.

**Cách nhanh trong Supabase Dashboard:** mở SQL Editor, dán nguyên nội dung
[`supabase/production_upgrade.sql`](supabase/production_upgrade.sql) rồi **Run**.
Script chạy trong một transaction, có thể chạy lại và không xóa lịch, lương,
chấm công hoặc thông báo trước đó. Nó bổ sung/đồng bộ cấu trúc bảng lương,
chống trùng ca, thông báo, chấm công, và nghiệp vụ chính thức/thời vụ.

**Tự chạy SQL khi merge vào `main`:** workflow
[`.github/workflows/supabase-production.yml`](.github/workflows/supabase-production.yml)
tự áp dụng đúng file `production_upgrade.sql` trên mỗi commit thay đổi thư mục
`supabase/`. Trước khi dùng, hãy cấu hình GitHub Actions secret
`SUPABASE_DB_URL` (nên đặt trong Environment `production`) chứa URI kết nối
PostgreSQL của **đúng project Supabase** đang phục vụ website. Dùng kết nối
**Session Pooler hỗ trợ IPv4**, bật SSL. Không đưa mật khẩu SQL hoặc
`service_role` vào frontend hay commit. Nếu thiếu secret, workflow sẽ **thất bại
rõ ràng** và không cập nhật database; merge GitHub hoặc Vercel deploy **không
thay thế bước chạy SQL**. Có thể bấm **Actions → Supabase production migration →
Run workflow** để chạy thủ công sau khi thêm secret.

Kiểm tra sau khi chạy thành công:

```sql
select to_regclass('public.member_compensation') as compensation,
       to_regclass('public.shift_attendance') as attendance,
       to_regclass('public.shift_notifications') as notifications;
select count(*) as staff_without_category
from public.company_members m
left join public.member_compensation c
 on c.company_id=m.company_id and c.user_id=m.user_id
where m.role='staff' and c.user_id is null;
```

Nếu cần làm mới PostgREST schema cache sau migration:
`NOTIFY pgrst, 'reload schema';`

### Xem trước từng vai trò

Chạy `npm run dev` và mở trang `/tests/role.html` với một trong các giá trị `?role=admin`, `?role=manager`, `?role=staff`, `?role=freelance`. Các trang này dùng dữ liệu giả lập để kiểm tra giao diện.

### Phần còn thiếu

- Quy trình duyệt/điều chỉnh sai sót chấm công, xử lý đến muộn/vắng mặt, và quy đổi thành bảng lương thực lĩnh.
- Thông báo nhắc lịch qua push/Zalo/Facebook hoặc tự gửi nhắc trước giờ làm (hiện mới có thông báo trong ứng dụng cho các sự kiện thay đổi ca).
- Nhật ký kiểm toán thay đổi chi tiết (ai sửa và giá trị trước/sau), ngoài thông báo đã gửi cho nhân viên.
- Màn hình báo cáo tổng hợp giờ công và xuất bảng lương.

Không nên gọi các tính năng trên là đã hoàn thành chỉ vì hiện có màn hình giờ công dự kiến.

## Manager: khu vực hoạt động, cast và thông báo (2026-11)

- Trong **Hồ sơ của tôi**, Manager nhập **Quê quán** và **Khu vực đang hoạt động** bằng tỉnh/thành phố, phường/xã. Bộ chọn có ô tìm kiếm; khu vực hoạt động tự điền vào địa điểm ca mới, có thể thay đổi ngay trong form phân ca.
- Ca làm mới chỉ có **một ngày** (ngày lấy từ ô lịch và không sửa trong biểu mẫu). Ngày hiển thị thứ, ngày và tháng, không hiện năm. Giờ kết thúc phải sau giờ bắt đầu trong cùng ngày.
- Trường **Cast / thù lao ca** lưu số tiền VND; gợi ý 300K, 400K, 500K, 600K, 700K, 1.000K hoặc tự nhập. Đây là thù lao dự kiến của ca; hệ thống cộng Cast vào bảng lương khi nhân viên đã chấm công ra.
- Manager có tab **Thông báo**: nhân viên chấm công vào/ra và yêu cầu gia nhập công ty; có số lượng chưa đọc và đánh dấu đã đọc. STAFF vẫn nhận thông báo ca làm như trước.
- **Database cũ**: chạy `supabase/manager_location_cast.sql` rồi `supabase/manager_notifications.sql` trong Supabase SQL Editor. **Database mới**: dùng `supabase/FULL_SETUP_FROM_SCRATCH.sql` đã tích hợp hai thay đổi. Push GitHub không tự chạy SQL.

### Khóa cast sau chấm công và giữ giao diện chọn nhân viên

Khi cập nhật một công việc, Manager vẫn thấy checkbox như lúc tạo và có thể chọn nhiều nhân viên; mỗi người được lưu một ca riêng để chấm công. Sau khi có nhân viên chấm công vào, nhân viên đã chấm công không thể bị bỏ khỏi công việc, giờ làm và trường/nút Cast của nhóm đều bị khóa; database cũng từ chối mọi yêu cầu đổi cast trực tiếp với lỗi `P4512`. Với Supabase đang chạy, áp dụng `supabase/lock_clocked_shift_cast.sql` trong SQL Editor; bản cài đặt mới đã bao gồm migration này.


## Cập nhật phân ca, lương và giao diện (06/11/2026)

- **Lịch Manager**: chạm một lần vào ngày (kể cả ngày đã có ca) để tạo ca mới; chạm nhanh hai lần trong khoảng 350 ms để chọn sửa ca đã có. Nút **+ Thêm ca** và **Sửa ca** tại chi tiết ngày vẫn hoạt động.
- **Phân nhiều nhân viên**: checkbox chọn được nhiều STAFF cả khi tạo lẫn sửa. Khi sửa, tất cả ca cùng công việc, địa điểm, thời điểm và Cast được chỉnh như một nhóm. Không thể bỏ người đã chấm công hoặc đổi giờ/Cast của nhóm sau khi có chấm công. Việc sửa nhóm được lưu nguyên tử bằng RPC, không để trạng thái phân công dở dang.
- **Lương mới**: chính thức = lương tháng + phụ cấp hàng tháng + Cast các ca hoàn tất; thời vụ = phụ cấp tháng (nếu có) + Cast các ca hoàn tất. Giờ thực tế = tổng thời gian giữa chấm công vào và chấm công ra. Đây vẫn là **báo cáo ước tính**, chưa tính thuế, bảo hiểm, khấu trừ và không tự quyết toán.
- **UI**: không hiển thị thanh cuộn, nhưng vẫn cuộn được bằng chuột, bàn di chuột, cảm ứng và bàn phím.
- **Database đang sử dụng**: sau khi đảm bảo đã có các migration hồ sơ/địa điểm/Cast trước đó, chạy `supabase/multi_staff_assignment.sql` và `supabase/monthly_cast_payroll.sql` trong Supabase SQL Editor. Hoặc chạy `supabase/production_upgrade.sql` tổng hợp trên schema đã cài đặt. **Sao lưu dữ liệu trước khi chạy; không chạy file `RESET_SHIFTLY_ONLY.sql` trên database đang dùng.** File `supabase/FULL_SETUP_FROM_SCRATCH.sql` dành cho database hoàn toàn mới.
- **Vercel** tự động triển khai các commit mới trên `main` theo cấu hình `vercel.json`.
