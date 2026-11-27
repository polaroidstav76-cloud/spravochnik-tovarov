/* Refresh externally saved receipt expenses without interrupting spreadsheet edits. */
(()=>{
 const $=id=>document.getElementById(id),modal=$('bigReportModal');if(!modal)return;
 const bar=document.createElement('div');bar.className='actions';bar.style.justifyContent='flex-start';const b=document.createElement('button');b.type='button';b.className='secondary';b.textContent='Обновить данные отчёта';const status=document.createElement('span');status.className='status';status.setAttribute('role','status');bar.append(b,status);$('grTitle').after(bar);
 let busy=false;
 const safe=()=>!gr.ed&&!gr.saving&&!gr.queue?.size;
 const key=()=>isAdmin?'admin:'+gr.sheets[gr.cur]?.id:'staff:'+gr.shiftId+':'+gr.staffCur;
 async function refresh(manual=false){if(busy||document.hidden||!modal.classList.contains('show'))return;if(!safe()){if(manual)status.textContent='Заверши редактирование ячейки и дождись сохранения.';return;}
  const who=staffAccount?.user_id,view=key(),admin=isAdmin;busy=true;b.disabled=true;
  try{let fresh,slot;
   if(admin){slot=gr.cur;const sheet=gr.sheets[slot];if(!sheet)return;const meta=await db.from('report_sheets').select('updated_at').eq('id',sheet.id).single();if(meta.error)throw meta.error;if(!manual&&sheet.updated_at===meta.data.updated_at)return;const r=await db.from('report_sheets').select('id,sort_order,title,branch_id,data,months,staff_visible,updated_at').eq('id',sheet.id).single();if(r.error)throw r.error;fresh=r.data;}
   else{if(!gr.shiftId||!gr.staffTabs?.[gr.staffCur]?.branchTab)return;const r=await db.rpc('report_staff_view',{p_shift_id:gr.shiftId});if(r.error)throw r.error;fresh=r.data;}
   if(!safe()||view!==key()||who!==staffAccount?.user_id||admin!==isAdmin||!modal.classList.contains('show'))return;
   const scroll=$('grWrap'),top=scroll?.scrollTop||0,left=scroll?.scrollLeft||0;
   if(admin){gr.sheets[slot]=fresh;grDrawSheet();}else{gr.staffTabs[gr.staffCur]={...fresh,branchTab:true};grShowStaff(gr.staffTabs[gr.staffCur]);}
   if($('grWrap')){$('grWrap').scrollTop=top;$('grWrap').scrollLeft=left;}
   status.textContent='Обновлено '+new Date().toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'});
  }catch(e){status.textContent='Не удалось обновить: '+(e.message||'нет связи');}finally{busy=false;b.disabled=false;}
 }
 b.onclick=()=>refresh(true);setInterval(()=>refresh(),30000);window.addEventListener('focus',()=>refresh());
})();
