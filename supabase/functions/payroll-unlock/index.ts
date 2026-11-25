import { createClient } from "jsr:@supabase/supabase-js@2";
const origins=new Set(['https://polaroidstav76-cloud.github.io','http://127.0.0.1:8795']);
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin')||'',headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin',...(origins.has(origin)?{'Access-Control-Allow-Origin':origin}:{}),'Access-Control-Allow-Headers':'authorization,x-client-info,apikey,content-type','Access-Control-Allow-Methods':'POST,OPTIONS'};
 const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers});
 if(origin&&!origins.has(origin))return reply({error:'Недопустимый источник'},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({error:'Используйте POST'},405);
 try{
  const jwt=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
  const server=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  const user=await server.auth.getUser(jwt);if(user.error||!user.data.user?.email)return reply({error:'Войдите в свой аккаунт заново'},401);
  const raw=await req.text();if(raw.length>2000)return reply({error:'Слишком длинный пароль'},400);
  const body=JSON.parse(raw),password=body.password;if(typeof password!=='string'||!password||password.length>1000)return reply({error:'Введите пароль своего аккаунта'},400);
  const verifier=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_ANON_KEY')!,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
  const checked=await verifier.auth.signInWithPassword({email:user.data.user.email,password});
  if(checked.error||checked.data.user?.id!==user.data.user.id)return reply({error:'Неверный пароль. Нужен пароль аккаунта, в котором вы сейчас работаете'},403);
  await verifier.auth.signOut({scope:'local'});
  const claims=JSON.parse(atob(jwt.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));
  if(!claims.session_id)return reply({error:'Войдите в свой аккаунт заново'},401);
  const r=await server.rpc('payroll_unlock',{p_user:user.data.user.id,p_session:claims.session_id});
  if(r.error)return reply({error:'Не удалось открыть зарплату. Войдите в свой аккаунт заново'},403);
  return reply({ok:true});
 }catch{return reply({error:'Не удалось проверить пароль. Попробуйте ещё раз'},400);}
});
