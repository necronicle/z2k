// Sort state shared across loadState() invocations so a refresh
// (manual button or after delete) preserves the chosen column.
// Defaults: profile asc — same order as the previous unsorted view.
//
// Persisted per browser under z2k-state-sort, next to z2k-sidebar and the
// theme key: it is a display preference, not router configuration, and one
// value is shared by the desktop headers and the mobile sheet — two different
// orders on the same screen surprise more than they help.
const STATE_SORT_KEY = "z2k-state-sort";

// The labels double as the mobile sheet's option list, so the set of sortable
// keys is declared once and cannot drift between the two controls.
export const STATE_SORT_LABELS = { key: "Профиль", host: "Домен", strategy: "Стратегия", frozen: "Заморозка", age: "Возраст" };

function loadStateSort() {
  // Anything unrecognised falls back to the default. A stale value (a column
  // renamed in a later release) would otherwise leave the table sorted by
  // nothing at all, which reads as a broken load rather than a stale setting.
  const fallback = { key: "key", dir: "asc" };
  try {
    const raw = localStorage.getItem(STATE_SORT_KEY);
    if (!raw) return fallback;
    const v = JSON.parse(raw);
    if (!v || !STATE_SORT_LABELS[v.key]) return fallback;
    if (v.dir !== "asc" && v.dir !== "desc") return fallback;
    return { key: v.key, dir: v.dir };
  } catch (_) { return fallback; }
}

export function saveStateSort() {
  try { localStorage.setItem(STATE_SORT_KEY, JSON.stringify(stateSort)); } catch (_) {}
}

export let stateSort = loadStateSort();

// Размеры пулов, прочитанные с /pools. Живут здесь, а меняет их страница
// стратегий — единственное место во всём файле, где значение присваивалось
// через границу раздела (замер связности нашёл ровно одно). В модулях
// импортированное имя менять нельзя, поэтому запись идёт через сеттер: так
// владение остаётся у модели, а не размазывается по странице.
export let statePools = {};

export function setStatePools(v) { statePools = v || {}; }

// ГРУППИРОВКА СТРОК РОТАТОРА ПО ДОМЕНУ.
//
// Ключ ротации у служебных пулов теперь — полное имя хоста (z2k_service_hostkey
// в files/lua/z2k-modern-core.lua ставит nld=0), и таблица показывает каждый
// поддомен отдельной строкой. На роутере владельца 14.09 это 109 записей, из
// них 18 — поддомены apple.com, а у discord.media их бывает под сотню
// (finland10000 … finland10100). Искать среди такого нужный сайт невозможно.
//
// Группировка — только вид. Движок по-прежнему держит отдельную ячейку на
// каждое имя, и правка строки уходит в API с тем же сырым ключом; родитель
// нигде не хранится и вычисляется здесь при отрисовке.
//
// Родитель — последние две метки имени, и три, если предпоследняя — служебный
// уровень национальной зоны (news.bbc.co.uk → bbc.co.uk). Полного списка
// публичных суффиксов тут нет сознательно: это ~230 КБ, которые пришлось бы
// отдавать с роутера ради подписи над строками. Промах эвристики здесь стоит
// дёшево — строки не теряются, а оказываются под соседним заголовком. В движке
// та же эвристика была бы ошибкой другого масштаба: чужие сайты делили бы одну
// стратегию, поэтому там её и нет (комментарий у z2k_service_hostkey).
const SLD_GENERIC = new Set([
  "ac", "biz", "co", "com", "edu", "go", "gob", "gov", "info", "int", "ltd",
  "mil", "msk", "ne", "net", "nhs", "nic", "nom", "or", "org", "plc", "pp",
  "sch", "spb",
]);

export function groupDomain(name) {
  const s = String(name == null ? "" : name).toLowerCase();
  // Адрес вместо имени (запись без SNI) не группируется: «3.4» из 1.2.3.4
  // было бы бессмыслицей, а у IPv6 меток нет вовсе.
  if (s.indexOf(":") >= 0 || /^[0-9.]+$/.test(s)) return s;
  const p = s.split(".");
  if (p.length <= 2) return s;
  const tld = p[p.length - 1];
  const sld = p[p.length - 2];
  return p.slice((tld.length === 2 && SLD_GENERIC.has(sld)) ? -3 : -2).join(".");
}

// Раскрытые группы. По умолчанию всё свёрнуто: смысл группировки в том, чтобы
// 109 строк стали 42, а не в том, чтобы добавить к ним ещё 19 заголовков.
// Запоминается в браузере рядом с сортировкой — это настройка вида, а не
// роутера. Без памяти любая правка строки внутри группы сворачивала бы её:
// после каждого изменения таблица перерисовывается целиком.
const STATE_OPEN_KEY = "z2k-state-open-groups";
// Потолок, чтобы список не рос вечно: имена групп после очистки стейта
// остаются в хранилище. Set хранит порядок вставки, отрезаются самые старые.
const STATE_OPEN_MAX = 200;

