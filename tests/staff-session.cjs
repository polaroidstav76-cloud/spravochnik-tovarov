const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {controller,canResume}=require('../staff-session.js');const {parseHTML}=require('linkedom');
const tick=()=>new Promise(r=>setImmediate(r));
(async()=>{
 // Supabase holds its auth lock while invoking listeners. No API call can happen inside it.
 let held=true,calls=0,applied=[],queue=[];
 const auth={getUser:async()=>{assert(!held,'auth listener attempted nested SDK call');calls++;return{data:{user:{id:'a'}}}},signOut:async args=>{assert.deepEqual(args,{scope:'local'});return{}}};
 const c=controller({auth,readAccount:async()=>({data:{user_id:'a',active:true}}),apply:(a,s)=>applied.push([a,s]),schedule:fn=>{queue.push(fn);return queue.length},cancel:()=>{}});
 assert.equal(c.changed(),undefined);assert.equal(calls,0);held=false;queue.shift()();await tick();assert.equal(applied[0][0].user_id,'a');await c.logout();
 // A network failure keeps the verified UI account; a genuinely missing session locks it.
 let transient=0;auth.getUser=async()=>({error:{status:503,message:'unavailable'}});await c.refresh();assert.equal(applied.length,1);
 auth.getUser=async()=>({data:{user:null},error:{status:403,code:'session_not_found'}});await c.refresh();assert.equal(applied.at(-1)[0],null);assert.equal(applied.at(-1)[1].signedIn,false);
 const revoked=controller({auth:{getUser:async()=>({data:{user:{id:'a'}}})},readAccount:async()=>({error:{code:'PT401'}}),apply:(a,s)=>applied.push([a,s])});await revoked.refresh();assert.equal(applied.at(-1)[1].reason,'disabled');
 // Older asynchronous checks must never overwrite the newer verified account.
 let complete;const seen=[];let n=0;
 const race=controller({auth:{getUser:()=>++n===1?new Promise(r=>complete=r):Promise.resolve({data:{user:{id:'b'}}})},readAccount:async id=>({data:{user_id:id,active:true}}),apply:a=>seen.push(a)});
 const first=race.refresh();await race.refresh();complete({data:{user:{id:'a'}}});await first;assert.deepEqual(seen.map(x=>x.user_id),['b']);
 assert(canResume('a','a'));assert(!canResume('a','b'));assert(!canResume(null,'a'));
 // Exercise the real login and UI bindings with an existing sale and shift.
 const html=fs.readFileSync('index.html','utf8');const {document}=parseHTML('<body>'+['loginModal','loginError','loginBtn','logoutBtn','payrollBtn','staffPayrollBtn','staffAccountsBtn','authStatus','adminbar','testsBtn','pricesBtn','customersBtn','salesAdminBtn','reportsBtn','doLogin','password','email'].map(id=>id==='password'||id==='email'?`<input id="${id}">`:`<div id="${id}"></div>`).join('')+'</body>');
 let user='a',reloads=0,logouts=[];const draft=[{catalogId:10,quantity:2}],session={shiftId:123,branchId:5};
 const ctx={document,CloudshopStaffSession:require('../staff-session.js'),STAFF_LOGIN_REQUIRED:true,isAdmin:false,$:id=>document.getElementById(id),render(){},open:id=>document.getElementById(id).classList.add('show'),close:id=>document.getElementById(id).classList.remove('show'),setTimeout:()=>1,clearTimeout(){},loadStaffWorkspace:async()=>{},staffLoginEmail:s=>s,location:{reload:()=>reloads++},saleDraft:draft,salesSession:session,
 db:{auth:{getUser:async()=>({data:{user:{id:user}}}),signInWithPassword:async()=>({data:{user:{id:user}},error:null}),signOut:async args=>{logouts.push(args);return{}}},from:()=>({select:fields=>{assert(fields.split(',').includes('person_id'),'account identity must include person_id for shift access');return {eq:()=>({maybeSingle:async()=>({data:{user_id:user,name:'Сотрудник',role:'staff',active:true,person_id:4}})})}}})}};
 ctx.window=ctx;vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('let staffAccount=null'),html.indexOf('window.editProduct=')),ctx);
 await vm.runInContext('refreshAuth()',ctx);assert(!document.body.classList.contains('staff-locked'));assert.equal(vm.runInContext('staffAccount.person_id',ctx),4);
 vm.runInContext("applyStaffAuth(null,{signedIn:false})",ctx);assert(document.body.classList.contains('staff-locked'));assert(document.getElementById('loginModal').classList.contains('show'));
 const loginStart=html.indexOf("$('doLogin').onclick=async()=>");const loginEnd=html.indexOf("$('password').addEventListener",loginStart);vm.runInContext(html.slice(loginStart,loginEnd),ctx);
 await document.getElementById('doLogin').onclick();assert.equal(reloads,0);assert.equal(ctx.saleDraft,draft);assert.equal(ctx.salesSession,session);assert(!document.body.classList.contains('staff-locked'));assert(!document.getElementById('loginModal').classList.contains('show'));
 vm.runInContext("applyStaffAuth(null,{signedIn:false})",ctx);user='b';await document.getElementById('doLogin').onclick();assert.equal(reloads,1);vm.runInContext("applyStaffAuth({user_id:'b',role:'staff',active:true},{signedIn:true})",ctx);assert(document.body.classList.contains('staff-locked'),'another user must not inherit the old draft');
 const logoutStart=html.indexOf("$('logoutBtn').onclick=async()=>");const logoutEnd=html.indexOf('\n',logoutStart);vm.runInContext(html.slice(logoutStart,logoutEnd),ctx);await document.getElementById('logoutBtn').onclick();assert.equal(logouts[0].scope,'local');
 console.log('PASS staff session: deferred auth callbacks, local logout, transient network errors, invalid/revoked sessions, stale response isolation, same-user re-login preserving sale/shift, cross-user lock and no reload for session recovery');
})().catch(e=>{console.error(e);process.exitCode=1});
