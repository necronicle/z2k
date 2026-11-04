// Exact report from issue #78, against whitelist_server.py and the real CGI.
import assert from 'node:assert/strict';
const {chromium} = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const base = process.env.Z2K_PANEL_TEST_URL || 'http://127.0.0.1:18786';
assert.equal(new URL(base).hostname, '127.0.0.1');
const input = `macbb.org
macserialjunkie.com
download-center.dxo.com
ports.macports.org
macked.app
cdn.openwidget.com
www.emclient.com
postimgs.org
forum.ru-board.com
mediafire.com
workupload.com
mega.nz
imgbb.co
pyinstaller.org
affinity.studio
`;
const expected = input.trim().split('\n').filter(d => d !== 'mediafire.com');
const browser = await chromium.launch({channel:'chrome',headless:true});
const page = await browser.newPage();
const headers = {'X-Z2K-Panel':'1','Content-Type':'text/plain'};
const endpoint = base + '/cgi-bin/api/extra-domains';
const state = async () => (await page.request.get(endpoint,{headers})).json();
const idle = () => page.locator('#wl-card[aria-busy="false"]').waitFor();
async function reset(text) {
  const s = await state();
  const r = await page.request.post(endpoint+'/save?revision='+s.revision,{headers,data:text});
  assert.equal(r.status(),200,await r.text());
  await page.goto(base+'/test-extra'); await idle();
}
async function check(label) {
  const s = await state();
  assert.deepEqual(s.domains,expected,label+': '+await page.locator('#wl-editor-error').textContent());
  assert.match(await page.locator('#toast-stack').textContent(),/Пропущено.*1/,label);
  console.log('PASS:',label);
}
try {
  for (const initial of ['', '# keep comment\nmacbb.org\nmacserialjunkie.com\n']) {
    await reset(initial);
    for (let repeat=0;repeat<2;repeat++) {
      await page.locator('#toast-stack').evaluate(el=>el.replaceChildren());
      await page.locator('#wl-import-file').setInputFiles({name:'issue78.txt',mimeType:'text/plain',buffer:Buffer.from(input)});
      await idle(); await check(`file import initial=${!!initial} repeat=${repeat}`);
      if(initial) assert.ok((await state()).text.startsWith('# keep comment\n'));
    }
  }
  for (const initial of ['', 'macbb.org\nmacserialjunkie.com\n']) {
    await reset(initial);
    await page.locator('#wl-edit-all').click();
    await page.locator('#wl-editor-text').fill(input);
    await page.locator('#wl-save').click(); await idle();
    await check(`whole-list editor initial=${!!initial}`);
    await page.locator('#wl-undo').click(); await idle();
    assert.equal((await state()).text,initial.trimEnd(),'editor undo');
  }
  await reset('macbb.org\nuntouched.example\n');
  await page.locator('[data-row="0"]').click();
  await page.locator('#wl-edit-selected').click();
  await page.locator('#wl-editor-text').fill(input);
  await page.locator('#wl-save').click(); await idle();
  assert.deepEqual((await state()).domains,[...expected,'untouched.example']);
  assert.match(await page.locator('#toast-stack').textContent(),/Пропущено.*1/);
  await page.locator('#wl-undo').click(); await idle();
  assert.equal((await state()).text,'macbb.org\nuntouched.example','selected editor undo');
  console.log('PASS: selected editor preserves unselected entries and supports undo');
  const before = await state();
  await page.locator('#wl-input').fill('mediafire.com');
  await page.locator('#wl-add-btn').click(); await idle();
  assert.match(await page.locator('#wl-error').textContent(),/mediafire.com.*РКН/);
  assert.deepEqual(await state(),before,'single-add coverage rejection remains atomic');
  console.log('PASS: single-add retains strict coverage diagnostic');
  // Seed a valid entry first, then make it covered by another editable list.
  await reset('# existing comment\nlate-covered.example\nmacbb.org\n');
  const exclusions = base+'/cgi-bin/api/whitelist';
  const oldExclusions = await (await page.request.get(exclusions,{headers})).json();
  const excludeResult = await page.request.post(exclusions+'/save?revision='+oldExclusions.revision,{headers,data:oldExclusions.text+'\nlate-covered.example\n'});
  assert.equal(excludeResult.status(),200);
  try {
    await page.locator('[data-del="1"]').click(); await idle();
    assert.deepEqual((await state()).domains,['macbb.org']);
    await page.locator('#wl-undo').click(); await idle();
    assert.equal((await state()).text,'# existing comment\nlate-covered.example\nmacbb.org');
    await page.locator('#wl-edit-all').click();
    await page.locator('#wl-editor-text').fill('# existing comment\nlate-covered.example\nmacbb.org\nmediafire.com\nnew.example\n');
    await page.locator('#wl-save').click(); await idle();
    assert.deepEqual((await state()).domains,['late-covered.example','macbb.org','new.example']);
    assert.ok((await state()).text.startsWith('# existing comment\n'));
    await page.locator('#wl-undo').click(); await idle();
    assert.equal((await state()).text,'# existing comment\nlate-covered.example\nmacbb.org');
    console.log('PASS: covered entry delete/undo and bulk preservation with comments');
  } finally {
    const current = await (await page.request.get(exclusions,{headers})).json();
    const restored = await page.request.post(exclusions+'/save?revision='+current.revision,{headers,data:oldExclusions.text});
    assert.equal(restored.status(),200);
  }
} finally { await browser.close(); }
