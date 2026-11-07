import { createHash, randomUUID } from 'node:crypto'

const MAX_IMAGE_BYTES = 2 * 1024 * 1024
const MAX_BASE64_LENGTH = Math.ceil(MAX_IMAGE_BYTES / 3) * 4
const SUPABASE_URL = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL ||
  'https://uohhzeaunklxxvnqzobm.supabase.co'
// A publishable/anon key is not a secret. The user's access token is verified by Supabase Auth.
const SUPABASE_PUBLISHABLE_KEY = process.env.SUPABASE_ANON_KEY ||
  process.env.VITE_SUPABASE_ANON_KEY || 'sb_publishable_mJWbbL7EQD3Ch1NVmVHnTw_qCvru-Q9'

function respond(res, status, body) {
  res.setHeader('Cache-Control', 'no-store')
  return res.status(status).json(body)
}

function cloudinaryCredentials() {
  if (process.env.CLOUDINARY_URL) {
    try {
      const parsed = new URL(process.env.CLOUDINARY_URL)
      if (parsed.protocol !== 'cloudinary:' || !parsed.hostname || !parsed.username || !parsed.password) return null
      return {
        cloud: parsed.hostname,
        key: decodeURIComponent(parsed.username),
        secret: decodeURIComponent(parsed.password)
      }
    } catch {
      return null
    }
  }
  const cloud = process.env.CLOUDINARY_CLOUD_NAME || 'dh9e61rog'
  const key = process.env.CLOUDINARY_API_KEY
  const secret = process.env.CLOUDINARY_API_SECRET
  return cloud && key && secret ? { cloud, key, secret } : null
}

function decodeImage(value) {
  if (typeof value !== 'string' || value.length > MAX_BASE64_LENGTH + 40) return null
  const match = /^data:image\/(jpeg|png|webp);base64,([A-Za-z0-9+/]+={0,2})$/.exec(value)
  if (!match || match[2].length > MAX_BASE64_LENGTH) return null
  const buffer = Buffer.from(match[2], 'base64')
  if (!buffer.length || buffer.length > MAX_IMAGE_BYTES || buffer.toString('base64') !== match[2]) return null
  const type = match[1]
  const valid = type === 'jpeg'
    ? buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff
    : type === 'png'
      ? buffer.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))
      : buffer.length >= 12 && buffer.toString('ascii', 0, 4) === 'RIFF' &&
        buffer.toString('ascii', 8, 12) === 'WEBP'
  return valid ? { buffer, type } : null
}

export default async function handler(req, res) {
  if (req.method !== 'POST') return respond(res, 405, { error: 'Chỉ hỗ trợ POST.' })

  const token = /^Bearer\s+(.+)$/i.exec(req.headers.authorization || '')?.[1]
  if (!token) return respond(res, 401, { error: 'Vui lòng đăng nhập để tải ảnh.' })

  const config = cloudinaryCredentials()
  if (!config || !/^[a-zA-Z0-9_-]+$/.test(config.cloud)) {
    return respond(res, 503, { error: 'Cloudinary chưa được cấu hình trên Vercel.' })
  }

  let user
  try {
    const auth = await fetch(`${SUPABASE_URL.replace(/\/$/, '')}/auth/v1/user`, {
      headers: { apikey: SUPABASE_PUBLISHABLE_KEY, authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(10000)
    })
    if (!auth.ok) return respond(res, 401, { error: 'Phiên đăng nhập không hợp lệ.' })
    user = await auth.json()
    if (!/^[0-9a-f]{8}-[0-9a-f-]{27,}$/i.test(user?.id || '')) {
      return respond(res, 401, { error: 'Không xác định được tài khoản.' })
    }
  } catch {
    return respond(res, 502, { error: 'Không thể xác thực với Supabase.' })
  }

  let payload
  try {
    payload = typeof req.body === 'string' ? JSON.parse(req.body) : req.body
  } catch {
    return respond(res, 400, { error: 'Dữ liệu ảnh không hợp lệ.' })
  }
  const image = decodeImage(payload?.image)
  if (!image) {
    return respond(res, 400, { error: 'Ảnh phải là JPG, PNG hoặc WebP và không quá 2 MB.' })
  }

  const params = {
    overwrite: 'false',
    public_id: `shiftly/avatars/${user.id}/${randomUUID()}`,
    timestamp: String(Math.floor(Date.now() / 1000))
  }
  const serialized = Object.entries(params).sort(([a], [b]) => a.localeCompare(b))
    .map(([name, value]) => `${name}=${value}`).join('&')
  const signature = createHash('sha1').update(serialized + config.secret).digest('hex')
  const multipart = new FormData()
  multipart.append('file', new Blob([image.buffer], { type: `image/${image.type}` }),
    `avatar.${image.type === 'jpeg' ? 'jpg' : image.type}`)
  for (const [name, value] of Object.entries(params)) multipart.append(name, value)
  multipart.append('api_key', config.key)
  multipart.append('signature', signature)

  try {
    const upload = await fetch(
      `https://api.cloudinary.com/v1_1/${config.cloud}/image/upload`,
      { method: 'POST', body: multipart, signal: AbortSignal.timeout(20000) }
    )
    if (!upload.ok) return respond(res, 502, { error: 'Cloudinary từ chối ảnh tải lên.' })
    const result = await upload.json()
    const url = new URL(result.secure_url)
    const prefix = `/${config.cloud}/image/upload/`
    if (url.origin !== 'https://res.cloudinary.com' || !url.pathname.startsWith(prefix)) {
      return respond(res, 502, { error: 'Cloudinary trả về đường dẫn không hợp lệ.' })
    }
    // Cloudinary CDN auto-selects a compact format and quality on avatar delivery.
    const avatarUrl = url.origin +
      url.pathname.replace(prefix, `${prefix}c_limit,w_480,h_480,f_auto,q_auto/`)
    return respond(res, 200, { avatar_url: avatarUrl })
  } catch {
    return respond(res, 502, { error: 'Không thể kết nối Cloudinary. Vui lòng thử lại.' })
  }
}
