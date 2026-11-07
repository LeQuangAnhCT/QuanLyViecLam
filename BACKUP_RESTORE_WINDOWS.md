# Khôi phục project Shiftly sau khi cài Windows

## Cài lại môi trường

1. Cài Node.js 22.x (bản LTS nếu có).
2. Giải nén thư mục project vào vị trí làm việc.
3. Mở PowerShell tại thư mục project và chạy:

```powershell
npm ci
Copy-Item .env.example .env
notepad .env
npm run build
npm run dev
```

4. Điền `VITE_SUPABASE_URL` và `VITE_SUPABASE_ANON_KEY` trong `.env` nếu project cần kết nối Supabase.

## Kiểm tra

```powershell
npm run test:domain
npm run test:db
```

Các file SQL trong thư mục `supabase` là migration/thiết lập database. Không đưa khóa bí mật hoặc file `.env` lên Git/đám mây công khai.
