const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {parseHTML}=require('linkedom');const html=fs.readFileSync('index.html','utf8');
for(const m of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi))if(m[1].trim())new vm.Script(m[1]);
const {document,window}=parseHTML('<body>'+['saleClubSearchBtn','saleClubNewPhone','saleClubQuery','saleLoyaltyBalance','saleUsePoints','salePointsToUse','salePointsFields','saleClubStatus','saleClubResults'].map(id=>`<div><input id="${id}"></div>`).join('')+'</body>');
const box=document.createElement('div');box.id='saleClubResults';document.getElementById('saleClubResults').replaceWith(box);
let rows=[],chosen=null;
const ctx=vm.createContext({document,window,$:id=>document.getElementById(id),saleLoyaltyCustomerId:'old',saleLoyaltyCustomer:{},esc:s=>String(s??'').replace(/</g,'&lt;').replace(/"/g,'&quot;'),salesMoney:String,updateSaleTotal(){},selectSaleLoyaltyCustomer:c=>{chosen=c.customer_id;vm.runInContext('saleClubNeedsSelection=false',ctx)},db:{rpc:async()=>({data:rows})}});
const a=html.indexOf('let saleClubNeedsSelection='),b=html.indexOf('function renderLoyaltyCustomer',a);vm.runInContext(html.slice(a,b),ctx);
for(const number of ['+7 (900) 123-45-67','8 900 1234567','9001234567']){assert.equal(ctx.clubPhoneNational(number),'9001234567');assert.equal(ctx.normalizePhone(number),'79001234567');assert.equal(ctx.validClubPhone(number),true)}
assert.equal(ctx.normalizePhone('4567'),'4567');assert.equal(ctx.validClubPhone('1234'),false);assert.equal(ctx.validClubPhone('790012345678'),false);
const input=document.getElementById('saleClubNewPhone');for(const value of ['+7','8','+7 900 1234567','89001234567']){input.value=value;input.dispatchEvent(new window.Event('input'));assert.equal(input.value,value==='+7'||value==='8'?'':'9001234567')}
const start=html.indexOf('function showSaleClubMatches'),end=html.indexOf("$('saleUsePoints').onchange=",start);vm.runInContext(html.slice(start,end),ctx);
(async()=>{
 rows=[{customer_id:'one',customer_name:'Первый',customer_phone:'+79001234567',balance:10,order_count:1},{customer_id:'two',customer_name:'Второй',customer_phone:'+79111234567',balance:20,order_count:2}];
 document.getElementById('saleClubQuery').value='4567';await document.getElementById('saleClubSearchBtn').onclick();assert.equal(chosen,null);assert.equal(ctx.saleLoyaltyCustomerId,null);assert.equal(vm.runInContext('saleClubNeedsSelection',ctx),true);assert(box.innerHTML.includes('полный номер'));
 document.getElementById('saleClubQuery').value='89001234567';rows=[rows[0]];await document.getElementById('saleClubSearchBtn').onclick();assert.equal(chosen,'one');assert.equal(vm.runInContext('saleClubNeedsSelection',ctx),false);
 chosen=null;rows.push({...rows[0],customer_id:'legacy',customer_name:'Старая карта'});await document.getElementById('saleClubSearchBtn').onclick();assert.equal(chosen,null);const buttons=box.querySelectorAll('[data-club-match]');assert.equal(buttons.length,2);buttons[1].onclick();assert.equal(chosen,'legacy');
 assert(html.includes('<span aria-hidden="true">+7</span>'));
 console.log('PASS: fixed +7 prefix; typing/paste normalization; invalid-length validation; suffix ambiguity and explicit selection for duplicated full numbers; scripts parse');
})().catch(e=>{console.error(e);process.exitCode=1});
