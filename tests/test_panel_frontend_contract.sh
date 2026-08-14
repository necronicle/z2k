#!/bin/sh
# tests/test_panel_frontend_contract.sh — контракты фронтенда панели, которые
# нельзя проверить ни на бекенде, ни глазами.
#
# Проверяем ПОВЕДЕНИЕ, а не наличие строк: страницы исполняются в заглушке DOM
# с программируемым fetch, и утверждения делаются по тому, что панель реально
# сделала — что нарисовала, что сказала юзеру, сколько раз сходила в сеть.
# Грепом такое не ловится: «поллер не останавливается» и «старый ответ затирает
# свежий» — это про порядок и время, а не про текст файла.
#
# Каждый поведенческий случай продублирован мета-проверкой: в копии app.js
# ломается ровно та строка, ради которой случай написан, и тест обязан на этом
# покраснеть. Иначе он декорация.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
# Источник — ВЕСЬ JavaScript панели, а не один файл: с 2026-08-14 фронтенд
# разбит на модули, и греп по точке входа не нашёл бы ничего (см.
# tests/lib/panel_js.sh).
JS=$(sh "$(cd "$(dirname "$0")" && pwd)/lib/panel_js.sh")
CSS="$HERE/webpanel/www/style.css"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pfront.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

[ -f "$JS" ] && [ -f "$CSS" ] || { printf '[FAIL] missing panel sources\n'; exit 1; }

# ---------------------------------------------------------------------------
# Статика: контракты, которые обязаны держаться в КАЖДОМ месте файла.
# ---------------------------------------------------------------------------

