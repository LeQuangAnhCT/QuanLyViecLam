import React,{useEffect,useState} from 'react';
import {supabase} from './lib/supabase';
import './multiApp.css';
import Discovery from './Discovery';

const localDate = d => [d.getFullYear(),String(d.getMonth()+1).padStart(2,'0'),String(d.getDate()).padStart(2,'0')].join('-');
const errorText = e => e?.message || 'Có lỗi xảy ra. Vui lòng thử lại.';

export default function MultiApp(){
  const [session,setSession]=useState(undefined);
  useEffect(()=>{supabase.auth.getSession().then(({data})=>setSession(data.session));const {data}=supabase.auth.onAuthStateChange((_e,s)=>setSession(s));return()=>data.subscription.unsubscribe()},[]);
  if(session===undefined)return <main className="login">Đang tải Shiftly...</main>;
  if(!session)return <main className="login"><span className="mark">S</span><h1>SHIFTLY</h1><p>Quản lý lịch làm việc cho đội ngũ sự kiện.</p><button className="primary" onClick={()=>supabase.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin}})}>Tiếp tục với Google</button></main>;
  return <Workspace user={session.user}/>;
}

function Workspace({user}){
  const isAdmin=user.app_metadata?.role==='admin';
  const [restriction,setRestriction]=useState(null);
  useEffect(()=>{supabase.from('account_restrictions').select('disabled,reason').eq('user_id',user.id).maybeSingle().then(({data})=>setRestriction(data))},[user.id]);
  const [companies,setCompanies]=useState([]),[invitations,setInvitations]=useState([]),[company,setCompany]=useState(''),[members,setMembers]=useState([]),[shifts,setShifts]=useState([]),[tab,setTab]=useState('calendar'),[error,setError]=useState(''),[busy,setBusy]=useState(false),[modal,setModal]=useState(null),[month,setMonth]=useState(()=>new Date(new Date().getFullYear(),new Date().getMonth(),1));
  const current=companies.find(c=>c.id===company),manager=isAdmin||current?.role==='manager';
  async function refreshCompanies(){
    const [c,i]=await Promise.all([supabase.from('companies').select('id,name'),supabase.from('company_invitations').select('id,company_id,email,status').eq('status','pending')]);
    if(c.error||i.error){setError(errorText(c.error||i.error));return}
    const {data:m,error:e}=await supabase.from('company_members').select('company_id,role').eq('user_id',user.id);
    if(e){setError(errorText(e));return}
    const list=(c.data||[]).map(x=>({...x,role:(m||[]).find(v=>v.company_id===x.id)?.role})).filter(x=>isAdmin||x.role);
    setCompanies(list);setInvitations((i.data||[]).filter(v=>v.email.toLowerCase()===user.email?.toLowerCase()).map(v=>({...v,company_name:(c.data||[]).find(x=>x.id===v.company_id)?.name})));
    setCompany(old=>list.some(x=>x.id===old)?old:list[0]?.id||'');
  }
  async function refreshCompany(id){
    if(!id){setMembers([]);setShifts([]);return}
    const [m,s]=await Promise.all([supabase.rpc('company_roster',{p_company:id}),supabase.from('company_shifts').select('*').eq('company_id',id).order('starts_at')]);
    if(m.error||s.error){setError(errorText(m.error||s.error));return}
    setMembers(m.data||[]);setShifts(s.data||[]);
  }
  useEffect(()=>{refreshCompanies()},[user.id]);
  useEffect(()=>{refreshCompany(company)},[company]);
  async function run(fn,success){setBusy(true);setError('');try{const {error:e}=await fn();if(e)throw e;await refreshCompanies();if(company)await refreshCompany(company);if(success)setModal(null)}catch(e){setError(errorText(e))}finally{setBusy(false)}}
  const rosterName=id=>members.find(m=>m.user_id===id)?.full_name||'Nhân viên';
  const days=new Date(month.getFullYear(),month.getMonth()+1,0).getDate(),first=(new Date(month.getFullYear(),month.getMonth(),1).getDay()+6)%7;
  if(restriction?.disabled)return <main className="login"><h1>Tài khoản đã bị vô hiệu hóa</h1><p>Lý do: {restriction.reason}</p><button className="secondary" onClick={()=>supabase.auth.signOut()}>Thoát</button></main>;
  return <div className="shell"><aside className="sidebar"><div className="brand"><span className="mark">S</span><div><b>SHIFTLY</b><small>Quản lý sự kiện</small></div></div><nav className="nav"><button className={tab==='calendar'?'active':''} onClick={()=>setTab('calendar')}>Lịch làm việc</button><button className={tab==='people'?'active':''} onClick={()=>setTab('people')}>Nhân viên</button><button className={tab==='attendance'?'active':''} onClick={()=>setTab('attendance')}>Giờ công dự kiến</button></nav><div className="sidebar-foot">{isAdmin?'Admin':current?.role==='manager'?'Manager':'Staff'}<br/>{user.email}</div></aside>
  <section className="main"><header className="topbar"><h1>Shiftly</h1><button className="logout" onClick={()=>supabase.auth.signOut()}>Thoát</button></header><main className="content">
  <Discovery user={user} isAdmin={isAdmin} companies={companies} company={company} manager={current?.role==='manager'} refresh={refreshCompanies}/>
  <div className="company-bar"><label>Công ty<select value={company} onChange={e=>setCompany(e.target.value)}><option value="">Chọn công ty</option>{companies.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label></div>
  {error&&<div className="notice error" role="alert">{error}</div>}
  {invitations.length>0&&<section className="panel invitation"><h3>Lời mời tham gia</h3>{invitations.map(i=><div key={i.id}>Công ty: {i.company_name||i.company_id} <button className="secondary" disabled={busy} onClick={()=>run(()=>supabase.rpc('accept_company_invitation',{p_invitation:i.id}))}>Chấp nhận</button></div>)}</section>}
  {!company?<div className="empty">Bạn chưa tham gia công ty nào. Manager có thể mời bạn bằng email đăng nhập.</div>:<>
  {tab==='calendar'&&<><div className="calendar-head"><div><div className="kicker">LỊCH PHÂN CA</div><h2>{month.toLocaleDateString('vi-VN',{month:'long',year:'numeric'})}</h2></div><div className="month-actions"><button onClick={()=>setMonth(new Date(month.getFullYear(),month.getMonth()-1,1))}>‹</button><button onClick={()=>setMonth(new Date())}>Hôm nay</button><button onClick={()=>setMonth(new Date(month.getFullYear(),month.getMonth()+1,1))}>›</button></div></div><section className="calendar"><div className="weekdays">{['T2','T3','T4','T5','T6','T7','CN'].map(x=><b key={x}>{x}</b>)}</div><div className="days">{Array.from({length:first+days},(_,i)=>{const d=i-first+1;if(d<1)return <div key={i} className="day muted"/>;const date=localDate(new Date(month.getFullYear(),month.getMonth(),d)),items=shifts.filter(s=>localDate(new Date(s.starts_at))===date);return <button key={i} className="day" onClick={()=>manager&&setModal({type:'shift',date})}><span>{d}</span>{items.map(s=><small key={s.id}>{new Date(s.starts_at).toLocaleTimeString('vi-VN',{hour:'2-digit',minute:'2-digit'})} {rosterName(s.user_id)}</small>)}</button>})}</div></section><p className="calendar-hint">{manager?'Chọn một ngày để phân ca.':'Lịch hiển thị các ca được giao cho bạn.'}</p></>}
  {tab==='people'&&<section className="panel"><div className="panel-head"><h3>Nhân viên · {current?.name}</h3>{manager&&<button onClick={()=>setModal({type:'invite'})}>+ Mời nhân viên</button>}</div>{members.map(m=><div className="assignment" key={m.user_id}><div className="avatar">{m.full_name?.slice(0,1).toUpperCase()}</div><div><b>{m.full_name}</b><small>{m.email}</small></div><span className="status">{m.role}</span></div>)}<p className="calendar-hint">Nhân viên đăng nhập bằng email được mời rồi chọn Chấp nhận.</p></section>}
  {tab==='attendance'&&<section className="panel"><div className="panel-head"><h3>Giờ công theo lịch</h3></div><p className="calendar-hint">Giờ dự kiến, không xác nhận nhân viên đã có mặt.</p>{shifts.map(s=><div className="assignment" key={s.id}><div className="rail"/><div><b>{s.title} · {rosterName(s.user_id)}</b><small>{new Date(s.starts_at).toLocaleString('vi-VN')} · {s.location||'Chưa có địa điểm'}</small></div><span>{((new Date(s.ends_at)-new Date(s.starts_at))/3600000).toFixed(2)} giờ</span></div>)}</section>}
  </>}
  </main></section>
  {modal&&<Dialog modal={modal} close={()=>setModal(null)} busy={busy} members={members} save={values=>{if(modal.type==='company')return run(()=>supabase.rpc('create_company_by_email',{p_name:values.name,p_email:values.email}),true);if(modal.type==='invite')return run(()=>supabase.from('company_invitations').insert({company_id:company,email:values.email.trim().toLowerCase()}),true);if(!values.user_ids.length){setError('Hãy chọn ít nhất một nhân viên.');return}const start=new Date(values.date+'T'+values.start),end=new Date(values.end_date+'T'+values.end);if(end<=start){setError('Giờ kết thúc phải sau giờ bắt đầu.');return}return run(()=>supabase.from('company_shifts').insert(values.user_ids.map(id=>({company_id:company,user_id:id,title:values.title,location:values.location,starts_at:start.toISOString(),ends_at:end.toISOString()}))),true)}}/>}
  </div>;
}
function Dialog({modal,close,save,busy,members}){const [v,setV]=useState({date:modal.date||localDate(new Date()),end_date:modal.date||localDate(new Date()),start:'08:00',end:'12:00',email:'',name:'',title:'',location:'',user_ids:[]});const field=(name,label,type='text')=><label>{label}<input required={name!=='location'} type={type} value={v[name]} onChange={e=>setV({...v,[name]:e.target.value,...(name==='date'?{end_date:e.target.value}:{})})}/></label>;return <div className="overlay"><form className="modal" onSubmit={e=>{e.preventDefault();save(v)}}><div className="modal-head"><h2>{modal.type==='company'?'Tạo công ty':modal.type==='invite'?'Mời nhân viên':'Phân ca làm việc'}</h2><button type="button" onClick={close}>×</button></div>{modal.type==='company'&&<>{field('name','Tên công ty')}{field('email','Email manager đã đăng nhập','email')}</>}{modal.type==='invite'&&field('email','Email nhân viên','email')}{modal.type==='shift'&&<>{field('title','Công việc / sự kiện')}{field('location','Địa điểm')}{field('date','Ngày bắt đầu','date')}<label>Buổi<select defaultValue="morning" onChange={e=>{const times={morning:['08:00','12:00'],afternoon:['13:00','17:00'],evening:['18:00','23:00'],all:['08:00','23:00']};const t=times[e.target.value];if(t)setV({...v,start:t[0],end:t[1]})}}><option value="morning">Sáng</option><option value="afternoon">Chiều</option><option value="evening">Tối</option><option value="all">Cả ngày</option><option value="custom">Tự chọn</option></select></label><div className="form-grid">{field('start','Bắt đầu','time')}{field('end','Kết thúc','time')}</div>{field('end_date','Ngày kết thúc (chọn ngày sau nếu qua đêm)','date')}<fieldset className="member-picker"><legend>Nhân viên</legend>{members.map(m=><label key={m.user_id}><input type="checkbox" checked={v.user_ids.includes(m.user_id)} onChange={e=>setV({...v,user_ids:e.target.checked?[...v.user_ids,m.user_id]:v.user_ids.filter(id=>id!==m.user_id)})}/>{m.full_name} · {m.email}</label>)}{!members.length&&<small>Chưa có thành viên để phân ca.</small>}</fieldset></>}<div className="form-actions"><button type="button" className="secondary" onClick={close}>Hủy</button><button className="primary" disabled={busy}>{busy?'Đang lưu...':'Lưu'}</button></div></form></div>}
