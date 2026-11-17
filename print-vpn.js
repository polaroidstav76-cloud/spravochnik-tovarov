(()=>{
 const notice=document.createElement('aside');notice.hidden=true;notice.style.cssText='position:fixed;right:18px;bottom:20px;max-width:420px;z-index:99990;padding:18px;background:#fff4cb;color:#352b08;border:2px solid #dfaa21;border-radius:16px;box-shadow:0 8px 35px #0003';notice.setAttribute('role','alert');document.body.append(notice);
 let busy=false,context='';
 async function poll(){
  const s=typeof salesSession!=='undefined'?salesSession:null,a=typeof staffAccount!=='undefined'?staffAccount:null;
  const key=(a?.user_id||'')+':'+(s?.shiftId||'');if(key!==context){context=key;notice.hidden=true;}
  if(!s?.shiftId||!a){notice.hidden=true;return;}if(busy||document.hidden)return;busy=true;
  try{const r=await db.rpc('print_vpn_reminders',{p_shift_id:s.shiftId});if(r.error||context!==key)return;
   const rows=(r.data||[]).filter(x=>localStorage.getItem('vpn:'+a.user_id+':'+x.id)!=='1');
   if(!rows.length){notice.hidden=true;return;}
   notice.replaceChildren();const title=document.createElement('b');title.textContent='🌐 Включите VPN для отправки заказов';notice.append(title);
   const body=document.createElement('p');body.textContent=rows.map(x=>(x.direction==='dtf'?'ДТФ':'Широкоформатная печать')+' — отправка в '+new Date(x.due_at).toLocaleTimeString('ru-RU',{timeZone:'Europe/Moscow',hour:'2-digit',minute:'2-digit'})).join('. ')+'. Не выключайте VPN ближайшие 30 минут: файлы должны автоматически отправиться партнёру.';notice.append(body);
   const ack=document.createElement('button');ack.className='primary';ack.textContent='Понятно';ack.onclick=()=>{for(const x of rows)localStorage.setItem('vpn:'+a.user_id+':'+x.id,'1');notice.hidden=true;};notice.append(ack);notice.hidden=false;
  }catch{}finally{busy=false;}
 }
 setInterval(poll,15000);setTimeout(poll,2000);window.addEventListener('focus',poll);
})();
