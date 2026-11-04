// Run against an isolated fixture server, never the live router's whitelist.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node tests/browser/whitelist.mjs
import assert from 'node:assert/strict';
const {chromium} = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const base = process.env.Z2K_PANEL_TEST_URL || 'http://127.0.0.1:18786';
assert.equal(new URL(base).hostname,'127.0.0.1','fixture server must be local');
const extra=process.env.Z2K_TEST_EXTRA==='1';
const endpoint=extra ? '/extra-domains' : '/whitelist';
const browser = await chromium.launch({channel:'chrome',headless:true});
const page = await browser.newPage({viewport:{width:1280,height:1000}});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
async function idle(){await page.locator('#wl-card[aria-busy="false"]').waitFor({timeout:10000});}
async function state(){return (await page.request.get(base+'/cgi-bin/api'+endpoint,{headers:{'X-Z2K-Panel':'1'}})).json();}
async function external(text){const s=await state();const r=await page.request.post(base+'/cgi-bin/api'+endpoint+'/save?revision='+s.revision,{headers:{'X-Z2K-Panel':'1','Content-Type':'text/plain'},data:text});assert.equal(r.status(),200,await r.text());}
try {
 if(extra) {
  const r=await page.request.get(base+'/cgi-bin/api/whitelist',{headers:{'X-Z2K-Panel':'1'}});const d=await r.json();
  await page.request.post(base+'/cgi-bin/api/whitelist/save?revision='+d.revision,{headers:{'X-Z2K-Panel':'1'},data:'excluded.example\n'});
 }
 await external('# my sites\na.example\nb.example\nc.example\nkeep.example\n');
 await page.goto(base+(extra ? '/test-extra' : '/test'));await idle();
 assert.equal(await page.locator('[data-row]').count(),4);
 await page.locator('#wl-import-file').setInputFiles({name:'domains.txt',mimeType:'text/plain',buffer:Buffer.from('imported.example\nIMPORTED.EXAMPLE\n')});await idle();
 assert.deepEqual((await state()).domains,['a.example','b.example','c.example','keep.example','imported.example']);
 await page.locator('#wl-undo').click();await idle();assert.equal((await state()).domains.length,4);
 await page.locator('#wl-import-file').setInputFiles({name:'invalid.txt',mimeType:'text/plain',buffer:Buffer.from('good.example\nbad domain\n')});await idle();
 assert.equal((await state()).domains.length,4);assert.match(await page.locator('#wl-error').textContent(),/строке 7/);
 if(extra) {
  await page.locator('#wl-import-file').setInputFiles({name:'covered.txt',mimeType:'text/plain',buffer:Buffer.from('sub.excluded.example\nnew.example\nexcluded.example\n')});await idle();
  assert.deepEqual((await state()).domains,['a.example','b.example','c.example','keep.example','new.example']);
  assert.match(await page.locator('#toast-stack').textContent(),/Пропущено.*2/);
  await page.locator('#wl-undo').click();await idle();assert.equal((await state()).domains.length,4);
  const r=await page.request.get(base+'/cgi-bin/api/whitelist',{headers:{'X-Z2K-Panel':'1'}});
  assert.deepEqual((await r.json()).domains,['excluded.example'],'extra-domain edits must not modify exclusions');
 }

 await page.locator('[data-row="1"]').click();
 await page.locator('[data-row="3"]').click({modifiers:['Shift']});
 assert.equal(await page.locator('[data-row]:checked').count(),3);
 await page.locator('#wl-search').fill('keep');
 await page.locator('#wl-select').click();
 assert.match(await page.locator('#wl-count').textContent(),/Выбрано 4/);
 await page.locator('#wl-unselect').click();
 await page.locator('#wl-search').fill('');
 await page.locator('[data-row="1"]').click();
 await page.locator('#wl-edit-selected').click();
 await page.locator('#wl-editor-text').fill('new.example');
 await page.locator('#wl-save').click();await idle();
 assert.deepEqual((await state()).domains,['new.example','b.example','c.example','keep.example']);
 await page.locator('#wl-undo').click();await idle();assert.equal((await state()).domains[0],'a.example');
 await page.locator('#wl-clear').click();await page.locator('#confirm-cancel').click();
 assert.equal((await state()).domains.length,4);
 await page.locator('#wl-clear').click();await page.locator('#confirm-ok').click();await idle();assert.equal((await state()).domains.length,0);
 await page.locator('#wl-undo').click();await idle();assert.equal((await state()).domains.length,4);
 await page.locator('#wl-search').fill('a.example');await page.locator('#wl-select').click();
 await page.locator('#wl-delete-selected').click();await page.locator('#confirm-ok').click();await idle();
 assert.deepEqual((await state()).domains,['b.example','c.example','keep.example']);
 await external('other-tab.example\n');
 await page.locator('#wl-undo').click();await idle();
 assert.match(await page.locator('#wl-error').textContent(),/другой вкладке/);
 assert.deepEqual((await state()).domains,['other-tab.example']);
 await page.locator('#wl-refresh').click();await idle();await page.locator('#wl-search').fill('');
 await page.locator('#wl-edit-all').click();await page.locator('#wl-editor-text').fill('valid.example\nbad domain');
 await page.locator('#wl-save').click();await idle();
 assert.equal(await page.locator('#wl-editor-text').inputValue(),'valid.example\nbad domain');
 assert.match(await page.locator('#wl-error').textContent(),/строке 2/);
 assert.equal(await page.locator('#wl-editor [role=alert]').count(),1,'editor must contain its error message');
 assert.deepEqual((await state()).domains,['other-tab.example']);
 await page.locator('#wl-editor-text').fill('my-draft.example');
 await external('concurrent.example\n');await page.locator('#wl-save').click();await idle();
 assert.equal(await page.locator('#wl-editor-text').inputValue(),'my-draft.example');
 assert.match(await page.locator('#wl-error').textContent(),/другой вкладке/);
 await page.locator('#wl-cancel').click();await page.locator('#wl-refresh').click();await idle();
 const big=Array.from({length:1500},(_,i)=>`site-${i}.example`).join('\n');
 await external(big);await page.locator('#wl-refresh').click();await idle();assert.equal(await page.locator('[data-row]').count(),1500);
 await page.locator('#wl-search').fill('site-1499');await page.locator('#wl-select').click();
 assert.equal(await page.locator('[data-row]:checked').count(),1);
 await page.screenshot({path:'/tmp/z2k-whitelist-desktop.png',fullPage:true});
 await page.setViewportSize({width:375,height:812});
 await page.locator('#wl-edit-selected').click();
 await page.screenshot({path:'/tmp/z2k-whitelist-mobile.png',fullPage:true});
 assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth),'mobile horizontal overflow');
 assert.notEqual(await page.locator('#wl-editor-text').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(255, 255, 255)','editor must respect dark theme');
 await page.locator('#wl-editor-text').focus();await page.keyboard.press('Tab');
 assert.equal(await page.locator('#wl-save').evaluate(el=>el===document.activeElement),true);
 assert.deepEqual(errors,[]);
 console.log('PASS: real CGI + browser: selection/Shift/filter, replace, delete, clear/cancel, undo/conflicts, draft retention, 1500 rows, mobile, keyboard');
} finally {await browser.close();}
