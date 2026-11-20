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
 return await r.json();
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
const publicActions=new Set(['branches','create','manifest','mode','reopen','group','reserve','complete_file','skip','finish','download']);
const staffActions=new Set(['list','configure']);
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
  if(!['branches','create','list','configure'].includes(action)&&!/^[a-f0-9]{64}$/.test(data.token||''))throw new Problem('Скопируйте ссылку целиком',404);
  if(action==='branches'||action==='list')return reply(await rpc(action,data,actor));
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
  if(['manifest','mode','reopen','group'].includes(action)){
   const result=await rpc(action,data);
   if(action==='manifest')result.configured=!!(await rpc('secret')).token;
   return reply(result);
  }
  const secret=await rpc('secret');if(!secret.token)throw new Problem('Фотоцентр ещё подключает хранилище. Ссылка сохранена — вернитесь к ней позже.',503);
  const token=secret.token;
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
  const order=await rpc('internal',data),root='disk:/Cloudshop-Client-Photos/'+order.id;
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
