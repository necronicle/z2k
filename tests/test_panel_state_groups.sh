#!/bin/sh
# tests/test_panel_state_groups.sh — группировка строк ротатора по домену.
#
# Ключ ротации у служебных пулов — полное имя хоста, и таблица «Автоподбор»
# показывала каждый поддомен отдельной строкой: 18 строк apple.com, до сотни у
# discord.media. Строки теперь собраны под заголовком родительского домена.
#
# Что здесь охраняется и почему именно это:
#
#   * Группировка — только ВИД. Строка внутри группы обязана уходить в API с
#     тем же сырым ключом (имя|семейство), иначе удаление и заморозка молча
#     промахнутся мимо записи.
#   * Родитель считается с учётом национальных зон второго уровня: без этого
#     все сайты *.co.uk слиплись бы в одну «группу co.uk».
#   * Адрес вместо имени не группируется — «3.4» из 1.2.3.4 бессмыслица.
#   * Заголовок получает только группа из РАЗНЫХ имён: v4 и v6 одного хоста —
#     не повод для раскрывашки.
#   * По умолчанию свёрнуто, раскрытие переживает перерисовку (после любой
#     правки таблица рисуется заново) и не ходит в сеть.
#   * Сортировка по домену ставит группы по имени родителя, а равные строки
#     в любой сортировке идут по домену — иначе группы перемешаны случайно.
#
# Поведение проверяется исполнением страницы в заглушке DOM, и каждый случай
# продублирован мутантом: сломанная строка обязана дать красный.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
JS=$(sh "$(cd "$(dirname "$0")" && pwd)/lib/panel_js.sh")
CSS="$HERE/webpanel/www/style.css"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pgroups.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

[ -f "$JS" ] && [ -f "$CSS" ] || { printf '[FAIL] missing panel sources\n'; exit 1; }

# --- CSS: свёрнутая группа прячет строки, и правило не проигрывает карточкам --
# На телефоне `.state-table tr { display: block }` стоит ПОЗЖЕ по файлу. Правило
# скрытия обязано быть специфичнее, иначе свёрнутая группа на телефоне
# показывает всё содержимое, а на десктопе прячет — и тест в браузере на
# широком экране этого не увидит.
grep -q '^\.state-table tbody\.sg-closed tr\.sg-member { display: none; }' "$CSS" \
    && ok "свёрнутая группа прячет свои строки (специфичнее мобильной карточки)" \
    || no "правило скрытия строк свёрнутой группы" ".state-table tbody.sg-closed tr.sg-member" "нет"
# Подпись поля на телефоне живёт в td::before. Направляющая группы, нарисованная
# тем же псевдоэлементом, затёрла бы подпись «Домен».
if grep -q 'td\.sg-leaf::before' "$CSS"; then
    no "направляющая группы не занимает td::before" "фон" "::before"
else
    ok "направляющая группы не занимает td::before (там подпись поля на телефоне)"
fi

if ! command -v node >/dev/null 2>&1; then
    skip "поведенческие сценарии" "node не найден"
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" = 0 ]
    exit
fi

# --- родитель домена ---------------------------------------------------------
awk '/const SLD_GENERIC = new Set/,/\]\);/{print} /function groupDomain\(/,/^  \}/{print}' "$JS" \
    | sed 's/^  //' > "$TMP/gd.js"
cat >> "$TMP/gd.js" <<'JS'
const cases = [
  ["finland10000.discord.media", "discord.media"],
  ["discord.media",              "discord.media"],
  ["gs-loc.apple.com",           "apple.com"],
  ["gspe35-ssl.ls.apple.com",    "apple.com"],
  ["news.bbc.co.uk",             "bbc.co.uk"],
  ["bbc.co.uk",                  "bbc.co.uk"],
  ["www.mos.msk.ru",             "mos.msk.ru"],
  ["x.t.co",                     "t.co"],
  ["rr2---sn-example-node.gvt1.com", "gvt1.com"],
  ["1.2.3.4",                    "1.2.3.4"],
  ["2a00:1450::200e",            "2a00:1450::200e"],
  ["localhost",                  "localhost"],
  ["API.X.COM",                  "x.com"],
];
for (const [inp, want] of cases) {
  const got = groupDomain(inp);
  console.log((got === want ? "OK " : "BAD ") + inp + " -> " + got + (got === want ? "" : " (ждали " + want + ")"));
}
JS
out=$(node "$TMP/gd.js" 2>&1)
nb=$(printf '%s\n' "$out" | grep -c '^BAD' || true)
nk=$(printf '%s\n' "$out" | grep -c '^OK' || true)
if [ "$nb" = 0 ] && [ "$nk" -ge 13 ]; then
    ok "родитель домена: $nk случаев (поддомены, co.uk, адреса, регистр)"
else
    no "родитель домена" "0 плохих из 13" "$(printf '%s' "$out" | tr '\n' ' ')"
fi

# --- группы человека: модель -------------------------------------------------
# Сопоставление по окончанию имени и правки файла построчно. Функции вынимаются
# из склейки и исполняются: проверка «в файле есть строка» здесь бесполезна.
for fn in domainGroupSections domainGroupIndex matchDomainGroup dgJoin domainGroupsAdd domainGroupsReplace domainGroupsAppend domainGroupProblem domainGroupsTextProblem; do
    awk -v f="function $fn(" 'index($0, "  " f) == 1 {g=1} g {print} g && /^  }$/ {exit}' "$JS"
done | sed 's/^  //' > "$TMP/ug.js"
cat >> "$TMP/ug.js" <<'JS'
const out = [];
const t = (label, cond, got) => out.push((cond ? "OK " : "BAD ") + label + (cond ? "" : " — " + got));
const text = "# мои\n[Google]\ngoogle.com\n\n[Почта]\nmail.google.com\n# заметка\n";
const { sections } = domainGroupSections(text);
const idx = domainGroupIndex(sections);
t("секции разобраны", sections.length === 2 && sections[1].name === "Почта", JSON.stringify(sections));
t("поддомен попадает в группу домена", matchDomainGroup(idx, "www.google.com|4") === 0, matchDomainGroup(idx, "www.google.com|4"));
t("самое длинное совпадение выигрывает", matchDomainGroup(idx, "x.mail.google.com|6") === 1, matchDomainGroup(idx, "x.mail.google.com|6"));
t("похожий хвост не совпадает", matchDomainGroup(idx, "notgoogle.com|4") === -1, matchDomainGroup(idx, "notgoogle.com|4"));
t("адрес ни в какую группу", matchDomainGroup(domainGroupIndex(domainGroupSections("[N]\n4\n").sections), "1.2.3.4|4") === -1, "совпал");
const added = domainGroupsAdd(text, "почта", "gmail.com");
t("добавление в секцию без учёта регистра и с комментариями на месте",
  added === "# мои\n[Google]\ngoogle.com\n\n[Почта]\nmail.google.com\n# заметка\ngmail.com\n", JSON.stringify(added));
