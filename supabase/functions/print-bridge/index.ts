import { createClient } from 'npm:@supabase/supabase-js@2.119.0';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
const actions=new Set(['pair','health','enqueue','status','next','complete']);
Deno.serve(async(req:Request)=>{
 const respond=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
 if(req.method!=='POST')return respond({error:'Method not allowed'},405);
 try{
  if(Number(req.headers.get('content-length')||0)>16384)return respond({error:'Request too large'},413);
  const raw=await req.text();if(raw.length>16384)return respond({error:'Request too large'},413);
  const body=JSON.parse(raw);if(!actions.has(body.action))return respond({error:'Unknown action'},400);
  const token=req.headers.get('x-device-token')||'';
  if(body.action!=='pair'&&!/^[a-f0-9]{64}$/.test(token))return respond({error:'Компьютер не подключён'},401);
  const {data,error}=await db.rpc('print_bridge_device_api',{p_action:body.action,p_token:token,p_payload:body.payload||{}});
  if(error)return respond({error:error.code==='PT401'?'Неверный или отключённый доступ компьютера':error.code==='PT403'?'Нет доступа для этого режима': 'Не удалось выполнить действие. Проверьте параметры файла или подключение.'},error.code==='PT401'?401:error.code==='PT403'?403:400);
  return respond({result:data});
 }catch{return respond({error:'Некорректный запрос'},400)}
});