# Заголовок X-Z2K-Panel — единственное доказательство для origin-стража в
# cgi/auth.sh, что запрос пришёл с этой страницы. Забыть его в одном вызове —
# получить 403 ровно в одной функции, и заметить это только в поле.
nfetch=$(grep -c 'fetch(' "$JS")
bare=$(awk '
    { line[NR] = $0 }
    END {
        for (i = 1; i <= NR; i++) {
            if (line[i] !~ /fetch\(/) continue
            found = 0
            for (j = i; j <= i + 6 && j <= NR; j++) if (line[j] ~ /PANEL_HDR/) found = 1
            if (!found) printf "%d ", i
        }
    }' "$JS")
if [ "$nfetch" -lt 5 ]; then
    no "проверка заголовка не вхолостую (вызовов fetch)" ">=5" "$nfetch"
elif [ -z "$bare" ]; then
    ok "X-Z2K-Panel подмешан во все $nfetch вызовов fetch"
else
    no "X-Z2K-Panel во всех вызовах fetch" "0 голых" "строки: $bare"
fi

# toast(msg, kind) строит класс "toast-"+kind. Класса, которого нет в style.css,
# не существует и визуально: тост уезжает в дефолтную рамку, а автор уверен,
# что подсветил успех.
badkind=""
for k in $(sed -n 's/.*toast(.*, *"\([a-z][a-z]*\)").*/\1/p' "$JS" | sort -u) ok; do
    grep -q "\.toast-$k" "$CSS" || badkind="$badkind $k"
done
[ -z "$badkind" ] \
    && ok "все kind'ы тостов существуют в style.css" \
    || no "kind'ы тостов существуют в style.css" "только описанные" "лишние:$badkind"

# Неизвестный id задачи обязан трактоваться терминально САМОЙ панелью: роутер
# мог не обновиться, и старый бекенд отвечает на такой id HTTP 200 с done:false.
grep -q 'd.status === "unknown"' "$JS" \
    && ok "status==\"unknown\" разбирается на фронте отдельно от done" \
    || no "status==\"unknown\" разбирается на фронте" 'd.status === "unknown"' "нет"

# renderToggles() затирает $app целиком. Джоб завершается через 10-20 секунд —
# юзер к этому моменту уже на другой странице, и адрес с подсветкой меню
# остались бы от неё.
unguarded=$(grep -n 'renderToggles();' "$JS" | grep -vc 'onTogglesPage()')
[ "$unguarded" = "0" ] \
    && ok "renderToggles из onDone вызывается только на своей странице" \
    || no "renderToggles из onDone под проверкой роута" "0 незащищённых" "$unguarded"

# Мёртвый код прежних заходов: спиннер, который не показывался никогда.
dead=$(grep -c 'pollServiceUntil\|waitForServiceActive\|showStatusSpinner\|hideStatusSpinner\|status-spin' "$JS")
[ "$dead" = "0" ] \
    && ok "мёртвый спиннер и его поллеры убраны" \
    || no "мёртвый спиннер убран" "0 упоминаний" "$dead"

# Соседний loadWarpStatus экранирует то же самое — рассинхрон однажды выстрелит.
grep -q '\${escapeHtml(c.value)}' "$JS" && ! grep -q '\${c.value}' "$JS" \
    && ok "значения статус-грида экранируются" \
    || no "значения статус-грида экранируются" "escapeHtml(c.value)" "сырое c.value"

# ---------------------------------------------------------------------------
# Поведение. Драйвер исполняет app.js в заглушке DOM и печатает OK/BAD.
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
    skip "поведенческие сценарии" "node не найден"
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" = 0 ]
    exit
fi

DRV="$TMP/driver.js"
cat > "$DRV" <<'DRIVER'
// Заглушка DOM с программируемым fetch. От tests/panel_harness.js отличается
// тем, что элементы ЗАПОМИНАЮТ обработчики и классы: сценарию нужно кликнуть
// по кнопке и посмотреть, что панель после этого сделала.
//
// app.js загружается ПОСЛЕ настройки сценария и сам рисует стартовый маршрут.
// Иначе панель успевала отрисовать дашборд на дефолтных ответах, её рендер
// выигрывал гонку у сценарного, и проверялся не тот баннер — сценарий зеленел
// на любом коде.
const fs = require("fs");
const APP = process.argv[2];
const SCEN = process.argv[3];

const REG = new Map();
// Селекторы, которые обязаны отвечать «нет такого элемента». openJobModal по
// такому проверяет, не открыта ли уже модалка этого джоба: вернуть заглушку —
// значит заставить его молча выйти и никогда не запустить поллер. Сценарий
// добавляет сюда свои, когда изображает уход со страницы.
const NULL_SEL = [".modal-backdrop[data-job-id="];
const TOASTS = [];
const CALLS = {};
const BODIES = {};
const UNHANDLED = [];

// Ключ элемента — последний #id селектора, если он есть. В настоящем DOM
// document.getElementById("tg-enable") и $app.querySelector("#tg-enable") —
// ОДИН узел; без нормализации это два независимых объекта, и проверка «кнопку
// вернули не в то состояние» проверяла бы не тот элемент, который её меняет.
function canon(s) {
  const parts = String(s).trim().split(/\s*>\s*|\s+/);
  const last = parts[parts.length - 1];
  return /^#[A-Za-z0-9_-]+$/.test(last) ? last : String(s);
}

function mkEl(key) {
  const cls = new Set();
  const el = {
    _sel: key || "?", _h: "", _parent: null,
    style: {}, dataset: {}, attributes: {}, children: [],
    hidden: false, disabled: false, checked: false, value: "", isConnected: true,
    listeners: {},
    classList: {
      add(...c) { c.forEach(x => cls.add(x)); },
      remove(...c) { c.forEach(x => cls.delete(x)); },
      toggle(c, on) { if (on === undefined) { if (cls.has(c)) cls.delete(c); else cls.add(c); } else if (on) cls.add(c); else cls.delete(c); },
      contains(c) { return cls.has(c); },
    },
    get firstElementChild() { return this.children[0] || null; },
    set innerHTML(v) { this._h = String(v); }, get innerHTML() { return this._h; },
    set textContent(v) { this._h = String(v); }, get textContent() { return this._h; },
    addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); },
    removeEventListener() {},
    appendChild(c) { c._parent = this; this.children.push(c); if (this._sel === "#toast-stack") TOASTS.push(String(c._h)); },
    removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); },
    remove() { if (this._parent) this._parent.removeChild(this); },
    setAttribute(k, v) { this.attributes[k] = v; }, getAttribute(k) { return this.attributes[k]; },
    removeAttribute(k) { delete this.attributes[k]; },
    querySelector(s) { return sel(this._sel + ">" + s); },
    querySelectorAll(s) { return selAll(String(s).split(",").map(p => this._sel + ">" + p.trim()).join(",")); },
    closest() { return mkEl("closest"); },
    // Фокус отслеживается: «предупреждение открывается с фокусом на отказе»
    // и «после закрытия фокус вернулся» иначе не проверить ничем.
    focus() { global.document.activeElement = this; },
    blur() {}, click() {}, insertAdjacentHTML() {}, scrollIntoView() {},
    fire(t, ev) { (this.listeners[t] || []).slice().forEach(f => f(ev || {})); },
  };
  return el;
}
function sel(s) {
  const k = canon(s);
  for (const n of NULL_SEL) if (k.indexOf(n) >= 0) return null;
  if (!REG.has(k)) REG.set(k, mkEl(k));
  return REG.get(k);
}
// Список селекторов через запятую — это разные элементы, а не один. Глобальный
// лок ходит именно таким списком, и склеивать его в один объект нельзя.
function selAll(s) {
  return String(s).split(",").map(x => x.trim()).filter(Boolean).map(sel).filter(Boolean);
}
const q = s => sel(s);

global.document = {
  documentElement: mkEl("html"), body: mkEl("body"), head: mkEl("head"),
  activeElement: null, listeners: {},
  getElementById(id) { return sel("#" + id); },
  querySelector(s) { return sel(s); },
  querySelectorAll(s) { return selAll(s); },
  createElement(t) { return mkEl("new:" + t); },
  // Escape ловится на document, а не на самой модалке — без записи
  // обработчиков «Escape = отказ» проверить нечем, а снятие обработчика при
  // закрытии не отличить от его отсутствия.
  addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); },
  removeEventListener(t, fn) {
    const a = this.listeners[t] || [];
    const i = a.indexOf(fn);
    if (i >= 0) a.splice(i, 1);
  },
  fire(t, ev) { (this.listeners[t] || []).slice().forEach(f => f(ev || {})); },
};
global.location = { hash: "#/dashboard", href: "http://r/", reload() {} };
global.history = { replaceState() {}, pushState() {} };
const mkStorage = () => {
  const m = new Map();
  return {
    getItem(k) { return m.has(String(k)) ? m.get(String(k)) : null; },
    setItem(k, v) { m.set(String(k), String(v)); },
    removeItem(k) { m.delete(String(k)); },
    clear() { m.clear(); }, key(i) { return Array.from(m.keys())[i] ?? null; },
    get length() { return m.size; },
  };
};
global.localStorage = mkStorage();
global.sessionStorage = mkStorage();
if (typeof global.URL.createObjectURL !== "function") {
  global.URL.createObjectURL = () => "blob:stub";
  global.URL.revokeObjectURL = () => {};
}
if (typeof global.Blob !== "function") { global.Blob = class { constructor() {} }; }
global.window = {
  addEventListener(t, fn) { if (t === "hashchange") global.__nav = fn; },
  removeEventListener() {}, matchMedia() { return { matches: false, addEventListener() {}, addListener() {} }; },
  location: global.location, localStorage: global.localStorage,
  sessionStorage: global.sessionStorage, document: global.document,
};
global.requestAnimationFrame = fn => setTimeout(fn, 0);
global.cancelAnimationFrame = id => clearTimeout(id);
global.getComputedStyle = () => ({ getPropertyValue: () => "" });
global.navigator = { clipboard: { writeText: async () => {} }, userAgent: "node" };
global.confirm = () => true;
global.prompt = () => null;

