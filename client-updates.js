(()=>{
  const clients=window.CloudshopClients||[];
  if(!clients.length)return;
  const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const labels={offered:'Ждёт ответа',accepted:'Клиент согласился',declined:'Клиент отказался',installed:'Установлено',withdrawn:'Снято'};
  const money=n=>Number(n)>0?new Intl.NumberFormat('ru-RU',{style:'currency',currency:'RUB'}).format(n):'Бесплатно';
  const date=s=>s?new Date(s).toLocaleString('ru-RU',{day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit'}):'';
  const button=document.createElement('button');button.id='clientUpdatesBtn';button.className='secondary';button.textContent='Обновления клиентов';button.style.display='none';document.getElementById('adminbar').insertBefore(button,document.getElementById('refreshBtn'));
  document.body.insertAdjacentHTML('beforeend',`<div id="clientUpdatesModal" class="modal"><div class="dialog" role="dialog" aria-modal="true" aria-labelledby="cuTitle"><div class="cu-head"><div><h2 id="cuTitle">Обновления клиентов</h2><p>Предложение → ответ клиента → работа → отметка об установке.</p></div><button type="button" id="cuClose" class="secondary">Закрыть</button></div><div class="cu-layout"><section><div class="field cu-target"><label for="cuTarget">Сайт клиента</label><select id="cuTarget">${clients.map(c=>`<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('')}</select></div><a id="cuSite" class="cu-link" target="_blank" rel="noopener">Открыть сайт клиента ↗</a><div id="cuSummary" class="cu-summary"></div><div class="field"><label for="cuFilter">Показать</label><select id="cuFilter"><option value="all">Все предложения</option><option value="offered">Ждут ответа</option><option value="accepted">Согласованы</option><option value="declined">Отказы</option><option value="installed">Установлены</option><option value="withdrawn">Сняты</option></select></div><button type="button" id="cuRefresh" class="secondary small">Обновить ответы</button><div id="cuListMsg" class="cu-msg" role="status"></div><div id="cuRows"></div></section><section class="cu-panel"><h3 id="cuFormTitle">Новое предложение</h3><form id="cuForm"><div class="field"><label for="cuName">Название *</label><input id="cuName" maxlength="140" required placeholder="Например: поиск заказов по телефону"></div><div class="field"><label for="cuDescription">Что изменится для клиента</label><textarea id="cuDescription" maxlength="8000" placeholder="Опишите результат простыми словами"></textarea></div><div class="cu-fields"><div class="field"><label for="cuPrice">Стоимость, ₽</label><input id="cuPrice" type="number" min="0" max="9999999999" step="0.01" value="0" required></div><div class="field"><label for="cuEta">Срок выполнения</label><input id="cuEta" maxlength="120" placeholder="Например: 3 рабочих дня"></div></div><div class="field"><label for="cuFiles">Примеры и скриншоты</label><input id="cuFiles" type="file" accept="image/png,image/jpeg,image/webp" multiple><p class="cu-note">До 3 изображений, каждое до 2 МБ; вместе до 4 МБ. Новые изображения заменят старые.</p><div id="cuExisting" class="cu-note"></div><label class="cu-remove"><input id="cuRemoveImages" type="checkbox">Убрать прежние изображения</label></div><p class="cu-note">0 ₽ — бесплатное предложение. Клиент увидит его в разделе «Обновления» при следующем входе или обновлении страницы.</p><button type="submit" id="cuSave" class="primary">Отправить предложение</button><button type="button" id="cuCancel" class="secondary small" style="display:none;margin-top:10px">Отменить редактирование</button><div id="cuFormMsg" class="cu-msg" role="status"></div></form><p class="cu-note">Согласие клиента не меняет код сайта и не списывает деньги. Публикацию правки выполняем отдельно после согласования.</p></section></div></div></div>`);
  const $=id=>document.getElementById(id),modal=$('clientUpdatesModal');
  let rows=[],editId=null,busy=false,generation=0;
  const target=()=>clients.find(c=>c.id===$('cuTarget').value);
  function message(id,text,bad=false){$(id).textContent=text;$(id).classList.toggle('bad',bad)}
  function setBusy(on){busy=on;$('cuSave').disabled=on;$('cuTarget').disabled=on;$('cuRefresh').disabled=on;modal.querySelectorAll('.cu-action').forEach(b=>b.disabled=on)}
  async function api(action,payload={},client=target()){
    if(!isAdmin)throw Error('Войдите администратором основного сайта');
    const {data,error}=await db.auth.getSession();
    if(error||!data.session?.access_token)throw Error('Войдите на основной сайт заново');
    const response=await fetch(client.url+'/functions/v1/client-updates',{method:'POST',headers:{apikey:client.key,Authorization:'Bearer '+data.session.access_token,'Content-Type':'application/json'},body:JSON.stringify({action,...payload}),signal:AbortSignal.timeout(30000)});
    let value;try{value=await response.json()}catch{throw Error('Сервер клиента не ответил. Повторите позже.')}
    if(!response.ok||value.error)throw Error(value.error||value.message||'Не удалось выполнить действие');
    return value;
  }
  function reset(){editId=null;$('cuForm').reset();$('cuPrice').value='0';$('cuFormTitle').textContent='Новое предложение';$('cuSave').textContent='Отправить предложение';$('cuCancel').style.display='none';$('cuExisting').textContent='';message('cuFormMsg','')}
  function draw(){
    const selected=$('cuFilter').value,client=target();
    $('cuSummary').innerHTML=['offered','accepted','installed'].map(s=>`<span>${esc(labels[s])}: ${rows.filter(r=>r.status===s).length}</span>`).join('');
    const shown=rows.filter(r=>selected==='all'||r.status===selected);
    $('cuRows').innerHTML=shown.length?shown.map(r=>`<article class="cu-card"><header><b>${esc(r.title)}</b><span class="cu-st ${Object.hasOwn(labels,r.status)?r.status:''}">${esc(labels[r.status]||r.status)}</span></header><div class="cu-meta">${esc(money(r.price))}${r.eta?' · '+esc(r.eta):''}<br>Отправлено ${date(r.created_at)}${r.decided_at?'<br>Ответ '+date(r.decided_at)+(r.decided_by_name?' · '+esc(r.decided_by_name):''):''}${r.installed_at?'<br>Установлено '+date(r.installed_at):''}</div><div class="cu-description">${esc(r.description)}</div><div class="cu-images">${(r.images||[]).filter(src=>typeof src==='string'&&src.startsWith(client.url+'/storage/v1/object/public/product-images/')).map(src=>`<a href="${esc(src)}" target="_blank" rel="noopener"><img src="${esc(src)}" alt="Пример обновления" loading="lazy"></a>`).join('')}</div><div class="cu-buttons">${r.status==='offered'?`<button type="button" class="secondary small cu-action" data-action="edit" data-id="${r.id}">Изменить</button><button type="button" class="danger small cu-action" data-action="withdrawn" data-id="${r.id}">Снять предложение</button>`:''}${r.status==='accepted'?`<button type="button" class="primary small cu-action" data-action="installed" data-id="${r.id}">Отметить установленным</button>`:''}${['declined','withdrawn'].includes(r.status)?`<button type="button" class="secondary small cu-action" data-action="offered" data-id="${r.id}">Предложить снова</button>`:''}</div></article>`).join(''):'<div class="cu-empty">Предложений пока нет. Создайте первое в форме рядом.</div>';
    modal.querySelectorAll('.cu-action').forEach(b=>b.disabled=busy);
  }
  async function load(){const token=++generation,client=target();$('cuSite').href=client.site;message('cuListMsg','Загружаю ответы…');try{const data=await api('list',{},client);if(token!==generation)return;rows=data.updates||[];draw();message('cuListMsg','Ответы обновлены: '+new Date().toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'}))}catch(e){if(token===generation){rows=[];draw();message('cuListMsg',e.message,true)}}}
  const fileData=file=>new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve({mime:file.type,base64:String(r.result).split(',')[1]});r.onerror=()=>reject(Error('Не удалось прочитать изображение'));r.readAsDataURL(file)});
  $('cuForm').addEventListener('submit',async event=>{
    event.preventDefault();if(busy)return;
    const files=[...$('cuFiles').files];
    if(files.length>3||files.some(f=>!['image/png','image/jpeg','image/webp'].includes(f.type)||f.size>2097152)||files.reduce((s,f)=>s+f.size,0)>4194304){message('cuFormMsg','До 3 файлов PNG, JPG или WebP: каждый до 2 МБ, вместе до 4 МБ.',true);return}
    const name=$('cuName').value.trim(),price=Number($('cuPrice').value);
    if(!name||!Number.isFinite(price)||price<0){message('cuFormMsg','Проверьте название и стоимость.',true);return}
    setBusy(true);message('cuFormMsg','Отправляю предложение клиенту…');
    try{await api('save',{id:editId,title:name,description:$('cuDescription').value,price,eta:$('cuEta').value,remove_images:$('cuRemoveImages').checked,files:await Promise.all(files.map(fileData))});reset();message('cuFormMsg','Готово. Предложение появилось на сайте клиента.');await load()}catch(e){message('cuFormMsg',e.message,true)}finally{setBusy(false)}
  });
  $('cuRows').addEventListener('click',async event=>{
    const b=event.target.closest('[data-action]');if(!b||busy)return;const row=rows.find(r=>Number(r.id)===Number(b.dataset.id));if(!row)return;
    const action=b.dataset.action;
    if(action==='edit'){editId=row.id;$('cuName').value=row.title;$('cuDescription').value=row.description||'';$('cuPrice').value=row.price;$('cuEta').value=row.eta||'';$('cuFiles').value='';$('cuRemoveImages').checked=false;$('cuExisting').textContent=`Изображений сохранено: ${(row.images||[]).length}`;$('cuFormTitle').textContent='Изменить предложение';$('cuSave').textContent='Сохранить изменения';$('cuCancel').style.display='inline-block';message('cuFormMsg','');$('cuName').focus();return}
    if(action==='installed'&&!confirm('Правка уже опубликована и проверена на сайте клиента? Эта кнопка только отмечает установку.'))return;
    if(action==='withdrawn'&&!confirm('Снять это предложение? Клиент больше не увидит его как новое.'))return;
    setBusy(true);try{await api('set_status',{id:row.id,status:action});await load()}catch(e){message('cuListMsg',e.message,true)}finally{setBusy(false)}
  });
  $('cuCancel').onclick=reset;$('cuFilter').onchange=draw;$('cuRefresh').onclick=load;
  $('cuTarget').onchange=()=>{rows=[];reset();draw();load()};
  button.onclick=()=>{if(!isAdmin)return;modal.classList.add('show');reset();load()};
  $('cuClose').onclick=()=>modal.classList.remove('show');
  modal.addEventListener('click',event=>{if(event.target===modal)modal.classList.remove('show')});
  document.addEventListener('keydown',event=>{if(event.key==='Escape'&&modal.classList.contains('show'))modal.classList.remove('show')});
  const sync=()=>{button.style.display=isAdmin?'inline-block':'none';if(!isAdmin){modal.classList.remove('show');rows=[];reset();draw();generation++}};
  const baseAuth=refreshAuth;refreshAuth=async function(){const result=await baseAuth.apply(this,arguments);sync();return result};
  sync();setInterval(()=>{if(isAdmin&&!busy&&modal.classList.contains('show')&&!document.hidden)load()},60000);
})();
