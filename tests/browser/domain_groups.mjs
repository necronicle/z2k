// Группы доменов на вкладке «Автоподбор» в настоящем браузере.
// Run against an isolated fixture server, never the live router:
//   python3 tests/browser/domain_groups_server.py &
//   PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node tests/browser/domain_groups.mjs
import assert from 'node:assert/strict';
const {chromium} = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const base = process.env.Z2K_PANEL_TEST_URL || 'http://127.0.0.1:18790';
assert.equal(new URL(base).hostname,'127.0.0.1','fixture server must be local');
const b=await chromium.launch({channel:'chrome',headless:true});
const errs=[];
try {
{
const p=await b.newPage({viewport:{width:1280,height:900}});
p.on('pageerror',e=>errs.push(e.message));
p.on('dialog',d=>d.accept());
const groups=async()=>(await (await p.request.get(base+'/cgi-bin/api/domain-groups',{headers:{'X-Z2K-Panel':'1'}})).json());
// Known starting point: a previous run (of this file or of
// domain_groups_buttons.mjs) leaves its groups and rows behind.
await p.request.get(base+'/cgi-bin/api/__test/reset',{headers:{'X-Z2K-Panel':'1'}});
{const g0=await groups();const r=await p.request.post(base+'/cgi-bin/api/domain-groups/save?revision='+g0.revision,{headers:{'X-Z2K-Panel':'1','Content-Type':'text/plain'},data:'# Мои сервисы\n[Discord]\ndiscord.com\ndiscord.media\ndiscordapp.net\n\n[YouTube]\nyoutube.com\ngooglevideo.com\nytimg.com\n'});assert.equal(r.status(),200);}
await p.goto(base+'/test?dark');await p.waitForSelector('.state-table');
// 1. assign apple.com to new group
await p.click('.ug-assign[data-domain="apple.com"]');
await p.selectOption('#ug-assign-group','-1');await p.fill('#ug-assign-name','Apple');
await p.click('#ug-assign-ok');await p.waitForSelector('.ug-assign-modal',{state:'detached'});
let g=await groups();assert.match(g.text,/\[Apple\]\napple\.com/);assert.match(g.text,/# Мои сервисы/);
await p.waitForSelector('tbody.ug[data-ug="2"]');
assert.equal(await p.locator('tbody[data-ug-of="2"][data-ug-closed]').count()>0,true,'новая группа свёрнута');
// 2. duplicate domain refused client-side
await p.locator('.ug-assign').first().click();
await p.fill('#ug-assign-domain','discord.com');await p.selectOption('#ug-assign-group','1');await p.click('#ug-assign-ok');
assert.match(await p.locator('#ug-assign-error').textContent(),/уже входит в группу «Discord»/);
await p.click('#confirm-cancel');
// 3. search by group name shows googlevideo rows
await p.fill('#state-search','tube');await p.waitForTimeout(200);
const html=await p.locator('#state-body').innerHTML();
assert.match(html,/googlevideo\.com/);assert.doesNotMatch(html,/chatgpt/);
assert.equal(await p.locator('tbody[data-ug-of="1"][data-ug-closed]').count(),0,'при поиске раскрыта');
await p.fill('#state-search','');
// 4. collapse/expand persists in localStorage, no network
await p.click('tbody.ug[data-ug="0"] .ug-head');
assert.match(await p.evaluate(()=>localStorage.getItem('z2k-state-open-ugroups')),/Discord/);
await p.reload();await p.waitForSelector('.state-table');
assert.equal(await p.locator('tbody[data-ug-of="0"][data-ug-closed]').count(),0,'раскрытие пережило перезагрузку');
// 5. rename group keeps open state
await p.click('tbody.ug[data-ug="0"] .ug-edit');await p.fill('#ug-name','Дискорд');await p.click('#ug-save');
await p.waitForSelector('#ug-editor[hidden]',{state:'attached'});
g=await groups();assert.match(g.text,/\[Дискорд\]/);
assert.match(await p.evaluate(()=>localStorage.getItem('z2k-state-open-ugroups')),/Дискорд/);
// 6. case-insensitive cyrillic duplicate refused
await p.click('#ug-new');await p.fill('#ug-name','дискорд');await p.fill('#ug-domains','x.org');await p.click('#ug-save');
assert.match(await p.locator('#ug-error').textContent(),/уже есть/);await p.click('#ug-cancel');
// 7. conflict from another device
const rev=g.revision;
await p.request.post(base+'/cgi-bin/api/domain-groups/save?revision='+rev,{headers:{'X-Z2K-Panel':'1','Content-Type':'text/plain'},data:g.text+'\n[Other]\nother.org\n'});
await p.click('#ug-new');await p.fill('#ug-name','Late');await p.fill('#ug-domains','late.org');await p.click('#ug-save');
await p.waitForTimeout(400);
assert.match(await p.locator('#ug-error').textContent(),/другом устройстве/);
assert.equal(await p.inputValue('#ug-domains'),'late.org','текст не потерян');
await p.click('#ug-cancel');
// 8. freeze group across pools
await p.reload();await p.waitForSelector('.state-table');
await p.click('tbody.ug[data-ug="0"] .ug-freeze');await p.waitForTimeout(500);
// 9. delete group
await p.click('#ug-card summary');await p.locator('.ug-m-del').last().click();await p.waitForTimeout(400);
g=await groups();assert.doesNotMatch(g.text,/\[Other\]/);
// 10. XSS-ish name
await p.click('#ug-new');await p.fill('#ug-name','<img src=x onerror=alert(1)>');await p.fill('#ug-domains','rutracker.org');await p.click('#ug-save');await p.waitForTimeout(400);
assert.equal(await p.locator('#state-body img').count(),0);
assert.match(await p.locator('#state-body').innerHTML(),/&lt;img/);

}
{
const groups2=async p=>(await (await p.request.get(base+'/cgi-bin/api/domain-groups',{headers:{'X-Z2K-Panel':'1'}})).json());
const p=await b.newPage({viewport:{width:1280,height:900}});p.on('pageerror',e=>errs.push(e.message));p.on('dialog',d=>d.accept());
await p.goto(base+'/test?dark');await p.waitForSelector('.state-table');
// reset fixture groups
let g=await groups2(p);
await p.request.post(base+'/cgi-bin/api/domain-groups/save?revision='+g.revision,{headers:{'X-Z2K-Panel':'1','Content-Type':'text/plain'},data:'[Discord]\ndiscord.com\ndiscord.media\ndiscordapp.net\n'});
await p.reload();await p.waitForSelector('.state-table');
assert.equal(await p.locator('#ug-selbar').isHidden(),true);
// pick chatgpt (v4 row) -> v6 row syncs
await p.locator('.ug-pick[data-domain="chatgpt.com"]').first().check();
assert.equal(await p.locator('.ug-pick[data-domain="chatgpt.com"]:checked').count(),2);
assert.match(await p.locator('#ug-selbar').textContent(),/Отмечено доменов: 1/);
// search, pick found
await p.fill('#state-search','apple');await p.waitForTimeout(150);
await p.click('#ug-pick-found');await p.waitForTimeout(150);
await p.fill('#state-search','');await p.waitForTimeout(150);
assert.match(await p.locator('#ug-selbar').textContent(),/Отмечено доменов: 2/);
// header checkbox does not toggle group
await p.locator('tbody.sg .ug-pick').first().click();await p.locator('tbody.sg .ug-pick').first().click();
assert.equal(await p.locator('tbody.sg.sg-closed').count()>0,true);

await p.click('#ug-pick-assign');
await p.selectOption('#ug-assign-group','-1');await p.fill('#ug-assign-name','Разное');

await p.click('#ug-assign-ok');await p.waitForSelector('.ug-assign-modal',{state:'detached'});
g=await groups2(p);assert.match(g.text,/\[Разное\]\napple\.com\nchatgpt\.com/);
assert.equal(await p.locator('#ug-selbar').isHidden(),true);
// add to existing group
await p.locator('.ug-pick[data-domain="rutracker.org"]').check();
await p.click('#ug-pick-assign');await p.selectOption('#ug-assign-group','0');await p.click('#ug-assign-ok');
await p.waitForSelector('.ug-assign-modal',{state:'detached'});
g=await groups2(p);assert.match(g.text,/discordapp\.net\nrutracker\.org/);
assert.equal(await p.locator('#ug-selbar').isHidden(),true,'одна отметка тоже снимается после переноса');
// Endfield: восемь имён gryphline.com, три hg-cdn.com и три имени на общей
// инфраструктуре. Заголовки автогрупп берут домен целиком, строки — своё
// точное имя: nvidia.com и anticheatexpert.com в группу игры попасть не должны.
await p.locator('.ug-pick[data-domain="gryphline.com"]').check();
await p.locator('.ug-pick[data-domain="hg-cdn.com"]').check();
for (const d of ['pc.crashsight.wetest.net','down.anticheatexpert.com','ngx.download.nvidia.com']) await p.locator(`.ug-pick[data-domain="${d}"]`).first().check();
assert.match(await p.locator('#ug-selbar').textContent(),/Отмечено доменов: 5/);
await p.click('#ug-pick-assign');await p.selectOption('#ug-assign-group','-1');await p.fill('#ug-assign-name','Arknights: Endfield');
await p.click('#ug-assign-ok');await p.waitForSelector('.ug-assign-modal',{state:'detached'});
g=await groups2(p);
assert.match(g.text,/\[Arknights: Endfield\]\ndown\.anticheatexpert\.com\ngryphline\.com\nhg-cdn\.com\nngx\.download\.nvidia\.com\npc\.crashsight\.wetest\.net/);
assert.doesNotMatch(g.text,/^nvidia\.com$/m);
const ef=await p.locator('tbody.ug').filter({hasText:'Arknights: Endfield'}).locator('.sg-count').textContent();
assert.equal(ef.trim(),'14','все 14 имён Endfield под одной группой');
const m=await b.newPage({viewport:{width:390,height:900}});
await m.goto(base+'/test?light');await m.waitForSelector('.state-table');
await m.locator('.ug-pick').first().check();await m.waitForTimeout(150);

}
assert.deepEqual(errs,[],'page errors');
console.log('domain groups browser: OK');
} finally { await b.close(); }
