/* Device pairing is admin-only; file notifications require a real target-branch shift. */
(()=>{
 'use strict';
 const $=id=>document.getElementById(id),escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const button=document.createElement('button');button.id='printBridgeBtn';button.type='button';button.className='secondary';button.textContent='30×40';button.hidden=true;
 const refresh=$('refreshBtn');if(!refresh)return;refresh.parentNode.insertBefore(button,refresh);
 document.body.insertAdjacentHTML('beforeend',`<div class="modal" id="printBridgeModal"><div class="dialog pb-dialog" role="dialog" aria-modal="true" aria-labelledby="pbTitle"><div class="pb-tools"><h2 id="pbTitle" style="margin-right:auto">Файлы 30×40</h2><button type="button" id="pbClose" class="secondary">Закрыть</button></div><section id="pbAdmin" class="pb-admin" hidden><h3>Подключение компьютеров</h3><p id="pbTarget"></p><p class="pb-note">Основная программа принимает файлы бота. Приёмник на компьютере с принтером сохраняет их в папку. Новый код заменяет прежнее подключение этого режима после активации.</p><div class="pb-tools"><button type="button" id="pbPairSource" class="secondary">Код для основной программы</button><button type="button" id="pbPairReceiver" class="secondary">Код для приёмника 30×40</button></div><div id="pbCodeBox" class="pb-code" hidden><input id="pbCode" readonly autocomplete="off" aria-label="Одноразовый код подключения"><button type="button" id="pbCopy" class="secondary">Скопировать код</button></div><div id="pbCodeInfo" class="pb-note"></div><div id="pbDevices"></div></section><div id="pbMessage" class="pb-note" role="status"></div><div id="pbFiles"></div><p class="pb-note">Уведомление появляется после сохранения и проверки файла на компьютере с принтером. Печать запускает сотрудник. Кнопка «Прочитано» не означает, что файл напечатан.</p></div></div>`);
 let user=null,target=null,rows=[],context='',busy=false;const announced=new Set();
 const account=()=>typeof staffAccount!=='undefined'?staffAccount:null;
 const session=()=>typeof salesSession!=='undefined'?salesSession:null;
 const admin=()=>account()?.role==='admin';
 const key=()=>String(account()?.user_id||'')+':'+String(session()?.shiftId||'');
 async function rpc(name,args){const r=await db.rpc(name,args);if(r.error)throw r.error;return r.data;}
 function message(text,error=false){$('pbMessage').textContent=text;$('pbMessage').classList.toggle('pb-error',error);}
 function draw(){
  $('pbFiles').innerHTML=rows.length?rows.map(r=>`<div class="pb-file ${r.is_read?'':'pb-unread'}"><div class="pb-file-name">${escape(r.filename)}</div><div class="pb-note">Скачан: ${escape(new Date(r.downloaded_at).toLocaleString('ru-RU'))} · ${escape(r.source_branch)}</div><div class="pb-note">В папке приёмника: ${escape(r.relative_path)}</div>${r.is_read?'<span class="pb-note">Прочитано</span>':`<button type="button" class="secondary small" data-pb-read="${escape(r.id)}">Прочитано</button>`}</div>`).join(''):'<div class="pb-note">Скачанных файлов пока нет.</div>';
  for(const b of $('pbFiles').querySelectorAll('[data-pb-read]'))b.onclick=async()=>{
   const snapshot=key();b.disabled=true;
   try{await rpc('print_bridge_read',{p_shift_id:session()?.shiftId,p_job_id:b.dataset.pbRead});if(snapshot!==key())return;rows=rows.map(r=>r.id===b.dataset.pbRead?{...r,is_read:true}:r);draw();badge();}
   catch{message('Не удалось сохранить отметку. Проверьте интернет и открытую смену.',true);b.disabled=false;}
  };
 }
 function badge(){const n=rows.filter(r=>!r.is_read).length;button.textContent='30×40'+(n?' · '+n:'');}
 function toast(fresh){
  document.querySelector('.pb-toast')?.remove();const box=document.createElement('div');box.className='pb-toast';box.setAttribute('role','alert');
  const text=document.createElement('div');text.textContent=fresh.length===1?'30×40: скачан файл «'+fresh[0].filename+'»':'30×40: скачано файлов — '+fresh.length+'. '+fresh.slice(0,3).map(r=>r.filename).join(', ');box.append(text);
  const show=document.createElement('button');show.type='button';show.className='secondary';show.textContent='Посмотреть';show.onclick=()=>{box.remove();openModal();};box.append(show);document.body.append(box);setTimeout(()=>box.remove(),15000);
 }
 async function poll(){
  if(busy)return;busy=true;
  try{
   const a=account(),s=session();if(!a){user=null;target=null;rows=[];context='';announced.clear();button.hidden=true;$('printBridgeModal').classList.remove('show');return;}
   if(user!==a.user_id){user=a.user_id;target=null;rows=[];announced.clear();}
   if(!target)target=await rpc('print_bridge_target');
   const visible=!!(s?.shiftId&&Number(s.branchId)===Number(target.branch_id));button.hidden=!admin()&&!visible;$('pbAdmin').hidden=!admin();
   if(context!==key()){context=key();rows=[];announced.clear();draw();badge();document.querySelector('.pb-toast')?.remove();}
   if(!visible){rows=[];draw();badge();message('Уведомления доступны сотрудникам открытой смены '+target.branch+'.');return;}
   const snapshot=key();const files=await rpc('print_bridge_files',{p_shift_id:s.shiftId});if(snapshot!==key())return;
   rows=Array.isArray(files)?files:[];draw();badge();message('Файлы сохранены на компьютере с принтером.');
   const fresh=rows.filter(r=>!r.is_read&&!announced.has(r.id));rows.forEach(r=>announced.add(r.id));if(fresh.length)toast(fresh);
  }catch{rows=[];draw();badge();message('Не удалось проверить файлы 30×40. Проверьте вход, смену и интернет.',true);}
  finally{busy=false;}
 }
 async function loadSetup(){
  if(!admin())return;
  const data=await rpc('print_bridge_setup');$('pbTarget').textContent='Филиал с принтером: '+data.branch;
  $('pbDevices').innerHTML=(data.devices||[]).map(d=>`<div class="pb-note">${d.role==='source'?'Основная программа':'Приёмник'}: ${escape(d.label)} · ${d.last_seen?'связь '+escape(new Date(d.last_seen).toLocaleString('ru-RU')):'ожидает первого задания / проверки'} <button type="button" class="secondary small" data-pb-revoke="${escape(d.id)}">Отключить</button></div>`).join('');
  for(const b of $('pbDevices').querySelectorAll('[data-pb-revoke]'))b.onclick=async()=>{if(!confirm('Отключить доступ этого компьютера? Для повторного подключения понадобится новый код.'))return;try{await rpc('print_bridge_revoke',{p_id:b.dataset.pbRevoke});await loadSetup();}catch{message('Не удалось отключить компьютер.',true);}};
 }
 async function openModal(){
  $('printBridgeModal').classList.add('show');$('pbAdmin').hidden=!admin();await poll();
  if(admin())try{await loadSetup();}catch{message('Не удалось загрузить подключённые компьютеры.',true);}
 }
 button.onclick=openModal;
 $('pbClose').onclick=()=>{$('printBridgeModal').classList.remove('show');$('pbCode').value='';$('pbCodeBox').hidden=true;$('pbCodeInfo').textContent='';};
 async function makeCode(role){
  $('pbPairSource').disabled=true;$('pbPairReceiver').disabled=true;
  try{const data=await rpc('print_bridge_pair_code',{p_role:role});$('pbCode').value=data.code;$('pbCodeBox').hidden=false;$('pbCodeInfo').textContent=(role==='source'?'Вставьте в основной программе, вкладка «Мастерская и 30×40».':'Вставьте в приёмнике, запущенном через START-30X40.cmd на компьютере с принтером.')+' Код действует 15 минут; в переписку с поддержкой его не отправляйте.';}
  catch{message('Код не создан. Нужен вход администратора.',true);}
  finally{$('pbPairSource').disabled=false;$('pbPairReceiver').disabled=false;}
 }
 $('pbPairSource').onclick=()=>makeCode('source');$('pbPairReceiver').onclick=()=>makeCode('receiver');
 $('pbCopy').onclick=async()=>{try{if(navigator.clipboard)await navigator.clipboard.writeText($('pbCode').value);else{$('pbCode').select();document.execCommand('copy');}$('pbCodeInfo').textContent+=' Скопировано.';}catch{$('pbCode').select();message('Выделен код. Скопируйте его через Ctrl+C.');}};
 setTimeout(poll,1500);setInterval(()=>{if(!document.hidden)poll();},15000);
 window.addEventListener('focus',poll);window.addEventListener('online',poll);document.addEventListener('visibilitychange',()=>{if(!document.hidden)poll();});
})();
