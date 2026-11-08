// Закупка у поставщика: отдельный каталог, частичные количества, список развозки.
(() => {
  let items=[], requests=[], draft={selected:{},manual:[],notes:''}, key='', busy=false;
  const code=q=>q.supplier_code||q.code||'';
  const remaining=q=>q.qty==null?null:Math.max(0,Number(q.qty)-Number(q.ordered_qty||0));
  const save=()=>localStorage.setItem(key,JSON.stringify(draft));
  const options=()=>stkPlaces().map(b=>`<option value="${b.id}">${esc(b.name)}</option>`).join('');
  const chosen=()=>Object.entries(draft.selected).map(([id,qty])=>({request_id:Number(id),qty:Number(qty)}));
  const payload=()=>[...chosen(),...draft.manual.map(m=>({...m,qty:Number(m.qty),branch_id:Number(m.branch_id)}))];
  const preview=()=>payload().map(x=>{const q=x.request_id?requests.find(q=>Number(q.id)===x.request_id):x;return `${code(q)||x.code||'Без кода'} — ${x.qty} шт — ${q.branch_name||stkBranchName(q.branch_id)}\n${q.name}`}).join('\n\n')+(draft.notes?'\n\nДополнительно: '+draft.notes:'');
  function bind(id,event,fn){if($(id))$(id)[event]=fn}
  function status(s){if($('prStatus'))$('prStatus').textContent=s}
  window.stkDrawBuy=async function(){
    const who=await db.auth.getUser();
    const next='polaroid_purchase_round_'+(who.data?.user?.id||'guest');
    if(next!==key){key=next;try{draft=JSON.parse(localStorage.getItem(key))||{selected:{},manual:[],notes:''}}catch{draft={selected:{},manual:[],notes:''}}}
    $('stockBody').innerHTML='<div class="status">Загрузка закупки…</div>';
    const [a,b]=await Promise.all([db.from('purchase_catalog').select('*').order('id'),db.rpc('stock_purchase_live')]);
    if(a.error||b.error){$('stockBody').textContent='Ошибка загрузки: '+(a.error||b.error).message;return}
    items=a.data||[];requests=b.data.requests||[];stk.buy=b.data;stkDrawBadge();
    draw();
  };
  // Лексическое имя основной страницы также меняем: обработчик вкладок использует его напрямую.
  stkDrawBuy=window.stkDrawBuy;
  function draw(){
    const locked=!!draft.submitted;
    const pending=requests.filter(q=>q.status!=='bought').sort((a,b)=>Number(b.urgent)-Number(a.urgent));
    const bought=requests.filter(q=>q.status==='bought');
    $('stockBody').innerHTML=`<h3>Закупка</h3><div class="stk-sub">Выберите товар из каталога магазина. Количество — в штуках или упаковках, как указано в названии.</div>
      ${stkCanWork()?`<div class="block"><label for="prSearch">Найти по коду или названию</label><input id="prSearch" placeholder="Код или название"><div id="prCatalog" style="max-height:260px;overflow:auto"></div><div id="prPicked" class="status"></div><div class="row"><div class="field"><label>Количество *</label><input id="prQty" type="number" min="0.001" step="0.001" value="1"></div><div class="field"><label>Филиал</label><select id="prBranch">${options()}</select></div><div class="field"><label>Срочность</label><select id="prUrgent"><option value="false">Обычная</option><option value="true">Срочно</option></select></div><div class="field"><label>Комментарий</label><input id="prComment" maxlength="500"></div></div><button id="prAdd" class="primary">Добавить заявку</button></div>`:'<div class="status">Откройте смену, чтобы добавить заявку.</div>'}
      ${isAdmin?`<details class="block"><summary>Изменить или добавить товары магазина</summary><div class="row"><input id="prItemCode" placeholder="Код"><input id="prItemName" placeholder="Наименование" maxlength="250"></div><input id="prItemId" type="hidden"><button id="prItemSave" class="secondary">Сохранить товар</button><button id="prItemReset">Новый товар</button><div id="prItemStatus" class="status"></div><div style="max-height:220px;overflow:auto">${items.map(i=>`<div style="margin:6px 0"><button data-edit-item="${i.id}" class="small">Изменить</button> ${esc(i.code)} — ${esc(i.name)}${i.active?'':' (скрыт)'}</div>`).join('')}</div><label><input id="prItemActive" type="checkbox" checked style="width:auto"> Доступен сотрудникам</label></details>`:''}
      <div id="prStatus" class="status" role="status"></div><div style="overflow:auto"><table class="customer-table stk-table"><thead><tr>${isAdmin?'<th>Заказать</th>':''}<th>Код / товар</th><th>Куда</th><th>Нужно ещё</th><th>Срочность</th></tr></thead><tbody>${pending.map(q=>`<tr>${isAdmin?`<td><input type="checkbox" data-order="${q.id}" aria-label="Заказать ${esc(q.name)}" ${draft.selected[q.id]?'checked':''} ${locked?'disabled':''} style="width:20px;height:20px">${draft.selected[q.id]?`<div>${esc(draft.selected[q.id])} шт <button class="small" data-quantity="${q.id}" ${locked?'disabled':''}>Изменить</button></div>`:''}</td>`:''}<td><b>${esc(code(q)||'Без кода')}</b> — ${esc(q.name)}<div class="status">${esc(q.person_name||'')}${q.comment?' · '+esc(q.comment):''}</div></td><td>${esc(q.branch_name||stkBranchName(q.branch_id))}</td><td>${remaining(q)??'не указано'}${Number(q.ordered_qty)>0?`<div class="status">Заказано ранее: ${esc(q.ordered_qty)}</div>`:''}</td><td>${q.urgent?'🔴 Срочно':'Обычная'}</td></tr>`).join('')||'<tr><td colspan="5">Непокупленных заявок нет.</td></tr>'}</tbody></table></div>
      ${isAdmin?`<div class="block" style="margin-top:16px"><h3>Текущая закупка и развозка</h3><button id="prManualAdd" ${locked?'disabled':''}>＋ Дописать товар вручную</button><div id="prManual">${draft.manual.map((m,i)=>`<div class="row" data-manual="${i}" style="margin-top:10px"><input data-f="code" placeholder="Код" value="${esc(m.code)}" ${locked?'disabled':''}><input data-f="name" placeholder="Наименование" value="${esc(m.name)}" maxlength="250" ${locked?'disabled':''}><input data-f="qty" type="number" min="0.001" step="0.001" value="${esc(m.qty)}" ${locked?'disabled':''}><select data-f="branch_id" ${locked?'disabled':''}>${options()}</select><button data-remove="${i}" ${locked?'disabled':''}>Убрать</button></div>`).join('')}</div><label>Дополнительные записи к списку</label><textarea id="prNotes" maxlength="3000" ${locked?'disabled':''}>${esc(draft.notes)}</textarea><button id="prPreview" class="secondary">Проверить итоговый список</button><button id="prFinish" class="primary">${locked?'Повторить сохранение закупки':'Закупка окончена'}</button><div id="prPreviewText" style="white-space:pre-wrap;margin-top:10px"></div><div class="status">Укажите фактически заказанное количество. Неполностью закупленные заявки останутся сверху. Остатки склада оформляются отдельно.</div></div><details><summary>Последние завершённые закупки</summary><div id="prHistory"></div></details>`:''}
      ${bought.length?`<details><summary>Купленные заявки (${bought.length})</summary>${bought.map(q=>`<div style="padding:7px">✅ ${esc(code(q))} — ${esc(q.name)} — ${esc(q.branch_name||stkBranchName(q.branch_id))} — ${esc(q.ordered_qty||q.qty||'')} шт</div>`).join('')}</details>`:''}`;
    let picked=null;
    const catalog=()=>{
      const q=$('prSearch').value.toLowerCase().trim();
      $('prCatalog').innerHTML=items.filter(i=>i.active&&(!q||(i.code+' '+i.name).toLowerCase().includes(q))).map(i=>`<button data-pick="${i.id}" class="secondary small" style="display:block;text-align:left;width:100%;margin:4px 0">${esc(i.code)} — ${esc(i.name)}</button>`).join('')||'Товар не найден';
      $('prCatalog').querySelectorAll('[data-pick]').forEach(el=>el.onclick=()=>{picked=items.find(i=>i.id===Number(el.dataset.pick));$('prPicked').textContent='Выбрано: '+picked.code+' — '+picked.name});
    };
    if($('prSearch')){catalog();$('prSearch').oninput=()=>{picked=null;$('prPicked').textContent='';catalog()};$('prBranch').value=String(stkMyBranch()||stkBranches()[0]?.id||'')}
    bind('prAdd','onclick',async()=>{
      if(!picked){status('Выберите товар из списка.');return}
      const qty=Number($('prQty').value);if(!(qty>0)){status('Укажите количество больше нуля.');return}
      $('prAdd').disabled=true;
      const r=await db.rpc('purchase_request_add',{...stkActor(),p_branch_id:Number($('prBranch').value),p_item_id:picked.id,p_qty:qty,p_urgent:$('prUrgent').value==='true',p_comment:$('prComment').value||null});
      if(r.error){$('prAdd').disabled=false;status(r.error.message);return}await stkDrawBuy();
    });
    document.querySelectorAll('[data-edit-item]').forEach(el=>el.onclick=()=>{const i=items.find(i=>i.id===Number(el.dataset.editItem));$('prItemId').value=i.id;$('prItemCode').value=i.code;$('prItemName').value=i.name;$('prItemActive').checked=i.active});
    bind('prItemReset','onclick',()=>{$('prItemId').value='';$('prItemCode').value='';$('prItemName').value='';$('prItemActive').checked=true});
    bind('prItemSave','onclick',async()=>{const value={code:$('prItemCode').value.trim(),name:$('prItemName').value.trim(),active:$('prItemActive').checked};if(!value.code||!value.name){$('prItemStatus').textContent='Укажите код и название';return}const id=$('prItemId').value;const r=id?await db.from('purchase_catalog').update(value).eq('id',Number(id)):await db.from('purchase_catalog').insert(value);if(r.error){$('prItemStatus').textContent=r.error.message;return}await stkDrawBuy()});
    document.querySelectorAll('[data-order],[data-quantity]').forEach(el=>el.onclick=()=>{
      if(locked)return;const id=el.dataset.order||el.dataset.quantity,q=requests.find(q=>Number(q.id)===Number(id));
      if(el.dataset.order&&!el.checked){delete draft.selected[id];save();draw();return}
      const raw=prompt('Сколько заказано для «'+(q.branch_name||stkBranchName(q.branch_id))+'»?',String(draft.selected[id]||remaining(q)||1));
      if(raw===null){draw();return}const n=Number(raw.replace(',','.'));if(!(n>0)||remaining(q)!==null&&n>remaining(q)){alert('Укажите положительное количество не больше остатка заявки. Для дополнительного количества добавьте ручную строку.');draw();return}draft.selected[id]=n;save();draw();
    });
    bind('prManualAdd','onclick',()=>{draft.manual.push({code:'',name:'',qty:1,branch_id:stkPlaces()[0]?.id||''});save();draw()});
    document.querySelectorAll('[data-manual]').forEach(row=>{const i=Number(row.dataset.manual);row.querySelector('[data-f="branch_id"]').value=String(draft.manual[i].branch_id);row.querySelectorAll('[data-f]').forEach(input=>input.oninput=()=>{draft.manual[i][input.dataset.f]=input.value;save()})});
    document.querySelectorAll('[data-remove]').forEach(el=>el.onclick=()=>{draft.manual.splice(Number(el.dataset.remove),1);save();draw()});
    bind('prNotes','oninput',()=>{draft.notes=$('prNotes').value;save()});
    bind('prPreview','onclick',()=>{$('prPreviewText').textContent=preview()||'Выберите заказанные товары'});
    bind('prFinish','onclick',finish);
    if(isAdmin)loadHistory();
  }
  async function finish(){
    if(busy)return;
    if(!draft.submitted){const lines=payload();if(!lines.length){status('Выберите заказанные товары или добавьте ручную строку.');return}if(lines.some(x=>!Number.isFinite(x.qty)||x.qty<=0||(!x.request_id&&(!x.name?.trim()||!x.branch_id)))){status('Проверьте название, филиал и количество каждой строки.');return}if(!confirm('Завершить закупку и отправить в Telegram?\n\n'+preview()))return;draft.submitted={p_id:crypto.randomUUID(),p_lines:lines,p_notes:draft.notes};save()}
    busy=true;draw();$('prFinish').disabled=true;status('Сохраняю закупку…');
    try{const r=await db.rpc('purchase_finish',draft.submitted);if(r.error){if(r.error.code){delete draft.submitted;save()}throw new Error(r.error.message)}const id=r.data.id;draft={selected:{},manual:[],notes:''};save();await stkDrawBuy();status('Закупка сохранена. Проверяю доставку в Telegram…');setTimeout(()=>checkDelivery(id),2000)}catch(e){draw();status('Не удалось подтвердить завершение: '+e.message+'. Повторите сохранение: дубли не создадутся.');$('prFinish').disabled=false}finally{busy=false}
  }
  async function checkDelivery(id){const r=await db.rpc('purchase_delivery_status',{p_id:id});if(r.error){status('Закупка сохранена. Статус Telegram пока недоступен.');return}const d=r.data;status(d.failed?'Закупка сохранена, но есть ошибка доставки Telegram. Список доступен в истории для копирования.':d.total>0&&d.sent===d.total?'Закупка окончена. Список отправлен в Telegram.':'Закупка сохранена. Сообщение ожидает отправки в Telegram.');}
  async function loadHistory(){const r=await db.from('purchase_batches').select('id,created_at,message').order('created_at',{ascending:false}).limit(10);if(!$('prHistory'))return;$('prHistory').innerHTML=(r.data||[]).map(b=>`<details class="block"><summary>${esc(new Date(b.created_at).toLocaleString('ru-RU'))}</summary><pre style="white-space:pre-wrap">${esc(b.message)}</pre><button data-copy-batch="${b.id}">Копировать</button><button data-check-batch="${b.id}">Проверить Telegram</button></details>`).join('')||'История пока пуста';$('prHistory').querySelectorAll('[data-copy-batch]').forEach(el=>el.onclick=async()=>{const b=r.data.find(b=>b.id===el.dataset.copyBatch);await navigator.clipboard.writeText(b.message);status('Список скопирован')});$('prHistory').querySelectorAll('[data-check-batch]').forEach(el=>el.onclick=()=>checkDelivery(el.dataset.checkBatch));}
})();
