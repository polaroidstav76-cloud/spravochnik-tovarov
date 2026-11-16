(()=>{
 'use strict';
 const H=CloudshopWorkflow,$=id=>document.getElementById(id);
 const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const rpc=async(name,args)=>{const r=await db.rpc(name,args);if(r.error)throw r.error;return r.data;};
 let minimized=false,owner=null,shift=null;
 const draft=()=>typeof saleDraft!=='undefined'&&saleDraft.length>0;
 const identity=()=>typeof staffAccount!=='undefined'?staffAccount?.user_id:null;
 const sameShift=()=>!saleContext?.shiftId||saleContext.shiftId===salesSession?.shiftId;
 const baseClose=close,baseOpen=open,baseSale=openSaleV4;
 const resume=document.createElement('button');resume.type='button';resume.id='resumeSaleDraft';resume.className='wf-resume';resume.textContent='Вернуться к продаже';resume.hidden=true;document.body.append(resume);
 function clearDraft(){owner=null;shift=null;saleDraft=[];saleLoyaltyCustomerId=null;saleLoyaltyCustomer=null;salePickup=null;minimized=false;resume.hidden=true;}
 function restore(){
  if((owner&&owner!==identity())||(shift&&shift!==salesSession?.shiftId)){alert('Черновик относится к другой смене или пользователю. Вернитесь в прежнюю смену либо закройте черновик с удалением.');return false;}
  minimized=false;resume.hidden=true;discard.hidden=true;baseOpen('saleModal');return true;
 }
 resume.onclick=restore;
 const discard=document.createElement('button');discard.type='button';discard.className='secondary small';discard.textContent='Удалить свёрнутый черновик';discard.hidden=true;discard.id='discardSaleDraft';resume.insertAdjacentElement('afterend',discard);discard.style.cssText='position:fixed;left:20px;bottom:78px;z-index:99980';
 discard.onclick=()=>{if(confirm('Удалить свёрнутую продажу? Все товары и введённые данные будут потеряны.')){clearDraft();discard.hidden=true;}};
 const minimize=document.createElement('button');minimize.id='minimizeSale';minimize.type='button';minimize.className='secondary';minimize.textContent='Свернуть';$('closeSale').insertAdjacentElement('beforebegin',minimize);
 minimize.onclick=()=>{
  if($('saveSale').disabled){alert('Дождитесь завершения оформления продажи.');return;}
  owner=identity();shift=saleContext?.shiftId||salesSession?.shiftId;minimized=true;baseClose('saleModal');resume.textContent='Продажа · '+(saleDraft?.length||0)+' поз. — развернуть';resume.hidden=false;discard.hidden=!draft();
 };
 close=function(id){
  if(id==='saleModal'){
   if($('saveSale').disabled&&draft()){alert('Продажа оформляется. Дождитесь результата.');return false;}
   if(draft()&&!confirm('Вы точно хотите закрыть окно продажи? Все товары и введённые данные будут удалены.'))return false;
   clearDraft();discard.hidden=true;
  }
  baseClose(id);return true;
 };
 $('closeSale').onclick=()=>close('saleModal');
 openSaleV4=async function(){
  if(minimized){const restored=restore();if(restored)discard.hidden=true;return;}
  if($('saleModal').classList.contains('show')&&draft()){baseOpen('saleModal');return;}
  const result=await baseSale.apply(this,arguments);owner=identity();shift=saleContext?.shiftId||salesSession?.shiftId;return result;
 };
 $('salesBtn').onclick=()=>openSaleV4();
 const basePickup=startPickupPayment;
 window.startPickupPayment=async function(id){
  if(draft()&&(minimized||$('saleModal').classList.contains('show'))){
   if(Number(salePickup?.id)===Number(id)){restore();discard.hidden=true;return;}
   if(!confirm('Текущая продажа будет заменена заказом при получении. Все введённые данные текущего черновика будут удалены. Продолжить?'))return;
   clearDraft();discard.hidden=true;baseClose('saleModal');
  }
  return basePickup.apply(this,arguments);
 };
 window.addEventListener('beforeunload',event=>{if(draft()){event.preventDefault();event.returnValue='';}});

 const baseTotal=window.updateSaleTotal;
 function limit(){const gross=saleGrossTotal(),discount=Math.min(100,Math.max(0,Number($('saleDiscountPercent')?.value)||0));const after=H.money(gross-H.money(gross*discount/100));return H.pointLimit(after,saleLoyaltyCustomer?.balance||0);}
 window.updateSaleTotal=function(){baseTotal.apply(this,arguments);const max=limit();$('salePointsMax').value=salesMoney(max);$('salePointsToUse').max=String(max);$('salePointsMax').closest('.field')?.querySelector('label')?.replaceChildren(document.createTextNode('Можно списать у клиента'));};
 const baseSave=$('saveSale').onclick;
 $('saveSale').onclick=async function(event){
  if(!sameShift()){alert('Смена изменилась. Нельзя оформить черновик в другой смене.');return;}
  if(salePointsUsed()<0||salePointsUsed()>limit()){$('saleStatus').textContent='У этого клиента можно списать максимум '+salesMoney(limit())+' с учётом баланса и суммы заказа.';return;}
  if($('saleClubEnabled').checked&&!saleLoyaltyCustomerId&&validClubPhone($('saleClubNewPhone').value)){
   const full=clubPhoneValue($('saleClubNewPhone').value),snapshot=full;
   try{const matches=await rpc('loyalty_find_customers',{p_query:full});
    if(snapshot!==clubPhoneValue($('saleClubNewPhone').value))return;
    if(matches?.length){showSaleClubMatches(matches);$('saleClubStatus').textContent='Карта с этим номером уже существует. Проверьте выбранного клиента и нажмите оформление ещё раз.';return;}
   }catch(e){$('saleStatus').textContent='Не удалось проверить номер карты: '+e.message;return;}
  }
  const result=await baseSave.call(this,event);if(!draft()){minimized=false;resume.hidden=true;discard.hidden=true;}return result;
 };

 let lookupTimer=null;
 $('saleClubQuery').addEventListener('input',()=>{
  saleClubLookupSerial++;saleLoyaltyCustomerId=null;saleLoyaltyCustomer=null;saleClubNeedsSelection=true;
  $('saleLoyaltyBalance').textContent='';$('saleUsePoints').checked=false;$('salePointsToUse').value='0';updateSaleTotal();
  $('saleClubResults').textContent='';clearTimeout(lookupTimer);
  const digits=$('saleClubQuery').value.replace(/\D/g,'');
  if(digits.length===4||validClubPhone(digits))lookupTimer=setTimeout(()=>$('saleClubSearchBtn').click(),300);
 });
 $('clubLookup').addEventListener('input',()=>{window.__clubLookupEpoch=(window.__clubLookupEpoch||0)+1;});
 const customerPanel=$('customerAdminRows');
 if(customerPanel){
  const stats=document.createElement('section');stats.className='wf-stats';stats.id='cardCreationStats';
  const today=H.moscowDay(Date.now()),first=today.slice(0,8)+'01';
  stats.innerHTML=`<h3>Кто создаёт клубные карты</h3><div class="row"><div class="field"><label>С даты</label><input id="wfCardsFrom" type="date" value="${first}"></div><div class="field"><label>По дату</label><input id="wfCardsTo" type="date" value="${today}"></div></div><button id="wfCardsLoad" type="button" class="secondary">Показать сводку</button><div id="wfCardsResult" role="status"></div>`;customerPanel.insertAdjacentElement('beforebegin',stats);
  let statsEpoch=0,statsStarted=false;
  $('wfCardsLoad').onclick=async()=>{
   const epoch=++statsEpoch;$('wfCardsResult').textContent='Считаю…';
   try{const data=await rpc('workflow_card_stats',{p_from:$('wfCardsFrom').value,p_to:$('wfCardsTo').value});if(epoch!==statsEpoch)return;
    const leaders=(data.rows||[]).filter(r=>r.key!=='unknown'&&r.current_count>0);const best=leaders[0]?.current_count||0;
    const top=leaders.filter(r=>r.current_count===best).map(r=>r.name).join(', ');const delta=Number(data.total)-Number(data.previous_total);
    $('wfCardsResult').innerHTML=`<div class="wf-summary">За ${escape(data.from)} — ${escape(data.to)}: ${Number(data.total)} карт. За предыдущий такой же период: ${Number(data.previous_total)} (${delta>=0?'+':''}${delta}).</div><p>${best?'Больше всего карт: '+escape(top)+' — '+best+'.':'За период нет карт с установленным автором.'} ${Number(data.unknown)>0?'Автор не указан у '+Number(data.unknown)+' карт.':''}</p><table class="customer-table"><thead><tr><th>Сотрудник</th><th>Создано</th><th>Предыдущий период</th><th>Разница</th></tr></thead><tbody>${(data.rows||[]).map(r=>`<tr><td>${escape(r.name)}</td><td>${Number(r.current_count)}</td><td>${Number(r.previous_count)}</td><td>${Number(r.current_count)-Number(r.previous_count)}</td></tr>`).join('')}</tbody></table><p class="wf-small">Считается дата создания карты, а не последней покупки. Старые случаи без достоверного автора показаны отдельно.</p>`;
   }catch(e){$('wfCardsResult').textContent='Ошибка: '+e.message;}
  };
  const oldLoad=loadCustomerAdminRows;loadCustomerAdminRows=async function(){const result=await oldLoad.apply(this,arguments);if(isAdmin&&!statsStarted){statsStarted=true;$('wfCardsLoad').click();}return result;};
 }

 // A saved receipt is already committed before this status request; display any accounting exception explicitly.
 const oldStockSave=stkSaveOp;
 stkSaveOp=async function(){const receipt=stk.opKind==='receipt',shiftId=salesSession?.shiftId;const result=await oldStockSave.apply(this,arguments);
  if(result===true&&receipt&&shiftId)try{const status=await rpc('workflow_shift_expenses',{p_shift_id:shiftId});v5Toast(status.error?'Приход сохранён; расходы требуют проверки: '+status.error:'Расходы по приходам за смену: '+salesMoney(status.receipt_total)+'. Комментарий добавлен в отчёт.');}catch{v5Toast('Проверьте сумму расходов в отчёте: статус синхронизации не получен.');}return result;};

 const expenseButton=document.createElement('button');expenseButton.type='button';expenseButton.id='expenseHistoryBtn';expenseButton.className='secondary';expenseButton.textContent='Расходы по приходам';expenseButton.hidden=true;$('reportsBtn').insertAdjacentElement('afterend',expenseButton);
 document.body.insertAdjacentHTML('beforeend',`<div class="modal" id="workflowExpensesModal"><div class="dialog" style="max-width:1000px"><h2>История расходов по приходам</h2><p>Суммы закупок и их отражение в отчётах. Старые расходы сверяются отдельно, чтобы не учесть одну покупку дважды.</p><div class="row"><div class="field"><label>С даты</label><input id="wfExpenseFrom" type="date" value="${H.moscowDay(Date.now()).slice(0,8)+'01'}"></div><div class="field"><label>По дату</label><input id="wfExpenseTo" type="date" value="${H.moscowDay(Date.now())}"></div></div><div class="actions"><button id="wfExpenseLoad" class="primary">Показать расходы</button><button id="wfExpenseClose" class="secondary">Закрыть</button></div><div id="wfExpenseResult" role="status"></div></div></div>`);
 let expenses=[];
 function expenseHTML(rows){return rows.map((r,index)=>`<details class="wf-expense-day"><summary>${escape(r.day)} · ${escape(r.branch)} · приходы ${salesMoney(r.receipt_total)}</summary><p>В отчёте: ${r.report_available?salesMoney(r.report_total):'нет доступной строки'}. Автоматически учтено: ${salesMoney(r.synced_total)}.</p>${r.error?`<div class="wf-warning">${escape(r.error)}</div>`:''}${r.missing_amount?`<div class="wf-warning">Без суммы: ${Number(r.missing_amount)}. Историческую стоимость нужно уточнить.</div>`:''}<table class="customer-table"><thead><tr><th>Что купили</th><th>Сумма</th><th>Кто внёс</th><th>Куда поступило</th><th>Комментарий</th></tr></thead><tbody>${(r.items||[]).map(i=>`<tr><td>${escape(i.name)}</td><td>${i.amount==null?'Не указана':salesMoney(i.amount)}</td><td>${escape(i.person_name||'Не указан')}</td><td>${escape(i.stock_branch)}</td><td>${escape(i.detail)}</td></tr>`).join('')}</tbody></table>${r.complete_sync?'<p>Все приходы этой даты синхронизированы.</p>':r.report_available?`<div class="wf-choices"><button class="secondary" data-expense-index="${index}" data-expense-choice="already_included" ${Number(r.report_total)<Number(r.receipt_total)?'disabled':''}>Эти приходы уже входят в сумму отчёта</button><button class="primary" data-expense-index="${index}" data-expense-choice="add_receipts">Добавить неучтённые приходы к отчёту</button></div><p class="wf-small">Первый вариант сохраняет текущую сумму; второй прибавляет только ещё не синхронизированные приходы. Ручные расходы и комментарии сохраняются. ${r.formula?'В ячейке формула: после подтверждения будет сохранена проверенная числовая сумма.':''}</p>`:'<p class="wf-small">Приход сохранён в истории. Для записи в отчёт нужна строка нужного филиала и даты. Приходы мастерской без смены нельзя автоматически приписывать кассе другого филиала.</p>'}</details>`).join('');}
 $('wfExpenseLoad').onclick=async()=>{try{
  expenses=await rpc('workflow_expense_history',{p_from:$('wfExpenseFrom').value,p_to:$('wfExpenseTo').value});
  $('wfExpenseResult').innerHTML=`<div class="wf-summary">Известная сумма приходов: ${salesMoney(expenses.reduce((n,r)=>n+Number(r.receipt_total),0))}</div>`+(expenses.length?expenseHTML(expenses):'<p>За выбранный период приходов нет.</p>');
  for(const b of $('wfExpenseResult').querySelectorAll('[data-expense-index]'))b.onclick=async()=>{
   const r=expenses[Number(b.dataset.expenseIndex)],choice=b.dataset.expenseChoice;
   const next=choice==='already_included'?Number(r.report_total):Number(r.report_total)+Number(r.receipt_total)-Number(r.synced_total);
   if(!confirm(`${r.branch}, ${r.day}: расходы в отчёте ${salesMoney(r.report_total)} → ${salesMoney(next)}. Подтвердить сверку?`))return;
   b.disabled=true;try{await rpc('workflow_reconcile_expenses',{p_branch:r.branch_id,p_day:r.day,p_choice:choice,p_expected_total:r.report_total,p_expected_receipts:r.receipt_total});await $('wfExpenseLoad').onclick();}catch(e){alert(e.message);b.disabled=false;}
  };
 }catch(e){$('wfExpenseResult').textContent='Ошибка: '+e.message;}};
 expenseButton.onclick=()=>{baseOpen('workflowExpensesModal');$('wfExpenseLoad').click();};$('wfExpenseClose').onclick=()=>baseClose('workflowExpensesModal');

 ckDue=row=>H.deadline(row);
 const banner=document.createElement('aside');banner.id='workflowDeadlineBanner';banner.className='wf-deadline';banner.hidden=true;banner.setAttribute('role','alert');document.body.append(banner);
 const warned=new Set();let deadlineBusy=false;
 async function deadlines(){
  expenseButton.hidden=!isAdmin;
  if(deadlineBusy||document.hidden||!salesSession?.shiftId||!staffAccount){if(!salesSession?.shiftId)banner.hidden=true;return;}
  deadlineBusy=true;const branch=Number(salesSession.branchId),user=identity();
  try{const r=await db.from('branch_checks').select('id,branch_id,product,order_no,deadline,created_at,check_date,readiness').eq('branch_id',branch).neq('readiness','Готово').order('created_at');if(r.error)return;if(branch!==Number(salesSession?.branchId)||user!==identity())return;
   const now=Date.now(),due=(r.data||[]).map(row=>({row,date:H.deadline(row)})).filter(x=>x.date&&now>=x.date.warn);
   const fresh=due.filter(x=>{x.key=user+':'+x.row.id+':'+x.date.end+':'+(now>=x.date.end?'late':'soon');try{return !warned.has(x.key)&&localStorage.getItem('deadline:'+x.key)!=='1';}catch{return !warned.has(x.key);}});
   if(!fresh.length){banner.hidden=true;return;}
   banner.classList.toggle('late',fresh.some(x=>now>=x.date.end));banner.innerHTML=`<b>${fresh.some(x=>now>=x.date.end)?'Есть просроченные заказы':'До срока заказа осталось не больше часа'}</b><div>${fresh.slice(0,5).map(x=>'№ '+escape(x.row.order_no||x.row.id)+' — '+escape(x.row.product)).join('<br>')}</div><p>Поторопитесь с выполнением. Если не успеваете — предупредите клиента и согласуйте новый срок.</p><div class="actions"><button type="button" id="wfDeadlineOpen" class="primary">Открыть чеки</button><button type="button" id="wfDeadlineAck" class="secondary">Понятно</button></div>`;banner.hidden=false;
   function acknowledge(){for(const x of fresh){warned.add(x.key);try{localStorage.setItem('deadline:'+x.key,'1');}catch{}}banner.hidden=true;}
   $('wfDeadlineAck').onclick=acknowledge;$('wfDeadlineOpen').onclick=()=>{acknowledge();openChecks();};
  }catch{}finally{deadlineBusy=false;}
 }
 const oldSessionUI=updateSalesSessionUI;updateSalesSessionUI=function(){const result=oldSessionUI.apply(this,arguments);banner.hidden=true;deadlines();return result;};
 setTimeout(deadlines,2000);setInterval(deadlines,60000);window.addEventListener('focus',deadlines);window.addEventListener('online',deadlines);
 document.addEventListener('visibilitychange',()=>{if(!document.hidden)deadlines();});
})();
