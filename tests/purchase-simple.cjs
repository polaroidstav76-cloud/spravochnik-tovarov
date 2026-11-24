const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),{parseHTML}=require('linkedom');
const source=fs.readFileSync('purchase-rounds.js','utf8');
async function setup(){
 const {document}=parseHTML('<body><div id="stockBody"></div></body>');const calls=[];let fail=false,branch=8,shift=50;
 const items=[{id:1,name:'Мат 21×30, 230 г/м',code:'4670',active:true},{id:2,name:'Глянец 10х15',code:'7789',active:true},{id:3,name:'Мат 21х30 старый',code:'old',active:false}];
 const ctx={document,window:{},isAdmin:false,stk:{},stkDrawBuy:null,$:id=>document.getElementById(id),esc:s=>String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;'),stkPlaces:()=>[{id:8,name:'Тухачевского 26/10'}],stkMyBranch:()=>branch,stkBranches:()=>[{id:8}],stkBranchName:id=>id===8?'Тухачевского 26/10':'Другой филиал',stkCanWork:()=>true,stkActor:()=>({p_shift_id:shift,p_person_id:2}),stkDrawBadge(){},v5Toast:t=>ctx.toast=t,localStorage:{getItem:()=>null,setItem(){}},db:{auth:{getUser:async()=>({data:{user:{id:'staff'}}})},from:()=>({select:()=>({order:async()=>({data:items})})}),rpc:async(name,args)=>{calls.push({name,args});if((name==='stock_purchase_live'||name==='purchase_branch_view'))return{data:{requests:[]}};return fail?{error:{message:'Нет связи'}}:{data:100};}}};
 vm.createContext(ctx);vm.runInContext(source,ctx);await ctx.window.stkDrawBuy();return {ctx,document,calls,fail:v=>fail=v,change:()=>{branch=5;shift=99;}};
}
(async()=>{
 const h=await setup(),$=id=>h.document.getElementById(id);
 assert($('prCurrentRequests').nextElementSibling.id==='prBranchHistory');assert($('prBranchHistory').nextElementSibling.contains($('prSearch')));assert.equal($('prFreeName'),null);assert.equal($('prFreeCode'),null);assert.equal($('prBranch'),null);assert($('prAutoBranch').textContent.includes('Тухачевского 26/10'));
 for(const q of ['21х30 мат','мат 21x30','21 х 30 МАТ']){$('prSearch').value=q;$('prSearch').oninput();assert.equal(h.document.querySelectorAll('[data-pick]').length,1);assert.equal(h.document.querySelector('[data-pick]').dataset.pick,'1');}
 h.document.querySelector('[data-pick]').onclick();assert.equal($('prSearch').value,'Мат 21×30, 230 г/м');await $('prAdd').onclick();
 let req=h.calls.find(x=>x.name==='purchase_request_add');assert.equal(req.args.p_item_id,1);assert.equal(req.args.p_branch_id,8);assert($('prAdded').textContent.includes('✅'));assert(h.ctx.toast.includes('Тухачевского 26/10'));
 $('prSearch').value='Необычный <товар>';$('prSearch').oninput();assert.equal(h.document.querySelectorAll('[data-pick]').length,0);assert($('prCatalog').textContent.includes('Название уже введено'));
 h.fail(true);await $('prAdd').onclick();assert.equal($('prSearch').value,'Необычный <товар>');assert($('prStatus').textContent.includes('Нет связи'));assert.equal($('prAdd').disabled,false);
 h.fail(false);await $('prAdd').onclick();req=h.calls.filter(x=>x.name==='purchase_free_request_add').at(-1);assert.equal(req.args.p_name,'Необычный <товар>');assert.equal(req.args.p_code,null);assert.equal(req.args.p_branch_id,8);assert.equal($('prAdded').querySelector('товар'),null);
 $('prSearch').value='Ещё товар';$('prSearch').oninput();h.change();const count=h.calls.length;await $('prAdd').onclick();assert.equal(h.calls.length,count);assert($('prStatus').textContent.includes('Смена изменилась'));
 console.log('PASS simple purchase: unified name input, word-order/size search, catalogue choice, free item without code, automatic shift branch, success banner/toast, retained input on errors and changed-shift protection');
})().catch(e=>{console.error(e);process.exitCode=1;});
