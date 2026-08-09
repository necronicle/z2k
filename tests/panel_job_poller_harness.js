// Воспроизведение того, что видели люди: опрос задачи, пока панель переезжает.
//
// ЧТО ИМЕННО ВОСПРОИЗВОДИТСЯ. На пятом шаге переустановки /opt/zapret2 уезжает
// в сторону, а lighttpd остаётся жив — и на /cgi-bin/api/job отвечает 404 из
// собственного обработчика: наш CGI в этот момент просто не существует. Файлы
// задачи при этом лежат в /tmp и переезд переживают, то есть настоящий итог
// узнать МОЖНО, надо лишь дождаться возвращения панели.
//
// Панель этого не делала: три неудачных опроса подряд объявляли задачу
// законченной и дописывали в лог «панель ответила ошибкой: 404 Not Found —
// чем кончилась задача, неизвестно». Через четыре секунды после начала
// обновления. Каждому. При том что обновление шло и доходило до конца.
//
// Здесь исполняется НАСТОЯЩИЙ app.js — не его пересказ. Единственная добавка:
// строка экспорта, вставленная перед закрытием IIFE, чтобы дотянуться до
// поллера (в браузере он приватный и вызывается из обработчика кнопки, до
// которого в node не добраться).
//
// Запуск: node tests/panel_job_poller_harness.js <путь к app.js>

const fs = require("fs");
const APP = process.argv[2];

const toasts = [];

// --- Минимальный DOM ---------------------------------------------------------
const mkEl = () => ({
  _h: "", style: {}, dataset: {},
  classList: { add(){}, remove(){}, toggle(){}, contains(){ return false; } },
  children: [],
  set innerHTML(v){ this._h = String(v); }, get innerHTML(){ return this._h; },
  set textContent(v){ this._h = String(v); }, get textContent(){ return this._h; },
  addEventListener(){}, removeEventListener(){},
  appendChild(c){ this.children.push(c); if (c && c._h) toasts.push(c._h); },
  removeChild(){}, setAttribute(){}, getAttribute(){ return null; },
  removeAttribute(){}, querySelector(){ return null; }, querySelectorAll(){ return []; },
  closest(){ return null; }, focus(){}, blur(){}, click(){}, insertAdjacentHTML(){},
  scrollIntoView(){}, remove(){},
  get firstElementChild(){ return this.children[0] || null; },
});
global.document = {
  documentElement: mkEl(), body: mkEl(), head: mkEl(),
  getElementById(){ return mkEl(); },
  querySelector(){ return null; }, querySelectorAll(){ return []; },
  createElement(){ return mkEl(); }, addEventListener(){}, removeEventListener(){},
};
global.location = { hash: "#/dashboard", href: "http://r/", reload(){} };
global.history = { replaceState(){}, pushState(){} };
const mkStorage = () => { const m = new Map(); return {
  getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k,v) => m.set(k,String(v)),
  removeItem: k => m.delete(k), clear: () => m.clear(), key: i => [...m.keys()][i] ?? null,
  get length(){ return m.size; } }; };
global.localStorage = mkStorage(); global.sessionStorage = mkStorage();
global.window = {
  addEventListener(){}, removeEventListener(){},
  matchMedia(){ return { matches:false, addEventListener(){}, addListener(){} }; },
  location: global.location, localStorage: global.localStorage,
  sessionStorage: global.sessionStorage, document: global.document,
};
global.requestAnimationFrame = fn => setTimeout(fn, 0);
global.cancelAnimationFrame = id => clearTimeout(id);
global.getComputedStyle = () => ({ getPropertyValue: () => "" });
global.navigator = { clipboard: { writeText: async () => {} }, userAgent: "node" };
if (typeof global.Blob !== "function") { global.Blob = class {}; }
if (typeof global.URL.createObjectURL !== "function") {
  global.URL.createObjectURL = () => "blob:stub"; global.URL.revokeObjectURL = () => {};
}

// Часы поллера ускоряем: он планирует себя через setTimeout, и без этого
// прогон занимал бы минуты реального времени. Порядок вызовов сохраняется.
const realTimeout = global.setTimeout;
global.setTimeout = (fn, _ms) => realTimeout(fn, 0);

// --- Панель уехала: ровно тот ответ, что отдаёт lighttpd ---------------------
//
// N опросов подряд отвечают 404 (дерево переезжает), потом панель возвращается
// и отдаёт НАСТОЯЩИЙ итог задачи — он всё это время лежал в /tmp.
const OUTAGE_TICKS = Number(process.env.OUTAGE_TICKS || 8);
let jobCalls = 0;
const DONE_LOG = "[i] Установка завершена";
global.fetch = async (url) => {
  const p = String(url).replace(/^.*\/cgi-bin\/api/, "").split("?")[0];
  if (p === "/job") {
    jobCalls++;
    if (jobCalls <= OUTAGE_TICKS) {
      // Живой сервер без файлов. Тело — HTML lighttpd, не наш JSON.
      return { ok:false, status:404, statusText:"Not Found",
               json: async () => { throw new Error("not json"); },
               text: async () => "<html><body>404 Not Found</body></html>" };
    }
    return { ok:true, status:200,
             json: async () => ({ ok:true, done:true, exit:0, log:DONE_LOG }),
             text: async () => "" };
  }
  return { ok:true, status:200, json: async () => ({ ok:true }), text: async () => "{}" };
};

// --- Загружаем настоящий app.js с приклеенным экспортом -----------------------
let src = fs.readFileSync(APP, "utf8");
const marker = "\n})();";
const at = src.lastIndexOf(marker);
if (at < 0) { console.log("НЕ НАШЁЛ конец IIFE в app.js"); process.exit(1); }
src = src.slice(0, at) +
      "\n  globalThis.__z2k_test = { _startJobPoller, httpError, toast };\n" +
      src.slice(at);

try { new Function(src)(); }
catch (e) { console.log("ЗАГРУЗКА УПАЛА: " + e.message); process.exit(1); }

const T = globalThis.__z2k_test;
if (!T || typeof T._startJobPoller !== "function") {
  console.log("НЕ ДОТЯНУЛСЯ до поллера"); process.exit(1);
}

// --- Прогон -------------------------------------------------------------------
const logs = [];
let finished = null;
const poller = T._startJobPoller("testjob", {
  tolerateOutage: true,
  onDone: (d) => { finished = d; },
});
// Момент каждого сообщения меряем в опросах, а не в порядковом номере записи:
// «объявил задачу законченной, пока панель ещё лежала» — это про время.
poller.attachers.add((log, done) => { logs.push({ log, done, atCall: jobCalls }); });

realTimeout(() => {
  const all = logs.map(x => x.log).join("\n");
  const doneEarly = logs.find(x => x.done && x.atCall <= OUTAGE_TICKS);
  const result = {
    jobCalls,
    outageTicks: OUTAGE_TICKS,
    finished: finished ? { exit: finished.exit, outcome: finished.outcome || null } : null,
    finalLog: finished ? String(finished.log || "") : "",
    // Всё, что панель вообще сказала человеку за прогон.
    everySaid: all,
    toasts,
    // Объявила ли задачу законченной ДО того, как панель вернулась.
    finishedDuringOutage: !!doneEarly,
  };
  console.log(JSON.stringify(result, null, 2));
  process.exit(0);
}, 400);
