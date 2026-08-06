// Прогон КАЖДОЙ страницы панели с исполнением её кода.
// Грепом такое не ловится: STRATEGY_POOL_NAMES — не вызов функции, а обращение
// к константе, и статическая проверка по вызовам его пропустила.
const fs = require("fs");
const path = process.argv[2];
const routes = process.argv.slice(3);

const errors = [];

// Ловим ошибки, которые код ПОЙМАЛ и отрисовал вместо того, чтобы бросить.
// Без этого харнесс защищал ровно один маршрут из девяти: почти каждый
// загрузчик обёрнут в try/catch и на исключении пишет текст в DOM, а наружу
// ничего не выходит — прогон отвечает «ok». Именно так выглядела бы регрессия
// r-71.1, случись она в любой странице кроме «Свои стратегии».
//
// Список шаблонов узкий намеренно. Ловим ТОЛЬКО признаки поломки кода —
// обращение к несуществующему имени или вызов не-функции. Общие маркеры вроде
// «Ошибка» или класса var(--bad) брать нельзя: ими штатно сообщают «сервис не
// запущен» и «не удалось загрузить», и тест краснел бы на здоровой панели.
const RENDERED_BUG = /(is not defined|is not a function|undefined is not|Cannot read propert|of undefined|of null)/;
function noteRendered(html) {
  const m = String(html).match(RENDERED_BUG);
  if (m) errors.push("отрисована ошибка: " + m[0]);
}
const mkEl = () => {
  const el = {
    _h: "", style: {}, dataset: {}, classList: { add(){}, remove(){}, toggle(){}, contains(){return false} },
    children: [], attributes: {},
    set innerHTML(v){ this._h = String(v); noteRendered(this._h); },
    get innerHTML(){ return this._h; },
    set textContent(v){ this._h = String(v); noteRendered(this._h); },
    get textContent(){ return this._h; },
    addEventListener(){}, removeEventListener(){}, appendChild(){}, removeChild(){},
    setAttribute(k,v){ this.attributes[k]=v; }, getAttribute(k){ return this.attributes[k]; },
    removeAttribute(){}, querySelector(){ return mkEl(); }, querySelectorAll(){ return []; },
    closest(){ return null; }, focus(){}, blur(){}, click(){}, insertAdjacentHTML(){},
    scrollIntoView(){}, remove(){},
  };
  return el;
};
global.document = {
  documentElement: mkEl(), body: mkEl(), head: mkEl(),
  getElementById(){ return mkEl(); },
  querySelector(){ return mkEl(); }, querySelectorAll(){ return []; },
  createElement(){ return mkEl(); }, addEventListener(){}, removeEventListener(){},
};
global.location = { hash: "#/dashboard", href: "http://r/", reload(){} };
global.history = { replaceState(){}, pushState(){} };
// Заглушки задаются ЯВНО и перекрывают хостовые, даже если node их предоставляет.
// Иначе тест зависит от версии node: локальный v25 отдаёт настоящий
// sessionStorage, и падение «sessionStorage is not defined» вылезло только на
// CI, где node старее. Тест, который проходит из-за окружения, а не из-за кода,
// хуже отсутствующего — он даёт ложную уверенность.
const mkStorage = () => {
  const m = new Map();
  return {
    getItem(k){ return m.has(String(k)) ? m.get(String(k)) : null; },
    setItem(k, v){ m.set(String(k), String(v)); },
    removeItem(k){ m.delete(String(k)); },
    clear(){ m.clear(); },
    key(i){ return Array.from(m.keys())[i] ?? null; },
    get length(){ return m.size; },
  };
};
global.localStorage = mkStorage();
global.sessionStorage = mkStorage();
// URL.createObjectURL/revokeObjectURL в node отсутствуют — их зовёт выгрузка
// диагностики в файл (app.js:1348).
if (typeof global.URL.createObjectURL !== "function") {
  global.URL.createObjectURL = () => "blob:stub";
  global.URL.revokeObjectURL = () => {};
}
if (typeof global.Blob !== "function") { global.Blob = class { constructor(){} }; }
global.window = {
  addEventListener(t, fn){ if (t === "hashchange") global.__nav = fn; },
  removeEventListener(){}, matchMedia(){ return { matches:false, addEventListener(){}, addListener(){} }; },
  location: global.location, localStorage: global.localStorage,
  sessionStorage: global.sessionStorage, document: global.document,
};
global.requestAnimationFrame = fn => setTimeout(fn, 0);
global.cancelAnimationFrame = id => clearTimeout(id);
global.getComputedStyle = () => ({ getPropertyValue: () => "" });
global.navigator = { clipboard: { writeText: async () => {} }, userAgent: "node" };
// Ответы должны быть ПРАВДОПОДОБНЫМИ, иначе тест бесполезен: с пустым {ok:true}
// список пулов приходит пустым, .map() не выполняется, и обращение к
// STRATEGY_POOL_NAMES внутри него никогда не происходит — ровно поэтому первая
// версия этой заглушки пропустила реальную поломку страницы «Свои стратегии».
const FIXTURES = {
  "/status": { ok:true, installed:"r-71.1", running:true, service:"running",
    toggles:{rst_filter:"0",silent_fallback:"0",game_warp:"0",customd:"0",dynamic_ttl:"1",
             stats:"1",ppe:"1",auto_update:"1",autohostlist:"0"}, tunnel:{running:true} },
  "/strategy/pools": { ok:true, pools:[
    {pool:"rkn_tcp",custom:0,line:""},{pool:"yt_tcp",custom:1,line:"--filter-tcp=443"},
    {pool:"gv_tcp",custom:0,line:""},{pool:"yt_quic",custom:0,line:""}] },
  "/strategy/pool": { ok:true, pool:"rkn_tcp", custom:0, line:"" },
  "/state": { ok:true, entries:[
    {key:"rkn_tcp",host:"example.com|4",strategy:"3",ts:1785830000,mode:"auto"},
    {key:"yt_tcp",host:"youtube.com|4",strategy:"7",ts:1785830100,mode:"frozen"},
    {key:"discord_udp",host:"nohost",strategy:"2",ts:1785830200,mode:"auto"}] },
  "/pools": { ok:true, pools:{rkn_tcp:50,yt_tcp:22,gv_tcp:22,yt_quic:13,discord_udp:9} },
  "/whitelist": { ok:true, domains:["gosuslugi.ru","sberbank.ru","keenetic.link"] },
  "/exclude": { ok:true, entries:["tiandycloud.com","203.0.113.0/24","2001:db8::1"] },
  "/extra-domains": { ok:true, domains:["example.org","cdnbase.com"] },
  "/warp/status": { ok:true, enabled:false, running:false, iface:"", ip:"" },
  "/warp/games": { ok:true, games:[{name:"ApexLegends",entries:42,on:1},{name:"Valorant",entries:13,on:0}] },
  "/warp/lists": { ok:true, lists:[{name:"custom",entries:5,size:120,mtime:1785830000}] },
  "/warp/list": { ok:true, name:"custom", content:"1.2.3.4\n5.6.7.8" },
  "/update/status": { ok:true, installed:"r-71.1", available:"r-71.1", behind:0,
    last_check:1785830000, pending:[] },
  "/policy/status": { ok:true, enabled:false, policy:"" },
  "/diag": { ok:true, diag:"=== что не так ===\n  явных проблем не найдено\n" },
  "/job": { ok:true, done:true, exit:0, log:"" },
};
global.fetch = async (url) => {
  const p = String(url).replace(/^.*\/cgi-bin\/api/, "").split("?")[0];
  const body = FIXTURES[p] || { ok:true };
  return { ok:true, status:200, json: async () => body, text: async () => JSON.stringify(body) };
};
process.on("unhandledRejection", e => errors.push("async: " + (e && e.message || e)));

try { new Function(fs.readFileSync(path, "utf8"))(); }
catch (e) { console.log("ЗАГРУЗКА УПАЛА: " + e.message); process.exit(1); }

(async () => {
  for (const r of routes) {
    global.location.hash = "#/" + r;
    const before = errors.length;
    try { global.__nav && global.__nav(); await new Promise(res => setTimeout(res, 30)); }
    catch (e) { errors.push(r + ": " + e.message); }
    const bad = errors.slice(before);
    console.log(`  ${bad.length ? "ПАДАЕТ" : "ok    "}  #/${r}${bad.length ? "  — " + bad[0] : ""}`);
  }
  process.exit(errors.length ? 1 : 0);
})();
