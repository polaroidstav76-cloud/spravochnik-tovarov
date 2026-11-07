const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const {stripTypeScriptTypes}=require('node:module');
const source=fs.readFileSync(require('node:path').join(__dirname,'../supabase/functions/telegram-purchase/index.ts'),'utf8').replace(/^import .*;\s*/m,'');
let handler,sent=[],calls=[],status='ready',allowed=true,failSend=false,failDb=false;
vm.runInNewContext(stripTypeScriptTypes(source),{
  Request,Response,Date,
  Deno:{env:{get:()=>''},serve:fn=>handler=fn},
  createClient:()=>({rpc:async(name,args)=>{
    calls.push({name,args});
    if(name==='telegram_purchase_config')return {data:{token:'test',secret:'secret'}};
    if(name==='telegram_purchase_data')return {data:allowed?[]:null};
    return failDb?{error:{message:'offline'}}:{data:{status,id:77}};
  }}),
  fetch:async(url,options)=>{sent.push(JSON.parse(options.body));return Response.json({ok:!failSend})},
});
const request=(text,type='private')=>new Request('https://test.local',{method:'POST',headers:{'X-Telegram-Bot-Api-Secret-Token':'secret'},body:JSON.stringify({message:{message_id:100,chat:{id:123,type},text}})});
(async()=>{
  await handler(request('📥 Приход'));
  assert(sent.at(-1).text.includes('только мастерская'));
  assert.equal(calls.at(-1).args.p_action,'start');
  assert(sent.at(-1).reply_markup.keyboard.flat().some(x=>x.text==='📥 Приход'));
  status='saved';
  await handler(request('Клей-пена <А> — 5 шт — 1 250,50 руб.'));
  assert.equal(calls.at(-1).args.p_name,'Клей-пена <А>');
  assert.equal(calls.at(-1).args.p_amount,1250.50);
  assert.equal(calls.at(-1).args.p_qty,5);
  await handler(request('Клей — 1,5 шт — 100 руб'));
  assert.equal(calls.at(-1).args.p_qty,1.5);
  assert.equal(calls.at(-1).args.p_amount,100);
  assert.equal(calls.at(-1).args.p_message_id,100);
  assert(sent.some(m=>m.text.includes('&lt;А&gt;')));
  for(const text of ['Клей - 1 шт - 0 руб','Клей — -1 шт — 10 руб','Клей — 2 шт — 12,345 руб','Клей — abc','Клей — 1250']){
    status='invalid';await handler(request(text));assert(sent.at(-1).text.includes('Не удалось разобрать'));
  }
  status='unit_mismatch';await handler(request('Бумага — 5 шт — 100 руб'));assert(sent.at(-1).text.includes('единица измерения'));
  status='inactive_material';await handler(request('Клей — 5 шт — 100 руб'));assert(sent.at(-1).text.includes('Материал отключён'));
  status='inactive';let n=sent.length;await handler(request('Клей — 2 шт — 10 руб'));assert.equal(sent.length,n);
  status='expired';await handler(request('Клей — 2 шт — 10 руб'));assert(sent.at(-1).text.includes('истекло'));
  status='cancelled';await handler(request('Отмена'));assert.equal(calls.at(-1).args.p_action,'cancel');
  await handler(request('🛒 Закупка'));assert(calls.some(c=>c.name==='telegram_workshop_receipt'&&c.args.p_action==='cancel'));
  n=sent.length;await handler(request('Приход','group'));assert.equal(sent.length,n);
  allowed=false;await handler(request('Приход'));assert.equal(sent.length,n);allowed=true;
  failDb=true;assert.equal((await handler(request('Приход'))).status,503);failDb=false;
  failSend=true;status='saved';assert.equal((await handler(request('Клей — 2 шт — 10 руб'))).status,503);
  console.log('PASS: receipt menu, private recipient access, ruble parsing, escaping, invalid/expired input, cancellation, retryable failures');
})().catch(e=>{console.error(e);process.exitCode=1});
