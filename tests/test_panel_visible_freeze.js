const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const elements = new Map();
const element = id => { if (!elements.has(id)) elements.set(id, { value: '', disabled: false, textContent: '', setAttribute() {} }); return elements.get(id); };
let calls = [], messages = [], refreshes = 0;
const context = vm.createContext({
  console, Set, Map, URLSearchParams,
  document: { getElementById: element },
  confirm: () => true,
  apiPostText: async (url, body) => { calls.push({ url, body }); return { done: body.trim().split('\n').length, total: body.trim().split('\n').length }; },
  toast: text => messages.push(text), toastErr: (text, error) => messages.push(text + error.message),
});
const source = fs.readFileSync('webpanel/www/js/pages/strategies.js', 'utf8').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
vm.runInContext(source, context);
vm.runInContext('loadState = async () => refreshTestState()', context);
context.refreshTestState = () => { refreshes++; };
const run = code => vm.runInContext(code, context);
const entries = [
  { key: 'rkn_tcp', host: 'discord.com|4', mode: 'auto', strategy: 2 },
  { key: 'quic', host: 'discord.media|6', mode: 'frozen', strategy: 5 },
  { key: 'rkn_tcp', host: 'example.org|4', mode: 'auto', strategy: 3 },
  { key: 'discord_udp', host: 'nohost', mode: 'auto', strategy: 1 },
];
async function main() {
  context.fixture = entries; run('stateCache = fixture');
  element('state-search').value = ' DiSc ';
  run('updateVisibleFreezeButton()');
  assert.match(element('state-freeze-visible').textContent, /Заморозить найденные.*2/);
  await run('stateFreezeVisible()');
  assert.equal(calls.length, 2);
  assert(calls.every(c => !c.body.includes('example.org') && !c.body.includes('nohost')));
  assert(calls.every(c => c.url.includes('action=freeze')));
  assert.equal(refreshes, 1);
  calls = []; element('state-search').value = '';
  await run('stateFreezeVisible()');
  assert.equal(calls.reduce((n, c) => n + c.body.trim().split('\n').length, 0), 3);
  calls = []; element('state-search').value = 'discord.media';
  run('updateVisibleFreezeButton()');
  assert.match(element('state-freeze-visible').textContent, /Разморозить найденные.*1/);
  await run('stateFreezeVisible()');
  assert(calls[0].url.includes('action=unfreeze'));
  element('state-search').value = 'nothing'; calls = [];
  run('updateVisibleFreezeButton()');
  assert.equal(element('state-freeze-visible').disabled, true);
  await run('stateFreezeVisible()'); assert.equal(calls.length, 0);
  context.confirm = () => false; element('state-search').value = '';
  await run('stateFreezeVisible()'); assert.equal(calls.length, 0);
  context.confirm = () => true;
  element('state-search').value = 'disc'; calls = [];
  const post = context.apiPostText;
  let release;
  context.apiPostText = async (url, body) => {
    calls.push({url, body});
    if (calls.length === 1) await new Promise(resolve => { release = resolve; });
    return {done: 1};
  };
  const pending = run('stateFreezeVisible()');
  assert.equal(element('state-freeze-visible').disabled, true);
  element('state-search').value = 'example';
  await run('stateFreezeVisible()'); assert.equal(calls.length, 1);
  release(); await pending;
  assert.equal(calls.length, 2);
  assert(calls.every(c => !c.body.includes('example.org')));
  calls = []; messages = []; element('state-search').value = 'disc';
  context.apiPostText = async (url, body) => {
    calls.push({url, body});
    if (calls.length === 2) throw new Error('offline');
    return {done: 1};
  };
  await run('stateFreezeVisible()');
  assert(messages.some(m => m.includes('1 из 2') && m.includes('offline')));
  assert.equal(element('state-freeze-visible').disabled, false);
  context.apiPostText = post; calls = []; element('state-search').value = '';
  context.fixture = Array.from({length: 600}, (_,i) => ({key: 'rkn_tcp', host: i + '.' + 'a'.repeat(110) + '.com|4', mode: 'auto'}));
  run('stateCache = fixture'); await run('stateFreezeVisible()');
  assert(calls.length > 1); assert(calls.every(c => Buffer.byteLength(c.body) < 65536));
  assert.equal(calls.reduce((n,c) => n+c.body.trim().split('\n').length,0),600);
  console.log('PASS: filtering, pools, unfreeze, empty, cancellation, snapshot, busy, failure and chunking');
}
main().catch(e => { console.error(e); process.exitCode = 1; });
