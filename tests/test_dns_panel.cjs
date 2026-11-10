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
