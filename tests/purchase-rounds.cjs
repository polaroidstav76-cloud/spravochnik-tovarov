const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const root=path.join(__dirname,'..');
const catalogue=JSON.parse(fs.readFileSync(path.join(root,'purchase-catalog.json'),'utf8'));
assert.equal(catalogue.length,31);assert.equal(catalogue[0].code,'7789');assert.equal(catalogue.at(-1).code,'5976');
assert(!catalogue.some(x=>x.code==='4504'));assert(catalogue.every(x=>Object.keys(x).sort().join(',')==='code,name'));
const source=fs.readFileSync(path.join(root,'purchase-rounds.js'),'utf8');new vm.Script(source);
const ctx=vm.createContext({window:{},stkDrawBuy:null,stkBranchName:id=>({5:'Тухачевского 26/4',8:'Тухачевского 26/10',7:'Доваторцев 84/6'})[id]});
vm.runInContext(source.replace(/\}\)\(\);\s*$/,`globalThis.test={archived,remaining,payload,preview,set:(r,d)=>{requests=r;draft=d}};})();`),ctx);
const requests=[{id:1,supplier_code:'5976',name:'Бумага А3',branch_id:5,qty:8,ordered_qty:3},{id:2,supplier_code:'4812',name:'Двусторонняя бумага',branch_id:8,qty:3,ordered_qty:0}];
ctx.test.set(requests,{selected:{1:5,2:3},manual:[{code:'1111',name:'Ручная строка',qty:'10',branch_id:'7'}],notes:'Позвонить перед доставкой'});
assert.equal(ctx.test.remaining(requests[0]),5);assert.equal(ctx.test.remaining({qty:null}),null);assert.equal(ctx.test.remaining({qty:2,ordered_qty:5}),0);
const p=JSON.parse(JSON.stringify(ctx.test.payload()));assert.equal(p.length,3);assert.equal(p[2].branch_id,7);assert.equal(p[2].qty,10);
const text=ctx.test.preview();assert(text.includes('5976 — 5 шт — Тухачевского 26/4'));assert(text.includes('4812 — 3 шт — Тухачевского 26/10'));assert(text.includes('1111 — 10 шт — Доваторцев 84/6'));assert(text.includes('Позвонить перед доставкой'));
assert.equal(ctx.test.archived({status:'bought',closed_at:new Date(Date.now()-13*86400000).toISOString()}),false);assert.equal(ctx.test.archived({status:'bought',closed_at:new Date(Date.now()-15*86400000).toISOString()}),true);assert.equal(ctx.test.archived({status:'open',closed_at:new Date(Date.now()-15*86400000).toISOString()}),false);assert.equal(ctx.test.archived({status:'bought',closed_at:null}),false);
console.log('PASS: PDF cutoff, no prices, partial quantities, manual additions, per-branch distribution, notes, script syntax');