const STATUS = {
  ok: true, installed: "r-73", service: "active",
  toggles: { rst_filter: "0", silent_fallback: "0", game_warp: "0", customd: "0",
             dynamic_ttl: "1", stats: "1", ppe: "1", auto_update: "1", autohostlist: "0" },
  tunnel: { running: false },
};
const UPD_OK = { ok: true, installed: "r-73", available: "r-73", behind: 0, last_check: 0, pending: [] };
let ROUTER = async () => ({ ok: true });
global.fetch = async (url, init) => {
  const p = String(url).replace(/^.*\/cgi-bin\/api/, "").split("?")[0];
  const method = (init && init.method) || "GET";
  CALLS[p] = (CALLS[p] || 0) + 1;
  if (init && init.body !== undefined) (BODIES[p] = BODIES[p] || []).push(String(init.body));
  const body = await ROUTER(p, method);
  // Ответ с кодом ошибки — это ОТВЕТ, а не обрыв связи. Панель обязана
  // отличать одно от другого, поэтому фикстура умеет и то и другое:
  // __status делает отказ,брошенное исключение — потерю связи.
  const status = (body && body.__status) || 200;
  return { ok: status < 400, status, statusText: String(status),
           json: async () => body, text: async () => JSON.stringify(body) };
};
const sleep = ms => new Promise(r => setTimeout(r, ms));

const OUT = [];
const check = (name, cond, detail) => OUT.push((cond ? "OK " : "BAD ") + name + (cond ? "" : "  :: " + String(detail || "")));

// Ошибки, которые код поймал и отрисовал, наружу не выходят — но означают
// поломку ровно так же, как брошенное исключение.
process.on("unhandledRejection", e => UNHANDLED.push((e && e.message) || String(e)));

function loadApp() { new Function(fs.readFileSync(APP, "utf8"))(); }

// Эталон предупреждения об автохостлисте. Формулировка согласована с
// владельцем: сверяем её ЦЕЛИКОМ, а не по куску, иначе «смягчил половину
// фразы» пройдёт незамеченным.
const AHL_WARN =
  "Включая автохостлист вы рискуете что будут попадать левые адреса и что-то перестанет работать. " +
  "Жалобы на прекративший работу сайт после включения автохостлиста не принимаются.";

// Модалка подтверждения — единственный .modal-backdrop без data-job-id:
// у джобной он проставлен всегда. Без этого «модалки нет» зеленело бы на
// открытой модалке задачи и наоборот.
function confirmBox() {
  return document.body.children.find(c => c.className === "modal-backdrop" && !c.dataset.jobId) || null;
}
function warnText(bd) {
  // Без .trim(): утверждение обещает «дословно», а тримленное сравнение
  // пропускало добивку пробелами и переводами строк по краям формулировки.
  const m = /<div class="modal-warning" id="confirm-text">([\s\S]*?)<\/div>/.exec(bd ? bd.innerHTML : "");
  return m ? m[1] : null;
}
const postedValue = (p) => {
  const b = (BODIES[p] || [])[0];
  return b === undefined ? null : new URLSearchParams(b).get("value");
};

