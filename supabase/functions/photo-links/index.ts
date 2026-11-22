import { createClient } from 'npm:@supabase/supabase-js@2.119.0';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
const API='https://cloud-api.yandex.net/v1/disk';
const folderCache=new Map<string,Promise<void>>();
const origins=new Set(['https://polaroidstav76-cloud.github.io','https://foto-26.ru','https://www.foto-26.ru']);
class Problem extends Error { constructor(message:string,public status=400){super(message)} }
async function rpc(action:string,data:Record<string,unknown>={},actor:string|null=null):Promise<any>{
 const r=await db.rpc('photo_links_api',{p_action:action,p_data:data,p_actor:actor});
 if(r.error)throw new Problem(r.error.code?.startsWith('PT')?r.error.message:r.error.code==='P0001'?r.error.message:'Не удалось сохранить изменения. Повторите действие.',/^PT[1-5][0-9]{2}$/.test(r.error.code||'')?Number(r.error.code.slice(2)):400);
 return r.data;
}
async function disk(token:string,path:string,params:Record<string,string>={},method='GET'):Promise<any>{
 let r:Response;
 try{r=await fetch(API+path+'?'+new URLSearchParams(params),{method,headers:{Authorization:'OAuth '+token},signal:AbortSignal.timeout(20000)});}catch{throw new Problem('Яндекс Диск не отвечает. Фотографии уже в очереди можно повторить без повторного выбора.',503)}
 if(method==='PUT'&&path==='/resources'&&r.status===409)return {};
 if(!r.ok){await r.body?.cancel();if(r.status===404)throw new Problem('Файл ещё не найден на Диске. Повторите загрузку.',404);throw new Problem(r.status===401?'Доступ к Яндекс Диску истёк. Сообщите сотруднику фотоцентра.':r.status===507?'На Диске закончилось место. Сообщите сотруднику фотоцентра.':'Не удалось выполнить операцию на Яндекс Диске. Повторите чуть позже.',r.status===401?503:502)}
 if(r.status===204)return {};
 const text=await r.text();return text?JSON.parse(text):{};
}
function trustedHref(value:unknown):string{
 try{const u=new URL(String(value));if(u.protocol==='https:'&&['yandex.net','yandex.ru','yandex.com','yadi.sk'].some(d=>u.hostname===d||u.hostname.endsWith('.'+d)))return u.href;}catch{}
 throw new Problem('Диск не выдал ссылку для файла. Попробуйте ещё раз.',502);
}
async function folders(token:string,path:string):Promise<void>{
 const key=token+':'+path;if(folderCache.has(key))return folderCache.get(key)!;
 const task=(async()=>{const split=path.lastIndexOf('/');if(split>6)await folders(token,path.slice(0,split));await disk(token,'/resources',{path},'PUT');})();
 folderCache.set(key,task);try{await task;}catch(e){folderCache.delete(key);throw e;}
 if(folderCache.size>2000)folderCache.clear();
}
async function writeText(token:string,path:string,text:string){
 const slot=await disk(token,'/resources/upload',{path,overwrite:'true'});
 let r:Response;try{r=await fetch(trustedHref(slot.href),{method:'PUT',body:new TextEncoder().encode(text),signal:AbortSignal.timeout(25000)});}catch{throw new Problem('Не удалось сохранить комментарий. Повторите завершение загрузки.',503)}
 if(!r.ok){await r.body?.cancel();throw new Problem('Не удалось сохранить комментарий. Повторите завершение загрузки.',502)}
}
async function operation(token:string,result:any){
 if(!result.href||!String(result.href).includes('/operations/'))return;
 const href=trustedHref(result.href);const u=new URL(href);if(u.hostname!=='cloud-api.yandex.net')throw new Problem('Некорректный адрес операции Диска',502);
 for(let i=0;i<35;i++){
  let r;try{r=await fetch(href,{headers:{Authorization:'OAuth '+token},signal:AbortSignal.timeout(10000)});}catch{throw new Problem('Диск ещё сохраняет JPG. Повторите сохранение.',503);}
  if(!r.ok)throw new Problem('Не удалось проверить сохранение JPG. Повторите.',503);
  const value=await r.json();if(value.status==='success')return;if(value.status==='failed')throw new Problem('Диск не сохранил JPG. Повторите.',502);
  await new Promise(resolve=>setTimeout(resolve,600));
 }
 throw new Problem('Диск ещё сохраняет JPG. Подождите немного и повторите.',503);
}
function jpegHeader(bytes:Uint8Array){
 if(bytes[0]!==255||bytes[1]!==216)throw new Problem('Ожидался файл JPG');
 let pos=2,width=0,height=0,dpi=false;
 while(pos+4<bytes.length&&bytes[pos]===255){
  const marker=bytes[pos+1],length=(bytes[pos+2]<<8)|bytes[pos+3];if(marker===0xda||marker===0xd9)break;if(length<2||pos+length+2>bytes.length)break;
  if(marker===0xe0&&length>=16&&bytes[pos+4]===74&&bytes[pos+5]===70&&bytes[pos+6]===73&&bytes[pos+7]===70&&bytes[pos+11]===1)dpi=((bytes[pos+12]<<8)|bytes[pos+13])===300&&((bytes[pos+14]<<8)|bytes[pos+15])===300;
  if([0xc0,0xc1,0xc2].includes(marker)){height=(bytes[pos+5]<<8)|bytes[pos+6];width=(bytes[pos+7]<<8)|bytes[pos+8];}
  pos+=length+2;
 }
 return {width,height,dpi};
}
async function verifyJpeg(token:string,render:any){
 const meta=await disk(token,'/resources',{path:render.path,fields:'size,type'});
 if(meta.type!=='file'||Number(meta.size)!==Number(render.size))throw new Problem('JPG загрузился не полностью. Повторите сохранение.');
 const download=await disk(token,'/resources/download',{path:render.path});
 const response=await fetch(trustedHref(download.href),{headers:{Range:'bytes=0-262143'},signal:AbortSignal.timeout(20000)});
 if(!response.ok||!response.body)throw new Problem('Не удалось проверить JPG. Повторите сохранение.',503);
 const reader=response.body.getReader(),chunks:Uint8Array[]=[];let total=0;
 try{while(total<262144){const next=await reader.read();if(next.done)break;const chunk=next.value.slice(0,262144-total);chunks.push(chunk);total+=chunk.length;}}finally{await reader.cancel();}
 const bytes=new Uint8Array(total);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 const header=jpegHeader(bytes);if(!header.dpi||header.width!==render.width||header.height!==render.height)throw new Problem('JPG должен соответствовать выбранному размеру и иметь 300 dpi');
}

