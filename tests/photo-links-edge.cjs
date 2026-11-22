const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require('typescript');
let handler,rpcs=[],fetches=[],diskMode='normal',currentAction='';
const fakeToken='test-storage-token-never-return-this';
const db={auth:{getUser:async jwt=>({data:{user:jwt==='valid-admin'?{id:'admin'}:null},error:jwt==='valid-admin'?null:{message:'invalid'}})},rpc:async(name,args)=>{
 rpcs.push(args);const d=args.p_data;let data={ok:true};
 switch(args.p_action){
  case 'remove_begin':data={order_id:'order1',path:'disk:/Cloudshop-Client-Photos/order1/photo.jpg',target:'disk:/Cloudshop-Client-Ready/order1/photo.jpg'};break;
  case 'secret':data={token:fakeToken};break;
  case 'branches':data={admin:args.p_actor==='admin',branches:[],configured:true};break;
  case 'manifest':data={id:'order1',branch:'Branch',order_number:'1',source:'staff',groups:[{id:'g1',label:'10x15'}],files:[{id:'f1',group_id:'g1',status:'ready',size:123}]};break;
  case 'reserve':data={id:d.id,path:'disk:/Cloudshop-Client-Photos/order1/01_10x15/f1_photo.jpg',size:d.size,status:'pending'};break;
  case 'file':data={path:'disk:/Cloudshop-Client-Photos/order1/01_10x15/f1_photo.jpg',size:123};break;
  case 'internal':data={id:'order1'};break;
  case 'crop_reserve':case 'crop_render':data={id:'r1',path:'disk:/Cloudshop-Client-Crops/order1/r1.jpg',target:'disk:/Cloudshop-Client-Ready/order1/r1.jpg',size:123,width:1772,height:1181,status:'pending'};break;
  case 'crop_source':data={path:'disk:/original.jpg'};break;
 }
 return {data,error:null};
}};
const context={console,Request,Response,Headers,URL,URLSearchParams,TextEncoder,AbortSignal,crypto:require('node:crypto').webcrypto,createClient:()=>db,Deno:{env:{get:()=>''},serve:h=>handler=h},fetch:async(url,opt={})=>{
 fetches.push({url:String(url),opt});const u=new URL(url);let body={};
 if(u.hostname==='download.disk.yandex.net'){const data=new Uint8Array([255,216,255,224,0,16,74,70,73,70,0,1,2,1,1,44,1,44,0,0,255,192,0,17,8,4,157,6,236,3,1,17,0,2,17,0,3,17,0,255,218,0,2]);if(diskMode==='bad-dpi')data[15]=96;return new Response(data,{status:206});}
 if(u.pathname.endsWith('/disk/'))body={user:{uid:'disk-owner'},total_space:2000000000000,used_space:100};
 else if(u.pathname==='/v1/disk/resources/download')body={href:'https://download.disk.yandex.net/original.jpg'};
 else if(u.pathname.endsWith('/resources/upload'))body={href:'https://upload.disk.yandex.net/signed-one-file'};
 else if(u.pathname.endsWith('/public/resources/download'))body={href:'https://download.disk.yandex.net/folder.zip'};
 else if(u.pathname.endsWith('/resources')&&opt.method!=='PUT')body={type:'file',size:diskMode==='wrong-size'?999:123,public_url:'https://disk.yandex.ru/d/order1',public_key:'public-key'};
 if(diskMode==='unauthorized')return new Response('{}',{status:401});
 if(diskMode==='missing'&&u.pathname.endsWith('/resources')&&opt.method!=='PUT')return new Response('{}',{status:404});
 return new Response(JSON.stringify(body),{status:200,headers:{'Content-Type':'application/json'}});
}};
let source=fs.readFileSync('supabase/functions/photo-links/index.ts','utf8').replace(/^import .*\n/,'');source=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;vm.runInNewContext(source,context);
const origin='https://polaroidstav76-cloud.github.io',token='a'.repeat(64);
async function call(action,data={},jwt='',customOrigin=origin){currentAction=action;const r=await handler(new Request('https://edge.example/photo-links',{method:'POST',headers:{'Content-Type':'application/json',Origin:customOrigin,...(jwt?{Authorization:'Bearer '+jwt}:{})},body:JSON.stringify({action,data})}));const b=await r.json();assert.ok(!JSON.stringify(b).includes(fakeToken));return {r,b};}
(async()=>{
 assert.equal((await call('list')).r.status,401);assert.equal((await call('seen',{id:'o1'})).r.status,401);assert.equal((await call('seen',{id:'o1',updated_at:new Date().toISOString()},'valid-admin')).r.status,200);assert.equal((await call('consultation',{token,needed:true})).r.status,200);assert.equal((await call('contacts_save',{branch_id:1,links:{}},'valid-admin')).r.status,200);
 assert.equal((await call('delete_link',{id:'o1'})).r.status,401);assert.equal((await call('delete_link',{id:'o1'},'valid-admin')).r.status,200);assert.ok(rpcs.some(x=>x.p_action==='delete_link'&&x.p_actor==='admin'));
 assert.equal((await call('branches',{},'invalid')).r.status,401);
 assert.equal((await call('branches',{},'', 'https://evil.example')).r.status,403);
 const branch=await call('branches');assert.equal(branch.r.headers.get('Access-Control-Allow-Origin'),origin);assert.equal(branch.b.configured,true);
 assert.equal((await call('secret')).r.status,400);
 assert.equal((await call('manifest',{token:'short'})).r.status,404);
 assert.equal((await call('manifest',{token})).b.configured,true);
 assert.equal((await call('configure',{token:'a'.repeat(40)},'valid-admin')).r.status,200);assert.equal(rpcs.find(x=>x.p_action==='configure').p_data.account_id,'disk-owner');
 diskMode='unauthorized';assert.equal((await call('configure',{token:'a'.repeat(40)},'valid-admin')).r.status,503);diskMode='normal';
 const id='12345678-1234-1234-1234-123456789012';
 assert.equal((await call('reserve',{token,id,name:'script.exe',size:123})).r.status,400);
 const slot=await call('reserve',{token,id,group_id:'g1',name:'photo.jpg',size:123});assert.equal(slot.r.status,200);assert.equal(slot.b.href,'https://upload.disk.yandex.net/signed-one-file');
 assert.equal(fetches.filter(x=>x.opt.method==='PUT'&&x.url.includes('/resources?')).length>=3,true);
 diskMode='wrong-size';assert.equal((await call('complete_file',{token,id})).r.status,400);diskMode='normal';
 assert.equal((await call('complete_file',{token,id})).b.ok,true);
 const skip=await call('skip',{token,id});assert.equal(skip.b.saved,true,'already uploaded originals are retained');
 diskMode='missing';assert.equal((await call('skip',{token,id})).b.ok,true);diskMode='normal';
 assert.equal((await call('finish',{token,comment:'Без полей'})).b.ok,true);
 assert.deepEqual(Array.from(rpcs.find(x=>x.p_action==='finish').p_data.snapshot),['f1']);
 const archive=await call('download',{token});assert.equal(archive.b.href,'https://download.disk.yandex.net/folder.zip');
 assert.ok(fetches.some(x=>x.url.includes('/public/resources/download?')));
 assert.equal((await call('crop_source',{token,id})).b.href,'https://download.disk.yandex.net/original.jpg');
 assert.equal((await call('crop_reserve',{token,id,render_id:'r1',size:123})).r.status,200);
 diskMode='bad-dpi';assert.equal((await call('crop_complete',{token,id,render_id:'r1'})).r.status,400);diskMode='normal';
 assert.equal((await call('crop_complete',{token,id,render_id:'r1'})).r.status,200);assert.ok(rpcs.some(x=>x.p_action==='crop_commit'));
 assert.equal((await call('remove_photo',{token,id,operation_id:id})).r.status,200);assert.ok(rpcs.some(x=>x.p_action==='remove_commit'));
 console.log('Photo links Edge: auth, CORS, secret isolation, storage setup, upload slots, size verification, skip safety, finish snapshot and ZIP passed.');
})().catch(e=>{console.error(e);process.exit(1)});