const SCENARIOS = {
  // Джоб, о котором роутер уже ничего не знает: файлы подчистил job_reap или
  // роутер перезагрузился посреди обновления. Бекенд отвечает УСПЕШНО, поэтому
  // счётчик сетевых ошибок такой ответ не поймает.
  stale_apply: {
    hash: "#/dashboard",
    setup() {
      sessionStorage.setItem("z2k_apply_job", JSON.stringify({ id: "42", target: "r-99" }));
      ROUTER = async (p) => {
        // Форма СТАРОГО бекенда (done:false) — роутер у юзера мог не обновиться.
        if (p === "/job") return { ok: true, status: "unknown", done: false, exit: null, log: "" };
        if (p === "/update/status") return UPD_OK;
        return STATUS;
      };
    },
    async run() {
      await sleep(250);
      const banner = q("#update-banner").innerHTML;
      check("баннер не залипает на «обновление в процессе»", banner.indexOf("в процессе") < 0, banner.slice(0, 140));
      check("id мёртвой задачи убран из sessionStorage", sessionStorage.getItem("z2k_apply_job") === null,
            sessionStorage.getItem("z2k_apply_job"));
    },
  },

  // Тот же ответ, но уже под работающим поллером: он обязан остановиться,
  // разлочить UI и сказать юзеру, что задачи нет.
  poller_gone: {
    hash: "#/dashboard",
    setup() {
      ROUTER = async (p) => {
        if (p === "/job") return { ok: true, status: "unknown", done: false, exit: null, log: "" };
        if (p === "/service/restart") return { ok: true, job: "7" };
        if (p === "/update/status") return UPD_OK;
        return STATUS;
      };
    },
    async run() {
      await sleep(60);
      const btn = q("#app>[data-svc]");
      btn.dataset.svc = "restart";
      btn.fire("click");
      await sleep(2600);
      check("поллер остановился, а не опрашивает вечно", (CALLS["/job"] || 0) <= 2, "запросов /job: " + CALLS["/job"]);
      check("UI разлочен после исчезнувшей задачи", !q(".card").classList.contains("card-locked"), "card-locked висит");
      check("юзеру сказали, что задача не найдена", TOASTS.some(t => /не найдена/.test(t)), TOASTS.join(" | "));
    },
  },

  // Связь с панелью пропала на середине переключения. Ничего в конфиге не
  // откатывалось — значит «вернул как было» это ложь.
  outage: {
    hash: "#/toggles",
    setup() {
      ROUTER = async (p) => {
        if (p === "/job") throw new Error("Failed to fetch");
        if (p === "/toggle/stats") return { ok: true, job: "11" };
        return STATUS;
      };
    },
    async run() {
      await sleep(80);
      const box = q('#app>[data-key="stats"]>input');
      check("тумблер включился после успешного /status", box.disabled === false, "disabled=" + box.disabled);
      box.checked = false;
      box.fire("change");
      await sleep(7000);
      check("панель не врёт про откат", !TOASTS.some(t => /вернул как было/.test(t)), TOASTS.join(" | "));
      // «Результат неизвестен» человеку больше НЕ сообщается. Раньше это был
      // единственный ответ на обрыв, и он же выпадал каждому при штатной
      // переустановке. Вместо догадки панель показывает ФАКТ: дождавшись
      // связи, перечитывает состояние с роутера и говорит, как есть.
      check("панель не рассуждает о том, чего не знает",
            !TOASTS.some(t => /неизвестно|ответила ошибкой/.test(t)), TOASTS.join(" | "));
      check("состояние перечитано с роутера, когда связь вернулась",
            TOASTS.some(t => /фактически/.test(t)), TOASTS.join(" | "));
    },
  },

  // Панель ОТВЕТИЛА отказом — например 403 от origin-стража вкладке со старым
  // закэшированным app.js. Это определённый ответ, а не потеря связи: терпеть
  // его как обрыв значит держать весь UI залоченным MAX_ERRORS × 2 с, то есть
  // около десяти минут.
  job_refused: {
    hash: "#/dashboard",
    setup() {
      ROUTER = async (p) => {
        if (p === "/job") return { __status: 403, ok: false, error: "forbidden" };
        if (p === "/service/restart") return { ok: true, job: "7" };
        if (p === "/update/status") return UPD_OK;
        return STATUS;
      };
    },
    async run() {
      await sleep(60);
      const btn = q("#app>[data-svc]");
      btn.dataset.svc = "restart";
      btn.fire("click");
      await sleep(60);
      check("пока задача идёт, UI заблокирован", q(".card").classList.contains("card-locked"), "лока не было вообще");
      await sleep(6200);
      check("определённый отказ не держит UI залоченным",
            !q(".card").classList.contains("card-locked"), "card-locked висит, запросов /job: " + CALLS["/job"]);
      check("опрос прекращён, а не продолжается", (CALLS["/job"] || 0) <= 3, "запросов /job: " + CALLS["/job"]);
      // Ни жалоб на связь, ни жалоб на отказ: и то и другое человеку ничего
      // не даёт, а при переустановке выпадало всем подряд. UI разлочен, и
      // состояние перечитывается — этого достаточно.
      check("панель ни на что не жалуется",
            !TOASTS.some(t => /Связь с панелью пропала|ответила ошибкой|неизвестно/.test(t)),
            TOASTS.join(" | "));
    },
  },

  // Два loadState в полёте: первый (медленный) обязан молчать, когда его
  // обогнал второй. Иначе удалённая строка «воскресает» после тоста «Удалено».
  state_race: {
    hash: "#/state",
    setup() {
      let n = 0;
      ROUTER = async (p) => {
        if (p === "/state") {
          n++;
          const host = n === 1 ? "old.example" : "new.example";
          if (n === 1) await sleep(300);
          return { ok: true, entries: [{ key: "rkn_tcp", host, strategy: "1", ts: 1, mode: "auto" }] };
        }
        if (p === "/pools") return { ok: true, pools: { rkn_tcp: 5 } };
        return STATUS;
      };
    },
    async run() {
      q("#state-refresh").fire("click");
      await sleep(700);
      const html = q("#state-body").innerHTML;
      check("отрисован свежий ответ", html.indexOf("new.example") >= 0, html.slice(0, 200));
      check("устаревший ответ не перезаписал таблицу", html.indexOf("old.example") < 0, html.slice(0, 200));
    },
  },

  // Пересортировка — операция ВИДА: строки уже в браузере, в сеть она не идёт.
  // Считать её новой загрузкой нельзя — так она отменяет летящий /state и
  // выбрасывает его ответ. Ровно тот баг, ради которого гейт вводился: удалил
  // строку, кликнул по заголовку колонки — удалённая строка снова на экране.
  state_resort_race: {
    hash: "#/state",
    setup() {
      let n = 0;
      ROUTER = async (p) => {
        if (p === "/state") {
          n++;
          if (n > 1) await sleep(400);   // перезагрузка после правки — медленная
          const host = n === 1 ? "before.example" : "after.example";
          return { ok: true, entries: [{ key: "rkn_tcp", host, strategy: "1", ts: 1, mode: "auto" }] };
        }
        if (p === "/pools") return { ok: true, pools: { rkn_tcp: 5 } };
        return STATUS;
      };
    },
    async run() {
      await sleep(80);
      check("первая загрузка отрисована", q("#state-body").innerHTML.indexOf("before.example") >= 0,
            q("#state-body").innerHTML.slice(0, 120));
      q("#state-refresh").fire("click");            // сеть: как после удаления строки
      await sleep(60);
      q("#state-body>th.sortable").fire("click");   // пересортировка, пока ответ в полёте
      await sleep(700);
      const html = q("#state-body").innerHTML;
      check("пересортировка не отменила сетевую загрузку", html.indexOf("after.example") >= 0, html.slice(0, 200));
      q("#state-body>th.sortable").fire("click");   // ещё раз — теперь точно из кэша
      await sleep(50);
      const again = q("#state-body").innerHTML;
      check("кэш обновлён свежим ответом, а не остался прежним",
            again.indexOf("after.example") >= 0 && again.indexOf("before.example") < 0, again.slice(0, 200));
    },
  },

  // Проверка обновлений упала — блок обязан остаться на месте вместе с
  // кнопкой, которой её и запускают, и не объявлять «последнюю версию».
  update_check_failed: {
    hash: "#/dashboard",
    setup() {
      // В разметке блок объявлен hidden — заглушка обязана стартовать так же,
      // иначе «не спрятан» выполняется само собой и ничего не проверяет.
      sel("#update-banner").hidden = true;
      ROUTER = async (p) => {
        if (p === "/update/status") throw new Error("Failed to fetch");
        return STATUS;
      };
    },
    async run() {
      await sleep(250);
      const b = q("#update-banner");
      check("блок обновления не спрятан", b.hidden === false, "hidden=" + b.hidden);
      check("кнопка повторной проверки на месте", b.innerHTML.indexOf("upd-recheck") >= 0, b.innerHTML.slice(0, 160));
      check("панель не выдаёт незнание за «последнюю версию»",
            b.innerHTML.indexOf("последняя версия") < 0, b.innerHTML.slice(0, 160));
    },
  },

  // /status не прочитался: панель не знает, что включено. Текст об этом уже
  // был, а кнопки туннеля под ним оставались живыми — клик по «Отключить»
  // реально валил туннель.
  toggles_status_failed: {
    hash: "#/toggles",
    setup() {
      ROUTER = async (p) => {
        if (p === "/status") throw new Error("Failed to fetch");
        return { ok: true };
      };
    },
    async run() {
      await sleep(120);
      const err = q("#toggles-error");
      check("сказано, что состояние не прочитано",
            err.hidden === false && err.innerHTML.indexOf("toggles-retry") >= 0, "hidden=" + err.hidden);
      check("кнопка «Включить» туннель не кликается", q("#tg-enable").disabled === true,
            "disabled=" + q("#tg-enable").disabled);
      check("кнопка «Отключить» туннель не кликается", q("#tg-disable").disabled === true,
            "disabled=" + q("#tg-disable").disabled);
    },
  },

  // /status на роутере занимает секунды — юзер успевает уйти со страницы.
  // Ответ приходит на пустое место: элементов «Режимов» в документе больше
  // нет. _stale ловит только более свежую загрузку, но не смену маршрута.
  toggles_left_page: {
    hash: "#/toggles",
    setup() {
      ROUTER = async (p) => {
        if (p === "/status") { await sleep(250); return STATUS; }
        return { ok: true };
      };
    },
    async run() {
      // Уход со страницы: $app перерисован, элементов «Режимов» больше нет.
      NULL_SEL.push("#tg-state-badge", "#tg-enable", "#tg-disable",
                    "#policy-name", "#policy-status", "#policy-mode", "#policy-save-btn");
      await sleep(500);
      check("ответ, пришедший после ухода со страницы, ничего не уронил",
            UNHANDLED.length === 0, UNHANDLED.join(" | "));
    },
  },

  // Автохостлист — единственный тумблер, который сам решает, чей трафик
  // обходить. Ошибка движка выглядит для юзера как «сайт сломался», поэтому
  // включение спрашивают вслух. Пока юзер не ответил, в сеть не уходит
  // НИЧЕГО: запрос, отправленный до ответа, уже перезапустил бы сервис.
  autohostlist_warn: {
    hash: "#/toggles",
    setup() {
      ROUTER = async (p) => {
        if (p === "/toggle/autohostlist") return { ok: true, job: "21" };
        if (p === "/job") return { ok: true, done: true, exit: 0, log: "готово" };
        return STATUS;
      };
    },
    async run() {
      await sleep(80);
      const box = q('#app>[data-key="autohostlist"]>input');
      box.focus();
      box.checked = true;      // change в браузере срабатывает УЖЕ после переключения
      box.fire("change");
      await sleep(40);
      const bd = confirmBox();
      check("включение автохостлиста спрашивает подтверждение", bd !== null, "модалки нет");
      check("до ответа юзера ни одного запроса на /toggle/",
            !CALLS["/toggle/autohostlist"], "запросов: " + CALLS["/toggle/autohostlist"]);
      check("текст предупреждения дословный", warnText(bd) === AHL_WARN, JSON.stringify(warnText(bd)));
      check("кнопки подписаны «Включать» и «Не включать»",
            bd !== null && /id="confirm-cancel">Не включать<\/button>/.test(bd.innerHTML)
                        && /id="confirm-ok">Включать<\/button>/.test(bd.innerHTML),
            bd ? bd.innerHTML.slice(0, 400) : "модалки нет");
      // Акцентная кнопка обязана совпадать с той, на которой стоит фокус:
      // диалог не должен подталкивать к действию, от которого предостерегает.
      check("акцентная кнопка — безопасная, а не «Включать»",
            bd !== null && /class="btn btn-primary" id="confirm-cancel"/.test(bd.innerHTML)
                        && !/btn-primary" id="confirm-ok"/.test(bd.innerHTML),
            bd ? bd.innerHTML.slice(0, 400) : "модалки нет");
      check("диалог объявлен ассистивным технологиям",
            bd !== null && /role="dialog"/.test(bd.innerHTML) && /aria-modal="true"/.test(bd.innerHTML)
                        && /aria-describedby="confirm-text"/.test(bd.innerHTML),
            bd ? bd.innerHTML.slice(0, 200) : "модалки нет");
      check("тумблер заблокирован, пока висит вопрос",
            box.disabled === true, "disabled=" + box.disabled);
      check("фокус стоит на отказе, чтобы случайный Enter ничего не включил",
            document.activeElement === q("#confirm-cancel"),
            "activeElement=" + (document.activeElement && document.activeElement._sel));
      // «Фокус вернулся» и «модалка убрана» обязаны требовать, чтобы модалка
      // вообще была: иначе оба утверждения выполняются сами собой на коде,
      // который ничего не показывает.
      const focusMoved = document.activeElement !== box;
      q("#confirm-cancel").fire("click");
      await sleep(60);
      check("«Не включать» — запроса так и не было",
            !CALLS["/toggle/autohostlist"], "запросов: " + CALLS["/toggle/autohostlist"]);
      check("«Не включать» — галочка снята", box.checked === false, "checked=" + box.checked);
      check("показанная модалка убрана из DOM", bd !== null && confirmBox() === null,
            "была=" + (bd !== null) + " осталась=" + (confirmBox() !== null));
      check("фокус уходил в модалку и вернулся туда, где был",
            focusMoved && document.activeElement === box,
            "уходил=" + focusMoved + " activeElement=" + (document.activeElement && document.activeElement._sel));
    },
  },

  // Согласие: запрос уходит ровно один и ровно после ответа юзера. Порядок
  // здесь и есть проверяемое: «один запрос с value=1» само по себе зеленеет
  // и на коде, который спрашивать не умеет вовсе.
  autohostlist_accept: {
    hash: "#/toggles",
    setup() {
      ROUTER = async (p) => {
        if (p === "/toggle/autohostlist") return { ok: true, job: "21" };
        if (p === "/job") return { ok: true, done: true, exit: 0, log: "готово" };
        return STATUS;
      };
    },
    async run() {
      await sleep(80);
      const box = q('#app>[data-key="autohostlist"]>input');
      box.checked = true;
      box.fire("change");
      await sleep(40);
      const before = CALLS["/toggle/autohostlist"] || 0;
      const shown = confirmBox() !== null;
      check("подтверждение показано, и до него сеть не трогали",
            shown && before === 0, "модалка=" + shown + " запросов=" + before);
      q("#confirm-ok").fire("click");
      await sleep(80);
      const after = CALLS["/toggle/autohostlist"] || 0;
      check("«Включать» — ровно один запрос, только после ответа, value=1",
            before === 0 && after === 1 && postedValue("/toggle/autohostlist") === "1",
            "before=" + before + " after=" + after + " value=" + postedValue("/toggle/autohostlist"));
      check("показанная модалка закрыта после выбора", shown && confirmBox() === null,
            "была=" + shown + " осталась=" + (confirmBox() !== null));
    },
  },

  // Escape равносилен «Не включать»: то же отсутствие запроса и та же снятая
  // галочка. Второй Escape уже некому услышать — обработчик снят вместе с
  // модалкой, промис резолвится один раз.
  autohostlist_escape: {
    hash: "#/toggles",
    setup() {
      ROUTER = async (p) => {
        if (p === "/toggle/autohostlist") return { ok: true, job: "21" };
        if (p === "/job") return { ok: true, done: true, exit: 0, log: "готово" };
        return STATUS;
      };
    },
    async run() {
      await sleep(80);
      const box = q('#app>[data-key="autohostlist"]>input');
      box.checked = true;
      box.fire("change");
      await sleep(40);
      const wasOpen = confirmBox() !== null;
      check("модалка открыта до Escape", wasOpen, "модалки нет");
      check("до Escape запросов не было",
            !CALLS["/toggle/autohostlist"], "запросов: " + CALLS["/toggle/autohostlist"]);
      document.fire("keydown", { key: "Escape" });
      await sleep(60);
      check("Escape = отказ: запроса нет",
            !CALLS["/toggle/autohostlist"], "запросов: " + CALLS["/toggle/autohostlist"]);
      check("Escape = отказ: галочка снята", box.checked === false, "checked=" + box.checked);
      check("Escape закрыл открытую модалку", wasOpen && confirmBox() === null,
            "была=" + wasOpen + " осталась=" + (confirmBox() !== null));
      document.fire("keydown", { key: "Escape" });
      await sleep(40);
      check("повторный Escape ничего не включил",
            !CALLS["/toggle/autohostlist"] && box.checked === false,
            "запросов: " + CALLS["/toggle/autohostlist"] + " checked=" + box.checked);
    },
  },

  // Выключение — не опасная операция, и спрашивать про неё нечего. Случай
  // ловит расширение условия до «любое переключение автохостлиста»;
  // на до-фиксовом коде он зелёный по построению — там модалки нет вообще.
  autohostlist_off: {
    hash: "#/toggles",
    setup() {
      STATUS.toggles.autohostlist = "1";
      ROUTER = async (p) => {
        if (p === "/toggle/autohostlist") return { ok: true, job: "22" };
        if (p === "/job") return { ok: true, done: true, exit: 0, log: "готово" };
        return STATUS;
      };
    },
    async run() {
      await sleep(80);
      const box = q('#app>[data-key="autohostlist"]>input');
      check("тумблер отрисован включённым", box.checked === true, "checked=" + box.checked);
      box.checked = false;
      box.fire("change");
      await sleep(60);
      check("выключение не спрашивает подтверждения", confirmBox() === null, "модалка показана");
      check("выключение сразу ушло на бекенд с value=0",
            (CALLS["/toggle/autohostlist"] || 0) === 1 && postedValue("/toggle/autohostlist") === "0",
            "запросов=" + CALLS["/toggle/autohostlist"] + " value=" + postedValue("/toggle/autohostlist"));
    },
  },

  // Остальные тумблеры предупреждение не наследуют. Случай ловит расширение
  // условия до «любое включение»; на до-фиксовом коде зелёный по построению.
  other_toggle_no_warn: {
    hash: "#/toggles",
    setup() {
      ROUTER = async (p) => {
        if (p === "/toggle/rst-filter") return { ok: true, job: "23" };
        if (p === "/job") return { ok: true, done: true, exit: 0, log: "готово" };
        return STATUS;
      };
    },
    async run() {
      await sleep(80);
      const box = q('#app>[data-key="rst_filter"]>input');
      box.checked = true;
      box.fire("change");
      await sleep(60);
      check("другой тумблер не спрашивает подтверждения", confirmBox() === null, "модалка показана");
      check("другой тумблер ушёл на бекенд сразу",
            (CALLS["/toggle/rst-filter"] || 0) === 1, "запросов: " + CALLS["/toggle/rst-filter"]);
    },
  },

  // Способы закрыть диалог, которые сценарии выше не трогали. Без них можно
  // было снять условие `e.target === backdrop` или защиту от двойного ответа,
  // и весь набор остался бы зелёным.
  autohostlist_dismiss: {
    hash: "#/toggles",
    setup() {
      ROUTER = async (p) => {
        if (p === "/toggle/autohostlist") return { ok: true, job: "31" };
        if (p === "/job") return { ok: true, done: true, exit: 0, log: "готово" };
        return STATUS;
      };
    },
    async run() {
      await sleep(80);
      const box = q('#app>[data-key="autohostlist"]>input');
      box.checked = true;
      box.fire("change");
      await sleep(40);
      const bd = confirmBox();
      check("диалог открыт", bd !== null, "модалки нет");

      // Клик ВНУТРИ окна не должен считаться ответом. Бьём по самой подложке,
      // подставляя target внутреннего узла: именно так всплывший клик выглядит
      // для её обработчика. Клик по внутреннему узлу напрямую этот обработчик
      // не задел бы вовсе, и мутант «закрываться от любого клика» прошёл бы.
      bd.fire("click", { target: q("#confirm-title") });
      await sleep(30);
      check("клик внутри окна ничего не закрывает",
            confirmBox() !== null, "диалог исчез от клика по своему же заголовку");
      check("клик внутри окна не ушёл на бекенд",
            !CALLS["/toggle/autohostlist"], "запросов: " + CALLS["/toggle/autohostlist"]);

      // Клик по подложке = отказ.
      bd.fire("click", { target: bd });
      await sleep(40);
      check("клик по подложке закрыл диалог", confirmBox() === null, "диалог на месте");
      check("клик по подложке = отказ: запроса нет",
            !CALLS["/toggle/autohostlist"], "запросов: " + CALLS["/toggle/autohostlist"]);
      check("клик по подложке = отказ: галочка снята", box.checked === false, "checked=" + box.checked);
      check("тумблер разблокирован после отказа", box.disabled === false, "disabled=" + box.disabled);

      // Ответ ровно один: Escape после закрытия не должен ничего дорезолвить.
      document.fire("keydown", { key: "Escape" });
      await sleep(30);
      check("повторный ответ невозможен",
            !CALLS["/toggle/autohostlist"] && box.checked === false,
            "запросов: " + CALLS["/toggle/autohostlist"] + " checked=" + box.checked);
    },
  },
};