function loadOpenGroups() {
  try {
    const v = JSON.parse(localStorage.getItem(STATE_OPEN_KEY));
    return new Set(Array.isArray(v) ? v.filter(x => typeof x === "string") : []);
  } catch (_) { return new Set(); }
}

export const stateOpenGroups = loadOpenGroups();

export function saveOpenGroups() {
  const all = Array.from(stateOpenGroups);
  try { localStorage.setItem(STATE_OPEN_KEY, JSON.stringify(all.slice(-STATE_OPEN_MAX))); } catch (_) {}
}

// A missing timestamp is not a very old record. Keep that distinction through
// sorting and rendering; zero is the backend's absent-time sentinel.
export function stateAge(ts, nowSec) {
  const timestamp = Number(ts);
  return Number.isFinite(timestamp) && timestamp > 0 ? nowSec - timestamp : null;
}

// Sort members first, then assemble the visible table blocks. Metadata carries
// the exact age in seconds also consumed by the page formatter.
export function buildStateBlocks(entries, meta) {
  // Sort a shallow copy — never mutate the cached server response.
  const sorted = entries.slice().sort((a, b) => {
    let av, bv;
    switch (stateSort.key) {
      case "key":      av = String(a.key  || ""); bv = String(b.key  || ""); break;
      // По домену — сперва по родителю, потом по полному имени. Иначе группа
      // вставала бы туда, где по алфавиту её первый поддомен: apple.com
      // оказывался у «api.», discord.media — у «c-arn04».
      // Домен — первым, пул — вторым: иначе колонка «Домен» незаметно
      // сортирует по профилю, а группы одного домена из разных пулов
      // разъезжаются по разным концам таблицы.
      case "host":     av = meta.get(a).group + "\u0000" + String(a.key || "") + "\u0000" + String(a.host || "");
                       bv = meta.get(b).group + "\u0000" + String(b.key || "") + "\u0000" + String(b.host || ""); break;
      case "strategy": av = Number(a.strategy) || 0; bv = Number(b.strategy) || 0; break;
      // По возрастанию — замороженные сверху: колонку жмут, чтобы найти
      // именно их среди сотен строк на авторотации.
      case "frozen":   av = a.mode === "frozen" ? 0 : 1; bv = b.mode === "frozen" ? 0 : 1; break;
      // 'age' sorts by age value (= now - ts). Asc → freshest first
      // (small age), which matches what we'd want by default when
      // a user clicks «Возраст» — "what's been moving recently".
      case "age":
        av = meta.get(a).age; bv = meta.get(b).age;
        // Unknown ages stay last regardless of direction.
        if (av === null || bv === null) {
          if (av !== bv) return av === null ? 1 : -1;
        }
        break;
      default:         return 0;
    }
    if (av < bv) return stateSort.dir === "asc" ? -1 : 1;
    if (av > bv) return stateSort.dir === "asc" ?  1 : -1;
    // Равные по выбранной колонке — по домену. Без этого внутри одного
    // профиля строки шли в порядке файла, и группы перемешивались с
    // одиночными строками случайно; v4 и v6 одного хоста разъезжались.
    const ah = meta.get(a).group + "\u0000" + String(a.key || "") + "\u0000" + String(a.host || "");
    const bh = meta.get(b).group + "\u0000" + String(b.key || "") + "\u0000" + String(b.host || "");
    return ah < bh ? -1 : ah > bh ? 1 : 0;
  });

  const blocks = [];
  const byGroup = new Map();
  for (const e of sorted) {
    const m = meta.get(e);
    let b = byGroup.get(m.gkey);
    if (!b) {
      b = { group: m.group, gkey: m.gkey, pool: String(e.key || ""), rows: [], names: new Set() };
      byGroup.set(m.gkey, b);
      blocks.push(b);
    }
    b.rows.push(e);
    b.names.add(m.name);
  }

  for (const b of blocks) {
    b.age = null;
    for (const e of b.rows) {
      const age = meta.get(e).age;
      if (age !== null && (b.age === null || age < b.age)) b.age = age;
    }
  }
  if (stateSort.key !== "age") return blocks;

  // Only different names get a group header. A v4/v6 pair of ONE name
  // renders as loose rows, so keeping it atomic would pull an old row next
  // to its fresh sibling and break the displayed age order even in asc.
  const ageBlocks = blocks.flatMap(b => b.names.size >= 2 ? [b] : b.rows.map(e => ({
    ...b, rows: [e], age: meta.get(e).age,
  })));
  // The group displays its freshest member in either direction. Sorting by
  // the first member instead would use the oldest age in desc.
  return ageBlocks.sort((a, b) => {
    if (a.age === null || b.age === null) {
      if (a.age !== b.age) return a.age === null ? 1 : -1;
      return 0;
    }
    return stateSort.dir === "asc" ? a.age - b.age : b.age - a.age;
  });
}

