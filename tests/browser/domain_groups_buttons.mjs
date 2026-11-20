// Every button of the «Автоподбор» tab next to user domain groups, in a real
// browser. The table's own controls (row strategy, lock, ×, auto-group reset and
// freeze, «Заморозить все», «Удалить все записи», sorting, search) must keep
// working inside and around groups, and nothing must eat what the user typed.
//   python3 tests/browser/domain_groups_server.py &
//   PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node tests/browser/domain_groups_buttons.mjs
import assert from 'node:assert/strict';
const {chromium} = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const base = process.env.Z2K_PANEL_TEST_URL || 'http://127.0.0.1:18790';
assert.equal(new URL(base).hostname,'127.0.0.1','fixture server must be local');
const H = {'X-Z2K-Panel':'1'};
const b = await chromium.launch({channel:'chrome',headless:true});
const p = await b.newPage({viewport:{width:1280,height:1000}});
const errs = []; p.on('pageerror', e => errs.push(e.message));
let dialogs = []; p.on('dialog', d => { dialogs.push(d.message()); d.accept(); });
const api = path => base + '/cgi-bin/api' + path;
const groups = async () => (await (await p.request.get(api('/domain-groups'), {headers:H})).json());
const put = async t => { const g = await groups(); const r = await p.request.post(api('/domain-groups/save?revision=' + g.revision), {headers:{...H,'Content-Type':'text/plain'}, data:t}); assert.equal(r.status(), 200, await r.text()); };
const state = async () => (await (await p.request.get(api('/state'), {headers:H})).json()).entries;
const slow = s => p.request.get(api('/__test/slow?s=' + s), {headers:H});
const reset = async (text) => { await slow(0); await p.request.get(api('/__test/reset'), {headers:H}); await put(text); await p.goto(base + '/test?dark'); await p.evaluate(() => localStorage.clear()); await p.reload(); await p.waitForSelector('.state-table'); };
const settle = () => p.waitForTimeout(500);
const ug = name => p.locator('tbody.ug').filter({hasText: name});
const ugCount = async name => Number((await ug(name).locator('.sg-count').textContent()).trim());
const open = async name => { if (await ug(name).evaluate(el => el.classList.contains('ug-closed'))) await ug(name).locator('.ug-head').click(); };
const GROUPS = '[Discord]\ndiscord.com\ndiscord.media\ndiscordapp.net\n\n[YouTube]\nyoutube.com\ngooglevideo.com\nytimg.com\n';
const step = (name) => console.log('· ' + name);

