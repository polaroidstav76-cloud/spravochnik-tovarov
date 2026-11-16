const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {parseHTML}=require('linkedom');
const code=fs.readFileSync(require('node:path').join(__dirname,'../print-bridge.js'),'utf8');
async function harness({role='staff',branch=5,allowed=true,filename='<img src=x onerror=alert(1)>.tif'}={}){
 const {document,window}=parseHTML('<html><body><div><button id="refreshBtn">Refresh</button></div></body></html>');
 const timers=[];const calls=[];const user={user_id:'user-1',role};const session={shiftId:100,branchId:branch};
 const context={document,window,console,Date,Set,String,Number,Array,Promise,navigator:{clipboard:{writeText:async value=>{context.copied=value}}},confirm:()=>true,staffAccount:user,salesSession:session,
 setTimeout:fn=>{timers.push(fn);return timers.length;},setInterval:()=>1,
 db:{rpc:async(name,args)=>{calls.push([name,args]);if(name==='print_bridge_target')return{data:{branch_id:5,branch:'Target'}};
 if(name==='print_bridge_files')return allowed?{data:[{id:'job-1',filename,relative_path:filename,source_branch:'Source',size_bytes:4,downloaded_at:'2026-11-16T12:00:00Z',is_read:false}]}:{error:{message:'Denied'}};
 if(name==='print_bridge_setup')return{data:{branch:'Target',devices:[]}};
 if(name==='print_bridge_pair_code')return{data:{code:'a'.repeat(32),role:args.p_role}};
 if(name==='print_bridge_read')return{data:true};throw Error(name);}}};
 vm.createContext(context);vm.runInContext(code,context);await timers[0]();
 return{document,calls,context};
}
(async()=>{
 const other=await harness({branch:8});assert.equal(other.document.getElementById('printBridgeBtn').hidden,true);assert(!other.calls.some(c=>c[0]==='print_bridge_files'));assert.equal(other.document.querySelector('.pb-toast'),null);
 const target=await harness();assert.equal(target.document.getElementById('printBridgeBtn').hidden,false);assert(target.document.querySelector('.pb-toast').textContent.includes('<img'));assert.equal(target.document.querySelector('img'),null,'Filename must never become HTML');
 await target.document.querySelector('[data-pb-read]').onclick();assert(target.calls.some(c=>c[0]==='print_bridge_read'));assert(target.document.getElementById('pbFiles').textContent.includes('Прочитано'));
 const denied=await harness({allowed:false});assert.equal(denied.document.querySelector('.pb-toast'),null);assert.equal(denied.document.querySelector('[data-pb-read]'),null);
 const admin=await harness({role:'admin',branch:8});await admin.document.getElementById('printBridgeBtn').onclick();assert.equal(admin.document.getElementById('pbAdmin').hidden,false);
 await admin.document.getElementById('pbPairReceiver').onclick();assert.equal(admin.document.getElementById('pbCode').value,'a'.repeat(32));await admin.document.getElementById('pbCopy').onclick();assert.equal(admin.context.copied,'a'.repeat(32));
 admin.document.getElementById('pbClose').onclick();assert.equal(admin.document.getElementById('pbCode').value,'');
 console.log('30x40 frontend: target visibility, denied access, escaped filenames, read state and admin pairing passed');
})().catch(e=>{console.error(e);process.exitCode=1});