// ГРУППЫ ДОМЕНОВ, ЗАДАННЫЕ ЧЕЛОВЕКОМ.
//
// Автогруппировка выше собирает поддомены под родителем, но один сервис — это
// почти всегда несколько РАЗНЫХ родителей: у Discord это discord.com,
// discord.gg, discordapp.net и discord.media, у YouTube — youtube.com,
// googlevideo.com, ytimg.com и ggpht.com. Эвристикой их не связать, а
// публичного списка «какой домен чей» нет. Поэтому связь задаёт человек, и
// эти группы стоят уровнем выше автогрупп.
//
// Это по-прежнему ТОЛЬКО ВИД. Файл lists/domain-groups.txt не читает движок,
// и каждая строка таблицы уходит в API со своим сырым ключом, как и раньше.
//
// Формат — секции:  [Имя] и по домену на строку; # — комментарий. Сервер
// проверяет файл при записи (domain_groups_save в actions.sh), здесь разбор
// снисходительный: файл могли поправить руками, и одна кривая строка не
// должна гасить все группы — она просто пропускается.

// Разбор с номерами строк: редактор группы меняет ровно её секцию и не трогает
// комментарии и порядок остального файла.
export function domainGroupSections(text) {
  const lines = String(text == null ? "" : text).split("\n");
  const sections = [];
  let cur = null;
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.length > 2 && t[0] === "[" && t[t.length - 1] === "]") {
      const name = t.slice(1, -1).trim();
      if (!name) continue;
      if (cur) cur.end = i;
      cur = { name, start: i, end: lines.length, domains: [] };
      sections.push(cur);
      continue;
    }
    if (!cur || !t || t[0] === "#") continue;
    cur.domains.push(t.toLowerCase());
  }
  return { lines, sections };
}

// Домен → номер группы. Первая секция выигрывает при повторе: сервер повтор не
// пропускает, а на файле, поправленном руками, выбор обязан быть устойчивым.
export function domainGroupIndex(sections) {
  const index = new Map();
  sections.forEach((s, i) => s.domains.forEach(d => { if (!index.has(d)) index.set(d, i); }));
  return index;
}

// Номер группы для имени хоста или -1. Сравнение по окончанию, от полного
// имени к родителю: discord.com покрывает cdn.discord.com, а самое длинное
// совпадение выигрывает — mail.google.com в одной группе и google.com в
// другой разводят почту и остальной Google. Так же устроены доменные списки
// Keenetic, рядом с которыми эту разметку и ведут.
export function matchDomainGroup(index, host) {
  if (!index || !index.size) return -1;
  const s = String(host == null ? "" : host).toLowerCase().replace(/\|[46]$/, "");
  // Адрес вместо имени ни в какую группу не попадает: «4» из 1.2.3.4 совпало
  // бы с чем угодно, а у IPv6 меток нет.
  if (!s || s.indexOf(":") >= 0 || /^[0-9.]+$/.test(s)) return -1;
  let rest = s;
  for (;;) {
    if (index.has(rest)) return index.get(rest);
    const dot = rest.indexOf(".");
    if (dot < 0) return -1;
    rest = rest.slice(dot + 1);
  }
}

// Правки файла — на уровне строк, а не сериализацией разобранного: иначе
// любое добавление домена из таблицы стирало бы комментарии, которые человек
// оставил руками, и переставляло бы секции.
function dgJoin(lines) {
  const out = lines.join("\n").replace(/\n{3,}/g, "\n\n").replace(/^\n+/, "");
  return out && !out.endsWith("\n") ? out + "\n" : out;
}

export function domainGroupsAdd(text, name, domain) {
  const { lines, sections } = domainGroupSections(text);
  const d = String(domain).trim().toLowerCase();
  const sec = sections.find(s => s.name.toLowerCase() === String(name).trim().toLowerCase());
  if (!sec) {
    const body = lines.slice();
    while (body.length && !body[body.length - 1].trim()) body.pop();
    if (body.length) body.push("");
    body.push("[" + String(name).trim() + "]", d);
    return dgJoin(body);
  }
  if (sec.domains.includes(d)) return dgJoin(lines);
  // Перед хвостом пустых строк секции, чтобы новый домен не отрывался от
  // остальных пустой строкой-разделителем.
  let at = sec.end;
  while (at > sec.start + 1 && !lines[at - 1].trim()) at--;
  return dgJoin([...lines.slice(0, at), d, ...lines.slice(at)]);
}

