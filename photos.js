(async()=>{
 const {api,el,button,size,validPhoto,put}=PhotoLinks,app=document.getElementById('photoApp'),error=document.getElementById('photoError');
 let offlineAdvice=false;let token=location.hash.slice(1),manifest=null,queue=[],working=false,active=0,modeBusy=false,currentGroup='',commentDraft=null,renderVersion=0,persisting=0;
 const params=new URLSearchParams(location.search),slug=params.get('branch');
 function fail(e){error.textContent=e.message||String(e);error.hidden=false;error.scrollIntoView({block:'nearest'});}
 function clearError(){error.hidden=true;}
 async function call(action,data={}){return api(action,{...data,token});}
 async function safe(fn,b){if(b)b.disabled=true;clearError();try{await fn();}catch(e){fail(e);}finally{if(b?.isConnected)b.disabled=false;}}
 function action(text,fn,primary=false){let b=button(text,()=>safe(()=>fn(b),b),primary);return b;}
 function announce(){window.dispatchEvent(new CustomEvent('photo:manifest',{detail:manifest}));}
 async function refresh(){manifest=await call('manifest');render();announce();}
 function showLink(){const p=el('p','Эта ссылка принадлежит вашему заказу. Не отправляйте её посторонним.',{class:'photo-muted'});app.append(p);}
 function support(parent,contacts,branch){const box=el('section',null,{class:'photo-support'}),details=el('details');details.append(el('summary','Написать в фотоцентр'));details.append(el('p',branch,{class:'photo-muted'}));const actions=el('div',null,{class:'photo-actions'});for(const [key,name]of [['whatsapp','WhatsApp'],['telegram','Telegram'],['max','MAX']]){const href=contacts?.[key];if(typeof href==='string'&&/^https:\/\//.test(href)){const url=new URL(href);if((key==='whatsapp'&&['wa.me','api.whatsapp.com'].includes(url.hostname))||(key==='telegram'&&url.hostname==='t.me')||(key==='max'&&url.hostname==='max.ru'))actions.append(el('a',name,{href,target:'_blank',rel:'noopener',class:'photo-button'}));}}if(!actions.children.length)actions.append(el('a','Контакты фотоцентра',{href:'https://foto-26.ru/contacts',target:'_blank',rel:'noopener',class:'photo-button'}));details.append(actions);box.append(details);parent.append(box);}
 function advice(parent,needed,change){const b=action(needed?'✓ Нужна консультация по размеру':'Нужна консультация по размеру',async()=>{const next=!needed;await change(next);needed=next;b.textContent=needed?'✓ Нужна консультация по размеру':'Нужна консультация по размеру';b.setAttribute('aria-pressed',String(needed));});b.setAttribute('aria-pressed',String(!!needed));b.classList.add('photo-advice');parent.append(b);}
 async function offline(){
  const state=await api('branches',{slug}),branch=state.branches[0];
  if(!branch)throw new Error('Ссылка филиала не найдена. Попросите сотрудника показать актуальный QR-код.');
  app.replaceChildren(el('h2','Фото для печати'),el('p',branch.name,{class:'photo-muted'}));
  if(!state.configured){app.append(el('p','Фотоцентр подключает хранилище. Пожалуйста, обратитесь к сотруднику.',{class:'photo-notice'}));return;}
  support(app,branch.contacts,branch.name);advice(app,offlineAdvice,async value=>{offlineAdvice=value;});
  const form=el('form'),phone=el('input',null,{type:'tel',autocomplete:'tel',inputmode:'tel',placeholder:'+7 999 123-45-67',required:'',maxlength:'30',id:'offlinePhone'});
  const messenger=el('select',null,{id:'offlineMessenger'});for(const [v,t]of [['','Выберите мессенджер'],['whatsapp','WhatsApp'],['max','MAX']])messenger.append(el('option',t,{value:v}));messenger.required=true;
  const trap=el('input',null,{type:'text',tabindex:'-1',autocomplete:'off',class:'photo-honeypot','aria-hidden':'true'});
  form.append(el('label','Ваш телефон',{for:'offlinePhone'}),phone,el('label','Где с вами связаться',{for:'offlineMessenger'}),messenger,trap,el('p','Номер нужен, чтобы сотрудник нашёл ваши фотографии и связался с вами по заказу.',{class:'photo-muted'}));
  const submit=button('Перейти к фотографиям',()=>{},true);submit.type='submit';form.append(submit);
  form.onsubmit=e=>{e.preventDefault();safe(async()=>{const r=await api('create',{slug,phone:phone.value,messenger:messenger.value,request_id:requestId,website:trap.value,needs_size_advice:offlineAdvice});token=r.token;history.replaceState(null,'',PhotoLinks.link(token));await refresh();},submit);};
  const requestId=crypto.randomUUID();app.append(form);
 }
 function readyFiles(g){return manifest.files.filter(f=>f.status==='ready'&&(!g||f.group_id===g));}
 function render(){
  renderVersion++;app.replaceChildren();
  app.append(el('p',manifest.branch+(manifest.order_number?' · Заказ '+manifest.order_number:'')+' · телефон …'+manifest.phone_hint,{class:'photo-muted'}));
  if(manifest.source==='offline'){support(app,manifest.contacts,manifest.branch);advice(app,manifest.needs_size_advice,async needed=>{await call('consultation',{needed});await refresh();});}
  if(!manifest.configured){app.append(el('div','Фотоцентр ещё подключает хранилище. Ссылка сохранена — вернитесь к ней позже.',{class:'photo-notice'}));return;}
  if(manifest.status==='complete'){
   const success=el('div',null,{class:'photo-success'});success.append(el('strong','Фотографии отправлены!'),el('p','Сотрудник фотоцентра свяжется с вами в ближайшее время для оформления заказа.'),el('p','Сохранено: '+readyFiles().length+' фото.'));app.append(success);
   for(const g of manifest.groups){const row=el('div',null,{class:'photo-summary'});row.append(el('span',g.label),el('b',readyFiles(g.id).length+' фото'));app.append(row);const gallery=el('div',null,{class:'photo-gallery'});for(const f of readyFiles(g.id)){const tile=el('div',null,{class:'photo-tile'}),image=el('img',null,{alt:'Отправленная фотография',loading:'lazy'});tile.append(image);gallery.append(tile);PhotoLinks.showPhotoPreview?.(image,f,token);}app.append(gallery);}
   if(manifest.comment)app.append(el('p','Комментарий: '+manifest.comment));
   const actions=el('div',null,{class:'photo-actions'});actions.append(action('Добавить ещё фото',async()=>{await call('reopen');queue=[];await refresh();},true),action('Скачать все фото ZIP',()=>download('ready')));app.append(actions);showLink();return;
  }
  if(!manifest.mode){
   app.append(el('h2','Какие размеры фотографий?'));
   const choices=el('div',null,{class:'photo-choices'});
   for(const [v,t,s]of [['same','Один размер','Просто загрузите фотографии. Размер обсудим в переписке.'],['different','Разные размеры','Разложите фотографии по размерам, например 10×15 и 15×21.']]){
    const b=action(t,async()=>{if(modeBusy)return;modeBusy=true;try{await call('mode',{mode:v});await refresh();}finally{modeBusy=false;}},true);b.append(el('small',s));choices.append(b);
   }app.append(choices);return;
  }
  app.append(el('p','При желании вы можете сами обрезать фотографии и выбрать, какая часть снимка попадёт на печать. Это необязательно — сотрудник фотоцентра подготовит фотографии за вас.',{class:'photo-crop-optional'}));
  app.append(el('h2',manifest.mode==='same'?'Добавьте фотографии':'Фотографии по размерам'));
  app.append(el('p','JPG, PNG, HEIC, TIFF, WEBP и RAW — без сжатия и изменения качества. До 512 МБ на файл, до 4,5 ГБ на ссылку.',{class:'photo-muted'}));
  if(manifest.mode==='same'&&!manifest.groups.length){safe(async()=>{await call('group');await refresh();});return;}
  for(const g of manifest.groups)renderGroup(g);
  if(manifest.mode==='different'){
   const form=el('form',null,{class:'photo-group'}),label=el('input',null,{placeholder:'Например: 10×15, квадрат 15×15…',maxlength:'80',required:'','aria-label':'Размер фотографий'});
   const b=button('Добавить размер',()=>{},true);b.type='submit';form.append(el('h3','Новый размер'),label,el('div',null,{class:'photo-actions'}));form.lastChild.append(b);
   form.onsubmit=e=>{e.preventDefault();safe(async()=>{const g=await call('group',{label:label.value});currentGroup=g.id;await refresh();document.getElementById('group-'+g.id)?.scrollIntoView({behavior:'smooth',block:'center'});},b);};app.append(form);
  }
  const label=el('label','Комментарий к заказу (необязательно)',{for:'photoComment'}),comment=el('textarea',null,{id:'photoComment',maxlength:'3000',rows:'3',placeholder:'Например: печатать без полей…'});comment.value=commentDraft??manifest.comment;comment.oninput=()=>commentDraft=comment.value;app.append(label,comment);
  const bar=el('div',null,{class:'photo-sticky'}),summary=el('p','',{id:'photoUploadSummary',class:'photo-muted'});
  const finish=action('Завершить загрузку фото',async()=>{if(working||queue.some(f=>f.state==='error'))throw new Error('Дождитесь загрузки фото. Файлы с ошибкой можно повторить или исключить.');PhotoLinks.beforePhotoFinish?.();await call('finish',{comment:comment.value});commentDraft=null;queue=[];await refresh();document.querySelector('.photo-success')?.scrollIntoView({behavior:'smooth',block:'start'});document.querySelector('.photo-success')?.setAttribute('tabindex','-1');document.querySelector('.photo-success')?.focus({preventScroll:true});},true);finish.id='photoFinish';
  bar.append(summary,finish);app.append(bar);updateSummary();
 }
 function renderGroup(g){
  const card=el('section',null,{class:'photo-group',id:'group-'+g.id});card.append(el('h3',g.label));
  const ready=readyFiles(g.id);if(ready.length){const list=el('div',null,{class:'photo-gallery'});for(const f of ready){const tile=button('',()=>window.dispatchEvent(new CustomEvent('photo:edit',{detail:f.id})));tile.className='photo-tile';tile.setAttribute('aria-label','Обрезать фото и добавить поля');const image=el('img',null,{alt:'Загруженная фотография',loading:'lazy'});tile.append(image,el('span',f.render_id?'✓ Подготовлено':'✓ Загружено'));const holder=el('div',null,{class:'photo-tile-item'});holder.append(tile,action('Удалить',()=>PhotoLinks.removePhoto(f.id)));list.append(holder);PhotoLinks.showPhotoPreview?.(image,f,token);}card.append(el('p','Сохранено '+ready.length+' фото',{class:'photo-muted'}),list);}
  const pending=manifest.files.filter(f=>f.group_id===g.id&&f.status==='pending'&&!queue.some(q=>q.id===f.id));
  if(pending.length){card.append(el('p','Эти файлы не завершили загрузку. Выберите их снова для повтора или исключите из заказа.',{class:'photo-muted'}));for(const f of pending){const row=el('div',null,{class:'photo-file'});row.append(el('span',f.name),action('Исключить',async()=>{await call('skip',{id:f.id});await refresh();}));card.append(row);}}
  const drop=el('div',null,{class:'photo-drop'}),input=el('input',null,{type:'file',multiple:'',accept:'.jpg,.jpeg,.png,.heic,.heif,.tif,.tiff,.webp,.avif,.bmp,.dng,.cr2,.nef,.arw',hidden:true});
  const choose=button('Выбрать фото',()=>input.click(),true);drop.append(choose,el('p','или перетащите фотографии сюда',{class:'photo-muted'}),input);
  input.onchange=()=>{addFiles(input.files,g.id);input.value='';};drop.ondragover=e=>{e.preventDefault();drop.classList.add('dragover');};drop.ondragleave=()=>drop.classList.remove('dragover');drop.ondrop=e=>{e.preventDefault();drop.classList.remove('dragover');addFiles(e.dataTransfer.files,g.id);};card.append(drop);
  if(manifest.mode==='different')card.append(button('Размер загружен · добавить другой',()=>{app.querySelector('form input')?.focus();app.querySelector('form')?.scrollIntoView({behavior:'smooth',block:'center'});}));
  const list=el('div',null,{id:'queue-'+g.id,class:'photo-gallery'});card.append(list);app.append(card);for(const f of queue.filter(f=>f.group_id===g.id&&!(f.state==='ready'&&manifest.files.some(x=>x.id===f.id&&x.status==='ready'))))drawFile(f);
 }
 function drawFile(f){
  let row=document.getElementById('upload-'+f.id);if(!row){row=el('div',null,{class:'photo-file',id:'upload-'+f.id});document.getElementById('queue-'+f.group_id)?.append(row);}
  const preview=row.querySelector('img')||el('img',null,{alt:'Выбранная фотография',class:'upload-preview'});row.replaceChildren(preview);if(!preview.src&&/^image\//.test(f.file.type)){const url=URL.createObjectURL(f.file);preview.onload=preview.onerror=()=>URL.revokeObjectURL(url);preview.src=url;}
  const status=f.state==='ready'?'✓ Сохранено':f.state==='error'?'Не загружено':f.state==='queued'?'В очереди':f.progress>=1?'Проверяем файл…':Math.round(f.progress*100)+'%';row.append(el('span',status));
  if(['uploading','queued'].includes(f.state)){const p=el('progress',null,{max:'1',value:String(f.progress)});row.append(p);}
  if(f.state==='error'){
   row.append(el('span',f.error||'Проверьте интернет',{class:'photo-error'}));const buttons=el('div');
   buttons.append(button('Повторить',()=>{f.state='queued';f.error='';drawFile(f);pump();}),action('Исключить',async()=>{if(f.reserved)await call('skip',{id:f.id});queue=queue.filter(x=>x!==f);row.remove();await PhotoLinks.local.remove(token,f.id,'original').catch(()=>{});await refresh();}));row.append(buttons);
  }
 }
 async function addFiles(files,group_id){
  clearError();const rejected=[];
  for(const file of Array.from(files||[])){
   if(!validPhoto(file)||file.name.length>180){rejected.push(file.name);continue;}
   if(queue.some(q=>q.group_id===group_id&&q.file.name===file.name&&q.file.size===file.size&&q.file.lastModified===file.lastModified))continue;
   const pending=manifest.files.find(f=>f.status==='pending'&&f.group_id===group_id&&f.name===file.name&&f.size===file.size&&!queue.some(q=>q.id===f.id));
   const f={id:pending?.id||crypto.randomUUID(),group_id,file,state:'queued',progress:0,reserved:!!pending};persisting++;
   try{await PhotoLinks.local.put(token,f.id,'original',{file,group_id,pending:true});}catch{fail(new Error('На устройстве не хватает места для черновика. Загрузка продолжится, но до её завершения не закрывайте браузер.'));}finally{persisting--;}
   queue.push(f);drawFile(f);pump();
  }
  if(rejected.length)fail(new Error('Не добавлены: '+rejected.slice(0,5).join(', ')+'. Нужен поддерживаемый формат фото, до 512 МБ, имя до 180 символов.'));
  pump();
 }
 function updateSummary(){const e=document.getElementById('photoUploadSummary');if(e){const saved=readyFiles().length+queue.filter(f=>f.state==='ready'&&!manifest.files.some(x=>x.id===f.id&&x.status==='ready')).length;e.textContent='Сохранено '+saved+' фото'+(working?' · загружается '+active:'')+(queue.some(f=>f.state==='error')?' · есть незагруженные файлы':'');}const finish=document.getElementById('photoFinish');if(finish)finish.disabled=working||PhotoLinks.cropsPending||queue.some(f=>f.state==='error')||manifest.files.some(f=>f.status==='pending'&&!queue.some(q=>q.id===f.id&&q.state==='ready'))||readyFiles().length+queue.filter(f=>f.state==='ready').length===0;}
 async function upload(f){
  f.state='uploading';f.progress=0;drawFile(f);
  for(let attempt=0;attempt<3;attempt++)try{
   const r=await call('reserve',{id:f.id,group_id:f.group_id,name:f.file.name,size:f.file.size});f.reserved=true;
   if(!r.ready){await put(r.href,f.file,p=>{f.progress=p;drawFile(f);});await call('complete_file',{id:f.id});}
   f.state='ready';f.progress=1;await PhotoLinks.local.put(token,f.id,'original',{file:f.file,group_id:f.group_id,pending:false}).catch(()=>{});drawFile(f);try{manifest=await call('manifest');render();announce();}catch{}return;
  }catch(e){if(attempt<2){await new Promise(r=>setTimeout(r,1000*(attempt+1)));continue;}f.state='error';f.error=e.message;drawFile(f);}
 }
 function pump(){const jobs=queue.filter(f=>f.state==='queued');for(const f of jobs){f.state='uploading';active++;working=true;updateSummary();upload(f).finally(()=>{active--;working=active>0;updateSummary();if(!working)call('manifest').then(m=>{manifest=m;announce();updateSummary();}).catch(fail);});}updateSummary();}
 async function download(variant){const win=window.open('about:blank','_blank');if(win){win.opener=null;win.document.body.textContent='Готовим общий архив фотографий. Пожалуйста, подождите…';}const progress=el('p','Готовим архив…',{role:'status'});app.append(progress);let cursor=0,snapshot='';try{let r;do{r=await call('download',{variant:variant||'ready',cursor,snapshot});if(r.preparing){cursor=r.cursor||0;snapshot=r.snapshot||'';progress.textContent='Готовим архив: '+r.done+' из '+r.total+' фото. Не закрывайте страницу.';if(win&&!win.closed)win.document.body.textContent=progress.textContent;}}while(r.preparing);progress.textContent='Архив готов.';if(win&&!win.closed)win.location=r.href||r.folder;else{const a=el('a','Скачать фото',{href:r.href||r.folder,target:'_blank',rel:'noopener',class:'photo-button'});app.append(a);}if(r.message)fail(new Error(r.message));}catch(e){win?.close();progress.textContent='Не удалось собрать архив. Повторите скачивание — подготовленные файлы сохранятся.';throw e;}}
 window.addEventListener('photo:removed',e=>{queue=queue.filter(f=>f.id!==e.detail);updateSummary();});
 window.addEventListener('photo:saving',updateSummary);
 window.addEventListener('photo:refresh',()=>refresh().catch(fail));
 window.addEventListener('beforeunload',e=>{if(working||persisting){e.preventDefault();e.returnValue='';}});
 try{if(/^[a-f0-9]{64}$/.test(token)){await refresh();const originals=await PhotoLinks.local.list(token,'original').catch(()=>[]);for(const row of originals){if(row.value.pending&&manifest.groups.some(g=>g.id===row.value.group_id)&&!manifest.files.some(f=>f.id===row.id&&f.status==='ready')){queue.push({id:row.id,group_id:row.value.group_id,file:row.value.file,state:'queued',progress:0,reserved:manifest.files.some(f=>f.id===row.id)});}}if(queue.length){render();pump();}}else if(slug)await offline();else{app.replaceChildren(el('h2','Нужна ваша личная ссылка'),el('p','Попросите сотрудника фотоцентра прислать ссылку для фото или отсканируйте QR-код в филиале.'));}}catch(e){app.replaceChildren(el('h2','Не удалось открыть загрузку'),action('Попробовать ещё раз',()=>location.reload(),true));fail(e);}
})();
