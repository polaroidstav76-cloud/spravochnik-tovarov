const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const helpers=html.slice(html.indexOf('const STK_BALANCE_MATERIALS_BY_SKU'),html.indexOf('// --- Операции: приход'));
const sale=html.slice(html.indexOf('function saleStockLine(c)'),html.indexOf('async function saleStockRefresh'));
const material=(id,name,extra={})=>({id,name,unit:'шт',norms:[],...extra});
const materials=[material(5,'Кружка белая'),material(32,'Футболка',{var_sizes:['S']}),material(82,'Футболка белая S',{parent_id:32,var_size:'S'}),material(149,'Пенокартон'),material(171,'ПВХ'),material(999,'Скрытая бумага')];
const table={};
const ctx=vm.createContext({stk:{balSearch:'',data:{},lowOnly:false},$:()=>table,
  stkMaterials:()=>materials,stkPlaces:()=>[{id:1,name:'Филиал'}],stkMyBranch:()=>1,
  stkHasVars:m=>!!m.var_sizes?.length,stkIsLow:()=>false,stkUse:()=>0,stkBal:id=>id===999?777:12,
  stkQty:String,esc:String,stkStoreNote:()=>'',stkWorkshop:()=>null,stkBranchName:()=>''});
vm.runInContext(helpers+'\n'+sale,ctx);
ctx.stkDrawBalRows();
assert(table.innerHTML.includes('Кружка белая')&&table.innerHTML.includes('↳ <b>S</b>')&&table.innerHTML.includes('ПВХ'));
assert(!table.innerHTML.includes('Скрытая бумага')&&!table.innerHTML.includes('777'));
assert.equal(ctx.stkBal(999,1),777); // Скрытый материал остаётся в данных и учитывается.
assert.equal(materials.length,6);
ctx.stk.balSearch='051';ctx.stkDrawBalRows();
assert(table.innerHTML.includes('↳ <b>S</b>')&&!table.innerHTML.includes('Кружка белая'));
ctx.stk.balSearch='';
assert(ctx.saleStockLine({sku:'025'}).includes('Остаток:'));
assert.equal(ctx.saleStockLine({sku:'999'}),'');
assert(ctx.saleStockLine({id:66,sku:'079'}).includes('Остаток:'));
assert.equal(ctx.saleStockLine({id:114,sku:'079'}),'');
assert(ctx.saleStockLine({sku:'131'}).includes('Остаток:'));
console.log('PASS: selected stock, size/color variants, SKU search, cashier indicators, hidden accounting retained');
