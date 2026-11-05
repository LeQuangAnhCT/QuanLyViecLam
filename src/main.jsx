import React, { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { supabase } from './lib/supabase'
import './styles.css'

const today = new Date().toISOString().slice(0, 10)
const emptyForm = { title: '', date: today, start: '08:00', end: '12:00', location: '', owner: 'Nguyễn An', status: 'upcoming' }

function Login() {
  async function login() {
    await supabase.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: window.location.origin } })
  }
  return <div className="app"><main className="login"><span className="mark">S</span><h1>SHIFTLY<br /><em>Lịch làm việc.</em></h1><p>Đăng nhập để đồng bộ lịch làm việc trên mọi thiết bị.</p><button className="primary" onClick={login}>Tiếp tục với Google</button><small>Đăng nhập an toàn bằng Supabase Auth</small></main></div>
}

function App({ user }) {
  const [shifts, setShifts] = useState([])
  const [online, setOnline] = useState(navigator.onLine)
  const [show, setShow] = useState(false)
  const [form, setForm] = useState(emptyForm)
  useEffect(() => { let active = true; async function load() { const { data } = await supabase.from('shifts').select('*').order('date').order('start'); if (active) setShifts(data || []) }; load(); const on = () => setOnline(true), off = () => setOnline(false); addEventListener('online', on); addEventListener('offline', off); navigator.serviceWorker?.register('/sw.js'); return () => { active = false; removeEventListener('online', on); removeEventListener('offline', off) } }, [])
  async function addShift(e) { e.preventDefault(); const item = { ...form, id: crypto.randomUUID(), user_id: user.id }; const { error } = await supabase.from('shifts').insert(item); if (!error) setShifts(v => [...v, item]); setForm(emptyForm); setShow(false) }
  async function removeShift(id) { const { error } = await supabase.from('shifts').delete().eq('id', id); if (!error) setShifts(v => v.filter(s => s.id !== id)) }
  async function logout() { await supabase.auth.signOut() }
  const hours = shifts.reduce((n, s) => n + (Number(s.end.slice(0, 2)) - Number(s.start.slice(0, 2))), 0)
  return <div className="app"><header><div className="brand"><span className="mark">S</span><div><b>SHIFTLY</b><small>{online ? 'Đã đồng bộ Supabase' : 'Ngoại tuyến'}</small></div></div><button className="icon-btn" onClick={logout}>Thoát</button></header><main><div className="eyebrow">LỊCH CỦA BẠN <span className="dot live" /></div><h1>Chào buổi sáng,<br /><em>{user.user_metadata?.full_name || user.email}.</em></h1><div className="hero"><div><span>HÔM NAY</span><strong>{shifts.filter(s => s.date === today).length} ca làm</strong><p>{today}</p></div><b>☼</b></div><section className="stats"><div><small>Tổng ca</small><b>{shifts.length}</b></div><div><small>Tổng giờ</small><b>{hours}h</b></div><div><small>Kết nối</small><b className="ok">Online</b></div></section><div className="section-head"><h2>Lịch làm việc</h2><button className="text-btn" onClick={() => setShow(true)}>+ Thêm ca</button></div><div className="shift-list">{shifts.map(s => <article className="shift" key={s.id}><div className="rail" /><div className="shift-main"><div className="shift-top"><span>{s.start} — {s.end}</span><span className="badge">Sắp tới</span></div><b>{s.title}</b><small>{s.location} · {s.owner}</small></div><button className="delete" onClick={() => removeShift(s.id)}>×</button></article>)}</div></main><button className="fab" onClick={() => setShow(true)}>+</button>{show && <div className="overlay"><form className="modal" onSubmit={addShift}><div className="modal-head"><h2>Thêm ca làm</h2><button type="button" className="icon-btn" onClick={() => setShow(false)}>×</button></div><label>Tên công việc<input required value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} /></label><label>Địa điểm<input value={form.location} onChange={e => setForm({ ...form, location: e.target.value })} /></label><div className="form-row"><label>Ngày<input type="date" value={form.date} onChange={e => setForm({ ...form, date: e.target.value })} /></label><label>Bắt đầu<input type="time" value={form.start} onChange={e => setForm({ ...form, start: e.target.value })} /></label><label>Kết thúc<input type="time" value={form.end} onChange={e => setForm({ ...form, end: e.target.value })} /></label></div><button className="primary">Lưu ca làm</button></form></div>}</div>
}

function Root() {
  const [user, setUser] = useState(null)
  const [loading, setLoading] = useState(true)
  useEffect(() => { let active = true; supabase.auth.getSession().then(({ data }) => { if (active) { setUser(data.session?.user || null); setLoading(false) } }); const { data } = supabase.auth.onAuthStateChange((_event, session) => setUser(session?.user || null)); return () => { active = false; data.subscription.unsubscribe() } }, [])
  if (loading) return <div className="app"><main><p>Đang tải Shiftly…</p></main></div>
  return user ? <App user={user} /> : <Login />
}

createRoot(document.getElementById('root')).render(<Root />)
