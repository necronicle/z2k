// Import the production ES module, without copying or extracting its comparator.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  global.localStorage = { getItem: () => null };
  const source = fs.readFileSync(path.join(__dirname, '../webpanel/www/js/state-model.js'), 'utf8');
  const model = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
  const now = 2000000000;
  const row = (host, age, key = 'tcp') => ({ host, key, ts: age === null ? 0 : now - age });
  const entries = [
    row('pair.net|4', 1440), row('pair.net|6', 86400),
    row('solo.org|4', 1560), row('hours.org|4', 7200), row('days.org|4', 172800),
    row('a.group.com|4', 120), row('b.group.com|6', 259200), row('c.group.com|4', null),
    row('a.group.com|4', 3600, 'quic'), row('b.group.com|6', 345600, 'quic'),
    row('missing.org|4', null), row('a.empty.com|4', null), row('b.empty.com|6', null),
  ];
  const snapshot = JSON.stringify(entries);
  const meta = new Map(entries.map(e => {
    const name = e.host.replace(/\|[46]$/, '');
    const group = model.groupDomain(name);
    return [e, { name, group, gkey: e.key + '|' + group, age: model.stateAge(e.ts, now) }];
  }));
  for (const bad of [undefined, null, '', 0, '0', 'bad', NaN, Infinity, -1]) {
    assert.equal(model.stateAge(bad, now), null);
  }
  assert.equal(model.stateAge(String(now - 120), now), 120);
  for (const dir of ['asc', 'desc']) {
    Object.assign(model.stateSort, { key: 'age', dir });
    const blocks = model.buildStateBlocks(entries, meta);
    const expected = dir === 'asc'
      ? [120, 1440, 1560, 3600, 7200, 86400, 172800, null, null]
      : [172800, 86400, 7200, 3600, 1560, 1440, 120, null, null];
    assert.deepEqual(blocks.map(b => b.age), expected, dir + ' displayed top-level ages');
    for (const b of blocks) {
      const ages = b.rows.map(e => meta.get(e).age);
      const known = ages.filter(a => a !== null);
      assert.equal(b.age, known.length ? Math.min(...known) : null);
      assert.deepEqual(ages, [...known].sort((a, z) => dir === 'asc' ? a - z : z - a)
        .concat(ages.filter(a => a === null)), dir + ' member ages');
    }
    assert.equal(blocks.flatMap(b => b.rows).length, entries.length);
    assert.equal(JSON.stringify(entries), snapshot, 'cached response remains unchanged');
  }
  console.log('[PASS] production state-model: mixed ages, groups, v4/v6, missing times, asc/desc');
})().catch(e => { console.error(e); process.exitCode = 1; });
