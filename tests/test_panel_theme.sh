#!/bin/sh
# Exercise the actual theme switcher; the computed header color is the source of truth.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v node >/dev/null 2>&1; then
    printf '[SKIP] theme-color requires node\n'
    exit 0
fi
node - "$ROOT" <<'JS'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const root = process.argv[2];
const html = fs.readFileSync(root + "/webpanel/www/index.html", "utf8");
assert.ok(/<meta\s+name="theme-color"\s+content="[^"]*"\s*>/.test(html), "theme-color metadata exists");
const source = fs.readFileSync(root + "/webpanel/www/js/chrome.js", "utf8")
  .replace(/^import .*;$/gm, "").replace(/^export /gm, "");
function setup(saved, light) {
  const attrs = {}, storage = new Map(saved ? [["z2k-theme", saved]] : []);
  const meta = { content: "" }, topbar = {};
  const colors = { light: "rgb(255, 255, 255)", dark: "rgb(22, 27, 34)" };
  const buttons = ["light", "dark", "auto"].map(mode => ({
    dataset: { themeBtn: mode }, setAttribute() {},
    addEventListener(_, fn) { this.click = fn; }
  }));
  const mq = { matches: light, addEventListener(_, fn) { this.change = fn; } };
  vm.runInNewContext(source + "\ninitTheme();", {
    document: {
      documentElement: { setAttribute(k, v) { attrs[k] = v; }, removeAttribute(k) { delete attrs[k]; } },
      querySelector(s) { return s === ".topbar" ? topbar : s === 'meta[name="theme-color"]' ? meta : null; },
      querySelectorAll() { return buttons; }
    },
    localStorage: { getItem(k) { return storage.get(k); }, setItem(k, v) { storage.set(k, v); } },
    window: { matchMedia() { return mq; } },
    getComputedStyle(el) {
      assert.equal(el, topbar);
      return { backgroundColor: attrs["data-theme"] === "light" ? colors.light : colors.dark };
    }
  });
  return { meta, colors, mq, click(mode) { buttons.find(b => b.dataset.themeBtn === mode).click(); } };
}
for (const light of [true, false]) {
  const s = setup(null, light);
  assert.equal(s.meta.content, light ? s.colors.light : s.colors.dark, "system theme at startup");
  s.mq.matches = !light; s.mq.change();
  assert.equal(s.meta.content, light ? s.colors.dark : s.colors.light, "live system change");
  for (const mode of ["light", "dark"]) {
    s.click(mode);
    assert.equal(s.meta.content, s.colors[mode], "manual theme");
    s.mq.matches = !s.mq.matches; s.mq.change();
    assert.equal(s.meta.content, s.colors[mode], "manual override survives system changes");
    s.colors[mode] = "rgb(37, 53, 71)";
    s.click(mode);
    assert.equal(s.meta.content, s.colors[mode], "updated CSS color is not hardcoded");
  }
  s.click("auto");
  assert.equal(s.meta.content, s.mq.matches ? s.colors.light : s.colors.dark, "return to system theme");
}
for (const mode of ["light", "dark"]) {
  const s = setup(mode, mode !== "light");
  assert.equal(s.meta.content, s.colors[mode], "saved override at startup");
}
console.log("[PASS] theme-color follows the header at startup and on manual/system theme changes");
JS
