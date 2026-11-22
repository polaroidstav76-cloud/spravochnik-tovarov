const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),{parseHTML}=require('linkedom');
async function setup(admin=false){
 const {document}=parseHTML('<body><div id="stockBody"></div></body>');let rows=[{id:77,name:'<img src=x>',branch_id:5,branch_name:'Филиал',status:'open',ordered_qty:2,qty:5}],confirm=true,error=false,calls=[],saved;
 const query={select(){return this},order(){return this},limit:async()=>({data:[]}),then(r){r({data:[]});}};
 const ctx={document,window:{},isAdmin:admin,stk:{},stkDrawBuy:null,$:id=>document.getElementById(id),esc:s=>String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;'),stkPlaces:()=>[{id:5,name:'Филиал'}],stkMyBranch:()=>5,stkBranches:()=>[{id:5}],stkBranchName:()=> 'Филиал',stkCanWork:()=>false,stkActor:()=>({}),stkDrawBadge(){},confirm:()=>confirm,localStorage:{getItem:()=>JSON.stringify({selected:{77:3,999:1},manual:[],notes:''}),setItem:(k,v)=>saved=JSON.parse(v)},db:{auth:{getUser:async()=>({data:{user:{id:admin?'admin':'staff'}}})},from:()=>query,rpc:async(name,args)=>{calls.push({name,args});if((name==='stock_purchase_live'||name==='purchase_branch_view'))return{data:{requests:rows}};if(error)return{error:{message:'Позиция изменилась'}};rows=[];return{data:true};}}};
 vm.createContext(ctx);vm.runInContext(fs.readFileSync('purchase-rounds.js','utf8'),ctx);await ctx.window.stkDrawBuy();
 return{ctx,document,calls,get saved(){return saved},confirm:v=>confirm=v,error:v=>error=v};
}
(async()=>{
 for(const admin of [false,true]){
  const h=await setup(admin);assert(h.document.querySelector('[data-delete-request]'));assert.equal(h.document.querySelector('img'),null);assert(!('999' in h.saved.selected));
  h.confirm(false);await h.document.querySelector('[data-delete-request]').onclick();assert(!h.calls.some(x=>x.name==='stock_request_delete'));
  h.confirm(true);h.error(true);await h.document.querySelector('[data-delete-request]').onclick();assert(h.document.getElementById('prStatus').textContent.includes('изменилась'));assert(!h.document.querySelector('[data-delete-request]').disabled);
  h.error(false);await h.document.querySelector('[data-delete-request]').onclick();assert(!h.document.querySelector('[data-delete-request]'));assert(!('77' in h.saved.selected));
  const req=h.calls.find(x=>x.name==='stock_request_delete');assert.equal(req.args.p_id,77);assert.equal(req.args.p_expected_ordered_qty,2);assert.equal(req.args.p_expected_status,'open');
 }
 console.log('PASS purchase deletion: staff/admin controls, confirmation cancellation, stale error, selected draft cleanup, list refresh and escaped names');
})().catch(e=>{console.error(e);process.exitCode=1;});