// Заменить секцию целиком (имя и тело) или удалить её, если name пустое.
export function domainGroupsReplace(text, index, name, bodyText) {
  const { lines, sections } = domainGroupSections(text);
  const sec = sections[index];
  if (!sec) return dgJoin(lines);
  const repl = name ? ["[" + name.trim() + "]", ...String(bodyText).replace(/\n+$/, "").split("\n"), ""] : [];
  return dgJoin([...lines.slice(0, sec.start), ...repl, ...lines.slice(sec.end)]);
}

export function domainGroupsAppend(text, name, bodyText) {
  const lines = String(text == null ? "" : text).split("\n");
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  if (lines.length) lines.push("");
  lines.push("[" + name.trim() + "]", ...String(bodyText).replace(/\n+$/, "").split("\n"));
  return dgJoin(lines);
}

// Проверка до отправки — с сообщениями ПРО ГРУППУ, а не про строку файла:
// человек правит одну секцию, и «строка 37» от сервера ему ничего не скажет.
// Сервер проверяет то же самое ещё раз; там последняя линия для правки руками.
//
// Регистр сравнивается через toLowerCase, то есть и для кириллицы: awk под
// LC_ALL=C сворачивает только латиницу, и «Дискорд»/«дискорд» он пропустил бы.
export function domainGroupProblem(sections, index, name, bodyText) {
  const n = String(name || "").trim();
  if (!n) return "Укажите имя группы.";
  if (new TextEncoder().encode(n).length > 96) return "Имя группы слишком длинное.";
  if (/[[\]]/.test(n) || Array.from(n).some(c => c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127))
    return "В имени группы нельзя использовать квадратные скобки.";
  const other = sections.find((s, i) => i !== index && s.name.toLowerCase() === n.toLowerCase());
  if (other) return `Группа «${other.name}» уже есть.`;
  const taken = new Map();
  sections.forEach((s, i) => { if (i !== index) s.domains.forEach(d => taken.set(d, s.name)); });
  const seen = new Set();
  for (const raw of String(bodyText).split("\n")) {
    const t = raw.trim();
    if (!t || t[0] === "#") continue;
    const d = t.toLowerCase();
    const bad = d.length > 253 || !/^[a-z0-9.-]+$/.test(d) || /^[0-9.]+$/.test(d) ||
      d.split(".").some(l => !l || l.length > 63 || l[0] === "-" || l[l.length - 1] === "-");
    if (bad) return `«${t}» — не домен. Укажите имя сайта без адреса, протокола и пути.`;
    if (taken.has(d)) return `${d} уже входит в группу «${taken.get(d)}».`;
    seen.add(d);
  }
  return seen.size ? "" : "Добавьте в группу хотя бы один домен.";
}

// Проверка файла целиком из режима «как текст». Сервер ловит то же, кроме
// двойников с разным регистром кириллицы («Дискорд» и «дискорд»): awk под
// LC_ALL=C сворачивает только латиницу. Двойник дал бы две группы, которые
// человек считает одной, и память раскрытия, общую на обе.
export function domainGroupsTextProblem(text) {
  const { sections } = domainGroupSections(text);
  const seen = new Map();
  for (const sec of sections) {
    const k = sec.name.toLowerCase();
    if (seen.has(k)) return `Группа «${sec.name}» повторяет «${seen.get(k)}» — имена групп не различаются регистром.`;
    seen.set(k, sec.name);
  }
  return "";
}

// Раскрытые группы — по имени, отдельно от автогрупп: ключ автогруппы
// составной «пул|домен», и смешивать два вида ключей в одном наборе значило бы
// однажды получить совпадение там, где его нет. Имя, а не номер: порядок секций
// меняется, а память о раскрытии не должна переезжать на соседа.
const UGROUP_OPEN_KEY = "z2k-state-open-ugroups";

function loadOpenUgroups() {
  try {
    const v = JSON.parse(localStorage.getItem(UGROUP_OPEN_KEY));
    return new Set(Array.isArray(v) ? v.filter(x => typeof x === "string") : []);
  } catch (_) { return new Set(); }
}

export const stateOpenUgroups = loadOpenUgroups();

export function saveOpenUgroups() {
  try { localStorage.setItem(UGROUP_OPEN_KEY, JSON.stringify(Array.from(stateOpenUgroups).slice(-STATE_OPEN_MAX))); } catch (_) {}
}
