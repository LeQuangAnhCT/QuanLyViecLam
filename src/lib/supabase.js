import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL || 'https://uohhzeaunklxxvnqzobm.supabase.co'
const key = import.meta.env.VITE_SUPABASE_ANON_KEY || 'sb_publishable_mJWbbL7EQD3Ch1NVmVHnTw_qCvru-Q9'
export const supabase = createClient(url, key)
