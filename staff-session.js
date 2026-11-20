/* Auth lifecycle: never await Supabase APIs inside its auth-event lock. */
(function(root){
 'use strict';
 const fatal=e=>!!e&&([400,401,403].includes(Number(e.status))||['session_not_found','refresh_token_not_found','refresh_token_already_used','bad_jwt','invalid_jwt'].includes(e.code)||e.name==='AuthSessionMissingError');
 function controller({auth,readAccount,apply,onTransient=()=>{},schedule=setTimeout,cancel=clearTimeout}){
  let revision=0,timer=null;
  async function refresh(){
   const id=++revision;
   try{
    const result=await auth.getUser();if(id!==revision)return false;
    if(result.error&&!fatal(result.error)){onTransient(result.error);return false;}
    const user=result.data?.user;
    if(!user){apply(null,{signedIn:false,reason:'signed-out'});return false;}
    const row=await readAccount(user.id);if(id!==revision)return false;
    if(row.error&&!fatal(row.error)&&row.error.code!=='PT401'){onTransient(row.error);return false;}
    if(row.error||!row.data?.active){apply(null,{signedIn:true,reason:'disabled'});return false;}
    apply(row.data,{signedIn:true,reason:'ready'});return true;
   }catch(e){if(id===revision)onTransient(e);return false;}
  }
  function changed(){
   revision++;if(timer!==null)cancel(timer);
   timer=schedule(()=>{timer=null;void refresh();},0);
  }
  return {refresh,changed,logout:()=>auth.signOut({scope:'local'})};
 }
 const api={controller,fatal,canResume:(before,after)=>!!before&&before===after};
 root.CloudshopStaffSession=api;if(typeof module==='object'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
