(()=>{
 const {api,el,button,local,crop,put}=PhotoLinks;let token=location.hash.slice(1),manifest=null,editor=null,observer=null;
 const panel=el('section',null,{class:'photo-card photo-crop-panel',hidden:true});document.getElementById('photoApp').after(panel);
 const call=(action,data={})=>api(action,{...data,token});
 const notify=()=>window.dispatchEvent(new Event('photo:refresh'));
 function error(box,e){box.textContent=e.message||String(e);box.className='photo-error';}
 function act(text,fn,primary=false){let b=button(text,async()=>{b.disabled=true;try{await fn(b);}catch(e){error(panel.querySelector('.crop-status')||panel,e);}finally{b.disabled=false;}},primary);return b;}
 function key(id){return 'photo-crop:'+token+':'+id;}
 function same(a,b){return JSON.stringify(Object.entries(a||{}).sort())===JSON.stringify(Object.entries(b||{}).sort());}
 function savedDraft(id){try{return JSON.parse(localStorage.getItem(key(id))||'null');}catch{return null;}}
 async function thumbnail(node,file){try{let blob=await local.get(token,file.id,'thumb');if(!blob){const item=await local.get(token,file.id,'original');if(!item?.file||typeof createImageBitmap!=='function')return;const img=await createImageBitmap(item.file,{resizeWidth:128});const c=document.createElement('canvas');c.width=128;c.height=Math.max(1,Math.round(img.height*128/img.width));c.getContext('2d').drawImage(img,0,0,c.width,c.height);img.close();blob=await new Promise(r=>c.toBlob(r,'image/jpeg',.82));c.width=c.height=1;if(blob)await local.put(token,file.id,'thumb',blob).catch(()=>{});}if(blob&&node.isConnected){const url=URL.createObjectURL(blob);node.onload=node.onerror=()=>URL.revokeObjectURL(url);node.src=url;}}catch{}}
 function render(){
  observer?.disconnect();observer=new IntersectionObserver(entries=>{for(const entry of entries)if(entry.isIntersecting){observer.unobserve(entry.target);thumbnail(entry.target,manifest.files.find(f=>f.id===entry.target.dataset.id));}},{rootMargin:'80px'});
  panel.replaceChildren();panel.hidden=!manifest?.configured;if(panel.hidden)return;
  panel.append(el('h2','Кадрирование по вашему желанию'));
  const status=el('p','',{class:'crop-status',role:'status'});panel.append(status);
  if(!manifest.crop_enabled){panel.append(el('p','Можно обработать только нужные фотографии. Остальные останутся оригиналами.',{class:'photo-muted'}),act('Хочу кадрировать сам',async()=>{await call('crop_enable');notify();},true));return;}
  panel.append(el('p','Выберите фото, размер и нужную часть снимка. Изменения сохраняются в черновик автоматически. Нажмите «Сохранить JPG», когда результат готов.',{class:'photo-muted'}));
  const files=manifest.files.filter(f=>f.status==='ready');
  if(!files.length){panel.append(el('p','Сначала загрузите фотографии выше — здесь появятся кнопки кадрирования.'));return;}
  const list=el('div',null,{class:'crop-file-list'});
  for(const f of files){const row=el('div',null,{class:'crop-file-row'}),info=el('div');const localDraft=savedDraft(f.id),draft=localDraft?.unsynced?localDraft.settings:f.crop_draft,dirty=draft&&!same(draft,f.render_settings);
   info.append(el('strong',f.name),el('small',f.render_id?(dirty?'Есть изменения в черновике':'✓ JPG готов · '+(crop.formats.find(x=>x.key===f.render_settings?.format)?.name||'')):draft?'Есть незавершённое кадрирование':'Оригинал без кадрирования'));
   const preview=el('img',null,{alt:'',class:'crop-thumb',width:'64',height:'64','data-id':f.id});observer.observe(preview);row.append(preview,info,act(draft?'Продолжить / изменить':'Кадрировать',()=>openEditor(f),true));list.append(row);
  }panel.append(list);
  if(manifest.crop_count)panel.append(act('Скачать готовые JPG',()=>download('print')),act('Оригиналы ZIP',()=>download('originals')));
 }
 async function download(variant){const win=window.open('about:blank','_blank');if(win)win.opener=null;try{const r=await call('download',{variant});if(win)win.location=r.href||r.folder;else panel.append(el('a','Открыть скачивание',{href:r.href||r.folder,target:'_blank',rel:'noopener'}));}catch(e){win?.close();throw e;}}
 async function openEditor(file){
  if(editor)return;const dialog=el('dialog',null,{class:'photo-crop-dialog'});document.body.append(dialog);editor=dialog;
  const head=el('div',null,{class:'photo-panel-head'});head.append(el('h2',file.name),button('Закрыть',close));dialog.append(head);
  const message=el('p','Открываем оригинал…',{role:'status',class:'photo-muted'});dialog.append(message);dialog.showModal();
  let img,state,revision=file.crop_revision||0,timer,writing=null,dirty=false,conflict=false,busy=false,removed=false,lastSynced=JSON.stringify(file.crop_draft),drawn,redraw=()=>{};
  function persist(){if(!state||removed)return;try{localStorage.setItem(key(file.id),JSON.stringify({settings:state,revision,unsynced:dirty,at:Date.now()}));}catch(e){message.textContent='Не удалось сохранить черновик на устройстве. Не закрывайте страницу до сохранения на сервере.';}}
  async function flush(){
   clearTimeout(timer);if(writing){await writing;if(dirty)return flush();return;}
   if(removed||!dirty||conflict||!state)return;
   const snapshot=structuredClone(state);writing=(async()=>{try{const r=await call('crop_draft',{id:file.id,revision,settings:snapshot});revision=r.revision;lastSynced=JSON.stringify(snapshot);dirty=JSON.stringify(state)!==lastSynced;persist();message.textContent=dirty?'Сохраняем новые изменения…':'Черновик сохранён. Можно закрыть браузер и вернуться по этой ссылке.';}
    catch(e){if(e.status===409)conflict=true;message.textContent=e.status===409?e.message:'Черновик сохранён на устройстве. Сервер пока недоступен — повторим при восстановлении связи.';throw e;}
    finally{writing=null;}})();await writing;if(dirty)return flush();
  }
  function changed(){state=crop.clamp(img,state);dirty=JSON.stringify(state)!==lastSynced;persist();redraw();clearTimeout(timer);timer=setTimeout(()=>flush().catch(()=>{}),550);}
  function close(){if(busy)return;persist();flush().catch(()=>{}).finally(notify);clearTimeout(timer);clearInterval(retry);window.removeEventListener('pagehide',persist);dialog.close();dialog.remove();editor=null;notify();}
  const retry=setInterval(()=>{if(dirty&&!conflict&&!busy)flush().catch(()=>{});},6000);window.addEventListener('pagehide',persist);dialog.addEventListener('cancel',e=>{e.preventDefault();close();});
  try{
   let record=await local.get(token,file.id,'original').catch(()=>null),blob=record?.file;
   if(!blob){const r=await call('crop_source',{id:file.id}),response=await fetch(r.href,{cache:'no-store'});if(!response.ok)throw new Error('Не удалось открыть оригинал. Проверьте интернет и повторите.');blob=await response.blob();if(blob.size!==Number(file.size))throw new Error('Оригинал загрузился не полностью. Откройте фото ещё раз.');await local.put(token,file.id,'original',{file:blob,pending:false,group_id:file.group_id}).catch(()=>{});}
   img=await crop.image(blob);if(!dialog.isConnected)return;
   state=structuredClone(file.crop_draft||crop.defaults(img));const localDraft=savedDraft(file.id);
   if(localDraft&&(localDraft.unsynced&&localDraft.revision===revision||JSON.stringify(localDraft.settings)===JSON.stringify(file.crop_draft)))state=localDraft.settings;
   const select=el('select',null,{'aria-label':'Размер для кадрирования'});for(const f of crop.formats)select.append(el('option',f.name,{value:f.key}));select.value=state.format;
   const canvas=el('canvas',null,{'aria-label':'Предпросмотр кадрирования',tabindex:'0'}),stage=el('div',null,{class:'crop-stage'});stage.append(canvas);dialog.append(stage);
   message.textContent='Перемещайте фото пальцем или мышью. Масштаб можно менять двумя пальцами или ползунком.';
   const controls=el('div',null,{class:'crop-controls'}),zoom=el('input',null,{type:'range',min:'1',max:'8',step:'0.01',value:state.zoom,'aria-label':'Масштаб фото'}),quality=el('p','',{class:'photo-muted'});
   const rotateFrame=button('Повернуть рамку',()=>{state.orientation=state.orientation==='portrait'?'landscape':'portrait';state.zoom=1;state.ox=state.oy=0;changed();});
   controls.append(el('label','Размер'),select,el('label','Приблизить'),zoom,el('div',null,{class:'photo-actions'}));
   controls.lastChild.append(rotateFrame,button('Повернуть фото ↻',()=>{state.rot=(state.rot+1)%4;changed();}),button('Сбросить положение',()=>{state.zoom=1;state.ox=state.oy=0;changed();}));dialog.append(controls,quality);
   select.onchange=()=>{state.format=select.value;state.zoom=1;state.ox=state.oy=0;changed();};zoom.oninput=()=>{state.zoom=Number(zoom.value);changed();};
   redraw=()=>{if(!img||!state)return;drawn=crop.draw(canvas,img,state,850);zoom.value=state.zoom;select.value=state.format;rotateFrame.disabled=!!crop.format(state).frame;const d=crop.dimensions(state);quality.textContent=d.width+'×'+d.height+' px · JPG · 300 dpi'+(crop.lowResolution(img,state)?' · Исходник небольшой: на печати может не хватить чёткости.':'');}
   let pointers=new Map(),start=null;
   canvas.onpointerdown=e=>{if(busy)return;canvas.setPointerCapture(e.pointerId);pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});start={s:{...state},points:[...pointers.values()]};};
   canvas.onpointermove=e=>{if(busy)return;if(!pointers.has(e.pointerId))return;e.preventDefault();pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});const points=[...pointers.values()],rect=canvas.getBoundingClientRect();
    if(points.length===2&&start.points.length===2){const dist=ps=>Math.hypot(ps[0].x-ps[1].x,ps[0].y-ps[1].y);state.zoom=Math.max(1,Math.min(8,start.s.zoom*dist(points)/Math.max(1,dist(start.points))));}
    else if(points.length===1&&start.points.length===1){const f=crop.format(state),d=crop.dimensions(state),win=f.frame?f.frame.slots[0].win:[0,0,d.width,d.height],cut=f.frame?f.frame.slots[0].cut:[0,0,d.width,d.height];state.ox=start.s.ox+(e.clientX-start.points[0].x)/rect.width*cut[2]/win[2];state.oy=start.s.oy+(e.clientY-start.points[0].y)/rect.height*cut[3]/win[3];}changed();};
   const release=e=>{pointers.delete(e.pointerId);start={s:{...state},points:[...pointers.values()]};};canvas.onpointerup=canvas.onpointercancel=release;
   canvas.onkeydown=e=>{if(busy)return;const axes={ArrowLeft:['ox',-.015],ArrowRight:['ox',.015],ArrowUp:['oy',-.015],ArrowDown:['oy',.015]};if(axes[e.key]){e.preventDefault();state[axes[e.key][0]]+=axes[e.key][1];changed();}};
   const actions=el('div',null,{class:'photo-actions crop-save-actions'});
   const save=button('Сохранить JPG',async()=>{
    if(busy)return;busy=true;for(const input of dialog.querySelectorAll('button,input,select'))input.disabled=true;
    try{
     if(conflict)throw new Error('Откройте фото заново: оно изменено в другой вкладке. Локальный черновик сохранён.');
     await flush();if(!file.crop_draft&&!dirty&&lastSynced==='null'){dirty=true;await flush();}
     const snapshot=structuredClone(state);let cached=await local.get(token,file.id,'render').catch(()=>null);
     if(!cached||JSON.stringify(cached.settings)!==JSON.stringify(snapshot)){message.textContent='Создаём JPG 300 dpi…';const output=await crop.jpeg(img,snapshot);cached={...output,settings:snapshot,render_id:crypto.randomUUID()};await local.put(token,file.id,'render',cached).catch(()=>{});}
     const slot=await call('crop_reserve',{id:file.id,render_id:cached.render_id,settings:snapshot,width:cached.width,height:cached.height,size:cached.blob.size});
     if(!slot.ready)await put(slot.href,cached.blob,p=>message.textContent='Сохраняем JPG: '+Math.round(p*100)+'%');
     message.textContent='Проверяем JPG и готовим файл для сотрудника…';await call('crop_complete',{id:file.id,render_id:cached.render_id});
     await local.remove(token,file.id,'render').catch(()=>{});message.textContent='✓ JPG сохранён. Сотрудник скачает эту версию.';busy=false;close();
    }catch(e){message.textContent=e.message;}
    finally{busy=false;for(const input of dialog.querySelectorAll('button,input,select'))input.disabled=false;redraw();}
   },true);
   actions.append(save,button('Оставить оригинал без кадрирования',async()=>{if(busy)return;busy=true;clearTimeout(timer);if(writing)await writing.catch(()=>{});dirty=false;removed=true;try{const operation_id=file.clearOperation||crypto.randomUUID();file.clearOperation=operation_id;await call('crop_clear',{id:file.id,operation_id});removed=true;localStorage.removeItem(key(file.id));busy=false;close();}catch(e){removed=false;dirty=JSON.stringify(state)!==lastSynced;persist();message.textContent=e.message;busy=false;}}));dialog.append(actions);
   if(localDraft?.unsynced&&localDraft.revision!==revision&&JSON.stringify(localDraft.settings)!==JSON.stringify(file.crop_draft)){
    const recovery=el('div','Есть другой черновик на этом устройстве.',{class:'photo-notice'});recovery.append(button('Восстановить черновик устройства',()=>{state=localDraft.settings;changed();recovery.remove();}),button('Оставить версию с сервера',()=>{persist();recovery.remove();}));dialog.append(recovery);
   }
   window.requestAnimationFrame(()=>{redraw();changed();});
  }catch(e){message.textContent=e.message;}
 }
 PhotoLinks.beforePhotoFinish=()=>{if(manifest?.files.some(f=>{const d=savedDraft(f.id);return (d?.unsynced||d?.revision===f.crop_revision)&&d?.settings&&!same(d.settings,f.render_settings);}))throw new Error('Сохраните JPG для незавершённого кадрирования или выберите «Оставить оригинал».');};
 window.addEventListener('photo:manifest',e=>{token=location.hash.slice(1);manifest=e.detail;render();});
})();