const publicActions=new Set(['branches','create','manifest','mode','reopen','group','reserve','complete_file','skip','finish','download','crop_enable','crop_draft','crop_source','crop_reserve','crop_complete','crop_clear','consultation','remove_photo']);
const staffActions=new Set(['list','configure','seen','contacts_save']);
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin')||'';
 const headers:Record<string,string>={'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Headers':'authorization, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
 if(origins.has(origin))headers['Access-Control-Allow-Origin']=origin;
 const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
 if(origin&&!origins.has(origin))return reply({error:'Недопустимый источник запроса'},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({error:'Используйте POST'},405);
 try{
  if(Number(req.headers.get('content-length')||0)>18000)throw new Problem('Слишком большой запрос',413);
  const raw=await req.text();if(raw.length>18000)throw new Problem('Слишком большой запрос',413);
  const b=JSON.parse(raw),action=String(b.action||'');
  if(!publicActions.has(action)&&!staffActions.has(action))throw new Problem('Неизвестное действие');
  let actor:string|null=null;
  const jwt=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
  if(jwt){const {data,error}=await db.auth.getUser(jwt);if(error||!data.user)throw new Problem('Войдите в Клаудшоп повторно',401);actor=data.user.id;}
  if(staffActions.has(action)&&!actor)throw new Problem('Требуется вход сотрудника',401);
  const data=(b.data&&typeof b.data==='object'&&!Array.isArray(b.data))?b.data:{};
  if(!['branches','create','list','configure','seen','contacts_save'].includes(action)&&!/^[a-f0-9]{64}$/.test(data.token||''))throw new Problem('Скопируйте ссылку целиком',404);
  if(action==='branches'||action==='list'||action==='seen'||action==='contacts_save'||action==='consultation')return reply(await rpc(action,data,actor));
  if(action==='configure'){
   const state=await rpc('branches',{},actor);if(!state.admin)throw new Problem('Только администратор',403);
   const token=String(data.token||'').trim();if(token.length<20||token.length>1000)throw new Problem('Вставьте OAuth-токен Яндекс Диска');
   const info=await disk(token,'/');await folders(token,'disk:/Cloudshop-Client-Photos');
   if(!info.user?.uid)throw new Problem('Не удалось определить аккаунт Диска',502);
   await rpc('configure',{token,account_id:String(info.user.uid)},actor);
   return reply({ok:true,total:info.total_space,used:info.used_space});
  }
  if(action==='create'){
   if(!actor){
    const ip=(req.headers.get('x-forwarded-for')||'unknown').split(',')[0].trim();
    const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode('photo-offline:'+ip));
    await rpc('rate',{key:Array.from(new Uint8Array(digest)).map(x=>x.toString(16).padStart(2,'0')).join('')});
    if(data.website)throw new Problem('Повторите создание заявки');
   }
   return reply(await rpc('create',data,actor));
  }
  if(['manifest','mode','reopen','group','crop_enable','crop_draft'].includes(action)){
   const result=await rpc(action,data);
   if(action==='manifest')result.configured=!!(await rpc('secret')).token;
   return reply(result);
  }
  const secret=await rpc('secret');if(!secret.token)throw new Problem('Фотоцентр ещё подключает хранилище. Ссылка сохранена — вернитесь к ней позже.',503);
  const token=secret.token;
  if(action==='remove_photo'){
   const f=await rpc('remove_begin',data);if(f.removed)return reply(f);
   const root='disk:/Cloudshop-Client-Removed/'+f.order_id;await folders(token,root);
   for(const [path,destination]of [[f.path,root+'/'+String(data.id)+'_original_'+String(f.path).split('/').pop()],[f.target,root+'/'+String(data.id)+'_print.jpg']]){
    if(!path)continue;
    try{await operation(token,await disk(token,'/resources/move',{from:path,path:destination,overwrite:'true'},'POST'));}catch(e){if(!(e instanceof Problem)||e.status!==404)throw e;}
   }
   return reply(await rpc('remove_commit',data));
  }
  if(action==='crop_source'){
   const f=await rpc('crop_source',data),download=await disk(token,'/resources/download',{path:f.path});return reply({href:trustedHref(download.href)});
  }
  if(action==='crop_reserve'){
   if(!Number.isSafeInteger(data.size)||data.size<=0||data.size>=60000000)throw new Problem('JPG слишком большой');
   const render=await rpc('crop_reserve',data);if(render.status==='ready')return reply({ready:true});
   await folders(token,render.path.slice(0,render.path.lastIndexOf('/')));
   const slot=await disk(token,'/resources/upload',{path:render.path,overwrite:'true'});return reply({href:trustedHref(slot.href)});
  }
  if(action==='crop_complete'){
   const render=await rpc('crop_render',data);
   if(render.status==='ready'&&render.current_render_id===render.id)return reply({ok:true});
   await verifyJpeg(token,render);await rpc('crop_publish',data);
   await folders(token,render.target.slice(0,render.target.lastIndexOf('/')));
   await operation(token,await disk(token,'/resources/copy',{from:render.path,path:render.target,overwrite:'true'},'POST'));
   const target=await disk(token,'/resources',{path:render.target,fields:'size,type'});if(Number(target.size)!==Number(render.size))throw new Problem('Диск ещё готовит JPG. Повторите сохранение.',503);
   return reply(await rpc('crop_commit',data));
  }
  if(action==='crop_clear'){
   const active=await rpc('crop_clear_begin',data);
   if(active.target){
    const order=await rpc('internal',data),path='disk:/Cloudshop-Client-Crops/'+order.id;
    await folders(token,path);
    try{await operation(token,await disk(token,'/resources/move',{from:active.target,path:path+'/removed_'+String(data.operation_id)+'.jpg',overwrite:'true'},'POST'));}
    catch(e){if(!(e instanceof Problem)||e.status!==404)throw e;}
   }
   return reply(await rpc('crop_clear',data));
  }

  if(action==='reserve'){
   if(!/\.(jpe?g|png|heic|heif|tiff?|webp|avif|bmp|dng|cr2|nef|arw)$/i.test(String(data.name||'')))throw new Problem('Выберите оригиналы фотографий: JPG, PNG, HEIC, TIFF, WEBP или RAW');
   if(!Number.isSafeInteger(data.size)||data.size<=0||data.size>536870912)throw new Problem('Размер одного фото — до 512 МБ');
   if(!/^[a-f0-9-]{36}$/.test(data.id||''))throw new Problem('Повторите выбор файла');
   const f=await rpc('reserve',data);
   if(f.status==='ready')return reply({ready:true,id:f.id});
   await folders(token,f.path.slice(0,f.path.lastIndexOf('/')));
   // A previous PUT may have succeeded while its response was lost. Never upload twice.
   if(f.reused)try{const existing=await disk(token,'/resources',{path:f.path,fields:'size,type'});if(existing.type==='file'&&Number(existing.size)===Number(f.size)){await rpc('complete_file',data);return reply({ready:true,id:f.id});}}catch(e){if(!(e instanceof Problem)||e.status===503)throw e;}
   const upload=await disk(token,'/resources/upload',{path:f.path,overwrite:'true'});
   return reply({id:f.id,href:trustedHref(upload.href)});
  }
  if(action==='skip'){
   const f=await rpc('file',data);
   try{const meta=await disk(token,'/resources',{path:f.path,fields:'size,type'});
    if(meta.type==='file'&&Number(meta.size)===Number(f.size)){await rpc('complete_file',data);return reply({ok:true,saved:true});}
    throw new Problem('Файл есть на Диске, но его размер отличается. Повторите загрузку.');
   }catch(e){if(!(e instanceof Problem)||e.status!==404)throw e;}
   return reply(await rpc('skip',data));
  }
  if(action==='complete_file'){
   const f=await rpc('file',data),meta=await disk(token,'/resources',{path:f.path,fields:'size,type'});
   if(meta.type!=='file'||Number(meta.size)!==Number(f.size))throw new Problem('Файл загрузился не полностью. Нажмите «Повторить».');
   await rpc('complete_file',data);return reply({ok:true});
  }
  const order=await rpc('internal',data);let root='disk:/Cloudshop-Client-Photos/'+order.id;
  if(action==='download'&&data.variant==='print'){const ready=await rpc('crop_download_check',data);if(!ready.count)throw new Problem('Кадрированные JPG ещё не сохранены');root='disk:/Cloudshop-Client-Ready/'+order.id;}
  if(action==='finish'){
   const m=await rpc('manifest',data);
   if(!m.files.some((x:any)=>x.status==='ready')||m.files.some((x:any)=>x.status==='pending'))throw new Problem('Дождитесь загрузки всех фото или исключите файлы с ошибкой');
   if(String(data.comment||'').length>3000)throw new Problem('Комментарий — до 3000 символов');
   const lines=['ПОЛАРОИД · фотографии клиента','Филиал: '+m.branch,'Заказ: '+(m.order_number||'без номера'),m.source==='offline'?'Офлайн-заказ':'Персональная ссылка','',...m.groups.map((g:any)=>g.label+': '+m.files.filter((f:any)=>f.group_id===g.id&&f.status==='ready').length+' фото'),'','Комментарий:',String(data.comment||'Без комментария')];
   await writeText(token,root+'/О заказе.txt',lines.join('\r\n'));
   await disk(token,'/resources/publish',{path:root},'PUT');
   return reply(await rpc('finish',{...data,snapshot:m.files.filter((f:any)=>f.status==='ready').map((f:any)=>f.id).sort()}));
  }
  if(action==='download'){
   const m=await rpc('manifest',data);if(!m.files.some((f:any)=>f.status==='ready'))throw new Problem('Фотографии ещё не загружены');
   await disk(token,'/resources/publish',{path:root},'PUT');
   const folder=await disk(token,'/resources',{path:root,fields:'public_url,public_key'});
   const folderUrl=trustedHref(folder.public_url);
   try{const download=await disk(token,'/public/resources/download',{public_key:folder.public_key||folderUrl});return reply({href:trustedHref(download.href),folder:folderUrl});}
   catch{return reply({folder:folderUrl,message:'Откройте папку и нажмите «Скачать всё» — Яндекс Диск соберёт ZIP.'});}
  }
  throw new Problem('Неизвестное действие');
 }catch(e){return reply({error:e instanceof Problem?e.message:'Не удалось выполнить действие. Проверьте интернет и повторите.'},e instanceof Problem?e.status:400)}
});
