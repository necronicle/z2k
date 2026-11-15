// Выполняем настоящие функции рендера DNS с минимальной DOM-поверхностью.
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const path = require("node:path");
const src = fs.readFileSync(path.join(__dirname, "../webpanel/www/js/pages/diag.js"), "utf8");
const host = { innerHTML: "" };
const context = { document: { getElementById: () => host }, escapeHtml: x => String(x) };
vm.createContext(context);
vm.runInContext(src.slice(src.indexOf("const DNS_STATE"), src.indexOf("async function loadDnsLast")) + ";this.renderDnsResult = renderDnsResult;", context);
context.renderDnsResult({ intercept: 1, intercept_by: "router", stub: "188.186.146.208", servers: [
  {name: "A", udp: "works", doh: "mismatch", dot: "unverified"},
  {name: "B", udp: "unknown", doh: "silent", dot: "limited"},
  {name: "C", udp: "hijack", doh: "spoof", dot: "none"},
] });
for (const text of ["признаков подмены нет", "ответы расходятся", "недостаточно данных", "TLS не проверен", "только контрольный запрос", "ответ подменён", "2 требуют уточнения", "1 перехвачено", "188.186.146.208", "место не установлено"]) assert.ok(host.innerHTML.includes(text), text);
assert.ok(!host.innerHTML.includes("честно"));
assert.ok(!host.innerHTML.includes("роутером ("));
assert.equal((host.innerHTML.match(/<details /g) || []).length, 3);
assert.ok(!host.innerHTML.includes('<details class="dns-group" open'));
console.log("[PASS] подписи DNS, неопределённые группы и осторожная атрибуция");

// Старые снимки без observations; proxy участвует в прежней плохой группе.
context.renderDnsResult({ servers: [
  {name: "xbox-dns.ru", udp: "proxy", doh: "proxy", dot: "none", verdict: "spoof"},
] });
assert.equal((host.innerHTML.match(/свой прокси вместо сайта/g) || []).length, 2);
assert.equal((host.innerHTML.match(/1 подменено/g) || []).length, 2);
assert.equal((host.innerHTML.match(/dns-tally dns-bad/g) || []).length, 2);
console.log("[PASS] старый снимок proxy, подпись и группировка");

// Снимок с observations и реквизитами подключения: раскрытие строки и копирование.
const listeners = {};
let copied = "";
const interactiveHost = {
  innerHTML: "",
  addEventListener(type, fn) { listeners[type] = fn; },
};
const ctx2 = {
  document: { getElementById: () => interactiveHost },
  escapeHtml: x => String(x),
  copyToClipboard: v => { copied = v; },
};
vm.createContext(ctx2);
vm.runInContext(src.slice(src.indexOf("const DNS_STATE"), src.indexOf("async function loadDnsLast")) + ";this.renderDnsResult = renderDnsResult;", ctx2);
ctx2.renderDnsResult({
  servers: [
    {
      name: "Cloudflare", udp: "spoof", udp_ms: 12, doh: "works", doh_ms: 28, dot: "works", dot_ms: 31, yt: "ok", current: 0,
      addr_udp: "1.1.1.1", addr_doh: "https://cloudflare-dns.com/dns-query", addr_dot: "one.one.one.one",
    },
    {
      name: "Ваш DNS (192.168.1.1)", udp: "works", udp_ms: 4, doh: "none", dot: "none", yt: "ok", current: 1,
      addr_udp: "192.168.1.1", addr_doh: "", addr_dot: "",
    },
    {
      name: "xbox", udp: "proxy", udp_ms: 19, doh: "none", dot: "none", yt: "ok", current: 0,
      addr_udp: "87.228.47.1", addr_doh: "", addr_dot: "",
    },
    {
      name: "Quad9", udp: "hijack", udp_ms: 8, doh: "works", doh_ms: 30, dot: "none", yt: "ok", current: 0,
      addr_udp: "9.9.9.9", addr_doh: "https://dns.quad9.net/dns-query", addr_dot: "",
    },
  ],
  observations: [
    { server: "Cloudflare", path: "u", domain: "rutor.info", outcome: "addresses", purpose: "target", addresses: ["203.0.113.99"], comparison: "different" },
    { server: "Cloudflare", path: "u", domain: "flibusta.is", outcome: "addresses", purpose: "target", addresses: ["203.0.113.99"], comparison: "different" },
    { server: "Cloudflare", path: "t", domain: "rutor.info", outcome: "addresses", purpose: "target", addresses: ["198.51.100.10"], comparison: "overlap" },
    { server: "Ваш DNS (192.168.1.1)", path: "u", domain: "shikimori.one", outcome: "addresses", purpose: "target", addresses: ["188.114.96.77"], comparison: "consensus" },
    { server: "xbox", path: "u", domain: "api.github.com", outcome: "addresses", purpose: "proxy", addresses: ["87.228.47.198"], comparison: "proxy" },
    { server: "Quad9", path: "u", domain: "rutor.info", outcome: "addresses", purpose: "target", addresses: ["188.186.146.208"], comparison: "different" },
    { server: "Quad9", path: "u", domain: "rezka.ag", outcome: "addresses", purpose: "target", addresses: ["188.186.146.208"], comparison: "different" },
  ],
});
assert.equal((interactiveHost.innerHTML.match(/<details /g) || []).length, 3);
assert.ok(interactiveHost.innerHTML.includes("запрос внутри TLS, порт 853"));
assert.ok(!interactiveHost.innerHTML.includes("только контрольный запрос"));
assert.ok(!interactiveHost.innerHTML.includes("честно"));
assert.ok(!interactiveHost.innerHTML.includes("dot:one.one.one.one"));
assert.equal((interactiveHost.innerHTML.match(/подменён на заглушку/g) || []).length, 4);
for (const text of [
  "dns-obs\" hidden",
  "data-copy=\"https://cloudflare-dns.com/dns-query\"",
  "data-copy=\"one.one.one.one\"",
  "совпадает с DoH",
  "подтверждён эталонами",
  "отдан прокси-адрес",
]) assert.ok(interactiveHost.innerHTML.includes(text), text);

const fakeBox = { hidden: true };
let expandedAttr = "false";
const fakeRow = {
  classList: { toggle() {} },
  querySelector: sel => (sel === ".dns-obs" ? fakeBox : null),
  setAttribute: (k, v) => { if (k === "aria-expanded") expandedAttr = v; },
};
let stopped = false;
listeners.click({
  stopPropagation() { stopped = true; },
  target: {
    closest: sel => (sel === ".dns-copy" ? { dataset: { copy: "one.one.one.one" } } : fakeRow),
  },
});
assert.equal(copied, "one.one.one.one");
assert.equal(stopped, true);
assert.equal(fakeBox.hidden, true);

listeners.click({
  target: { closest: sel => (sel === ".dns-row-exp" ? fakeRow : null) },
});
assert.equal(fakeBox.hidden, false);
assert.equal(expandedAttr, "true");

// Клик/выделение текста внутри открытого блока .dns-obs не схлопывает карточку.
listeners.click({
  target: { closest: sel => (sel === ".dns-obs" ? fakeBox : (sel === ".dns-row-exp" ? fakeRow : null)) },
});
assert.equal(fakeBox.hidden, false);
console.log("[PASS] подоменные наблюдения, копирование чистого реквизита DoT и устойчивость открытой строки");

