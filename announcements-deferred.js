(()=>{
 let saved=new Map(),pending=[],ctx='';
 const box=()=>$('annDeferredHome');
 async function rpc(action,id=null){const r=await db.rpc('announcement_snooze',{p_action:action,p_id:id});if(r.error)throw r.error;return r.data;}
 function clear(){saved.clear();pending=[];ctx='';if(box()){box().hidden=true;box().replaceChildren();}}
 function draw(sess){
  const root=box();if(!root)return;const expanded=root.querySelector('details')?.open||false;
  root.hidden=!pending.length;if(!pending.length){root.replaceChildren();return;}
  root.innerHTML=`<details ${expanded?'open':''}><summary>📢 Отложенные объявления · ${pending.length}</summary><div class="status">Можно прочитать сейчас. Следующее мягкое напоминание — через 4 часа после откладывания или предыдущего напоминания.</div>${pending.map(x=>`<div class="ann-deferred-row"><span>${x.is_urgent?'СРОЧНО · ':''}${esc(x.title)}</span><button class="secondary small" data-ann-open="${Number(x.id)}">Прочитать</button></div>`).join('')}</details>`;
  root.querySelectorAll('[data-ann-open]').forEach(b=>b.onclick=async()=>{const x=pending.find(x=>Number(x.id)===Number(b.dataset.annOpen));if(!x||annShowing||salesSession?.shiftId!==sess.shiftId)return;annShowing=true;try{await showOneAnnouncement(x,0,1,sess);}finally{annShowing=false;}await showAnnouncements(true);});
 }
 async function apply(queue,sess){
  const who=staffAccount?.user_id;if(!who){clear();return queue;}
  const data=await rpc('get');if(staffAccount?.user_id!==who||salesSession?.shiftId!==sess.shiftId)return [];
  if(ctx!==who){clear();ctx=who;}saved=new Map((data.snoozes||[]).map(x=>[Number(x.id),x]));pending=queue.filter(x=>saved.has(Number(x.id)));draw(sess);
  if(!document.hidden&&pending.some(x=>Date.parse(saved.get(Number(x.id)).next_reminder)<=Date.now())){
   const claim=await rpc('claim');const due=new Set((claim.due||[]).map(Number));if(pending.some(x=>due.has(Number(x.id)))&&staffAccount?.user_id===who&&typeof v5Toast==='function')v5Toast('📢 Есть отложенные объявления. Откройте их в блоке на главном экране.');
  }
  return queue.filter(x=>!saved.has(Number(x.id)));
 }
 async function later(x,sess){await rpc('later',x.id);saved.set(Number(x.id),{id:x.id,next_reminder:new Date(Date.now()+4*3600000).toISOString()});pending=pending.filter(y=>y.id!==x.id);pending.push(x);draw(sess);}
 async function read(x){await rpc('clear',x.id);saved.delete(Number(x.id));pending=pending.filter(y=>y.id!==x.id);if(salesSession)draw(salesSession);}
 window.AnnDeferred={apply,later,read,clear};
 setInterval(()=>{if(!staffAccount||!salesSession?.shiftId)clear();},15000);
})();
