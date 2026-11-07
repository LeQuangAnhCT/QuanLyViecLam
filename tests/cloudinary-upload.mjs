import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import handler from '../api/avatar-upload.js'

const originalFetch = globalThis.fetch
const originalCloudinaryUrl = process.env.CLOUDINARY_URL
const avatarPng = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y38hOMAAAAASUVORK5CYII='
const userId = 'be13a908-32eb-493b-8dfb-e170e40bf318'

function mockResponse() {
  return {
    statusCode: 200,
    body: null,
    headers: {},
    setHeader(name, value) { this.headers[name] = value; return this },
    status(code) { this.statusCode = code; return this },
    json(payload) { this.body = payload; return this }
  }
}
async function call({ method = 'POST', token = 'good-token', image = avatarPng } = {}) {
  const res = mockResponse()
  await handler({
    method,
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body: { image }
  }, res)
  return res
}

process.env.CLOUDINARY_URL = 'cloudinary://test-api-key:test-api-secret@dh9e61rog'
let authCalls = 0
let uploadCalls = 0
globalThis.fetch = async (url, options) => {
  if (String(url).endsWith('/auth/v1/user')) {
    authCalls++
    if (options.headers.authorization === 'Bearer bad-token') {
      return new Response('{}', { status: 401 })
    }
    return Response.json({ id: userId })
  }
  if (String(url) === 'https://api.cloudinary.com/v1_1/dh9e61rog/image/upload') {
    uploadCalls++
    const fields = options.body
    assert.equal(fields.get('api_key'), 'test-api-key')
    assert.equal(fields.get('overwrite'), 'false')
    assert.match(fields.get('public_id'), new RegExp(`^shiftly/avatars/${userId}/`))
    const signatureParts = ['overwrite', 'public_id', 'timestamp']
      .map(key => `${key}=${fields.get(key)}`).join('&')
    const expected = createHash('sha1').update(signatureParts + 'test-api-secret').digest('hex')
    assert.equal(fields.get('signature'), expected)
    assert.equal(fields.get('file').type, 'image/png')
    return Response.json({
      secure_url: `https://res.cloudinary.com/dh9e61rog/image/upload/v1234567890/${fields.get('public_id')}.png`
    })
  }
  throw new Error(`Unexpected fetch: ${url}`)
}

try {
  assert.equal((await call({ method: 'GET' })).statusCode, 405)
  assert.equal((await call({ token: '' })).statusCode, 401)
  assert.equal((await call({ token: 'bad-token' })).statusCode, 401)
  const badImage = await call({ image: 'data:image/png;base64,aGVsbG8=' })
  assert.equal(badImage.statusCode, 400)
  assert.match(badImage.body.error, /JPG/)

  const success = await call()
  assert.equal(success.statusCode, 200)
  assert.match(success.body.avatar_url,
    /^https:\/\/res\.cloudinary\.com\/dh9e61rog\/image\/upload\/c_limit,w_480,h_480,f_auto,q_auto\/v\d+\/shiftly\/avatars\//)
  assert.equal(uploadCalls, 1)
  assert.equal(authCalls, 3)

  delete process.env.CLOUDINARY_URL
  assert.equal((await call()).statusCode, 503)
  assert.equal(uploadCalls, 1)
  console.log('Cloudinary avatar authentication, validation, signed upload and URL: OK')
} finally {
  globalThis.fetch = originalFetch
  if (originalCloudinaryUrl === undefined) delete process.env.CLOUDINARY_URL
  else process.env.CLOUDINARY_URL = originalCloudinaryUrl
}
