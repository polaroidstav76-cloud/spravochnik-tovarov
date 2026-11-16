const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {parseHTML}=require('linkedom');const H=require('../workflow-helpers.js');
const source=fs.readFileSync(require('node:path').join(__dirname,'../cashdesk-workflow.js'),'utf8');
function harness(){
 const markup=`<body><button id="salesBtn"></button><button id="reportsBtn"></button><div id="saleModal" class="modal show"><div class="dialog"><button id="closeSale"></button><button id="saveSale"></button><div class="field"><label>Max</label><input id="salePointsMax"></div><input id="salePointsToUse" value="0"><input id="saleDiscountPercent" value="0"><input id="saleClubEnabled" type="checkbox"><input id="saleClubNewPhone" value="9001234567"><input id="saleClubQuery"><input id="clubLookup"><div id="saleLoyaltyBalance"></div><input id="saleUsePoints" type="checkbox"><div id="saleClubResults"></div><div id="saleClubStatus"></div><div id="saleStatus"></div></div></div></body>`;
 const {document,window}=parseHTML(markup);const $=id=>document.getElementById(id);let confirmations=true,saves=0,opens=0,purchaseCalls=0;
 const timers=[],intervals=[],alerts=[],storage=new Map(),rpcCalls=[];let checkRows=[];let matches=[];
 const ctx={document,CloudshopWorkflow:H,console,Date,Number,String,Array,Set,Math,Promise,Event:window.Event,
  $:id=>document.getElementById(id),staffAccount:{user_id:'owner',role:'staff'},isAdmin:false,salesSession:{shiftId:1,branchId:5},saleContext:{shiftId:1},saleDraft:[{catalogId:1,quantity:2,unitPrice:50}],saleLoyaltyCustomerId:'client',saleLoyaltyCustomer:{balance:20},salePickup:null,saleClubLookupSerial:0,saleClubNeedsSelection:false,
  open:id=>$(id)?.classList.add('show'),close:id=>$(id)?.classList.remove('show'),openSaleV4:async()=>{opens++;ctx.saleDraft=[];$('saleModal').classList.add('show');},startPickupPayment:async()=>{purchaseCalls++;},updateSaleTotal:()=>{},saleGrossTotal:()=>100,salePointsUsed:()=>Number($('salePointsToUse').value||0),salesMoney:value=>String(value),validClubPhone:value=>/^9\d{9}$/.test(value),clubPhoneValue:value=>'7'+value,showSaleClubMatches:rows=>{ctx.saleLoyaltyCustomerId=rows[0]?.customer_id;},loadCustomerAdminRows:async()=>{},stkSaveOp:async()=>undefined,stk:{opKind:'receipt'},v5Toast:msg=>alerts.push(msg),ckDue:()=>null,openChecks:()=>{},updateSalesSessionUI:()=>{},
  confirm:()=>confirmations,alert:text=>alerts.push(text),setTimeout:fn=>{timers.push(fn);return timers.length;},setInterval:fn=>{intervals.push(fn);return intervals.length;},clearTimeout:()=>{},
  localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v)},
  db:{rpc:async(name,args)=>{rpcCalls.push([name,args]);return{data:name==='loyalty_find_customers'?matches:[]};},from:()=>({select(){return this;},eq(){return this;},neq(){return this;},order:async()=>({data:checkRows.filter(r=>r.readiness!=='Готово')})})},
 };
 ctx.window=ctx;ctx.addEventListener=window.addEventListener.bind(window);
 $('saveSale').onclick=async()=>{saves++;};vm.createContext(ctx);vm.runInContext(source,ctx);
 return{ctx,document,$,alerts,timers,intervals,rpcCalls,confirm:value=>confirmations=value,get saves(){return saves;},get opens(){return opens;},setRows:rows=>checkRows=rows,setMatches:rows=>matches=rows};
}
(async()=>{
 let h=harness();const original=h.ctx.saleDraft;
 h.$('minimizeSale').onclick();assert(!h.$('saleModal').classList.contains('show'));assert.equal(h.$('resumeSaleDraft').hidden,false);assert.equal(h.ctx.saleDraft,original);assert.equal(h.ctx.saleLoyaltyCustomerId,'client');
 await h.ctx.openSaleV4();assert(h.$('saleModal').classList.contains('show'));assert.equal(h.opens,0);assert.equal(h.ctx.saleDraft,original);
 h.confirm(false);h.$('closeSale').onclick();assert(h.$('saleModal').classList.contains('show'));assert.equal(h.ctx.saleDraft.length,1);
 h.confirm(true);h.$('closeSale').onclick();assert(!h.$('saleModal').classList.contains('show'));assert.equal(h.ctx.saleDraft.length,0);
 h=harness();h.ctx.updateSaleTotal();assert.equal(h.$('salePointsMax').value,'20');h.$('salePointsToUse').value='30';await h.$('saveSale').onclick();assert.equal(h.saves,0);assert(h.$('saleStatus').textContent.includes('20'));
 h.$('salePointsToUse').value='20';await h.$('saveSale').onclick();assert.equal(h.saves,1);
 h=harness();h.$('minimizeSale').onclick();h.ctx.salesSession={shiftId:2,branchId:8};await h.ctx.openSaleV4();assert.equal(h.opens,0);assert.equal(h.$('resumeSaleDraft').hidden,false);assert(h.alerts.some(x=>x.includes('другой смене')));
 h=harness();h.ctx.saleDraft=[];h.$('saveSale').disabled=true;h.$('closeSale').onclick();assert(!h.$('saleModal').classList.contains('show'));
 h=harness();await h.ctx.stkSaveOp();assert.equal(h.rpcCalls.length,0,'Failed stock input must not claim that receipt was saved');
 h=harness();h.setRows([{id:1,order_no:'12',branch_id:5,product:'Холст',deadline:'1 час',created_at:new Date(Date.now()-30*60000).toISOString(),readiness:'В работе'}]);await h.timers[0]();assert.equal(h.$('workflowDeadlineBanner').hidden,false);assert(h.$('workflowDeadlineBanner').textContent.includes('предупредите клиента'));
 h.$('wfDeadlineAck').onclick();await h.intervals[0]();assert.equal(h.$('workflowDeadlineBanner').hidden,true,'Same deadline must not notify every minute after acknowledgment');
 assert.equal(H.pointLimit(100,20),20);assert.equal(H.pointLimit(100,50),30);assert.equal(H.pointLimit(50,20),15);assert.equal(H.pointLimit(100,-5),0);
 for(const [text,hours] of [['1-2 дня',48],['5 ч',5],['1,5 часа',1.5],['1 час 30 мин',1.5]]){const start='2026-11-16T10:00:00+03:00';const d=H.deadline({deadline:text,created_at:start});assert.equal((d.end-Date.parse(start))/3600000,hours);assert.equal(d.end-d.warn,3600000);}
 assert.equal(H.deadline({deadline:'31.02.2026',created_at:'2026-02-01'}),null);
 console.log('Cashdesk UI: minimize/restore, discard confirmation, shift isolation, balance cap, success-only receipt status, deadlines and acknowledgment passed');
})().catch(e=>{console.error(e);process.exitCode=1});
