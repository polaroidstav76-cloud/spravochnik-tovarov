(()=>{
 const {api,el,button,link,copy,size}=PhotoLinks;
 const launch=document.getElementById('photoLinksBtn');if(!launch)return;
 const panel=el('dialog',null,{class:'photo-panel'});document.body.append(panel);
 let state={},lastOrders=[],ctx='',loading=false,searchTimer=null,notice=null;
 function session(){return typeof salesSession==='undefined'?null:salesSession;}
 async function jwt(){const r=await db.auth.getSession();const token=r.data?.session?.access_token;if(!token)throw new Error('Войдите в Клаудшоп');return token;}
 async function request(action,data={}){return api(action,{...data,shift_id:session()?.shiftId||null},await jwt());}
 function report(e){const s=panel.querySelector('#photoStaffStatus');if(s){s.textContent=e.message||String(e);s.className='photo-panel-status photo-error';}}
 function act(text,fn,primary=false){let b=button(text,async()=>{b.disabled=true;try{await fn(b);}catch(e){report(e);}finally{b.disabled=false;}},primary);return b;}
 function field(label,input,parent){const id='photo-'+crypto.randomUUID();input.id=id;parent.append(el('label',label,{for:id}),input);return input;}
 function clientMessage(url){return `📷 Для загрузки большого количества фотографий, удобнее будет загрузить их по ссылке. Так фотографии сохранят исходное качество, а при отправке через мессенджер они могут сжиматься.

✂️ При загрузке вы можете сами обрезать фотографии под нужный формат печати. Если пропустите этот шаг, сотрудник фотоцентра при необходимости сделает это за вас бесплатно.

🔗 Ссылка для загрузки фотографий
${url}

✅ Как только вы загрузите фотографии, мы оформим ваш заказ.

💬 Если возникнут вопросы, пишите мне!`;}
 function linkBox(url,parent,message=false){const input=el(message?'textarea':'input',null,{readonly:'',class:'photo-link-input','aria-label':message?'Сообщение для клиента':'Ссылка на фотографии',...(message?{rows:'9'}:{})});const text=message?clientMessage(url):url;input.value=text;parent.append(input);parent.append(act(message?'Скопировать сообщение':'Скопировать ссылку',async b=>{b.textContent=await copy(text,input)?(message?'✓ Сообщение скопировано':'✓ Ссылка скопирована'):'Выделено — нажмите Ctrl+C';}));return input;}
 async function show(){
  if(loading)return;loading=true;
  try{
   const a=typeof staffAccount==='undefined'?null:staffAccount;if(!a)throw new Error('Войдите в Клаудшоп');
   state=await request('branches');
   panel.replaceChildren();const head=el('div',null,{class:'photo-panel-head'});head.append(el('h2','Ссылки для фото'),button('Закрыть',()=>panel.close()));panel.append(head);
   panel.append(el('p','Фото клиента — в одной ссылке. Оригиналы хранятся на вашем Яндекс Диске без автоматического удаления.',{class:'photo-muted'}));
   panel.append(el('div','',{id:'photoStaffStatus',class:'photo-panel-status',role:'status'}));
   if(!state.configured)panel.append(el('div',state.admin?'Сначала подключите Яндекс Диск в настройках ниже. После этого клиенты смогут загружать фотографии.':'Администратору нужно подключить Яндекс Диск. Ссылку уже можно создать и сохранить.',{class:'photo-notice'}));
   const grid=el('div',null,{class:'photo-panel-grid'}),create=el('section'),qr=el('section');grid.append(create,qr);panel.append(grid);
   create.classList.add('photo-order-block');qr.classList.add('photo-order-block');create.append(el('h3','Онлайн заказ'));
   const phone=field('Телефон клиента',el('input',null,{type:'tel',placeholder:'999 123-45-67',autocomplete:'tel-national',inputmode:'numeric',maxlength:'30'}),create);const phoneBox=el('div',null,{class:'photo-phone'});phone.replaceWith(phoneBox);phoneBox.append(el('span','+7'),phone);phone.oninput=()=>{let d=phone.value.replace(/\D/g,'');if(/^[78]/.test(d))d=d.slice(1);phone.value=d.slice(0,10);};
   const order=field('Номер заказа (необязательно)',el('input',null,{maxlength:'80',placeholder:'Можно оставить пустым'}),create);
   let branch=null;
   if(session()?.shiftId)create.append(el('p','Филиал: '+session().branchName,{class:'photo-muted'}));
   else if(state.admin){branch=field('Филиал',el('select'),create);branch.append(el('option','Выберите филиал',{value:''}));for(const b of state.branches)branch.append(el('option',b.name,{value:b.id}));}
   else create.append(el('p','Для создания ссылки откройте смену в своём филиале.',{class:'photo-notice'}));
   const result=el('div',null,{class:'photo-actions'});let createId=crypto.randomUUID();
   create.append(act('Получить ссылку',async()=>{
    const r=await request('create',{phone:'+7'+phone.value,order_number:order.value,branch_id:branch?.value||null,request_id:createId});createId=crypto.randomUUID();result.replaceChildren(el('p','✓ Ссылка создана. Отправьте её клиенту.',{class:'photo-success'}));const url=link(r.token);linkBox(url,result,true);await history();
   },true),result);
   qr.append(el('h3','Оффлайн заказ'),el('p','Постоянная ссылка: клиент укажет телефон и выберет WhatsApp или MAX. Каждый клиент получит отдельную загрузку.',{class:'photo-muted'}));
   const select=field('Филиал для QR-кода',el('select'),qr);for(const b of state.branches)select.append(el('option',b.name,{value:b.slug}));const preferred=state.branches.find(b=>Number(b.id)===Number(session()?.branchId));if(preferred)select.value=preferred.slug;
   const qrBox=el('div');qr.append(qrBox);
   const drawQR=()=>{
    const b=state.branches.find(x=>x.slug===select.value);if(!b)return;
    const url=new URL('photos.html',location.href);url.searchParams.set('branch',b.slug);url.hash='';qrBox.replaceChildren();linkBox(url.href,qrBox);
    const code=qrcode(0,'M');code.addData(url.href);code.make();const data=code.createDataURL(5,16),img=el('img',null,{src:data,alt:'QR: загрузить фото · '+b.name,width:'220',height:'220'});const wrap=el('div',null,{class:'photo-qr'});wrap.append(img);qrBox.append(wrap);
    const save=el('a','Скачать QR-код PNG',{href:data,download:'Фото-'+b.name.replace(/[/\\]/g,'-')+'.png',class:'photo-button'});qrBox.append(save);
   };select.onchange=drawQR;drawQR();
   if(state.admin)settings();
   const hist=el('section');hist.append(el('h3','История ссылок'),el('p','Показываются последние 200 ссылок: ваши и вашего филиала. Администратор видит все филиалы.',{class:'photo-muted'}));
   const search=field('Найти по телефону или номеру заказа',el('input',null,{type:'search',placeholder:'Телефон или номер заказа',id:'photoHistorySearch'}),hist);search.id='photoHistorySearch';
   search.oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>history().catch(report),350);};
   hist.append(el('div',null,{id:'photoHistory'}));panel.append(hist);
   if(!panel.open)panel.showModal();await history();
  }catch(e){if(panel.open)report(e);else alert(e.message);}finally{loading=false;}
 }
 function settings(){
  const details=el('details',null,{class:'photo-group'});details.append(el('summary',state.configured?'Настройки Яндекс Диска · подключён':'Подключить Яндекс Диск'));
  details.append(el('p','Вставьте OAuth-токен именно того аккаунта, где подключены 2 ТБ. Почту отправителя это не меняет. Токен хранится в зашифрованном хранилище сервера и не показывается сотрудникам.',{class:'photo-muted'}));
  const token=field('OAuth-токен Яндекс Диска',el('input',null,{type:'password',autocomplete:'off',spellcheck:'false',placeholder:'Токен вставляется только здесь'}),details);
  const status=el('p','',{role:'status'});details.append(act('Проверить и подключить Диск',async()=>{
   status.textContent='Проверяем доступ и папку для фотографий…';
   try{const r=await request('configure',{token:token.value});token.value='';state.configured=true;status.textContent='✓ Диск подключён. Свободно: '+size(r.total-r.used)+'. Можно создавать ссылки и загружать фото.';details.querySelector('summary').textContent='Настройки Яндекс Диска · подключён';}
   catch(e){status.textContent=e.message;throw e;}
  },true),status);
  const help=el('a','Где получить OAuth-токен →',{href:'https://yandex.ru/dev/disk-api/doc/ru/concepts/quickstart',target:'_blank',rel:'noopener'});details.append(help);panel.append(details);
 }
 let historySeq=0;
 async function history(){
  const seq=++historySeq,r=await request('list',{search:panel.querySelector('#photoHistorySearch')?.value||''});if(seq!==historySeq)return;
  lastOrders=r.orders;const box=panel.querySelector('#photoHistory');if(!box)return;box.replaceChildren();
  if(!lastOrders.length)box.append(el('p','Ссылок пока нет.',{class:'photo-muted'}));
  for(const o of lastOrders){
   const card=el('article',null,{class:'photo-order'}),title=el('strong',(o.source==='offline'?'ОФЛАЙН-ЗАКАЗ · ':'')+o.phone+(o.order_number?' · заказ '+o.order_number:''));card.append(title);const viewed=el('span',o.is_new===false?'Просмотрена':'Новая',{class:o.is_new===false?'photo-viewed':'photo-new'});card.append(viewed);if(o.needs_size_advice)card.append(el('p','Нужна консультация по размеру',{class:'photo-advice-note'}));
   card.append(el('p',o.branch_name+' · '+(o.employee_name||'Клиент по QR')+' · '+new Date(o.updated_at).toLocaleString('ru-RU'),{class:'photo-muted'}));
   card.append(el('p',(o.status==='complete'?'✓ Загрузка завершена':'Клиент загружает фото')+' · '+o.file_count+' фото · '+size(Number(o.bytes))+(o.messenger?' · '+(o.messenger==='max'?'MAX':'WhatsApp'):'')));
   if(o.comment)card.append(el('p','Комментарий: '+o.comment));
   const actions=el('div',null,{class:'photo-actions'}),url=link(o.token);const openPhoto=el('a','Открыть фото',{href:url,target:'_blank',rel:'noopener',class:'photo-button'});openPhoto.onclick=()=>{request('seen',{id:o.id,updated_at:o.updated_at}).then(()=>{o.is_new=false;viewed.textContent='Просмотрена';viewed.className='photo-viewed';poll();}).catch(report);};actions.append(openPhoto);
   card.append(actions);box.append(card);
  }
 }
 let pollBusy=false;
 async function poll(){
  const a=typeof staffAccount==='undefined'?null:staffAccount,key=(a?.user_id||'')+':'+(session()?.branchId||'');
  if(ctx!==key){const changed=!!ctx;ctx=key;notice?.remove();notice=null;launch.textContent='Ссылка для фото';if(changed&&panel.open)panel.close();}
  if(!a||document.hidden||pollBusy||panel.open)return;pollBusy=true;
  try{
   const r=await request('list'),fresh=r.orders.filter(o=>o.status==='complete'&&o.is_new!==false);
   if(fresh.length){launch.textContent='Фото клиентов · '+fresh.length;if(!notice){notice=el('div',null,{class:'photo-notice'});launch.closest('.desk-group')?.prepend(notice);}notice.replaceChildren(el('b','Новые фотографии клиентов: '+fresh.length),button('Открыть ссылки',show));}else{launch.textContent='Ссылка для фото';notice?.remove();notice=null;}
  }catch{}finally{pollBusy=false;}
 }
 launch.onclick=show;setInterval(poll,30000);setTimeout(poll,3000);window.addEventListener('focus',poll);
 panel.addEventListener('close',()=>{for(const input of panel.querySelectorAll('input[type=password]'))input.value='';poll();});
})();
