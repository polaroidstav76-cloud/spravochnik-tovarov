const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(require('node:path').join(__dirname, '../index.html'), 'utf8');
let scripts = 0;
for (const m of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
  if (m[1].trim()) { new vm.Script(m[1]); scripts++; }
}
const source = html.slice(html.indexOf('function stkBuyCount'), html.indexOf('// --- Материалы и нормы'));
const requests = [
  { id: 1, name: 'Купленная бумага', status: 'bought', urgent: true, created_at: '2026-01-01' },
  { id: 2, name: 'Обычная бумага', status: 'open', urgent: false, created_at: '2026-01-01' },
  { id: 3, name: 'Срочная бумага', material_id: 7, branch_id: 8, qty: 100, unit: 'лист', status: 'open', urgent: true, created_at: '2026-01-02' },
  { id: 4, name: '<скотч>', status: 'unavailable', created_at: '2026-01-03' },
];
const els = { stockBody: {}, stkBuyCopy: {}, stkBuyPrint: {} };
let copied, error = false, calls = [];
const ctx = vm.createContext({
  window: {}, stk: {}, isAdmin: true,
  $: id => els[id], esc: s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
  stkDrawBadge() {}, stkCanWork: () => false, stkQty: String, v5Date: String,
  stkBranchName: () => 'Тухачевского 26/4', stkMaterials: () => [{ id: 7, purchase_code: 'CODE-7' }],
  navigator: { clipboard: { writeText: async t => { copied = t; } } }, v5Toast() {}, alert() {},
  db: { rpc: async (name, args) => {
    calls.push({ name, args });
    if (name === 'stock_purchase_live') return { data: { rows: [{ name: 'Авторасчёт' }], requests } };
    if (error) return { error: { message: 'Ошибка сети' } };
    requests.find(r => r.id === args.p_id).status = args.p_status;
    return {};
  } },
});
vm.runInContext(source, ctx);
(async () => {
  await ctx.stkDrawBuy();
  let body = els.stockBody.innerHTML;
  assert(!body.includes('Авторасчёт'));
  assert(body.indexOf('<b style="">Срочная бумага') < body.indexOf('<b style="">Обычная бумага'));
  assert(body.indexOf('Обычная бумага') < body.indexOf('text-decoration:line-through'));
  assert(body.includes('CODE-7') && body.includes('Тухачевского 26/4') && body.includes('&lt;скотч&gt;'));
  assert.equal(ctx.stkBuyCount(), 3);
  await els.stkBuyCopy.onclick();
  assert(copied.includes('СРОЧНО!') && !copied.includes('Купленная бумага'));
  ctx.isAdmin = false;
  await ctx.stkDrawBuy();
  assert(!els.stockBody.innerHTML.includes('type="checkbox"'));
  ctx.isAdmin = true;
  await ctx.window.stkRequestToggle(3, { checked: true });
  assert.equal(requests.find(r => r.id === 3).status, 'bought');
  await ctx.window.stkRequestToggle(3, { checked: false });
  assert.equal(requests.find(r => r.id === 3).status, 'open');
  assert(!calls.some(c => c.name === 'stock_operation'));
  error = true;
  const input = { checked: true };
  await ctx.window.stkRequestToggle(3, input);
  assert.equal(input.checked, false);
  assert.equal(input.disabled, false);
  console.log(`PASS: ${scripts} inline scripts parsed; manual list, urgency, codes, export, roles, toggles, save failure`);
})().catch(e => { console.error(e); process.exitCode = 1; });
