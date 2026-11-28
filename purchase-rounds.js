// Закупка у поставщика: отдельный каталог, частичные количества, список развозки.
(() => {
  let items=[], requests=[], draft={selected:{},manual:[],notes:''}, key='', busy=false, lastBatch=null, batchHistory=[], viewBranch=null;
  const sentAt=q=>{const d=q.created_at?new Date(q.created_at):null;return d&&Number.isFinite(d.getTime())?'Отправлена: '+d.toLocaleString('ru-RU',{timeZone:'Europe/Moscow',day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit'})+' МСК':'Дата отправки не сохранена';};
  const code=q=>q.supplier_code||q.code||'';
  const searchKey=value=>String(value??'').toLowerCase().replace(/ё/g,'е').replace(/(\d)\s*[xх×]\s*(?=\d)/g,'$1x').replace(/[^a-zа-я0-9]+/g,' ').trim();
  const archived=q=>q.status==='bought'&&Number.isFinite(Date.parse(q.closed_at))&&Date.now()-Date.parse(q.closed_at)>=14*24*60*60*1000;
  const remaining=q=>q.qty==null?null:Math.max(0,Number(q.qty)-Number(q.ordered_qty||0));
  const save=()=>localStorage.setItem(key,JSON.stringify(draft));
  const options=()=>stkPlaces().map(b=>`<option value="${b.id}">${esc(b.name)}</option>`).join('');
  const chosen=()=>Object.entries(draft.selected).map(([id,qty])=>({request_id:Number(id),qty:Number(qty)}));
  const rawLines=()=>[...chosen().map(x=>({...x,...draft.details?.[x.request_id]})),...draft.manual.map(m=>({...m,qty:Number(m.qty),branch_id:Number(m.branch_id)}))];
  const payload=()=>window.PurchaseReceiving?PurchaseReceiving.enrich(rawLines(),requests):rawLines();
  const preview=()=>payload().map(x=>{const q=x.request_id?requests.find(q=>Number(q.id)===x.request_id):x;return `${code(q)||x.code||'Без кода'} — ${x.qty} ${x.purchase_unit||'шт'} — ${q.branch_name||stkBranchName(q.branch_id)}\n${q.name}${x.purchase_receiving?'\n'+(x.unit_price==null?'Цена будет заполнена позже':'Цена за единицу: '+salesMoney(x.unit_price)+'; сумма: '+salesMoney(x.qty*x.unit_price)):''}`}).join('\n\n')+(draft.notes?'\n\nДополнительно: '+draft.notes:'');
  function bind(id,event,fn){if($(id))$(id)[event]=fn}
  function status(s){if($('prStatus'))$('prStatus').textContent=s}
  window.stkDrawBuy=async function(){
    const who=await db.auth.getUser();
    const next='polaroid_purchase_round_'+(who.data?.user?.id||'guest');
    if(next!==key){key=next;try{draft=JSON.parse(localStorage.getItem(key))||{selected:{},manual:[],notes:''}}catch{draft={selected:{},manual:[],notes:''}}}
    $('stockBody').innerHTML='<div class="status">Загрузка закупки…</div>';
    const loadingShift=stkActor().p_shift_id,loadingBranch=stkMyBranch(),loadingAdmin=isAdmin;
    const [a,b]=await Promise.all([db.from('purchase_catalog').select('*').order('id'),isAdmin?db.rpc('stock_purchase_live'):db.rpc('purchase_branch_view',{p_shift_id:stkActor().p_shift_id})]);
    if(loadingAdmin!==isAdmin||loadingShift!==stkActor().p_shift_id||loadingBranch!==stkMyBranch())return false;
    if(a.error||b.error){$('stockBody').textContent='Ошибка загрузки: '+(a.error||b.error).message;return false}
    viewBranch=b.data.branch_id||stkMyBranch();items=a.data||[];requests=(b.data.requests||[]).map(q=>({...q,material_id:q.material_id||items.find(i=>Number(i.id)===Number(q.supplier_item_id))?.material_id||null})).filter(q=>isAdmin||Number(q.branch_id)===Number(viewBranch));lastBatch=isAdmin?null:b.data.last_batch;batchHistory=isAdmin?[]:(b.data.batches||(lastBatch?[lastBatch]:[]));stk.buy=b.data;stkDrawBadge();
    if(!draft.submitted){for(const id of Object.keys(draft.selected))if(!requests.some(q=>Number(q.id)===Number(id)))delete draft.selected[id];save();}
    draw();return true;
  };
  // Лексическое имя основной страницы также меняем: обработчик вкладок использует его напрямую.
  stkDrawBuy=window.stkDrawBuy;
  function draw(){
    const locked=isAdmin&&!!draft.submitted;
    const pending=requests.filter(q=>q.status!=='bought').sort((a,b)=>Number(b.urgent)-Number(a.urgent));
    const bought=isAdmin?requests.filter(archived):[];
    const visible=isAdmin?[...pending,...requests.filter(q=>q.status==='bought'&&!archived(q))]:pending;
    $('stockBody').innerHTML=`<h3>Закупка</h3><div class="stk-sub">Выберите товар из каталога магазина или впишите своё название. Количество — в штуках или упаковках, как указано в названии.</div>
      ${stkCanWork()?`<div class="block"><label for="prSearch">Наименование товара</label><input id="prSearch" maxlength="250" autocomplete="off" placeholder="Например: 21х30 мат"><div class="stk-sub">Начните вводить название и выберите товар из списка. Если его нет — оставьте своё название в этой же строке.</div><div id="prCatalog" style="max-height:260px;overflow:auto"></div><div id="prPicked" class="status" aria-live="polite"></div><div class="row"><div class="field"><label>Количество (необязательно)</label><input id="prQty" type="number" min="0.001" step="0.001" placeholder="Решает администратор"></div><div class="field"><label>Филиал</label>${isAdmin?`<select id="prBranch">${options()}</select>`:`<div id="prAutoBranch" class="status">${esc(stkBranchName(stkMyBranch()))} · из открытой смены</div>`}</div><div class="field"><label>Срочность</label><select id="prUrgent"><option value="false">Обычная</option><option value="true">Срочно</option></select></div><div class="field"><label>Комментарий</label><input id="prComment" maxlength="500"></div></div><button id="prAdd" class="primary">Добавить заявку</button></div>`:'<div class="status">Откройте смену, чтобы добавить заявку.</div>'}
      ${isAdmin?`<details class="block"><summary>Изменить или добавить товары магазина</summary><div class="row"><input id="prItemCode" placeholder="Код"><input id="prItemName" placeholder="Наименование" maxlength="250"></div><input id="prItemId" type="hidden"><button id="prItemSave" class="secondary">Сохранить товар</button><button id="prItemReset">Новый товар</button><div id="prItemStatus" class="status"></div><div style="max-height:220px;overflow:auto">${items.map(i=>`<div style="margin:6px 0"><button data-edit-item="${i.id}" class="small">Изменить</button> ${esc(i.code)} — ${esc(i.name)}${i.active?'':' (скрыт)'}</div>`).join('')}</div><label><input id="prItemActive" type="checkbox" checked style="width:auto"> Доступен сотрудникам</label></details>`:''}
      ${!isAdmin?`<section id="prBranchHistory"><h4>Оформленные заявки · текущий месяц</h4><div class="actions">${batchHistory.map((b,i)=>`<button ${i===0?'id="prLastRequest"':''} data-request-batch="${i}" class="secondary" aria-expanded="false" aria-controls="prLastRequestBody">${i===0?'Последняя заявка · ':'Заявка на '}${esc(new Date(b.created_at).toLocaleDateString('ru-RU',{timeZone:'Europe/Moscow'}))}</button>`).join('')||'<span class="status">В этом месяце оформленных закупок вашего филиала ещё нет.</span>'}</div><div id="prLastRequestBody" class="block" hidden></div></section>`:''}<div id="prStatus" class="status" role="status"></div><section id="prCurrentRequests">${!isAdmin?`<h4>Текущая заявка филиала · ${pending.length} поз.</h4><p class="stk-sub">Здесь все ещё не закупленные позиции вашего филиала. После оформления закупки заказанные позиции переходят в историю ниже.</p>`:''}<div style="overflow:auto"><table class="customer-table stk-table"><thead><tr>${isAdmin?'<th>Заказать</th>':''}<th>Код / товар</th><th>Куда</th><th>Количество в заявке</th><th>Срочность</th><th>Действия</th></tr></thead><tbody>${visible.map(q=>`<tr style="${q.status==='bought'?'background:#f0fdf4':''}">${isAdmin?`<td><input type="checkbox" data-order="${q.id}" aria-label="Заказать ${esc(q.name)}" ${q.status==='bought'||draft.selected[q.id]?'checked':''} ${locked||q.status==='bought'?'disabled':''} style="width:20px;height:20px">${draft.selected[q.id]?`<div>${esc(draft.selected[q.id])} шт <button class="small" data-quantity="${q.id}" ${locked?'disabled':''}>Изменить</button></div>`:''}</td>`:''}<td><b>${esc(code(q)||'Без кода')}</b> — ${esc(q.name)}<div class="status">${esc(q.person_name||'')}${q.comment?' · '+esc(q.comment):''}</div><div class="stk-sub">${esc(sentAt(q))}</div></td><td>${esc(q.branch_name||stkBranchName(q.branch_id))}</td><td>${q.status==='bought'?'✅ Куплено':remaining(q)??'решает администратор'}${Number(q.ordered_qty)>0?`<div class="status">Заказано ранее: ${esc(q.ordered_qty)}</div>`:''}</td><td>${q.urgent?'🔴 Срочно':'Обычная'}</td><td><button class="danger small" data-delete-request="${q.id}" ${locked?'disabled':''}>Удалить</button></td></tr>`).join('')||`<tr><td colspan="${isAdmin?6:5}">${isAdmin?'Заявок в общем списке нет.':'У вашего филиала пока нет текущих заявок.'}</td></tr>`}</tbody></table></div></section>
      ${isAdmin?`<div class="block" style="margin-top:16px"><h3>Текущая закупка и развозка</h3><button id="prManualAdd" ${locked?'disabled':''}>＋ Дописать товар вручную</button><div id="prManual">${draft.manual.map((m,i)=>`<div class="row" data-manual="${i}" style="margin-top:10px"><input data-f="code" placeholder="Код" value="${esc(m.code)}" ${locked?'disabled':''}><input data-f="name" placeholder="Наименование" value="${esc(m.name)}" maxlength="250" ${locked?'disabled':''}><select data-f="branch_id" ${locked?'disabled':''}>${options()}</select><button data-remove="${i}" ${locked?'disabled':''}>Убрать</button></div>`).join('')}</div><h4>Приход по купленным позициям</h4><div id="prReceivingRows">${window.PurchaseReceiving?PurchaseReceiving.rowsHTML(payload(),requests):''}</div><label>Дополнительные записи к списку</label><textarea id="prNotes" maxlength="3000" ${locked?'disabled':''}>${esc(draft.notes)}</textarea><button id="prPreview" class="secondary">Проверить итоговый список</button><button id="prFinish" class="primary">${locked?'Повторить сохранение закупки':'Закупка окончена'}</button><div id="prPreviewText" style="white-space:pre-wrap;margin-top:10px"></div><div class="status">После завершения купленное количество поступит на склад филиала. Остаток выбранной заявки не переносится. Стоимость учитывается отдельно в «Закупке», а не в расходах кассы.</div></div><details><summary>Последние завершённые закупки</summary><div id="prHistory"></div></details>`:''}
      ${bought.length?`<details><summary>Купленные заявки старше 14 дней (${bought.length})</summary>${bought.map(q=>`<div style="padding:7px">✅ ${esc(code(q))} — ${esc(q.name)} — ${esc(q.branch_name||stkBranchName(q.branch_id))} — ${esc(q.ordered_qty||q.qty||'')} шт <span class="stk-sub"> · ${esc(sentAt(q))}</span> <button class="danger small" data-delete-request="${q.id}" ${locked?'disabled':''}>Удалить</button></div>`).join('')}</details>`:''}`;
    document.querySelectorAll('[data-delete-request]').forEach(el=>el.onclick=async()=>{
      if(busy||(isAdmin&&draft.submitted))return;
      const id=Number(el.dataset.deleteRequest),q=requests.find(q=>Number(q.id)===id);if(!q)return;
      const history=Number(q.ordered_qty)>0||q.status==='bought'?'\nРанее оформленные закупки останутся в истории.':'';
      if(!confirm('Удалить из общего списка закупки?\n'+q.name+' — '+(q.branch_name||stkBranchName(q.branch_id))+history+'\nОстатки склада не изменятся.'))return;
      el.disabled=true;status('Удаляю позицию…');
      try{
        const r=await db.rpc('stock_request_delete',{p_id:id,p_expected_status:q.status,p_expected_ordered_qty:Number(q.ordered_qty||0)});
        if(r.error)throw new Error(r.error.message);
        delete draft.selected[id];save();await stkDrawBuy();status(r.data?'Позиция удалена из закупки.':'Позиция уже удалена. Список обновлён.');
      }catch(e){el.disabled=false;status('Не удалось удалить: '+e.message);}
    });
    if(!isAdmin&&$('prSearch')){const form=$('prSearch').closest('.block');if(form){form.before($('prCurrentRequests'));form.before($('prBranchHistory'));}}
    document.querySelectorAll('[data-request-batch]').forEach(button=>button.onclick=()=>{
      lastBatch=batchHistory[Number(button.dataset.requestBatch)];
      const box=$('prLastRequestBody'),open=box.hidden||box.dataset.batch!==lastBatch.id;box.hidden=!open;box.dataset.batch=lastBatch.id;document.querySelectorAll('[data-request-batch]').forEach(b=>b.setAttribute('aria-expanded',String(open&&b===button)));
      if(!open)return;
      const requested=lastBatch.requested||[],ordered=lastBatch.ordered||[];
      box.innerHTML=`<h3>Заявка · ${esc(stkBranchName(viewBranch))}</h3><p>Закупка оформлена администратором: <b>${esc(new Date(lastBatch.created_at).toLocaleString('ru-RU',{timeZone:'Europe/Moscow'}))}</b></p><h4>Что запрашивал филиал</h4>${!lastBatch.snapshot_available?'<div class="status">Для этой старой закупки состав заявки не сохранялся. Ниже показано то, что было заказано для вашего филиала.</div>':requested.length?`<ul>${requested.map(q=>`<li><b>${esc(q.name)}</b> — ${q.qty==null?'количество определяет администратор':esc(q.qty)+' шт'}${q.comment?' · '+esc(q.comment):''}<div class="stk-sub">${esc(sentAt(q))}</div></li>`).join('')}</ul>`:'<div class="status">На момент оформления закупки заявок вашего филиала не было.</div>'}<h4>Что заказано для филиала</h4>${ordered.length?`<ul>${ordered.map(q=>`<li><b>${esc(q.name)}</b> — ${esc(q.qty)} ${esc(q.unit||'шт')}</li>`).join('')}</ul>`:'<div class="status">В этой закупке для вашего филиала ничего не заказано. Текущие незакупленные заявки остаются в списке.</div>'}`;
    });
    let picked=null,adding=false;
    const openedActor=stkActor(),openedBranch=stkMyBranch();
    const catalog=()=>{
      const words=searchKey($('prSearch').value).split(' ').filter(Boolean);
      const matches=items.filter(i=>i.active&&words.every(word=>searchKey(i.code+' '+i.name).includes(word)));
      $('prCatalog').innerHTML=matches.map(i=>`<button data-pick="${i.id}" class="secondary small" style="display:block;text-align:left;width:100%;margin:4px 0">${esc(i.name)}${isAdmin?` · ${esc(i.code)}`:''}</button>`).join('')||'<div class="status">Товара нет в каталоге. Название уже введено — нажмите «Добавить заявку».</div>';
      $('prCatalog').querySelectorAll('[data-pick]').forEach(el=>el.onclick=()=>{
        picked=items.find(i=>Number(i.id)===Number(el.dataset.pick));
        $('prSearch').value=picked.name;$('prPicked').textContent='Выбран товар из каталога: '+picked.name;
        catalog();
      });
    };
    if($('prSearch')){
      catalog();$('prSearch').oninput=()=>{picked=null;$('prPicked').textContent='';catalog()};
      if($('prBranch'))$('prBranch').value=String(stkMyBranch()||stkBranches()[0]?.id||'');
    }
    bind('prAdd','onclick',async()=>{
      if(adding)return;
      const name=$('prSearch').value.trim();
      if(!name){status('Введите наименование товара.');$('prSearch').focus();return}
      const actor=stkActor(),branch=isAdmin?Number($('prBranch').value):Number(stkMyBranch());
      if(!branch||(!isAdmin&&(!actor.p_shift_id||actor.p_shift_id!==openedActor.p_shift_id||branch!==Number(openedBranch)))){status('Смена изменилась или закрыта. Откройте закупку заново, чтобы выбрать правильный филиал.');return}
      const exact=items.filter(i=>i.active&&searchKey(i.name)===searchKey(name));
      const item=picked&&picked.name===name?picked:exact.length===1?exact[0]:null;
      const rawQty=$('prQty').value.trim(),qty=rawQty===''?null:Number(rawQty);
      if(qty!==null&&(!Number.isFinite(qty)||qty<=0)){status('Укажите количество больше нуля.');return}
      adding=true;$('prAdd').disabled=true;$('prAdd').textContent='Добавляю…';status('Сохраняю заявку…');
      try{
        const common={...actor,p_branch_id:branch,p_qty:qty,p_urgent:$('prUrgent').value==='true',p_comment:$('prComment').value||null};
        const r=item?await db.rpc('purchase_request_add',{...common,p_item_id:item.id}):await db.rpc('purchase_free_request_add',{...common,p_name:name,p_code:null});
        if(r.error)throw new Error(r.error.message);
        const text='✅ Заявка «'+(item?.name||name)+'» добавлена. Филиал: '+stkBranchName(branch)+'.';
        try{await stkDrawBuy();}catch{}
        const banner=document.createElement('div');banner.setAttribute('role','status');banner.id='prAdded';banner.style.cssText='padding:14px;margin:12px 0;border:1px solid #86b89a;border-radius:10px;background:#eaf8ee;color:#14532d;font-weight:600';banner.textContent=text;
        const anchor=$('prAdd');if(anchor)anchor.insertAdjacentElement('afterend',banner);else $('stockBody').prepend(banner);
        if(typeof v5Toast==='function')v5Toast(text);if(isAdmin)$('prSearch')?.focus();else $('prCurrentRequests')?.scrollIntoView?.({behavior:'smooth',block:'start'});
      }catch(e){status('Заявка не добавлена: '+e.message);if($('prAdd')){$('prAdd').disabled=false;$('prAdd').textContent='Добавить заявку';}}
      finally{adding=false;}
    });
    document.querySelectorAll('[data-edit-item]').forEach(el=>el.onclick=()=>{const i=items.find(i=>i.id===Number(el.dataset.editItem));$('prItemId').value=i.id;$('prItemCode').value=i.code;$('prItemName').value=i.name;$('prItemActive').checked=i.active});
    bind('prItemReset','onclick',()=>{$('prItemId').value='';$('prItemCode').value='';$('prItemName').value='';$('prItemActive').checked=true});
    bind('prItemSave','onclick',async()=>{const value={code:$('prItemCode').value.trim(),name:$('prItemName').value.trim(),active:$('prItemActive').checked};if(!value.code||!value.name){$('prItemStatus').textContent='Укажите код и название';return}const id=$('prItemId').value;const r=id?await db.from('purchase_catalog').update(value).eq('id',Number(id)):await db.from('purchase_catalog').insert(value);if(r.error){$('prItemStatus').textContent=r.error.message;return}await stkDrawBuy()});
    document.querySelectorAll('[data-order],[data-quantity]').forEach(el=>el.onclick=()=>{
      if(locked)return;const id=el.dataset.order||el.dataset.quantity,q=requests.find(q=>Number(q.id)===Number(id));if(!q||q.status==='bought')return;
      if(el.dataset.order&&!el.checked){delete draft.selected[id];save();draw();return}
      const raw=prompt('Сколько заказано для «'+(q.branch_name||stkBranchName(q.branch_id))+'»?',String(draft.selected[id]||remaining(q)||1));
      if(raw===null){draw();return}const n=Number(raw.replace(',','.'));if(!Number.isFinite(n)||!(n>0)){alert('Укажите положительное количество.');draw();return}draft.selected[id]=n;save();draw();
    });
    bind('prManualAdd','onclick',()=>{draft.manual.push({code:'',name:'',qty:1,branch_id:stkPlaces()[0]?.id||''});save();draw()});
    document.querySelectorAll('[data-manual]').forEach(row=>{const i=Number(row.dataset.manual);row.querySelector('[data-f="branch_id"]').value=String(draft.manual[i].branch_id);row.querySelectorAll('[data-f]').forEach(input=>{input.oninput=()=>{draft.manual[i][input.dataset.f]=input.value;save();if(input.dataset.f==='name'){const label=$('prReceivingRows')?.querySelectorAll('[data-receiving-row]')[chosen().length+i]?.querySelector('td b');if(label)label.textContent=input.value}};if(['name','branch_id'].includes(input.dataset.f))input.onchange=()=>draw();});});
    document.querySelectorAll('[data-remove]').forEach(el=>el.onclick=()=>{draft.manual.splice(Number(el.dataset.remove),1);save();draw()});
    bind('prNotes','oninput',()=>{draft.notes=$('prNotes').value;save()});
    bind('prPreview','onclick',()=>{$('prPreviewText').textContent=preview()||'Выберите заказанные товары'});
    bind('prFinish','onclick',finish);
    if(isAdmin&&window.PurchaseReceiving){PurchaseReceiving.bindRows($('prReceivingRows'),(i,field,value)=>{const line=payload()[i];if(!line)return;if(line.request_id){if(field==='qty')draft.selected[line.request_id]=value;else{draft.details=draft.details||{};draft.details[line.request_id]={...draft.details[line.request_id],[field]:value};if(field==='material_id'){const m=stkMaterials(true).find(m=>Number(m.id)===Number(value));draft.details[line.request_id].unit_price=m?.pack_price??null;}}}else{const index=i-chosen().length;draft.manual[index][field]=value;if(field==='material_id'){const m=stkMaterials(true).find(m=>Number(m.id)===Number(value));draft.manual[index].unit_price=m?.pack_price??null;}}save();if(field==='material_id')draw();});}
    if(isAdmin)loadHistory();
  }
  async function finish(){
    if(busy)return;
    if(!draft.submitted){const lines=payload();if(!lines.length){status('Выберите заказанные товары или добавьте ручную строку.');return}if(lines.some(x=>!Number.isFinite(x.qty)||x.qty<=0||(!x.request_id&&(!x.name?.trim()||!x.branch_id)))){status('Проверьте название, филиал и количество каждой строки.');return}if(lines.some(x=>x.unit_price!=null&&(!Number.isFinite(Number(x.unit_price))||Number(x.unit_price)<0))){status('Проверьте цены закупки.');return}if(!confirm('Завершить закупку, провести приход по филиалам и отправить список в Telegram?\n\n'+preview()))return;draft.submitted={p_id:crypto.randomUUID(),p_lines:lines,p_notes:draft.notes};save()}
    busy=true;draw();$('prFinish').disabled=true;status('Сохраняю закупку…');
    try{const r=await db.rpc('purchase_finish',draft.submitted);if(r.error){if(r.error.code){delete draft.submitted;save()}throw new Error(r.error.message)}const id=r.data.id,received=r.data.received;draft={selected:{},manual:[],notes:''};save();await stkDrawBuy();status(received===false?'Эта закупка сохранена ранее. Повторный приход не создавался.':'Закупка сохранена. Товары поступили на склад. Проверяю доставку в Telegram…');setTimeout(()=>checkDelivery(id),2000)}catch(e){draw();status('Не удалось подтвердить завершение: '+e.message+'. Повторите сохранение: дубли не создадутся.');$('prFinish').disabled=false}finally{busy=false}
  }
  async function checkDelivery(id){const r=await db.rpc('purchase_delivery_status',{p_id:id});if(r.error){status('Закупка сохранена. Статус Telegram пока недоступен.');return}const d=r.data;status(d.failed?'Закупка сохранена, но есть ошибка доставки Telegram. Список доступен в истории для копирования.':d.total>0&&d.sent===d.total?'Закупка окончена. Список отправлен в Telegram.':'Закупка сохранена. Сообщение ожидает отправки в Telegram.');}
  async function loadHistory(){const r=window.PurchaseReceiving?await db.rpc('purchase_receiving_history'):await db.from('purchase_batches').select('id,created_at,message').order('created_at',{ascending:false}).limit(10);if(!$('prHistory'))return;if(r.error){$('prHistory').textContent='Не удалось загрузить историю: '+r.error.message;return}$('prHistory').innerHTML=(r.data||[]).map(b=>`<details class="block"><summary>${esc(new Date(b.created_at).toLocaleString('ru-RU'))}</summary>${window.PurchaseReceiving?PurchaseReceiving.historyRows(b):''}<pre style="white-space:pre-wrap">${esc(b.message)}</pre><button data-copy-batch="${b.id}">Копировать</button><button data-check-batch="${b.id}">Проверить Telegram</button></details>`).join('')||'История пока пуста';$('prHistory').querySelectorAll('[data-copy-batch]').forEach(el=>el.onclick=async()=>{const b=r.data.find(b=>b.id===el.dataset.copyBatch);await navigator.clipboard.writeText(b.message);status('Список скопирован')});$('prHistory').querySelectorAll('[data-check-batch]').forEach(el=>el.onclick=()=>checkDelivery(el.dataset.checkBatch));if(window.PurchaseReceiving)PurchaseReceiving.bindHistory($('prHistory'),loadHistory);}
})();