try {
  await reset(GROUPS);

  step('выбор стратегии в строке внутри группы');
  await open('Discord');
  const sel = p.locator('tbody[data-ug-of="0"] select.state-strat-sel').first();
  const key = await sel.getAttribute('data-key'), host = await sel.getAttribute('data-host');
  await sel.selectOption('7'); await settle();
  assert.equal((await state()).find(e => e.key === key && e.host === host).strategy, '7');
  assert.equal(await p.locator('tbody[data-ug-of="0"][data-ug-closed]').count(), 0, 'группа осталась раскрытой после перерисовки');

  step('замок строки внутри группы и счёт «N из M» в заголовке');
  const before = (await ug('Discord').locator('.sg-frozen').textContent().catch(() => '')).trim();
  await p.locator('tbody[data-ug-of="0"] .state-freeze[data-frozen="0"]:visible').first().click(); await settle();
  const after = (await ug('Discord').locator('.sg-frozen').textContent()).trim();
  assert.notEqual(after, before, `счёт заморозки обновился: ${before} → ${after}`);

  step('× строки внутри группы');
  const n0 = await ugCount('Discord');
  await p.locator('tbody[data-ug-of="0"] .state-del:visible').first().click(); await settle();
  assert.equal(await ugCount('Discord'), n0 - 1);

  step('сброс и заморозка автогруппы внутри группы');
  await p.locator('tbody.sg[data-ug-of="0"] .sg-head').first().click();
  const ag = p.locator('tbody.sg[data-ug-of="0"]').first();
  const agKey = await ag.getAttribute('data-group');
  await ag.locator('.sg-freeze').click(); await settle();
  const pool = agKey.split('|')[0], dom = agKey.split('|')[1];
  assert((await state()).filter(e => e.key === pool && e.host.replace(/\|[46]$/, '').endsWith(dom)).every(e => e.mode === 'frozen'), 'автогруппа заморожена');
  await p.locator(`tbody.sg[data-group="${agKey}"] .sg-reset`).click(); await settle();
  assert.equal((await state()).filter(e => e.key === pool && e.host.replace(/\|[46]$/, '').endsWith(dom)).length, 0, 'автогруппа сброшена');

  step('заморозка группы через пулы и разморозка');
  await reset(GROUPS);
  dialogs = [];
  await ug('YouTube').locator('.ug-freeze').click(); await settle();
  assert.match(dialogs[0], /Пулы: gv_tcp, rkn_tcp/, 'подтверждение называет пулы');
  const yt = e => /youtube\.com|googlevideo\.com|ytimg\.com/.test(e.host);
  assert((await state()).filter(yt).every(e => e.mode === 'frozen'));
  assert.equal((await ug('YouTube').locator('.sg-frozen').textContent()).trim(), 'все');
  await ug('YouTube').locator('.ug-freeze').click(); await settle();
  assert((await state()).filter(yt).every(e => e.mode === 'auto'), 'разморозка той же кнопкой');

  step('сброс группы: группа уходит из таблицы, но не из карточки');
  await ug('YouTube').locator('.ug-reset').click(); await settle();
  assert.equal((await state()).filter(yt).length, 0);
  assert.equal(await ug('YouTube').count(), 0);
  await p.click('#ug-card summary');
  assert.match(await p.locator('.ug-list').textContent(), /YouTube[\s\S]*в таблице пока нет записей/);
  await p.click('#ug-card summary');

  step('«Заморозить все» с поиском по имени группы');
  await reset(GROUPS);
  await p.fill('#state-search', 'tube'); await p.waitForTimeout(200);
  assert.match(await p.locator('#state-freeze-visible').textContent(), /Заморозить найденные · 4/);
  await p.click('#state-freeze-visible'); await settle();
  const st = await state();
  assert(st.filter(yt).every(e => e.mode === 'frozen') && st.filter(e => /chatgpt/.test(e.host)).every(e => e.mode === 'auto'), 'заморожено ровно найденное');
  await p.fill('#state-search', '');

  step('сортировка не переставляет группы и не сворачивает их');
  await reset(GROUPS);
  await open('Discord');
  const order = async () => p.locator('tbody.ug .sg-name').allTextContents();
  const o1 = await order();
  for (const col of ['host', 'strategy', 'age', 'frozen', 'key']) {
    await p.click(`th.sortable[data-sort="${col}"]`); await p.waitForTimeout(150);
    assert.deepEqual(await order(), o1, 'порядок групп по сортировке ' + col);
  }
  assert.equal(await p.locator('tbody[data-ug-of="0"][data-ug-closed]').count(), 0, 'раскрытие пережило сортировку');

  step('свернуть группу во время поиска, очистить поиск');
  await p.fill('#state-search', 'disc'); await p.waitForTimeout(150);
  await ug('Discord').locator('.ug-head').click();
  assert(await p.locator('tbody[data-ug-of="0"][data-ug-closed]').count() > 0, 'свернулась в выдаче');
  await p.fill('#state-search', 'disco'); await p.waitForTimeout(150);
  assert(await p.locator('tbody[data-ug-of="0"][data-ug-closed]').count() > 0, 'следующая буква не раскрыла обратно');
  await p.fill('#state-search', ''); await p.waitForTimeout(150);
  assert.equal(await p.locator('tbody[data-ug-of="0"][data-ug-closed]').count(), 0, 'после поиска вернулось запомненное раскрытие');

  step('клавиатура: Enter на заголовке группы');
  await ug('YouTube').locator('.ug-toggle').focus(); await p.keyboard.press('Enter');
  assert.equal(await p.locator('tbody[data-ug-of="1"][data-ug-closed]').count(), 0);

  step('«Обновить» и правка строки не стирают набранное в редакторе');
  await p.click('#ug-card summary'); await p.click('#ug-new');
  await p.fill('#ug-name', 'Набираю'); await p.fill('#ug-domains', 'typed.example');
  await p.click('#state-refresh'); await settle();
  assert.equal(await p.inputValue('#ug-name'), 'Набираю');
  assert.equal(await p.inputValue('#ug-domains'), 'typed.example');
  await p.locator('.state-freeze:visible').first().click(); await settle();
  assert.equal(await p.inputValue('#ug-domains'), 'typed.example');
  step('…но в редактор другой группы чужой текст не переезжает');
  await p.locator('.ug-m-edit').first().click();
  assert.match(await p.inputValue('#ug-domains'), /discord\.com/);
  await p.click('#ug-cancel');

  step('режим «как текст»: двойник имени с другим регистром кириллицы');
  await p.click('#ug-text');
  await p.fill('#ug-domains', '[Дискорд]\ndiscord.com\n[дискорд]\ndiscord.media\n'); await p.click('#ug-save'); await settle();
  assert.match(await p.locator('#ug-error').textContent(), /не различаются регистром/);
  assert.doesNotMatch((await groups()).text, /Дискорд/);
  await p.click('#ug-cancel');

  step('редактор: пустое имя, чужой домен, адрес вместо домена');
  await p.locator('.ug-m-edit').last().click();
  await p.fill('#ug-name', ''); await p.click('#ug-save');
  assert.match(await p.locator('#ug-error').textContent(), /Укажите имя/);
  await p.fill('#ug-name', 'YouTube'); await p.fill('#ug-domains', 'discord.com'); await p.click('#ug-save');
  assert.match(await p.locator('#ug-error').textContent(), /уже входит в группу «Discord»/);
  await p.fill('#ug-domains', 'https://youtube.com/'); await p.click('#ug-save');
  assert.match(await p.locator('#ug-error').textContent(), /не домен/);
  await p.click('#ug-cancel');

  step('пустой поиск убирает «Отметить найденные»');
  await p.fill('#state-search', 'ruTRACKER'); await p.waitForTimeout(150);
  assert.equal(await p.locator('#ug-pick-found').count(), 1);
  await p.fill('#state-search', 'rutrackerzzz'); await p.waitForTimeout(150);
  assert.equal(await p.locator('#ug-pick-found').count(), 0);
  await p.fill('#state-search', '');

  step('отмеченное, попавшее в группу другим путём, уходит из отметок');
  await p.locator('.ug-pick[data-domain="rutracker.org"]').check();
  await p.click('.ug-assign[data-domain="rutracker.org"]'); await p.selectOption('#ug-assign-group', '0'); await p.click('#ug-assign-ok');
  await p.waitForSelector('.ug-assign-modal', {state:'detached'}); await settle();
  assert.equal(await p.locator('#ug-selbar').isHidden(), true);

  step('окно: Escape, клик мимо, уход со страницы');
  await p.click('.ug-assign[data-domain="chatgpt.com"]'); await p.keyboard.press('Escape');
  assert.equal(await p.locator('.ug-assign-modal').count(), 0);
  await p.click('.ug-assign[data-domain="chatgpt.com"]'); await p.mouse.click(5, 5);
  assert.equal(await p.locator('.ug-assign-modal').count(), 0);
  // Уход со страницы закрывает окна маршрутизатор панели, поэтому здесь —
  // настоящая index.html, а не тестовая страница с одной вкладкой.
  await p.goto(base + '/index.html#/state'); await p.waitForSelector('.state-table');
  await p.click('.ug-assign[data-domain="chatgpt.com"]');
  await p.evaluate(() => { location.hash = '#/dashboard'; });
  await p.waitForTimeout(400);
  assert.equal(await p.locator('.ug-assign-modal').count(), 0, 'навигация закрывает окно');
  await p.evaluate(() => { location.hash = '#/state'; }); await p.waitForSelector('.state-table');
  await p.click('.ug-assign[data-domain="chatgpt.com"]');
  assert.equal(await p.locator('.ug-assign-modal').count(), 1, 'после возврата окно открывается снова');
  await p.keyboard.press('Escape');

  step('удаление группы забывает её раскрытие');
  await reset(GROUPS + '\n[Tmp]\nchatgpt.com\n');
  await ug('Tmp').locator('.ug-head').click();
  await p.click('#ug-card summary'); await p.locator('.ug-m-del').last().click(); await settle();
  assert.doesNotMatch(await p.evaluate(() => localStorage.getItem('z2k-state-open-ugroups') || ''), /Tmp/);

  step('гонка: сохранение группы во время долгого обновления таблицы');
  await reset(GROUPS);
  await slow(2);
  await p.click('#state-refresh'); await p.waitForTimeout(300);
  await p.click('.ug-assign[data-domain="chatgpt.com"]'); await p.selectOption('#ug-assign-group', '-1'); await p.fill('#ug-assign-name', 'Гонка');
  await p.click('#ug-assign-ok'); await p.waitForSelector('.ug-assign-modal', {state:'detached'});
  await p.waitForTimeout(2600); await slow(0);
  assert.equal(await ug('Гонка').count(), 1, 'группа не пропала после запоздалого ответа');
  await p.click('.ug-assign[data-domain="rutracker.org"]'); await p.selectOption('#ug-assign-group', '-1'); await p.fill('#ug-assign-name', 'После гонки');
  await p.click('#ug-assign-ok'); await p.waitForSelector('.ug-assign-modal', {state:'detached', timeout:3000});
  assert.match((await groups()).text, /\[После гонки\]/, 'следующая правка без ложного конфликта');

  step('«Удалить все записи»: таблица пуста, группы целы, панель отметок честная');
  await p.locator('.ug-pick:visible').first().check();
  await p.click('#state-clear-all'); await settle();
  assert.equal((await state()).length, 0);
  assert.match((await groups()).text, /\[Discord\]/);
  assert.equal(await p.locator('#ug-pick-found').count(), 0);

  assert.deepEqual(errs, [], 'ошибки страницы');
  console.log('domain groups buttons: OK');
} finally { await slow(0).catch(() => {}); await b.close(); }