(async () => {
  const sc = SCENARIOS[SCEN];
  if (!sc) { console.log("BAD неизвестный сценарий " + SCEN); process.exit(1); }
  const guard = setTimeout(() => { console.log("BAD сценарий " + SCEN + " не уложился в таймаут"); process.exit(1); }, 25000);
  try {
    global.location.hash = sc.hash;
    sc.setup();
    loadApp();          // панель сама отрисует стартовый маршрут — уже на фикстурах сценария
    await sc.run();
  } catch (e) { check("сценарий отработал", false, (e && e.message) || e); }
  await sleep(20);      // дать unhandledRejection долететь до обработчика
  check("ни одно исключение не ушло в никуда", UNHANDLED.length === 0, UNHANDLED.join(" | "));
  clearTimeout(guard);
  OUT.forEach(l => console.log(l));
  process.exit(OUT.some(l => l.slice(0, 3) === "BAD") ? 1 : 0);
})();
DRIVER

# Прогон сценария: каждая строка драйвера становится своим [PASS]/[FAIL].
run_scen() {
    _app="$1"; _scen="$2"
    node "$DRV" "$_app" "$_scen" 2>&1 | while IFS= read -r line; do
        case "$line" in
            "OK "*)  printf '[PASS] %s\n' "${line#OK }" ;;
            "BAD "*) printf '[FAIL] %s\n' "${line#BAD }" ;;
            *)       printf '       %s\n' "$line" ;;
        esac
    done
}

