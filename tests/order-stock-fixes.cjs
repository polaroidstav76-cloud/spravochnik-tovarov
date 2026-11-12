const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {parseHTML}=require('linkedom');
const html=fs.readFileSync('index.html','utf8');
for(const m of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi))if(m[1].trim())new vm.Script(m[1]);
const {document}=parseHTML('<body><div id="stockBody"></div></body>');
Object.defineProperty(document.defaultView.HTMLSelectElement.prototype,'value',{get(){return this.querySelector('option[selected]')?.value||this.querySelector('option')?.value||''},set(v){this.querySelectorAll('option').forEach(o=>o.toggleAttribute('selected',o.value===String(v)))}});
let calls=[];
const ctx=vm.createContext({document,window:{},isAdmin:false,stk:{},stkDrawBuy:null,$:id=>document.getElementById(id),esc:s=>String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;'),stkPlaces:()=>[{id:5,name:'Филиал'}],stkMyBranch:()=>5,stkBranches:()=>[{id:5}],stkBranchName:()=> 'Филиал',stkCanWork:()=>true,stkActor:()=>({p_shift_id:1,p_person_id:2}),stkDrawBadge(){},localStorage:{getItem:()=>null,setItem(){}},db:{auth:{getUser:async()=>({data:{user:{id:'staff'}}})},from:()=>({select:()=>({order:async()=>({data:[{id:10,name:'Бумага',code:'5976',active:true}]})})}),rpc:async(name,args)=>{calls.push({name,args});return name==='stock_purchase_live'?{data:{requests:[]}}:{data:1}}}});
vm.runInContext(fs.readFileSync('purchase-rounds.js','utf8'),ctx);
(async()=>{
 await ctx.window.stkDrawBuy();
 document.getElementById('prSearch').value='Товар которого нет';document.getElementById('prSearch').oninput();
 await document.getElementById('prAdd').onclick();
 assert(calls.some(c=>c.name==='purchase_free_request_add'&&c.args.p_name==='Товар которого нет'&&c.args.p_qty===null));
 document.querySelector('[data-pick]').onclick();await document.getElementById('prAdd').onclick();
 assert(calls.some(c=>c.name==='purchase_request_add'&&c.args.p_item_id===10));
 document.getElementById('prFreeName').value='Ручное название';await document.getElementById('prAdd').onclick();
 assert(calls.some(c=>c.name==='purchase_free_request_add'&&c.args.p_name==='Ручное название'));
 // Receipt input is retained without selecting any dropdown option, including after rerender.
 let combo;ctx.stk={opKind:'receipt',opRows:[{m:'',q:'3',p:'75'}]};
 Object.assign(ctx,{stkOpBranch:()=>5,stkStockMats:()=>[],stkMaterials:()=>[],stkCombo:(host,o)=>{combo=o},stkOpItems:()=>[],stkQty:String,stkBalanceVisible:()=>false,stkBal:()=>0,salesMoney:String,stkLoad:async()=>{},stkDrawOp:()=>{}});
 document.body.innerHTML='<div id="stkOpRows"></div><div id="stkOpStatus"></div><button id="stkSave"></button><input id="stkComment"><input id="stkSupplier">';
 const start=html.indexOf('function stkDrawOpRows()'),end=html.indexOf('// --- Кто выполнил заказ ---',start);
 vm.runInContext(html.slice(start,end),ctx);ctx.stkDrawOpRows();assert.equal(combo.free,true);combo.onInput('Новый материал');
 ctx.stkDrawOpRows();assert.equal(combo.value,'Новый материал');await ctx.stkSaveOp();
 const receipt=calls.find(c=>c.name==='stock_operation');assert.equal(receipt.args.p_items[0].name,'Новый материал');assert.equal(receipt.args.p_items[0].qty,3);assert.equal(receipt.args.p_items[0].material_id,null);
 // Existing pending order can be edited and saved again, or paid through the original payment route.
 const el={};const get=id=>el[id]||(el[id]={value:'',checked:false,style:{},classList:{contains:()=>true},focus(){}});
 const order={id:90,status:'pending',order_number:123,branch_id:5,items:[{catalog_id:10,quantity:1,unit_price:20}],client_name:'Контакт',client_order_ref:'Р-1',total:20};
 let rpc=[];const pc={window:null,$:get,salePickup:null,saleDraft:[],pickupOrders:[order],salesSession:{shiftId:1,branchId:5},saleLoyaltyCustomerId:null,pickupLastResult:null,pickupRpcOverride:null,loadPickups:async()=>{},close(){},alert(s){throw Error(s)},confirm:()=>true,setPickupOptionAvailable:on=>{pc.available=on},renderSaleDraft(){},syncPickupHoldBox(){},esc:String,v5Date:String,pickupClient:o=>o.client_name,salesMoney:String,v5Digits:s=>s.replace(/\D/g,''),salePointsUsed:()=>0,pickupFinal:()=>false,v5Toast(){},db:{rpc:async()=>({data:[]})},v5Rpc:async(name,args)=>{rpc.push({name,args});return {data:123}},openSaleV4:async()=>{pc.salePickup=null},openSalesWorkspace:async()=>{}};pc.window=pc;
 get('saveSale').onclick=async()=>pc.pickupRpcOverride({p_shift_id:1,p_employee_id:2,p_items:pc.saleDraft.map(i=>({catalog_id:i.catalogId,quantity:i.quantity,unit_price:i.unitPrice})),p_discount_percent:0,p_order_number:999,p_payment_method:get('salePayment').value});get('salePayment').onchange=()=>{};
 const pctx=vm.createContext(pc);vm.runInContext(html.slice(html.indexOf('const v5BaseSave='),html.indexOf('// При выборе клубной карты напоминаем')),pctx);
 await pc.startPickupPayment(90);assert.equal(pc.available,true);assert.equal(get('salePickupContact').value,'Контакт');assert.equal(get('salePickupRef').value,'Р-1');
 pc.saleDraft.push({catalogId:11,quantity:2,unitPrice:30});get('salePayment').value='on_pickup';await get('saveSale').onclick();
 assert.equal(rpc[0].name,'sales_update_pickup');assert.equal(rpc[0].args.p_pickup_id,90);assert.equal(rpc[0].args.p_items.length,2);assert(!('p_order_number' in rpc[0].args));
 get('salePayment').value='cash';await get('saveSale').onclick();assert.equal(rpc[1].name,'sales_pay_pickup');assert.equal(rpc[1].args.p_pickup_id,90);
 console.log('PASS: purchase search/free/catalog input; free receipt persistence and payload; existing pickup amendment, same ID and payment route; all inline script syntax');
})().catch(e=>{console.error(e);process.exitCode=1});