t("новая группа дописывается в конец",
  domainGroupsAdd(text, "Discord", "discord.com").endsWith("# заметка\n\n[Discord]\ndiscord.com\n"), JSON.stringify(domainGroupsAdd(text, "Discord", "discord.com")));
t("удаление секции не задевает соседей",
  domainGroupsReplace(text, 0, "", "") === "# мои\n[Почта]\nmail.google.com\n# заметка\n", JSON.stringify(domainGroupsReplace(text, 0, "", "")));
t("кириллический двойник имени отклонён", /уже есть/.test(domainGroupProblem(sections, -1, "ПОЧТА", "x.org")), domainGroupProblem(sections, -1, "ПОЧТА", "x.org"));
t("домен из другой группы отклонён", /Google/.test(domainGroupProblem(sections, 1, "Почта", "google.com")), domainGroupProblem(sections, 1, "Почта", "google.com"));
t("адрес сайта с протоколом отклонён", /не домен/.test(domainGroupProblem(sections, -1, "X", "https://x.org")), domainGroupProblem(sections, -1, "X", "https://x.org"));
t("режим текста: кириллический двойник имени отклонён",
  /регистром/.test(domainGroupsTextProblem("[Дискорд]\na.com\n[дискорд]\nb.com\n")), domainGroupsTextProblem("[Дискорд]\na.com\n[дискорд]\nb.com\n"));
t("режим текста: разные имена проходят", domainGroupsTextProblem("[A]\na.com\n[B]\nb.com\n") === "", "отказ");
t("скобки в имени отклонены", /скобки/.test(domainGroupProblem(sections, -1, "a]b", "x.org")), domainGroupProblem(sections, -1, "a]b", "x.org"));
console.log(out.join("\n"));
JS
ug_out=$(node "$TMP/ug.js" 2>&1)
ug_bad=$(printf '%s\n' "$ug_out" | grep -c '^BAD' || true)
ug_ok=$(printf '%s\n' "$ug_out" | grep -c '^OK' || true)
if [ "$ug_bad" = 0 ] && [ "$ug_ok" -ge 14 ]; then
    ok "группы человека, модель: $ug_ok случаев (суффиксы, правки файла, проверки ввода)"
else
    no "группы человека, модель" "0 плохих из 14" "$(printf '%s' "$ug_out" | tr '\n' ' ')"
fi

# --- отрисовка ---------------------------------------------------------------
DRV="$TMP/driver.js"
cat > "$DRV" <<'DRIVER'
const fs = require("fs");
const APP = process.argv[2];
const SCEN = process.argv[3];

const REG = new Map();
function canon(s) {
  const parts = String(s).trim().split(/\s*>\s*|\s+/);
  const last = parts[parts.length - 1];
  return /^#[A-Za-z0-9_-]+$/.test(last) ? last : String(s);
}
function mkEl(key) {
  const cls = new Set();
  return {
    _sel: key, _h: "", style: {}, dataset: {}, attributes: {}, children: [],
    hidden: false, disabled: false, value: "", listeners: {},
    classList: {
      add(...c) { c.forEach(x => cls.add(x)); }, remove(...c) { c.forEach(x => cls.delete(x)); },
      toggle(c, on) { if (on === undefined ? !cls.has(c) : on) cls.add(c); else cls.delete(c); },
      contains(c) { return cls.has(c); },
    },
    // Перерисовка УНИЧТОЖАЕТ потомков вместе с их обработчиками — в браузере
    // старые узлы просто исчезают. Заглушка же раздаёт один и тот же объект
    // на каждый запрос селектора и без этой строки копила подписки: после
    // трёх отрисовок один клик звал три обработчика, переключатель щёлкал
    // трижды, и проверка зеленела по чётности, а не по делу.
    set innerHTML(v) {
      for (const [k, el] of REG) if (k.startsWith(this._sel + ">")) el.listeners = {};
      this._h = String(v);
    },
    get innerHTML() { return this._h; },
    set textContent(v) { this._h = String(v); }, get textContent() { return this._h; },
    addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); },
    removeEventListener() {}, appendChild() {}, removeChild() {}, remove() {},
    setAttribute(k, v) { this.attributes[k] = String(v); }, getAttribute(k) { return this.attributes[k]; },
    removeAttribute(k) { delete this.attributes[k]; },
    querySelector(s) { return sel(this._sel + ">" + s); },
    querySelectorAll(s) { return String(s).split(",").map(p => sel(this._sel + ">" + p.trim())); },
    closest() { return null; }, focus() {}, blur() {}, click() {}, insertAdjacentHTML() {}, scrollIntoView() {},
    fire(t, ev) { (this.listeners[t] || []).slice().forEach(f => f(ev || {})); },
  };
}
function sel(s) { const k = canon(s); if (!REG.has(k)) REG.set(k, mkEl(k)); return REG.get(k); }
global.document = {
  documentElement: mkEl("html"), body: mkEl("body"), head: mkEl("head"), listeners: {},
  getElementById(id) { return sel("#" + id); }, querySelector(s) { return sel(s); },
  querySelectorAll(s) { return String(s).split(",").map(x => sel(x.trim())); },
  createElement(t) { return mkEl("new:" + t); }, addEventListener() {}, removeEventListener() {},
};
global.location = { hash: "#/dashboard", href: "http://r/", reload() {} };
global.history = { replaceState() {}, pushState() {} };
const mkStorage = () => {
  const m = new Map();
  return { getItem(k) { return m.has(String(k)) ? m.get(String(k)) : null; },
           setItem(k, v) { m.set(String(k), String(v)); }, removeItem(k) { m.delete(String(k)); },
           clear() { m.clear(); }, key(i) { return Array.from(m.keys())[i] ?? null; }, get length() { return m.size; } };
};
global.localStorage = mkStorage();
global.sessionStorage = mkStorage();
global.window = {
  addEventListener(t, fn) { if (t === "hashchange") global.__nav = fn; }, removeEventListener() {},
  matchMedia() { return { matches: false, addEventListener() {}, addListener() {} }; },
  location: global.location, localStorage: global.localStorage, sessionStorage: global.sessionStorage,
  document: global.document,
};
global.requestAnimationFrame = fn => setTimeout(fn, 0);
global.cancelAnimationFrame = id => clearTimeout(id);
global.getComputedStyle = () => ({ getPropertyValue: () => "" });
global.navigator = { clipboard: { writeText: async () => {} }, userAgent: "node" };
global.confirm = () => true;