# Счётчики внутри while-пайпа теряются (subshell), поэтому считаем по выводу.
for scen in stale_apply poller_gone outage job_refused state_race state_resort_race \
            update_check_failed toggles_status_failed toggles_left_page \
            autohostlist_warn autohostlist_accept autohostlist_escape \
            autohostlist_dismiss autohostlist_off other_toggle_no_warn; do
    out=$(run_scen "$JS" "$scen")
    printf '%s\n' "$out"
    PASS=$((PASS + $(printf '%s\n' "$out" | grep -c '^\[PASS\]')))
    FAIL=$((FAIL + $(printf '%s\n' "$out" | grep -c '^\[FAIL\]')))
done

# ---------------------------------------------------------------------------
# Мета: сломать ровно ту строку, ради которой сценарий написан, и убедиться,
# что тест краснеет. Тест, который не умеет падать, ничего не охраняет.
# ---------------------------------------------------------------------------
meta() {
    _label="$1"; _scen="$2"; _sed="$3"
    _mut="$TMP/mutant.js"
    sed "$_sed" "$JS" > "$_mut"
    if cmp -s "$_mut" "$JS"; then
        no "мета-случай собрался: $_label" "мутация применилась" "файл не изменился"
        return
    fi
    if node "$DRV" "$_mut" "$_scen" >/dev/null 2>&1; then
        no "тест ловит поломку: $_label" "сценарий падает" "прошёл"
    else
        ok "тест ловит поломку: $_label"
    fi
}
meta "неизвестный id перестал быть терминальным" poller_gone 's/d\.status === "unknown"/d.status === "z2k_never"/g'
meta "уборка мёртвого id обновления" stale_apply 's/d\.status === "unknown"/d.status === "z2k_never"/g'
meta "снят гейт по номеру запроса /state" state_race '/_stale("state", seq)/d'
meta "пересортировка снова считается новой загрузкой" state_resort_race 's/let seq = 0;/let seq = _newLoad("state");/'
meta "отказ панели снова неотличим от обрыва связи" job_refused 's/typeof e\.httpStatus === "number"/false/'
meta "кнопки туннеля снова живы при непрочитанном статусе" toggles_status_failed '/"#tg-enable"), true);/d; /"#tg-disable"), true);/d'
meta "ответ после ухода со страницы снова роняет страницу" toggles_left_page '/if (!badge) return;/d'
meta "упавшая проверка обновлений снова прячет весь блок" update_check_failed 's/^      err = e;$/      banner.hidden = true; return;/'
meta "предупреждение автохостлиста снято" autohostlist_warn 's/key === "autohostlist" && wanted === "1"/false/'
meta "запрос уходит, не дожидаясь ответа юзера" autohostlist_accept 's/const go = await confirmModal/const go = true; confirmModal/'
meta "Escape перестал быть отказом" autohostlist_escape 's/if (e.key === "Escape") { finish(false); return; }/return;/'
# Клик по подложке и защита от повторного ответа — их ловит только
# autohostlist_dismiss, поэтому мутанты именно на эти две строки.
meta "клик по подложке перестал быть отказом" autohostlist_dismiss 's/if (e.target === backdrop) finish(false);//'
meta "подложка закрывается от любого клика" autohostlist_dismiss 's/if (e.target === backdrop) finish(false);/finish(false);/'
# Мутанта на `if (answered) return;` тут нет намеренно: повторный resolve
# промис молча игнорирует сам, и снятие этой защиты не даёт НИ ОДНОГО
# наблюдаемого отличия. Утверждение, которое нельзя опровергнуть, — декорация;
# сама защита остаётся в коде как страховка от будущих побочных эффектов в
# finish(), но охранять её тестом нечем.
meta "тумблер не блокируется на время вопроса" autohostlist_warn 's/^      box.disabled = true;$//'
meta "спрашивают и при выключении" autohostlist_off 's/key === "autohostlist" && wanted === "1"/key === "autohostlist"/'
meta "спрашивают на любом тумблере" other_toggle_no_warn 's/key === "autohostlist" && wanted === "1"/wanted === "1"/'
# Фокус на отказе: с фокусом на «Включать» Enter по привычке включает молча.
meta "фокус уехал на кнопку согласия" autohostlist_warn 's/^      cancelBtn\.focus();$/      okBtn.focus();/'

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
