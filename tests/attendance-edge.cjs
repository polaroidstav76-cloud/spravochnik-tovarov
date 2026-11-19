const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),{stripTypeScriptTypes}=require('node:module');
let raw=fs.readFileSync(require('node:path').join(__dirname,'../supabase/functions/attendance-device/index.ts'),'utf8').replace(/^import .*\n/,'').replace('export async function','async function');
const code=stripTypeScriptTypes(raw,{mode:'strip'});let handler;const calls=[];
const ctx={Request,Response,JSON,Number,Set,createClient:()=>({rpc:async(n,p)=>{calls.push([n,p]);return {data:{saved:true}};}}),Deno:{env:{get:()=> 'test'},serve:f=>handler=f}};
vm.createContext(ctx);vm.runInContext(code,ctx);
(async()=>{
 assert.equal((await handler(new Request('https://example.com'))).status,405);
 assert.equal((await handler(new Request('https://example.com',{method:'POST',body:'{}'}))).status,400);
 assert.equal((await handler(new Request('https://example.com',{method:'POST',body:JSON.stringify({action:'report'})}))).status,401);
 assert.equal(calls.length,0);
 const req=new Request('https://example.com',{method:'POST',headers:{'x-device-token':'a'.repeat(64)},body:JSON.stringify({action:'report',payload:{boot_at:'2026-11-17T07:00:00Z'}})});
 const response=await handler(req);assert.equal(response.status,200);assert.equal(calls[0][0],'attendance_device_api');assert.equal(calls[0][1].p_token,'a'.repeat(64));
 assert.equal((await handler(new Request('https://example.com',{method:'POST',body:'a'.repeat(24577)}))).status,413);
 console.log('PASS attendance Edge API: method, size, action and token checks; authenticated device RPC only');
})().catch(e=>{console.error(e);process.exitCode=1;});
