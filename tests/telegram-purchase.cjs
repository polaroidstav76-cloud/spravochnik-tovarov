const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { stripTypeScriptTypes } = require('node:module');
const source = fs.readFileSync(require('node:path').join(__dirname, '../supabase/functions/telegram-purchase/index.ts'), 'utf8').replace(/^import .*;\s*/m, '');
let handler, allowed = true, sent = [], rows = [];
const context = {
  Response, Request, Date,
  Deno: { env: { get: () => 'test' }, serve: fn => { handler = fn; } },
  createClient: () => ({ rpc: async name => ({ data: name === 'telegram_purchase_config' ? { token: 'test-token', secret: 'secret' } : allowed ? rows : null }) }),
  fetch: async (url, req) => { sent.push(JSON.parse(req.body)); return Response.json({ ok: true }); },
};
vm.runInNewContext(stripTypeScriptTypes(source), context);
const request = (text, secret = 'secret') => new Request('https://test.local', { method: 'POST', headers: { 'X-Telegram-Bot-Api-Secret-Token': secret }, body: JSON.stringify({ message: { chat: { id: 123 }, text } }) });
(async () => {
  assert.equal((await handler(request('/start', 'wrong'))).status, 403);
  allowed = false;
  await handler(request('/purchase'));
  assert.equal(sent.length, 0);
  allowed = true;
  await handler(request('/start'));
  assert(sent[0].text.includes('Открытых заявок нет'));
  assert.equal(sent[0].reply_markup.keyboard[0][0].text, '🛒 Закупка');
  sent = [];
  rows = Array.from({ length: 30 }, () => ({ name: '<Бумага>', branch: 'Тухачевского 26/4', code: '10&15', urgent: true, qty: 100, unit: 'лист', comment: '&'.repeat(100) }));
  await handler(request('🛒 Закупка'));
  assert(sent.length > 1);
  assert(sent.every(m => m.text.length <= 4096));
  assert(sent[0].text.includes('&lt;Бумага&gt;') && sent[0].text.includes('10&amp;15'));
  assert.equal(sent.map(m => (m.text.match(/&lt;Бумага&gt;/g) || []).length).reduce((a, b) => a + b), 30);
  console.log('PASS: Telegram secret, recipient access, keyboard, empty list, HTML escaping, full pagination');
})().catch(e => { console.error(e); process.exitCode = 1; });
