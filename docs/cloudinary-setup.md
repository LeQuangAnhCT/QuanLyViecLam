# Cloudinary avatar storage for Shiftly

## Credentials (Vercel only)

1. In the Cloudinary Console, rotate any API Secret that has been shared in messages or screenshots.
2. Copy the **Cloud Name**, **API Key** and **new API Secret** from Cloudinary.
3. In each deployed Shiftly project, open **Vercel → Project → Settings → Environment Variables**.
4. Add a server-only variable with this format:

   `CLOUDINARY_URL=cloudinary://YOUR_API_KEY:YOUR_API_SECRET@dh9e61rog`

   Keep the actual key and secret in Vercel only. Do not commit them, use `VITE_`
   prefixes, paste them into the application, or expose them through public logs.
5. Redeploy the latest `main` deployment after saving the variable.

The API route `/api/avatar-upload` is a Vercel Node.js function. It validates
the Supabase login using the bearer access token, checks supported image formats
(JPG, PNG and WebP) and the 2 MB file limit, then uploads to Cloudinary using
a signed server-side request. The Cloudinary API Secret never reaches the browser.

All four account roles use the same `repository.uploadAvatar()` function.
The optimized Cloudinary URL is saved in `profiles.avatar_url`, preserving the
existing database schema and the interface. Only **new avatar uploads** use
Cloudinary. Existing Supabase Storage avatar URLs keep working; they are not
deleted or migrated automatically.

Payroll receipt images stay in the private Supabase Storage bucket
`payroll-receipts`, and the receipt signing/authorization flows are unchanged.

## Verify

- After redeploy, log in and update an avatar from Profile (JPG/PNG/WebP, <=2 MB).
- Confirm that `profiles.avatar_url` begins with
  `https://res.cloudinary.com/dh9e61rog/image/upload/`.
- Refresh as Admin, Manager, Staff or Freelance and check that it displays.
- Confirm old avatars and private payroll receipts still display.
- Run `npm run test:cloudinary` for mocked auth, validation and signed upload checks.

If the app shows **Cloudinary chưa được cấu hình trên Vercel**, make sure the
Vercel environment variable exists in the environment of the active deployment
and redeploy after changing it.