const NOW = Math.floor(Date.now() / 1000);
// Порядок в ответе намеренно перемешан: сортировка обязана его навести сама.
const ENTRIES = [
  { key: "rkn_tcp", host: "latency.discord.media|6",       strategy: "1", ts: NOW - 50,  mode: "auto" },
  { key: "rkn_tcp", host: "chatgpt.com|6",                 strategy: "2", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "news.bbc.co.uk|4",              strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "finland10001.discord.media|4",  strategy: "4", ts: NOW - 900, mode: "frozen" },
  { key: "rkn_tcp", host: "1.2.3.4|4",                     strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "sport.other.co.uk|4",           strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "finland10000.discord.media|4",  strategy: "2", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "chatgpt.com|4",                 strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "www.bbc.co.uk|4",               strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "2a00:1450::200e|6",             strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "cdn.discordapp.com|4",          strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "discord_udp", host: "nohost",                    strategy: "1", ts: NOW - 900, mode: "auto" },
  // Тот же домен в ДРУГОМ пуле: у quic свой арсенал, и складывать такие строки
  // в одну группу нельзя — сводка стратегий стала бы про разные наборы.
  { key: "quic", host: "latency.discord.media|4",           strategy: "3", ts: NOW - 900, mode: "auto" },
  { key: "quic", host: "finland10000.discord.media|4",      strategy: "1", ts: NOW - 900, mode: "auto" },
];
const CALLS = {};
const REQS = [];
// Сценарии про холодный кэш и про ошибку задают эти два рычага в setup():
// __stateDelay — сколько /state «едет» (на роутере это ~2.4 с шелл-CGI),
// __failStateAfter — с какого по счёту вызова /state отвечать отказом.
global.__stateDelay = 0;
global.__failStateAfter = 0;
global.fetch = async (url, init) => {
  const full = String(url).replace(/^.*\/cgi-bin\/api/, "");
  const p = full.split("?")[0];
  CALLS[p] = (CALLS[p] || 0) + 1;
  REQS.push({ path: p, url: full, body: init && init.body ? String(init.body) : "" });
  let body = { ok: true };
  if (p === "/state") {
    if (global.__stateDelay) await new Promise(r => setTimeout(r, global.__stateDelay));
    if (global.__failStateAfter && CALLS[p] >= global.__failStateAfter) {
      return { ok: false, status: 500, statusText: "Internal Server Error",
               json: async () => ({ ok: false, error: "движок не отвечает" }),
               text: async () => '{"ok":false,"error":"движок не отвечает"}' };
    }
    body = { ok: true, entries: ENTRIES };
  }
  if (p === "/pools") body = { ok: true, pools: { rkn_tcp: 50 } };
  // Группы человека. По умолчанию файла нет — таблица обязана выглядеть
  // ровно как до появления групп; сценарии про группы кладут свой текст.
  if (p === "/domain-groups") {
    if (global.__groupsFail) {
      return { ok: false, status: 404, statusText: "Not Found",
               json: async () => ({ ok: false, error: "unknown route" }), text: async () => '{"ok":false}' };
    }
    body = { ok: true, revision: "0".repeat(64), text: global.__groupsText || "" };
  }
  return { ok: true, status: 200, json: async () => body, text: async () => JSON.stringify(body) };
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const check = (label, cond, got) => console.log((cond ? "OK " : "BAD ") + label + (cond ? "" : " — " + got));

// Разбор отрисованного: tbody-блоки по порядку, с классом, группой и строками.
function blocks(html) {
  const out = [];
  const re = /<tbody([^>]*)>([\s\S]*?)<\/tbody>/g;
  let m;
  while ((m = re.exec(html))) {
    const attrs = m[1];
    // data-group с 16.09.2026 — СОСТАВНОЙ ключ «пул|домен»: один и тот же
    // домен в разных пулах это разные группы (номера стратегий у пулов свои).
    // Раскладываем, чтобы проверки ниже оставались про домен.
    const graw = (attrs.match(/data-group="([^"]*)"/) || [])[1] || "";
    const gparts = graw.split("|");
    const g = gparts.length > 1 ? gparts[1] : graw;
    const gpool = gparts.length > 1 ? gparts[0] : "";
    const cls = (attrs.match(/class="([^"]*)"/) || [])[1] || "";
    const hosts = [...m[2].matchAll(/class="btn btn-danger btn-icon state-del"[\s\S]*?data-host="([^"]*)"/g)].map(x => x[1]);
    const head = (m[2].match(/<tr class="sg-head">([\s\S]*?)<\/tr>/) || [])[1] || "";
    out.push({ group: g, pool: gpool, raw: graw, cls, hosts, head,
               members: (m[2].match(/class="sg-member"/g) || []).length });
  }
  return out;
}

const SC = {
  render: {
    setup() { localStorage.setItem("z2k-state-sort", JSON.stringify({ key: "host", dir: "asc" })); },
    async run() {
      const html = sel("#state-body").innerHTML;
      const b = blocks(html);
      const dm = b.find(x => x.group === "discord.media" && x.pool === "rkn_tcp");
      const dmq = b.find(x => x.group === "discord.media" && x.pool === "quic");
      check("один домен в двух пулах — две группы, а не одна",
            !!dm && !!dmq && dm.members === 3 && dmq.members === 2,
            JSON.stringify(b.map(x => x.raw)));
      check("группа помнит свой пул", !!dmq && dmq.pool === "quic", dmq && dmq.raw);
      // Кнопки пакетных действий: адресуются составным ключом, иначе действие
      // уедет в группу того же домена из соседнего пула.
      check("в шапке есть сброс группы с составным ключом",
            dm && /class="btn btn-danger btn-icon sg-reset"[\s\S]*?data-gkey="rkn_tcp\|discord\.media"/.test(dm.head)
               || (dm && dm.head.indexOf('sg-reset') >= 0 && dm.head.indexOf(dm.raw) >= 0),
            dm && dm.head.replace(/\s+/g, " ").slice(0, 300));
      check("в шапке есть заморозка группы",
            dm && /class="btn btn-icon sg-freeze"/.test(dm.head) && dm.head.indexOf('data-frozen="0"') >= 0,
            dm && dm.head.replace(/\s+/g, " ").slice(0, 300));
      check("частичная заморозка не выдаётся за полную",
            dm && /1 из 3/.test(dm.head), dm && dm.head.replace(/\s+/g, " ").slice(0, 300));
      check("поддомены discord.media собраны в одну группу", dm && dm.members === 3, JSON.stringify(b.map(x => x.group)));
      check("в группе уходят сырые ключи записей (имя|семейство)",
            dm && dm.hosts.join(",") === "finland10000.discord.media|4,finland10001.discord.media|4,latency.discord.media|6",
            dm && dm.hosts.join(","));
      check("по умолчанию группа свёрнута", dm && /\bsg-closed\b/.test(dm.cls), dm && dm.cls);
      check("в заголовке число записей", dm && /class="sg-count"[^>]*>3</.test(dm.head), dm && dm.head.slice(0, 300));
      check("в заголовке сводка стратегий", dm && />1, 2, 4</.test(dm.head), dm && dm.head.replace(/\s+/g, " ").slice(0, 400));
      check("в заголовке виден замороженный", dm && /1 из 3/.test(dm.head), dm && dm.head.replace(/\s+/g, " ").slice(0, 400));
      check("заголовок раскрывается с клавиатуры (кнопка с aria-expanded)",
            dm && /<button type="button" class="sg-toggle" aria-expanded="false"/.test(dm.head), dm && dm.head.slice(0, 200));
      check("bbc.co.uk — своя группа, не «co.uk»",
            b.some(x => x.group === "bbc.co.uk" && x.members === 2) && !b.some(x => x.group === "co.uk"),
            JSON.stringify(b.map(x => x.group)));
      check("одиночный поддомен другой зоны не получает заголовка", !b.some(x => x.group === "other.co.uk"),
            JSON.stringify(b.map(x => x.group)));
      check("v4 и v6 одного имени — не группа", !b.some(x => x.group === "chatgpt.com"),
            JSON.stringify(b.map(x => x.group)));
      check("адреса не группируются", !b.some(x => /1\.2\.3\.4|2a00|3\.4/.test(x.group)),
            JSON.stringify(b.map(x => x.group)));
      check("запись без имени (Discord-войс) в таблицу не попала", html.indexOf('data-host="nohost"') < 0, "nohost в таблице");
      // КЛЮЧ ГРУППЫ ОБЯЗАН ПЕРЕЖИВАТЬ РАЗБОР HTML. Он уезжает в data-group и
      // читается обратно из DOM, а стандарт велит заменить U+0000 в значении
      // атрибута на U+FFFD (проверено на parse5). С разделителем U+0000 ключ
      // переставал совпадать сам с собой, и память о раскрытии не работала
      // вовсе. Заглушка DOM этого не видит — она присваивает dataset.group
      // руками, минуя разбор, — поэтому смотрим на САМУ разметку.
      check("в ключе группы нет символов, которые разбор HTML подменяет",
            !/(data-group|data-gkey)="[^"]*[\u0000�]/.test(html),
            JSON.stringify((html.match(/data-group="[^"]*"/) || [])[0] || ""));
      const order = b.flatMap(x => x.group ? ["[" + x.group + "]"] : x.hosts);
      // Две группы discord.media подряд: домен первый ключ, пул второй —
      // quic перед rkn_tcp по алфавиту пула.
      const want = ["1.2.3.4|4", "2a00:1450::200e|6", "[bbc.co.uk]", "chatgpt.com|4", "chatgpt.com|6",
                    "[discord.media]", "[discord.media]", "cdn.discordapp.com|4", "sport.other.co.uk|4"];
      check("по домену группы стоят по имени родителя", JSON.stringify(order) === JSON.stringify(want), JSON.stringify(order));
    },
  },
  tiebreak: {
    setup() { localStorage.setItem("z2k-state-sort", JSON.stringify({ key: "key", dir: "asc" })); },
    async run() {
      const b = blocks(sel("#state-body").innerHTML);
      const order = b.flatMap(x => x.group ? ["[" + x.group + "]"] : x.hosts);
      // Сортировка по профилю: quic идёт раньше rkn_tcp, поэтому его группа
      // стоит первой, а внутри rkn_tcp порядок прежний — по домену.
      const want = ["[discord.media]", "1.2.3.4|4", "2a00:1450::200e|6", "[bbc.co.uk]", "chatgpt.com|4",
                    "chatgpt.com|6", "[discord.media]", "cdn.discordapp.com|4", "sport.other.co.uk|4"];
      check("равные по профилю строки идут по домену", JSON.stringify(order) === JSON.stringify(want), JSON.stringify(order));
    },
  },
  remembered: {
    // Ключ памяти с 16.09.2026 составной: «пул|домен». Старые записи от
    // прежних версий просто не совпадут, и группа отрисуется свёрнутой — это
    // разовая косметика, состояние ротации к ней отношения не имеет.
    setup() { localStorage.setItem("z2k-state-open-groups", JSON.stringify(["rkn_tcp|discord.media"])); },
    async run() {
      const b = blocks(sel("#state-body").innerHTML);
      const dm = b.find(x => x.group === "discord.media" && x.pool === "rkn_tcp");
      check("раскрытая раньше группа рисуется раскрытой", dm && !/\bsg-closed\b/.test(dm.cls), dm && dm.cls);
      const bbc = b.find(x => x.group === "bbc.co.uk");
      check("остальные группы по-прежнему свёрнуты", bbc && /\bsg-closed\b/.test(bbc.cls), bbc && bbc.cls);
    },
  },
  toggle: {
    setup() {},
    async run() {
      const tb = sel("#state-body>tbody.sg");
      tb.dataset.group = "discord.media";
      tb.classList.add("sg-closed");
      const before = CALLS["/state"] || 0;
      sel("#state-body>tbody.sg>.sg-head").fire("click");
      await sleep(20);
      check("клик раскрывает группу", !tb.classList.contains("sg-closed"), "sg-closed остался");
      check("кнопка сообщает, что раскрыто", sel("#state-body>tbody.sg>.sg-toggle").getAttribute("aria-expanded") === "true",
            sel("#state-body>tbody.sg>.sg-toggle").getAttribute("aria-expanded"));
      check("раскрытие запомнено", /discord\.media/.test(localStorage.getItem("z2k-state-open-groups") || ""),
            localStorage.getItem("z2k-state-open-groups"));
      check("раскрытие не ходит в сеть", (CALLS["/state"] || 0) === before, "запросов /state: " + CALLS["/state"]);
      sel("#state-body>tbody.sg>.sg-head").fire("click");
      await sleep(20);
      check("второй клик сворачивает", tb.classList.contains("sg-closed"), "не свернулось");
      check("свёрнутая группа из памяти убрана", !/discord\.media/.test(localStorage.getItem("z2k-state-open-groups") || ""),
            localStorage.getItem("z2k-state-open-groups"));
    },
  },
  // ПОИСК ПО ДОМЕНУ. Таблица на роутере — это сотни строк (у владельца 109,
  // из них до сотни поддоменов одного discord.media), и поле поиска здесь не
  // украшение, а единственный способ найти нужный сайт. Проверяется не только
  // «фильтрует», но и три решения, принятые вокруг фильтра.
  search: {
    // Раскрытие, поставленное ДО поиска: выдача не должна его ни потерять,
    // ни подменить собой.
    setup() { localStorage.setItem("z2k-state-open-groups", JSON.stringify(["rkn_tcp|discord.media"])); },
    async run() {
      const input = sel("#state-search");
      const type = async (v) => { input.value = v; input.fire("input"); await sleep(40); };
      const before = CALLS["/state"] || 0;
      const memory = () => localStorage.getItem("z2k-state-open-groups") || "";
      const seeded = memory();

      // Карточка Discord-войса стоит ВЫШЕ таблицы и живёт своей жизнью: в ней
      // выбирают стратегию и ставят галочку «заморозить», а применяют кнопкой.
      // Перерисовка по кэшу её данных не меняет, зато стирает невыбранное —
      // и поиск дёргал бы перерисовку на каждую букву. Метка переживает
      // отрисовку таблицы ровно тогда, когда карточку не трогали.
      sel("#discord-voice-controls").innerHTML = "SENTINEL";

      await type("discord.media");
      check("панель Discord-войса не перерисовывается на каждую букву",
            sel("#discord-voice-controls").innerHTML === "SENTINEL",
            sel("#discord-voice-controls").innerHTML.slice(0, 120));
      let html = sel("#state-body").innerHTML;
      let b = blocks(html);
      check("непопавшие строки убраны",
            !/chatgpt\.com|bbc\.co\.uk|1\.2\.3\.4|discordapp\.com/.test(html),
            html.replace(/\s+/g, " ").slice(0, 300));
      const dm = b.find(x => x.group === "discord.media" && x.pool === "rkn_tcp");
      const dmq = b.find(x => x.group === "discord.media" && x.pool === "quic");
      check("совпавшие группы сохранили состав",
            !!dm && !!dmq && dm.members === 3 && dmq.members === 2,
            JSON.stringify(b.map(x => x.raw + ":" + x.members)));
      // Найденное обязано быть ВИДНО. Иначе поиск сообщает, что совпадение
      // где-то есть, вместо того чтобы показать саму строку.
      check("во время поиска группы раскрыты",
            dm && dmq && !/\bsg-closed\b/.test(dm.cls) && !/\bsg-closed\b/.test(dmq.cls),
            JSON.stringify([dm && dm.cls, dmq && dmq.cls]));
      // Раскрытие живёт в localStorage и переживает перезагрузку страницы.
      // Одна отфильтрованная выдача не должна ни оставить полтысячи строк
      // развёрнутыми навсегда, ни стереть раскрытие, поставленное до поиска.
      // quic-группа в памяти НЕ значится и всё равно раскрыта — значит
      // раскрыл её поиск, а не память.
      check("поиск не переписал постоянную память", memory() === seeded, memory());
      // Весь набор уже в браузере. На роутере /state стоит секунды, и запрос
      // на каждую букву сделал бы поле непригодным.
      check("поиск не ходит в сеть", (CALLS["/state"] || 0) === before,
            "запросов /state: " + (CALLS["/state"] || 0) + ", было " + before);

      // Суффикс семейства — служебная часть ключа, в поле его никто не наберёт.
      await type("|4");
      check("суффикс семейства в поиск не попадает",
            /Ничего не найдено/.test(sel("#state-body").innerHTML),
            sel("#state-body").innerHTML.replace(/\s+/g, " ").slice(0, 200));

      await type("такого.домена.нет");
      check("пустая выдача сообщает об этом, а не молчит",
            /Ничего не найдено/.test(sel("#state-body").innerHTML),
            sel("#state-body").innerHTML.replace(/\s+/g, " ").slice(0, 200));

      // СВЁРНУТЬ ГРУППУ ПРЯМО В ВЫДАЧЕ. Раскрытие поиском не должно означать
      // «и не смей сворачивать»: строк в группе бывают сотни, и человек
      // схлопывает лишнюю, чтобы добраться до соседней.
      await type("discord.media");
      const tb = sel("#state-body>tbody.sg");
      tb.dataset.group = "quic|discord.media";
      tb.classList.remove("sg-closed");
      sel("#state-body>tbody.sg>.sg-head").fire("click");
      await sleep(20);
      check("в выдаче группа сворачивается с первого клика",
            tb.classList.contains("sg-closed"), "sg-closed не появился");
      check("свёртывание в выдаче не трогает постоянную память",
            memory() === seeded, memory());
      // Перерисовка случается на каждой букве, а ещё после заморозки и
      // удаления. Если раскрытие форсировать, свернуть группу нельзя вовсе.
      await type("discord.media");
      b = blocks(sel("#state-body").innerHTML);
      const dmq2 = b.find(x => x.group === "discord.media" && x.pool === "quic");
      check("свёрнутое в выдаче переживает перерисовку",
            dmq2 && /\bsg-closed\b/.test(dmq2.cls), dmq2 && dmq2.cls);

      await type("");
      html = sel("#state-body").innerHTML;
      b = blocks(html);
      check("очистка поля возвращает все строки",
            /chatgpt\.com/.test(html) && /bbc\.co\.uk/.test(html) && /discordapp\.com/.test(html),
            html.replace(/\s+/g, " ").slice(0, 300));
      // Свёрнутое внутри поиска забыто, а раскрытое ДО поиска — на месте.
      const dmAfter = b.find(x => x.group === "discord.media" && x.pool === "rkn_tcp");
      const restAfter = b.filter(x => x.group && !(x.pool === "rkn_tcp" && x.group === "discord.media"));
      check("после очистки вернулось раскрытие, бывшее до поиска",
            dmAfter && !/\bsg-closed\b/.test(dmAfter.cls), dmAfter && dmAfter.cls);
      check("после очистки остальные группы свёрнуты",
            restAfter.every(x => /\bsg-closed\b/.test(x.cls)),
            JSON.stringify(restAfter.map(x => x.raw + ":" + x.cls)));
    },
  },
  // ПЕЧАТЬ ДО ПЕРВОГО ОТВЕТА. Поле поиска доступно сразу, а /state на роутере
  // едет ~2.4 с. Пока перерисовка по кэшу безусловно проваливалась в сетевую
  // ветку, каждая буква отменяла летящий запрос и пускала новый — таблица
  // оставалась скелетом всю очередь нажатий.
  coldtype: {
    setup() { global.__stateDelay = 400; },
    async run() {
      const before = CALLS["/state"] || 0;
      const input = sel("#state-search");
      for (const v of ["d", "di", "dis", "disc"]) { input.value = v; input.fire("input"); await sleep(10); }
      check("печать до первого ответа не порождает запросов",
            (CALLS["/state"] || 0) === before,
            "было " + before + ", стало " + (CALLS["/state"] || 0));
      // Ответ приходит и рисуется УЖЕ отфильтрованным: и запрос, и сортировка
      // читаются в момент отрисовки, поэтому терять нечего.
      await sleep(600);
      const html = sel("#state-body").innerHTML;
      check("пришедший ответ нарисован с учётом набранного",
            html.indexOf("discord") >= 0 && !/chatgpt\.com|bbc\.co\.uk/.test(html),
            html.replace(/\s+/g, " ").slice(0, 300));
    },
  },
  // ОШИБКА ЗАГРУЗКИ И УСТАРЕВШИЙ КЭШ. Поле поиска лежит СНАРУЖИ #state-body и
  // переживает отрисованную ошибку — то есть даёт путь к перерисовке по кэшу,
  // которого раньше не было (кнопка сортировки исчезала вместе с таблицей).
  errorstale: {
    setup() { global.__failStateAfter = 2; },
    async run() {
      // Первая загрузка удалась, кэш тёплый. Теперь «Обновить» падает.
      sel("#state-refresh").fire("click");
      await sleep(80);
      const err = sel("#state-body").innerHTML;
      check("провал загрузки показан", /var\(--bad\)/.test(err), err.slice(0, 200));
      const input = sel("#state-search");
      input.value = "discord";
      input.fire("input");
      await sleep(60);
      const after = sel("#state-body").innerHTML;
      check("поиск не подменяет ошибку устаревшими строками",
            !/state-strat-sel/.test(after) && /var\(--bad\)/.test(after),
            after.replace(/\s+/g, " ").slice(0, 300));
    },
  },
  // ГРУППЫ ЧЕЛОВЕКА. Discord собран из разных родителей и разных пулов —
  // ровно то, чего автогруппировка сделать не может.
  ugroups: {
    setup() {
      global.__groupsText = "[Discord]\ndiscord.media\ndiscordapp.com\n\n[Пустая]\nnever.example\n";
      localStorage.setItem("z2k-state-sort", JSON.stringify({ key: "host", dir: "asc" }));
    },
    async run() {
      const html = sel("#state-body").innerHTML;
      const heads = [...html.matchAll(/<tbody class="ug([^"]*)" data-ug="(\d+)">([\s\S]*?)<\/tbody>/g)];
      check("заголовок только у группы, где есть записи", heads.length === 1 && heads[0][2] === "0",
            JSON.stringify(heads.map(h => h[2])));
      const head = heads.length ? heads[0][3] : "";
      check("группа названа именем человека", /class="sg-name">Discord</.test(head), head.slice(0, 300));
      check("в группе записи разных родителей и пулов: 6",
            /class="sg-count"[^>]*>6</.test(head), head.replace(/\s+/g, " ").slice(0, 400));
      check("профили группы перечислены", />quic, rkn_tcp</.test(head), head.replace(/\s+/g, " ").slice(0, 400));
      check("номера стратегий разных пулов не сводятся в одну строку",
            /data-label="Стратегия"[^>]*>—</.test(head), head.replace(/\s+/g, " ").slice(0, 600));
      check("группа по умолчанию свёрнута", heads.length && /ug-closed/.test(heads[0][1]), heads.length && heads[0][1]);
      const kids = [...html.matchAll(/<tbody([^>]*data-ug-of="0"[^>]*)>([\s\S]*?)<\/tbody>/g)];
      const kidHosts = kids.flatMap(k => [...k[2].matchAll(/state-del"[\s\S]*?data-host="([^"]*)"/g)].map(x => x[1]));
      check("все записи группы помечены и скрыты вместе с ней",
            kidHosts.length === 6 && kids.every(k => /data-ug-closed/.test(k[1])),
            JSON.stringify(kids.map(k => k[1])) + " " + kidHosts.join(","));
      check("внутри группы работает автогруппа поддоменов",
            kids.some(k => /data-group="rkn_tcp\|discord\.media"/.test(k[1])), JSON.stringify(kids.map(k => k[1])));
      const firstUg = html.indexOf('class="ug');
      const firstLoose = html.indexOf('data-host="1.2.3.4|4"');
      check("группы человека стоят выше строк без группы", firstUg >= 0 && firstUg < firstLoose, firstUg + " / " + firstLoose);
      check("у строки в группе нет кнопки «в группу»",
            !kids.some(k => /ug-assign/.test(k[2])), "кнопка внутри группы");
      // Строка кладёт в группу СВОЁ имя, заголовок автогруппы — домен целиком.
      // Родитель за строку подставлять нельзя: ngx.download.nvidia.com в
      // группе игры не должен тянуть за собой всю nvidia.com.
      check("строка добавляется своим именем, заголовок автогруппы — доменом",
            /ug-assign" data-domain="sport\.other\.co\.uk"/.test(html) &&
            /ug-assign" data-domain="bbc\.co\.uk"/.test(html) &&
            /class="ug-pick" data-domain="news\.bbc\.co\.uk"/.test(html) &&
            !/data-domain="other\.co\.uk"/.test(html),
            (html.match(/data-domain="[^"]*"/g) || []).join(","));
    },
  },
  // ОТМЕТКА ГАЛОЧКАМИ. Отмечается сайт (родитель), отметка переживает
  // перерисовку по поиску — иначе собрать в группу находки двух разных
  // поисков было бы нельзя.
  ugpick: {
    setup() { global.__groupsText = "[Discord]\ndiscord.media\n"; },
    async run() {
      let html = sel("#state-body").innerHTML;
      check("у строк без группы есть галочка отметки",
            /class="ug-pick" data-domain="chatgpt\.com"/.test(html) && /class="ug-pick" data-domain="bbc\.co\.uk"/.test(html),
            (html.match(/class="ug-pick" data-domain="[^"]*"/g) || []).join(","));
      check("у строк в группе галочки нет", !/class="ug-pick" data-domain="[^"]*discord\.media"/.test(html), "галочка в группе");
      const box = sel("#state-body>.ug-pick");
      box.dataset.domain = "chatgpt.com"; box.checked = true; box.fire("change");
      check("панель отмеченного показывает счёт", /Отмечено доменов: 1/.test(sel("#ug-selbar").innerHTML) && !sel("#ug-selbar").hidden,
            sel("#ug-selbar").innerHTML.replace(/\s+/g, " ").slice(0, 200));
      const input = sel("#state-search");
      input.value = "chat"; input.fire("input"); await sleep(40);
      input.value = ""; input.fire("input"); await sleep(40);
      html = sel("#state-body").innerHTML;
      check("отметка пережила поиск", /data-domain="chatgpt\.com" checked/.test(html),
            (html.match(/data-domain="chatgpt\.com"[^>]*>/) || [""])[0]);
      // Пустая выдача не должна оставлять «Отметить найденные» от прошлой
      // буквы: кнопка отметила бы то, чего на экране уже нет.
      input.value = "bbc"; input.fire("input"); await sleep(40);
      check("на выдаче есть «Отметить найденные»", /ug-pick-found/.test(sel("#ug-selbar").innerHTML), sel("#ug-selbar").innerHTML.slice(0, 200));
      input.value = "bbczzz"; input.fire("input"); await sleep(40);
      check("пустая выдача убирает «Отметить найденные»", !/ug-pick-found/.test(sel("#ug-selbar").innerHTML),
            sel("#ug-selbar").innerHTML.replace(/\s+/g, " ").slice(0, 200));
    },
  },
  // Поиск по имени группы: ни один домен так не называется.
  ugsearch: {
    setup() { global.__groupsText = "[Голос и чат]\ndiscord.media\n"; },
    async run() {
      const input = sel("#state-search");
      input.value = "голос"; input.fire("input"); await sleep(40);
      const html = sel("#state-body").innerHTML;
      const hosts = [...html.matchAll(/state-del"[\s\S]*?data-host="([^"]*)"/g)].map(x => x[1]);
      check("поиск по имени группы находит её записи",
            hosts.length === 5 && hosts.every(h => /discord\.media/.test(h)), hosts.join(","));
      check("найденная группа раскрыта", !/data-ug-closed/.test(html), "свёрнута");
      check("счётчик считает найденное по имени группы", /Найдено записей: 5 из/.test(sel("#state-search-count").textContent),
            sel("#state-search-count").textContent);
    },
  },
  // Роутер старше панели: маршрута нет. Таблица обязана нарисоваться как
  // раньше, без групп и без кнопок, которые некуда сохранить.
  ugold: {
    setup() { global.__groupsFail = true; },
    async run() {
      const html = sel("#state-body").innerHTML;
      check("без маршрута групп таблица на месте", /state-strat-sel/.test(html), html.slice(0, 200));
      check("без маршрута групп нет кнопок «в группу»", !/ug-assign/.test(html), "кнопки есть");
      check("карточка групп сообщает, что их нет", /Не удалось загрузить группы/.test(sel("#ug-body").innerHTML),
            sel("#ug-body").innerHTML.slice(0, 200));
    },
  },
};

for (const dir of ["asc", "desc"]) {
  SC["age_" + dir] = {
    setup() {
      Date.now = () => 2000000000000;
      localStorage.setItem("z2k-state-sort", JSON.stringify({ key: "age", dir }));
      const row = (host, age) => ({ key: "rkn_tcp", host, strategy: 1,
        ts: age === null ? 0 : 2000000000 - age, mode: "auto" });
      ENTRIES.splice(0, ENTRIES.length,
        row("pair.net|4", 1440), row("pair.net|6", 86400),
        row("solo.org|4", 1560), row("hours.org|4", 7200), row("days.org|4", 172800),
        row("a.group.com|4", 120), row("b.group.com|6", 259200), row("c.group.com|4", null),
        row("missing.org|4", null), row("a.empty.com|4", null), row("b.empty.com|6", null));
    },
    async run() {
      const html = sel("#state-body").innerHTML;
      const top = [], members = [];
      for (const match of html.matchAll(/<tr([^>]*)>([\s\S]*?)<\/tr>/g)) {
        const age = (match[2].match(/class="state-age">([^<]*)</) || [])[1];
        if (age === undefined) continue;
        (match[1].includes("sg-member") ? members : top).push(age);
      }
      const want = dir === "asc" ? ["2м", "24м", "26м", "2ч", "1д", "2д", "—", "—"]
        : ["2д", "1д", "2ч", "26м", "24м", "2м", "—", "—"];
      check("возраст " + dir + ": показанный верхний уровень упорядочен",
        JSON.stringify(top) === JSON.stringify(want), JSON.stringify(top));
      const group = html.match(/data-group="rkn_tcp\|group.com">([\s\S]*?)<\/tbody>/);
      const groupAges = group ? [...group[1].matchAll(/class="state-age">([^<]*)</g)].map(x => x[1]) : [];
      check("возраст " + dir + ": заголовок freshest, участники и пустые",
        JSON.stringify(groupAges) === JSON.stringify(dir === "asc" ? ["2м", "2м", "3д", "—"] : ["2м", "3д", "2м", "—"]), JSON.stringify(groupAges));
      check("возраст " + dir + ": строки не потеряны", members.length === 5, members.length);
    },
  };
}

(async () => {
  const s = SC[SCEN];
  s.setup();
  try { new Function(fs.readFileSync(APP, "utf8"))(); }
  catch (e) { console.log("BAD загрузка панели: " + e.message); process.exit(1); }
  await sleep(50);
  global.location.hash = "#/state";
  global.__nav && global.__nav();
  await sleep(120);
  await s.run();
  process.exit(0);
})().catch(e => { console.log("BAD сценарий упал: " + (e && e.stack || e)); process.exit(1); });
DRIVER

run_scen() {
    node "$DRV" "$1" "$2" 2>&1 | while IFS= read -r line; do
        case "$line" in
            "OK "*)  printf '[PASS] %s\n' "${line#OK }" ;;
            "BAD "*) printf '[FAIL] %s\n' "${line#BAD }" ;;
            *)       printf '       %s\n' "$line" ;;
        esac
    done
}
for scen in render tiebreak remembered toggle search coldtype errorstale age_asc age_desc ugroups ugsearch ugold ugpick; do
    out=$(run_scen "$JS" "$scen")
    printf '%s\n' "$out"
    PASS=$((PASS + $(printf '%s\n' "$out" | grep -c '^\[PASS\]')))
    FAIL=$((FAIL + $(printf '%s\n' "$out" | grep -c '^\[FAIL\]')))
    printf '%s\n' "$out" | grep -q '^\[PASS\]' || no "сценарий $scen что-то проверил" ">=1 PASS" "0"
done

# --- мутанты -----------------------------------------------------------------
meta() {
    _label="$1"; _scen="$2"; _sed="$3"
    _mut="$TMP/mutant.js"
    sed "$_sed" "$JS" > "$_mut"
    if cmp -s "$_mut" "$JS"; then
        no "мутант собрался: $_label" "файл изменён" "не изменился"
        return
    fi
    # Краснеть обязана ПРОВЕРКА, а не загрузка: мутант, сломавший синтаксис,
    # тоже дал бы BAD и выдал бы себя за пойманную поломку.
    if node "$DRV" "$_mut" "$_scen" 2>&1 | grep '^BAD' | grep -vq 'загрузка панели\|сценарий упал'; then
        ok "тест ловит поломку: $_label"
    else
        no "тест ловит поломку: $_label" "сценарий краснеет" "зелёный"
    fi
}
meta "заголовок над парой v4/v6 одного имени" render 's/if (b\.names\.size >= 2) {/if (b.rows.length >= 2) {/'
meta "зоны второго уровня не учитываются" render 's/(tld\.length === 2 && SLD_GENERIC\.has(sld)) ? -3 : -2/-2/'
meta "группы раскрыты по умолчанию" render 's/<tbody class="sg\${open ? "" : " sg-closed"}"/<tbody class="sg"/'
meta "сортировка по домену без родителя" render 's/case "host":     av = meta\.get(a)\.group + "\\u0000" + String(a\.key || "") + "\\u0000" + /case "host":     av = /'
meta "равные строки снова в порядке файла" tiebreak 's/return ah < bh ? -1 : ah > bh ? 1 : 0;/return 0;/'
meta "раскрытие не запоминается" remembered 's/const open = query ? !searchCollapsed\.has(b\.gkey) : stateOpenGroups\.has(b\.gkey);/const open = false;/'
meta "клик не сохраняет раскрытие" toggle 's/^ *saveOpenGroups();$//'
meta "поиск ничего не фильтрует" search 's/const visible = visibleStateEntries(all);/const visible = all;/'
meta "найденное прячется в свёрнутой группе" search 's/const open = query ? !searchCollapsed\.has(b\.gkey) : stateOpenGroups\.has(b\.gkey);/const open = stateOpenGroups.has(b.gkey);/'
meta "поиск идёт по ключу вместе с суффиксом семейства" search 's/const visible = visibleStateEntries(all);/const visible = all.filter(e => String(e.host).toLowerCase().includes(query));/'
meta "раскрытие форсируется и свернуть в выдаче нельзя" search 's/const open = query ? !searchCollapsed\.has(b\.gkey) : stateOpenGroups\.has(b\.gkey);/const open = query ? true : stateOpenGroups.has(b.gkey);/'
meta "свёртывание в выдаче пишется в постоянную память" search 's/if (open) searchCollapsed\.delete(g); else searchCollapsed\.add(g);/if (open) stateOpenGroups.add(g); else stateOpenGroups.delete(g); saveOpenGroups();/'
meta "поиск до первого ответа бьёт в сеть" coldtype 's/function resortState() { return stateCache ? loadState(true) : Promise.resolve(); }/function resortState() { return loadState(true); }/'
meta "ошибка подменяется устаревшим кэшем" errorstale 's/^ *stateCache = null;$//'
meta "ключ группы снова с U+0000 и не переживает разбор" render 's/const GKEY_SEP = "|";/const GKEY_SEP = "\\u0000";/'
meta "группы человека не раскладываются" ugroups 's/(ug >= 0 ? ugParts\[ug\] : ungrouped)\.push(e);/ungrouped.push(e);/'
meta "сводка стратегий через разные пулы" ugroups 's/\${pools\.length === 1 ? escapeHtml(strategySummary(rows)) : "—"}/${escapeHtml(strategySummary(rows))}/'
meta "группы человека раскрыты по умолчанию" ugroups 's/: stateOpenUgroups\.has(sec\.name);/: true;/'
meta "строка отмечается родителем вместо своего имени" ugroups 's/\${m\.ug < 0 ? pickHtml(m\.name) : ""}/${m.ug < 0 ? pickHtml(groupDomain(m.name)) : ""}/'
meta "поиск не видит имени группы" ugsearch 's/return ug >= 0 \&\& ugView\.sections\[ug\]\.name\.toLowerCase()\.includes(query);/return false;/'
meta "поддомен не попадает в группу домена" ugroups 's/if (index\.has(rest)) return index\.get(rest);/if (rest === s \&\& index.has(rest)) return index.get(rest);/'
meta "отметка теряется при перерисовке" ugpick 's/\${ugPicked\.has(parent) ? " checked" : ""}//'
meta "пустая выдача оставляет старое «Отметить найденные»" ugpick 's/^ *ugPickable = \[\];$//'
meta "панель отмеченного не обновляется" ugpick 's/^ *renderUgSelbar();$//'
meta "панель Discord-войса перерисовывается на каждую букву" search 's/if (!useCache) renderDiscordVoicePanel(entries);/renderDiscordVoicePanel(entries);/'

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
