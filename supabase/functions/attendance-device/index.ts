import {createClient} from 'npm:@supabase/supabase-js@2.119.0';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
export async function handler(req:Request){
 const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
 if(req.method!=='POST')return reply({error:'Method not allowed'},405);
 try{
  if(Number(req.headers.get('content-length')||0)>4096)return reply({error:'Request too large'},413);
  const raw=await req.text();if(raw.length>4096)return reply({error:'Request too large'},413);
  const body=JSON.parse(raw);if(!['pair','report'].includes(body.action))return reply({error:'Unknown action'},400);
  const token=req.headers.get('x-device-token')||'';
  if(body.action==='report'&&!/^[a-f0-9]{64}$/.test(token))return reply({error:'Device access required'},401);
  if(body.action==='pair'&&!/^[a-f0-9]{32}$/.test(body.payload?.code||''))return reply({error:'Код должен содержать 32 символа'},400);
  const {data,error}=await db.rpc('attendance_device_api',{p_action:body.action,p_token:token,p_payload:body.payload||{}});
  if(error)return reply({error:error.code==='PT401'?'Неверный, истёкший или отключённый доступ компьютера':'Проверьте код, время компьютера и настройки филиала в Клаудшопе'},error.code==='PT401'?401:400);
  return reply({result:data});
 }catch{return reply({error:'Некорректный запрос'},400);}
}
Deno.serve(handler);
