import { openSortSheet } from "../chrome.js";
import { apiGet, apiPost, apiPostText, errHtml, errMsg, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, skeletonLines } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { STATE_SORT_LABELS, buildStateBlocks, stateAge, groupDomain, saveOpenGroups, saveStateSort, setStatePools, stateOpenGroups, statePools, stateSort } from "../state-model.js";
import { domainGroupIndex, domainGroupProblem, domainGroupSections, domainGroupsTextProblem, domainGroupsAdd, domainGroupsAppend, domainGroupsReplace, matchDomainGroup, saveOpenUgroups, stateOpenUgroups } from "../state-model.js";

// Разделитель СОСТАВНОГО ключа группы («пул<sep>домен»).
//
// НЕ U+0000, хотя для сортировочных ключей ниже он как раз хорош. Этот ключ
// уезжает в data-group и читается обратно из DOM, а разбор HTML заменяет
// U+0000 на U+FFFD — это не причуда движка, а прямое требование стандарта
// (attribute value state: unexpected-null-character → U+FFFD). Проверено на
// parse5: записали «quic\u0000discord.media», прочитали
// «quic�discord.media».
//
// Ключ переставал совпадать сам с собой, и память о раскрытии групп не
// работала вовсе: клик сохранял вариант с U+FFFD, а следующая отрисовка
// спрашивала про вариант с U+0000 и получала «нет». Заметить это в тестах
// было нельзя — заглушка DOM присваивает dataset.group руками, минуя разбор.
//
// Вертикальная черта безопасна: ключ пула — [a-z_0-9], а имя группы здесь уже
// без суффикса семейства, который эту черту и содержит.
const GKEY_SEP = "|";

//
// Раньше это были два соседних пункта меню — «Стратегии» и «Rotator» — и люди
// не понимали, где заводить свою стратегию. По делу это одна сущность на двух
// уровнях: политика по пулу (что подбирать) и живой выбор по домену (что
// выбрано прямо сейчас). Две категории верхнего уровня, которые обе про
// «стратегию», — ровно тот перекрывающийся ярлык, который NN/g называет
// главной причиной промахов по навигации.
//
// Ось «настройка против наблюдения» взята не с потолка: так устроен сам
// веб-конфигуратор Keenetic, который наши люди видят каждый день (весь
// мониторинг собран в «Статусе», настройки разложены по доменам), и так же
// сделан AdGuard Home — «Фильтры» одна дверь с подвкладками, «Журнал
// запросов» отдельно.
//
// Маршрут `state` намеренно оставлен рабочим: старые ссылки, закладки и
// текст README ведут на него, и он открывает ту же страницу на вкладке
// «Автоподбор».
// Порядок намеренный: «Автоподбор» первой и по умолчанию. Сюда приходят
// разбираться, почему конкретный сайт не открылся, — это частый сценарий.
// Своя строка параметров нужна редко и целиком меняет поведение пула, так что
// она вторым шагом, а не тем, что встречает на входе.
// Названия — по тому, что вкладка РЕАЛЬНО содержит, а не по намерению.
// «Сейчас работает» было неправдой: пул, которому задали свою строку, работает,
// но в таблице не появляется никогда. Причина в движке — circular входит в саму
// строку стратегии, и пользовательская строка заменяет её целиком, так что
// подбор для этого пула выключается и записей он не создаёт
// (lib/config_official.sh, z2k_custom_strategy). Обещать «сейчас работает» и
// показывать только половину — хуже, чем назвать честно.
//
// «Свои стратегии» — дословно тот вопрос, с которого всё началось («где их
// вести»), и тот же термин, что в README. Совпадение слов в интерфейсе и
// документации важнее красоты.
const STRATEGY_TABS = [
  { id: "live",   route: "state",      label: "Автоподбор",
    hint: "Что подбор выбрал по каждому домену; здесь же ручной выбор и заморозка" },
  // Третья вкладка встала В СЕРЕДИНУ, и порядок здесь — лесенка по тому,
  // насколько глубоко человек вмешивается: посмотреть, что подбор выбрал сам →
  // замерить строку под конкретный домен → задать свою строку на весь пул.
  // Крайние две — наблюдение и настройка, между ними логично лежит измерение.
  { id: "pick",   route: "pick",       label: "Подбор по домену",
    hint: "Замерить, какая строка параметров пробивает конкретный домен" },
  { id: "config", route: "strategies", label: "Свои стратегии",
    hint: "Задать свою строку параметров вместо подбора — для целого пула" },
];

export function strategiesShell(activeId, bodyHtml) {
  const tabs = STRATEGY_TABS.map(t => `
    <a href="#/${t.route}" class="strat-tab${t.id === activeId ? " active" : ""}"
       role="tab" aria-selected="${t.id === activeId}" title="${escapeHtml(t.hint)}">
      ${escapeHtml(t.label)}
    </a>`).join("");
  const active = STRATEGY_TABS.find(t => t.id === activeId) || STRATEGY_TABS[0];
  return `
    <h1 class="page-title">Стратегии</h1>
    <div class="strat-tabs" role="tablist" aria-label="Виды раздела «Стратегии»">${tabs}</div>
    <p class="desc strat-tabhint">${escapeHtml(active.hint)}</p>
    ${bodyHtml}
  `;
}

// Подобранное имя показывается ПОД номером плеча, а не отдельной колонкой.
// Причина простая: имя есть у единиц строк — только там, где сработал обход
// блокировки по объёму, — и отдельный столбец у всех остальных был бы пустым.
// А не показывать вовсе нельзя: номер плеча сам по себе поведение уже не
// объясняет, и таблица врала бы умолчанием.
export async function renderState() {
  $app.innerHTML = strategiesShell("live", `
    <details class="card state-voice">
      <summary>Discord: голосовые каналы <span id="discord-voice-status">Загрузка…</span></summary>
      <p class="desc">
        Голосовой пул Discord не привязан к домену, поэтому в таблице ниже его
        нет: там показано то, что уже происходило, а здесь стратегию можно
        выбрать заранее — до первого звонка. Её так же можно заморозить, чтобы
        не менялась.
      </p>
      <div class="btn-row" id="discord-voice-controls">${skeletonLines(1)}</div>
    </details>
    <details class="card state-voice state-ugroups" id="ug-card">
      <summary>Группы доменов <span id="ug-status">Загрузка…</span></summary>
      <p class="desc">
        Группа собирает под одним именем домены одного сайта, приложения или
        сервиса — в таблице ниже они идут одним сворачиваемым блоком, даже
        если это разные домены и разные пулы. Домен включает свои поддомены.
        Группы хранятся на роутере, поэтому одинаковы на телефоне и на
        компьютере. На обход они не влияют: это только порядок в таблице.
      </p>
      <div id="ug-body">${skeletonLines(2)}</div>
    </details>
    <div class="card">
      <h3>Стратегии по доменам</h3>
      <details class="state-help"><summary>Как управлять?</summary>
      <p class="desc">
        Для каждого домена z2k запоминает стратегию, которая на нём заработала.
        Поддомены используют общую запись домена второго уровня. В каждой строке:
      </p>
      <ul class="desc" style="margin:4px 0 10px 18px;padding:0">
        <li><b>выпадающий список</b> — выбрать стратегию вручную (подбор
            продолжится с неё, удобно проскочить нерабочую);</li>
        <li><b>замок в столбце «Заморозка»</b> — открытый замок значит идёт
            автоподбор; нажмите, чтобы заморозить (замок закроется) и стратегия
            перестанет меняться; нажмите закрытый замок — разморозить;</li>
        <li><b>× слева</b> — удалить запись (старт с первой стратегии);</li>
        <li><b>домен со стрелкой</b> — записи его поддоменов собраны вместе;
            нажмите, чтобы раскрыть или свернуть;</li>
        <li><b>галочка у домена</b> — отметить для группы: у строки — именно
            это имя, у заголовка автогруппы — домен со всеми поддоменами.
            Отмеченное (можно набирать через несколько поисков, «Отметить
            найденные» берёт всю выдачу) переносится в группу кнопкой
            «В группу…» над таблицей;</li>
        <li><b>значок папки</b> — добавить домен в свою группу. Группы собирают
            разные домены одного сервиса под одним именем (discord.com,
            discord.media, discordapp.net — в «Discord»). Группы хранятся на
            роутере и одинаковы на всех устройствах; на обход они не влияют.</li>
      </ul>
      <p class="desc">
        «Заморозить все» закрепляет каждую запись на её текущей стратегии.
        Если задан поиск, кнопка действует только на найденные записи.
        Когда все они заморожены, этой же кнопкой можно вернуть автоподбор.
      </p>
      <p class="desc">
        Пул, которому вы задали <a href="#/strategies">свою стратегию</a>, здесь
        не появится: подбор для него выключен, а работает ровно ваша строка.
      </p>
      </details>
      <label class="state-search-label" for="state-search">Поиск по домену</label>
      <div class="state-search-wrap">
        <input id="state-search" class="state-search" type="search"
          placeholder="Домен или часть домена" aria-label="Поиск по домену"
          autocomplete="off" autocapitalize="off" spellcheck="false">
        <button type="button" class="state-search-clear" id="state-search-clear"
          aria-label="Очистить поиск" hidden>×</button>
      </div>
      <div class="state-tools">
        <span id="state-search-count" role="status" aria-live="polite">Загрузка записей…</span>
        <div class="btn-row">
          <button class="btn state-freeze-visible" id="state-freeze-visible" type="button" disabled>Заморозить все</button>
          <button class="btn" id="state-refresh">Обновить</button>
          <button class="btn btn-danger" id="state-clear-all">Удалить все записи</button>
        </div>
      </div>
      <div class="ug-selbar" id="ug-selbar" role="region" aria-label="Отмеченные домены" hidden></div>
      <div id="state-body">${skeletonLines(6)}</div>
    </div>
  `);
  // Wrapped, NOT passed directly: an event handler receives the Event object as
  // its first argument, which would land in useCache — truthy — and turn the
  // «Обновить» button into a no-op that re-renders stale rows.
  document.getElementById("state-refresh").addEventListener("click", () => loadState());
  document.getElementById("state-clear-all").addEventListener("click", stateClearAll);
  document.getElementById("state-freeze-visible").addEventListener("click", stateFreezeVisible);
  // Поиск — операция ВИДА, как и сортировка: весь набор уже в браузере,
  // поэтому идём через resortState (кэш), а не через loadState() с сетью.
  // На роутере /state стоит секунды, и ходить туда на каждую букву значило бы
  // сделать поле непригодным ровно там, где оно нужнее всего.
  const search = document.getElementById("state-search");
  const clear = document.getElementById("state-search-clear");
  search.addEventListener("input", () => {
    clear.hidden = !search.value;
    resortState();
  });
  clear.addEventListener("click", () => {
    search.value = "";
    clear.hidden = true;
    search.focus();
    resortState();
  });
  loadState();
}

// Discord-voice strategy panel — works even when no discord_udp/nohost row
// exists yet (state_set creates it), so the pool can be chosen before any
// voice traffic flows.
function renderDiscordVoicePanel(entries) {
  const dc = document.getElementById("discord-voice-controls");
  if (!dc) return;
  const dEntry = entries.find(e => e.key === "discord_udp" && e.host === "nohost");
  const poolN = Number(statePools["discord_udp"] || 0);
  const dCur = dEntry ? Number(dEntry.strategy) : 1;
  const dN = Math.max(poolN, dCur, 1);
  const dFrozen = dEntry ? dEntry.mode === "frozen" : false;
  let opts = "";
  for (let i = 1; i <= dN; i++) opts += `<option value="${i}"${i === dCur ? " selected" : ""}>Стратегия ${i}</option>`;
  const status = dEntry
    ? `сейчас: №${dCur}${dFrozen ? " 🔒 заморожено" : ""}`
    : (poolN ? `пул из ${poolN} стратегий; запись появится после «Применить»` : `пул недоступен (nfqws2 не запущен?)`);
  const summary = document.getElementById("discord-voice-status");
  if (summary) summary.textContent = dEntry
    ? `Стратегия ${dCur}${dFrozen ? " · заморожена" : ""}`
    : (poolN ? "Автоподбор" : "Пул недоступен");
  dc.innerHTML = `
    <select id="dv-strat">${opts}</select>
    <label style="display:inline-flex;align-items:center;gap:6px;margin:0 6px">
      <input type="checkbox" id="dv-freeze"${dFrozen ? " checked" : ""}> заморозить
    </label>
    <button class="btn" id="dv-apply">Применить</button>
    <span class="desc" style="margin-left:8px">${escapeHtml(status)}</span>
  `;
  document.getElementById("dv-apply").addEventListener("click", () => {
    const s = document.getElementById("dv-strat").value;
    const m = document.getElementById("dv-freeze").checked ? "frozen" : "auto";
    stateSet("discord_udp", "nohost", s, m);
  });
}

// Last server response, kept so that re-SORTING does not have to re-FETCH.
// Sorting is a view operation: the whole set is already in the browser, and
// /state costs ~2.4s on a Keenetic (123 rows, shell CGI parsing state.tsv).
// Refetching for it meant every tap on a column — and every pick in the mobile
// sheet — sat there for those 2.4 seconds with nothing to show for it.
// The network trip stays where it means something: entering the page, the
// explicit «Обновить» button, and after an edit or delete.
let stateCache = null;
let stateBulkBusy = false;

// Positional rotators and the broad UDP pool are internal, including cached rows.
function hiddenStrategyPool(key) {
  return key === "udp_misc" || /^circular_[0-9]+_[0-9]+$/.test(String(key || ""));
}

// Группы доменов, как их отдал роутер: текст файла, его версия для
// compare-and-swap и разбор. null — ещё не пришли или сервер их не знает
// (панель новее роутера); тогда таблица рисуется ровно как без групп.
let ugView = null;
let ugError = "";
let ugBusy = false;
// Открытый редактор: { mode: "new" | "group" | "text", index }.
let ugEdit = null;
// Домены, отмеченные галочками в таблице: у строки — её имя, у заголовка
// автогруппы — домен целиком. Отметка по имени, а не по строке: v4 и v6 одного
// хоста, тот же хост в другом пуле отмечаются вместе. Живёт, пока открыта страница,
// и переживает поиск: «нашёл discord — отметил, нашёл twitch — отметил,
// отправил всё в одну группу» — ровно тот сценарий, ради которого отметки.
let ugPicked = new Set();
// Родители строк без группы в текущей выдаче — для «Отметить найденные».
let ugPickable = [];
// Поколение групп. Растёт в начале и в конце каждой записи. Загрузка таблицы,
// начатая до записи или во время неё, приносит прежний текст групп — /state на
// роутере идёт секунды, и такой ответ приходит ПОСЛЕ свежего. Применять его
// нельзя: только что созданная группа пропадала с экрана, а следующая правка
// получала ложный отказ «изменено на другом устройстве» по устаревшей версии.
let ugGen = 0;

function setUgView(text, revision) {
  const t = text ? String(text) + (String(text).endsWith("\n") ? "" : "\n") : "";
  const { sections } = domainGroupSections(t);
  ugView = { text: t, revision: String(revision || ""), sections, index: domainGroupIndex(sections) };
  ugError = "";
}

// Номер группы для записи или -1. Без загруженных групп — всегда -1, и это не
// заглушка: поиск и «Заморозить все» обязаны работать и до прихода групп.
function entryUg(e) { return ugView ? matchDomainGroup(ugView.index, e.host) : -1; }

function visibleStateEntries(entries = stateCache || []) {
  const query = (document.getElementById("state-search")?.value || "").trim().toLowerCase();
  // Поиск видит и имя группы: «дискорд» находит всё, что человек сам туда
  // сложил, хотя ни один домен так не называется. Ради этого группы и заводят.
  return entries.filter(e => {
    if (hiddenStrategyPool(e.key) || e.host === "nohost") return false;
    if (String(e.host || "").replace(/\|[46]$/, "").toLowerCase().includes(query)) return true;
    const ug = query ? entryUg(e) : -1;
    return ug >= 0 && ugView.sections[ug].name.toLowerCase().includes(query);
  });
}

function updateVisibleFreezeButton() {
  const button = document.getElementById("state-freeze-visible");
  if (!button) return;
  const rows = visibleStateEntries();
  const filtered = !!(document.getElementById("state-search")?.value || "").trim();
  const frozen = rows.length > 0 && rows.every(e => e.mode === "frozen");
  button.disabled = stateBulkBusy || !rows.length;
  button.textContent = stateBulkBusy ? "Применяем…" :
    `${frozen ? "Разморозить" : "Заморозить"} ${filtered ? "найденные" : "все"}${rows.length ? ` · ${rows.length}` : ""}`;
  button.setAttribute("aria-busy", String(stateBulkBusy));
}

async function stateFreezeVisible() {
  if (stateBulkBusy) return;
  // Snapshot the filter result, including collapsed groups. Subsequent typing
  // or refreshes must not change the set halfway through the operation.
  const rows = visibleStateEntries().map(e => ({ key: e.key, host: e.host, mode: e.mode }));
  if (!rows.length) return;
  const action = rows.every(e => e.mode === "frozen") ? "unfreeze" : "freeze";
  const verb = action === "freeze" ? "Заморозить" : "Разморозить";
  const query = (document.getElementById("state-search")?.value || "").trim();
  const scope = query ? `по поиску «${query}»` : "в таблице";
  if (!confirm(`${verb} ${rows.length} записей ${scope}?\n\n${action === "freeze"
    ? "Каждая запись закрепится на своей текущей стратегии."
    : "Для этих записей продолжится автоматический подбор."}`)) return;
  stateBulkBusy = true;
  updateVisibleFreezeButton();
  let done = 0;
  try {
    const pools = new Map();
    for (const row of rows) {
      if (!pools.has(row.key)) pools.set(row.key, []);
      pools.get(row.key).push(row.host);
    }
    for (const [key, hosts] of pools) {
      // Endpoint limit is 64 KiB; domain keys are ASCII. Keep request bodies
      // comfortably below it, with one state rewrite per pool in normal use.
      const batches = [];
      let body = "";
      for (const host of hosts) {
        if (body.length + host.length + 1 > 60000) { batches.push(body); body = ""; }
        body += host + "\n";
      }
      if (body) batches.push(body);
      for (const batch of batches) {
        const result = await apiPostText(`/state/bulk?action=${action}&key=${encodeURIComponent(key)}`, batch);
        done += Number(result && result.done) || 0;
      }
    }
    toast(`${action === "freeze" ? "Заморожено" : "Разморожено"}: ${done} из ${rows.length}`);
  } catch (error) {
    toastErr(`Применено ${done} из ${rows.length}. Не удалось завершить: `, error);
  } finally {
    await loadState();
    // The entry guard excludes another batch until this refresh finishes.
    // eslint-disable-next-line require-atomic-updates
    stateBulkBusy = false;
    updateVisibleFreezeButton();
  }
}


// Группы, свёрнутые ВРУЧНУЮ во время поиска. Отдельно от stateOpenGroups и
// намеренно не в localStorage: тот набор переживает перезагрузку страницы, и
// снимать в нём флаг из-за одной отфильтрованной выдачи нельзя — человек
// потерял бы раскрытие, поставленное задолго до поиска. Набор живёт, пока в
// поле поиска что-то есть, и очищается вместе с ним.
let searchCollapsed = new Set();

// Запрос, который ещё в полёте. Новый вызов его отменяет: /state стоит
// ~2.4 с шелл-CGI на роутере, и два параллельных прогона соревнуются за
// тот же CPU ради ответа, который всё равно будет отброшен.
let _stateAbort = null;

// Перерисовка тем, что уже в руках. Пустой кэш значит, что первая загрузка
// ещё идёт или её оборвала ошибка — и в сеть отсюда НЕ идём.
//
// Раньше здесь был безусловный loadState(true), который при пустом кэше
// молча проваливался в сетевую ветку. С сортировкой это сходило с рук: по
// колонке кликают, когда таблица уже нарисована. Поле поиска доступно сразу,
// и каждая буква, набранная до прихода первого /state, отменяла летящий
// запрос и пускала новый — а он на роутере стоит ~2.4 с шелл-CGI, так что
// таблица оставалась скелетом всю очередь нажатий.
//
// Терять при этом нечего: и запрос, и сортировка читаются в МОМЕНТ
// отрисовки, поэтому пришедший ответ нарисуется уже отфильтрованным.
function resortState() { return stateCache ? loadState(true) : Promise.resolve(); }

async function loadState(useCache) {
  const body = document.getElementById("state-body");
  if (!body) return;
  // Поколение поднимает ТОЛЬКО сетевой путь. Пересортировка — операция вида:
  // строки уже в браузере, в сеть она не идёт. Считая её новой загрузкой, мы
  // отменяли летящий /state и выбрасывали его ответ вместе с обновлением
  // кэша — то есть возвращали ровно тот баг, ради которого гейт вводился:
  // удалил строку, кликнул по заголовку колонки — строка снова на экране.
  // seq === 0 значит «к этой перерисовке гейт не применяется».
  let seq = 0;
  try {
    let entries;
    if (useCache && stateCache) {
      entries = stateCache;
    } else {
      seq = _newLoad("state");
      if (_stateAbort) _stateAbort.abort();
      _stateAbort = typeof AbortController === "function" ? new AbortController() : null;
      const signal = _stateAbort ? _stateAbort.signal : undefined;
      // /pools may fail if nfqws2 isn't running — tolerate it (dropdowns then
      // fall back to the row's own strategy as the max).
      // Группы — третьим запросом и тоже без права уронить таблицу: роутер
      // старше панели их не знает, и это не повод не показывать стратегии.
      const gen = ugGen;
      const [d, poolsResp, groupsResp] = await Promise.all([
        apiGet("/state", { signal }),
        apiGet("/pools", { signal }).catch(() => ({ pools: {} })),
        apiGet("/domain-groups", { signal }).catch(e => ({ __error: e })),
      ]);
      // Ответ более старого вызова, обогнавший свежий, не должен ни
      // рисовать таблицу, ни отравлять stateCache: иначе только что
      // удалённая строка «воскресала» сразу после тоста «Удалено», а
      // последующие пересортировки шли уже по мусорному кэшу.
      if (_stale("state", seq)) return;
      setStatePools(Object.fromEntries(Object.entries((poolsResp && poolsResp.pools) || {})
        .filter(([key]) => !hiddenStrategyPool(key))));
      entries = (d.entries || []).filter(e => !hiddenStrategyPool(e.key));
      if (gen !== ugGen) {
        // Ответ про группы старше записи, прошедшей за время загрузки.
      } else if (groupsResp && !groupsResp.__error && typeof groupsResp.text === "string") {
        // Пока открыт редактор, разбор не подменяем: его поля посчитаны от
        // версии, с которой человек начал, а сохранение сверит её с роутером.
        if (!ugEdit) setUgView(groupsResp.text, groupsResp.revision);
      } else if (!ugView) {
        ugError = errMsg(groupsResp && groupsResp.__error);
      }
      // Гонку закрывает метка _stale несколькими строками выше: ответ,
      // обогнанный более свежим, до этого места не доходит. Линтер видит
      // «запись после await», но гейта не видит.
      // eslint-disable-next-line require-atomic-updates
      stateCache = entries;
    }

    // Discord-voice panel first — it must populate even with empty rotator state.
    //
    // Только на СЕТЕВОЙ загрузке. Перерисовка по кэшу (поиск, сортировка)
    // данных этой карточки не меняет — они те же entries и те же пулы, — а
    // перерисовка сбрасывает выбор в её селекторе и галочку «заморозить»,
    // которые человек выставил, но ещё не применил. С сортировкой это было
    // терпимо: по колонке кликают редко и осознанно. Поиск дёргает
    // перерисовку на КАЖДУЮ букву, то есть стирал бы выбор сразу.
    if (!useCache) renderDiscordVoicePanel(entries);
    // Карточка групп — по той же причине только на сетевой загрузке: в ней
    // может быть открыт редактор с ненабранным текстом.
    if (!useCache) renderUgManager();

    // Записи с host="nohost" — это пулы без домена, и единственный такой пул,
    // discord_udp, уже показан карточкой выше со своим селектором и заморозкой.
    // Без этого фильтра он появлялся в таблице ВТОРЫМ экземпляром, но только
    // после первого «Применить» (до него записи не существует) — поэтому на
    // свежем роутере дубля не видно и баг доживал до первого звонка.
    // Колонка «Домен» показывала бы у него буквальное «nohost».
    // Ключ ротации хранится с суффиксом семейства адресов: example.com|4 и
    // example.com|6 — ДВЕ разные записи с разными стратегиями. Суффикс
    // печатался как есть: непонятный хвост в имени, он же в подсказке
    // скринридера (читалась вертикальная черта) и в вопросе перед удалением.
    //
    // Суффикса может и не быть: у записей без имени хоста и у строк от
    // старых версий. Тогда метку не ставим, а не выдумываем.
    const splitFamily = (h) => {
      const raw = String(h == null ? "" : h);
      const cut = raw.lastIndexOf("|");
      if (cut < 0) return { name: raw, fam: "" };
      const tail = raw.slice(cut + 1);
      if (tail === "4") return { name: raw.slice(0, cut), fam: "IPv4" };
      if (tail === "6") return { name: raw.slice(0, cut), fam: "IPv6" };
      return { name: raw, fam: "" };
    };
    const all = entries.filter(e => !hiddenStrategyPool(e.key) && e.host !== "nohost");
    updateVisibleFreezeButton();

    const counter = document.getElementById("state-search-count");
    if (!all.length) {
      if (counter) counter.textContent = "Записей: 0";
      body.innerHTML = `<p style="color:var(--text-muted)">пока пусто — ни одна стратегия ещё не закреплена</p>`;
      ugPickable = [];
      renderUgSelbar();
      return;
    }

    // ПОИСК ПО ИМЕНИ. Ищем по имени БЕЗ суффикса семейства: человек набирает
    // «apple», а в ключе лежит «gs-loc5.apple.com|4», и вертикальная черта с
    // цифрой — служебная часть, которой в поле никто не наберёт.
    //
    // Подстрока, а не начало имени: у поддоменных групп искомое почти всегда
    // в середине (scontent-a12-3.xx.fbcdn.net), и поиск «по началу» не нашёл
    // бы ничего именно там, где записей сотни.
    //
    // Поле живёт в панели кнопок, СНАРУЖИ #state-body: эта функция заменяет
    // его innerHTML целиком, и поле внутри пересоздавалось бы на каждой букве,
    // теряя фокус и каретку.
    const searchEl = document.getElementById("state-search");
    const query = searchEl ? searchEl.value.trim().toLowerCase() : "";
    const visible = visibleStateEntries(all);
    if (counter) counter.textContent = query
      ? `Найдено записей: ${visible.length} из ${all.length}`
      : `Записей: ${all.length}`;
    // Поле очистили — сессия поиска кончилась, ручные сворачивания внутри неё
    // забываются, и таблица возвращается к тому, что помнит stateOpenGroups.
    if (!query) searchCollapsed = new Set();

    if (!visible.length) {
      body.innerHTML = `<p style="color:var(--text-muted)">Ничего не найдено. Измените поисковый запрос.</p>`;
      // Панель отмеченного живёт снаружи таблицы. Без этого на пустой выдаче
      // оставалась «Отметить найденные» от предыдущей буквы — и отмечала то,
      // чего на экране уже нет.
      ugPickable = [];
      renderUgSelbar();
      return;
    }
    const nowSec = Math.floor(Date.now() / 1000);
    // Имя без суффикса семейства и его родитель считаются один раз на строку:
    // ими пользуются и сортировка, и группировка, и отрисовка.
    // КЛЮЧ ГРУППЫ — ПУЛ ПЛЮС ДОМЕН, А НЕ ОДИН ДОМЕН.
    //
    // Номера стратегий живут внутри пула: у quic девять плеч, у gv_tcp
    // двадцать два. googlevideo.com встречается в обоих, и одна общая группа
    // складывала строки с несопоставимыми номерами — сводка в заголовке
    // получалась про «1, 3» из разных наборов, а групповое действие над такой
    // смесью объяснить человеку нечем.
    const meta = new Map(visible.map(e => {
      const hf = splitFamily(e.host);
      const dom = groupDomain(hf.name);
      return [e, { name: hf.name, fam: hf.fam, group: dom, ug: entryUg(e),
                   gkey: String(e.key || "") + GKEY_SEP + dom, age: stateAge(e.ts, nowSec) }];
    }));
    // ГРУППЫ ЧЕЛОВЕКА — УРОВНЕМ ВЫШЕ АВТОГРУПП. Строки раскладываются по
    // группам, и внутри каждой работает прежняя сборка: поддомены под
    // родителем, пул отдельно, выбранная сортировка. Сами группы стоят в том
    // порядке, в каком их завели, и выше строк без группы: порядок групп —
    // решение человека, и колонка сортировки его не переставляет.
    const ugParts = ugView ? ugView.sections.map(() => []) : [];
    const ungrouped = [];
    for (const e of visible) {
      const ug = meta.get(e).ug;
      (ug >= 0 ? ugParts[ug] : ungrouped).push(e);
    }
    const blocks = buildStateBlocks(ungrouped, meta);
    // «Отметить найденные» берёт то же, что дала бы ручная отметка: у
    // автогруппы — весь домен (её заголовок), у одиночной строки — её имя.
    ugPickable = Array.from(new Set(blocks.flatMap(b => b.names.size >= 2 ? [b.group] : Array.from(b.names))
      .filter(n => n.indexOf(":") < 0 && !/^[0-9.]+$/.test(n))));

    const fmtAge = (age) => age === null ? "—" : age < 60 ? age + "с" :
                            age < 3600 ? Math.floor(age / 60) + "м" :
                            age < 86400 ? Math.floor(age / 3600) + "ч" :
                            Math.floor(age / 86400) + "д";

    const rowHtml = (e, inGroup) => {
      const m = meta.get(e);
      const ageStr = fmtAge(m.age);
      const frozen = e.mode === "frozen";
      // Pool size from the live nfqws2 cmdline; fall back to the row's own
      // strategy so a stale/larger pinned value still appears in the dropdown.
      const N = Math.max(Number(statePools[e.key] || 0), Number(e.strategy) || 1);
      let opts = "";
      for (let i = 1; i <= N; i++) {
        opts += `<option value="${i}"${i === Number(e.strategy) ? " selected" : ""}>${i}</option>`;
      }
      // Внутри группы родитель уже написан в заголовке, поэтому в строке он
      // приглушён, и глаз цепляется за то, чем строки различаются. Имя,
      // совпадающее с родителем (сам chatgpt.com в группе chatgpt.com),
      // печатается целиком. Обе части — в ОДНОМ span: на телефоне ячейка
      // становится flex-контейнером, и текст с соседним span разъехались бы
      // в два элемента с зазором посреди имени.
      const tail = "." + m.group;
      const nameHtml = inGroup && m.name.length > tail.length && m.name.slice(-tail.length) === tail
        ? `<span>${escapeHtml(m.name.slice(0, -tail.length))}<span class="sg-parent">${escapeHtml(tail)}</span></span>`
        : escapeHtml(m.name);
      // data-host в атрибутах остаётся СЫРЫМ ключом: это идентификатор
      // записи для API, его резать нельзя. Делим только видимое человеку.
      // data-label attrs feed the mobile card layout (CSS pseudo-elements)
      return `
        <tr${inGroup ? ' class="sg-member"' : ""}${frozen ? ' style="background:rgba(120,140,255,0.10)"' : ''}>
          <td data-label="">
            <button class="btn btn-danger btn-icon state-del"
                    title="Удалить запись"
                    aria-label="Удалить ${escapeHtml(m.name)}${m.fam ? ", " + m.fam : ""}"
                    data-key="${escapeHtml(e.key)}"
                    data-host="${escapeHtml(e.host)}">${_icons.close}</button>
          </td>
          <td data-label="Профиль">${escapeHtml(e.key)}</td>
          <td data-label="Домен" class="state-host${inGroup ? " sg-leaf" : ""}">${m.ug < 0 ? pickHtml(m.name) : ""}${nameHtml}${m.fam ? ` <span class="fam-tag">${m.fam}</span>` : ""}${m.ug < 0 ? assignHtml(m.name) : ""}</td>
          <td data-label="Стратегия">
            <select class="state-strat-sel"
                    data-key="${escapeHtml(e.key)}"
                    data-host="${escapeHtml(e.host)}"
                    data-mode="${frozen ? "frozen" : "auto"}">${opts}</select>
            ${e.sni ? `<div class="state-sni" title="Домен пробивается подставным именем — обход блокировки по объёму">${escapeHtml(e.sni)}</div>` : ""}
          </td>
          <td data-label="Заморозка">
            <button class="btn btn-icon state-freeze"
                    data-key="${escapeHtml(e.key)}"
                    data-host="${escapeHtml(e.host)}"
                    data-strategy="${escapeHtml(e.strategy)}"
                    data-frozen="${frozen ? "1" : "0"}"
                    style="color:${frozen ? "var(--accent)" : "var(--text-muted)"}"
                    title="${frozen ? "Заморожено — нажмите, чтобы разморозить (вернуть авторотацию)" : "Авторотация — нажмите, чтобы заморозить на текущей стратегии"}">${frozen ? _icons.lockClosed : _icons.lockOpen}</button>
          </td>
          <td data-label="Возраст" class="state-age">${ageStr}</td>
        </tr>
      `;
    };

    const plural = (n, one, few, many) => {
      const d = n % 10, h = n % 100;
      if (d === 1 && h !== 11) return one;
      if (d >= 2 && d <= 4 && (h < 12 || h > 14)) return few;
      return many;
    };
    // Номера стратегий в сводке: одно число, если у всех одна; до трёх —
    // перечнем; больше — диапазоном, иначе ячейка расползается на всю строку.
    const strategySummary = (rows) => {
      const nums = Array.from(new Set(rows.map(e => Number(e.strategy) || 0))).sort((x, y) => x - y);
      return nums.length <= 3 ? nums.join(", ") : `${nums[0]}–${nums[nums.length - 1]}`;
    };

    // Кнопка «в группу» и галочка кладут в группу ТО ИМЯ, У КОТОРОГО СТОЯТ:
    // строка — своё точное имя, заголовок автогруппы — домен целиком (он
    // покрывает поддомены, и finland10000…10100.discord.media уходят одним
    // кликом). Подставлять родителя за строку нельзя: у игр и приложений
    // часть имён живёт на общей инфраструктуре — ngx.download.nvidia.com,
    // down.anticheatexpert.com (античит ACE у многих игр), crashsight.wetest.net,
    // — и родитель утащил бы в группу «Endfield» всю NVIDIA. Список в окне
    // всё равно можно поправить перед сохранением.
    const assignHtml = (name) => {
      if (!ugView || name.indexOf(":") >= 0 || /^[0-9.]+$/.test(name)) return "";
      const parent = name;
      return `<button type="button" class="btn-icon ug-assign" data-domain="${escapeHtml(parent)}"
                title="Добавить ${escapeHtml(parent)} в группу" aria-label="Добавить ${escapeHtml(parent)} в группу">${_icons.folderPlus}</button>`;
    };

    // Галочка отметки — у тех же мест, что и кнопка «в группу»: у каждой
    // строки без группы (включая строки автогрупп) и у заголовка автогруппы.
    const pickHtml = (name) => {
      if (!ugView || name.indexOf(":") >= 0 || /^[0-9.]+$/.test(name)) return "";
      const parent = name;
      return `<input type="checkbox" class="ug-pick" data-domain="${escapeHtml(parent)}"${ugPicked.has(parent) ? " checked" : ""}
                title="Отметить ${escapeHtml(parent)}" aria-label="Отметить ${escapeHtml(parent)}">`;
    };

    const groupHtml = (b, child = "") => {
      // Открытость помним по СОСТАВНОМУ ключу: googlevideo.com в quic и в
      // gv_tcp — разные группы, и сворачиваться они обязаны независимо.
      //
      // Во время поиска группы раскрыты принудительно: иначе находка прячется
      // за свёрнутым заголовком, и поиск показывает, что совпадение ГДЕ-ТО
      // есть, вместо того чтобы показать саму строку. Флаг раскрытия при этом
      // в stateOpenGroups НЕ пишется — он переживает перезагрузку страницы, и
      // одна отфильтрованная выдача оставила бы после себя навсегда
      // развёрнутыми полтысячи строк.
      // Раскрыты не НАСИЛЬНО: свёрнутое руками прямо сейчас уважается, иначе
      // следующая же буква (и любая перерисовка после заморозки или удаления)
      // возвращала бы группу раскрытой, и свернуть её было бы нельзя вовсе.
      // Оба набора идут мимо stateOpenGroups — см. searchCollapsed.
      const open = query ? !searchCollapsed.has(b.gkey) : stateOpenGroups.has(b.gkey);
      const n = b.rows.length;
      const keys = [b.pool];
      const nFrozen = b.rows.filter(e => e.mode === "frozen").length;
      // Действие над группой — одно на всю: заморозить, если заморожены не все,
      // иначе разморозить. Отдельной кнопки «разморозить» нет: состояние видно
      // в той же ячейке, и две кнопки на одно состояние путают.
      const groupFrozen = nFrozen === n && n > 0;
      const countText = `${n} ${plural(n, "запись", "записи", "записей")}`;
      // ВО ВРЕМЯ ПОИСКА В ГРУППЕ ВИДНЫ ТОЛЬКО СОВПАВШИЕ СТРОКИ, и пакетные
      // кнопки действуют ровно на них — они забирают строки из нарисованного
      // tbody. Значит слова обязаны это признавать: «вся группа» над тремя
      // строками из ста — неправда, а кнопка рядом необратима. Сужаем не
      // действие (сужать его незачем: человек видит, что жмёт), а подпись.
      const whole = !query;
      return `
        <tbody class="sg${open ? "" : " sg-closed"}" data-group="${escapeHtml(b.gkey)}"${child}>
          <tr class="sg-head">
            <td data-label="" class="sg-lead">
              <button class="btn btn-danger btn-icon sg-reset"
                      title="Сбросить подбор ${whole ? "для всей группы" : "для найденных в группе"} (${escapeHtml(String(n))} ${escapeHtml(plural(n, "записи", "записей", "записей"))})"
                      aria-label="Сбросить подбор ${whole ? "для группы" : "для найденных в группе"} ${escapeHtml(b.group)}"
                      data-gkey="${escapeHtml(b.gkey)}">${_icons.close}</button>
            </td>
            <td data-label="Профиль">${escapeHtml(keys.join(", "))}</td>
            <td data-label="Домен" class="sg-title">${b.rows.every(e => meta.get(e).ug < 0) ? pickHtml(b.group) : ""}
              <button type="button" class="sg-toggle" aria-expanded="${open}"
                      data-count="${escapeHtml(countText)}"
                      title="${open ? "Свернуть" : "Раскрыть"}: ${escapeHtml(countText)}">
                ${_icons.chevronDown}<span class="sg-name">${escapeHtml(b.group)}</span><span class="sg-count" aria-label="${escapeHtml(countText)}">${n}</span>
              </button>${b.rows.every(e => meta.get(e).ug < 0) ? assignHtml(b.group) : ""}
            </td>
            <td data-label="Стратегия">${escapeHtml(strategySummary(b.rows))}</td>
            <td data-label="Заморозка">
              <button class="btn btn-icon sg-freeze"
                      data-gkey="${escapeHtml(b.gkey)}"
                      data-frozen="${groupFrozen ? "1" : "0"}"
                      style="color:${nFrozen ? "var(--accent)" : "var(--text-muted)"}"
                      title="${groupFrozen
                        ? (whole ? "Вся группа заморожена — нажмите, чтобы вернуть авторотацию"
                                 : "Все найденные заморожены — нажмите, чтобы вернуть авторотацию")
                        : (whole ? "Заморозить всю группу на текущих стратегиях"
                                 : "Заморозить найденные на текущих стратегиях")}">${groupFrozen ? _icons.lockClosed : _icons.lockOpen}</button>
              ${nFrozen
                ? `<span class="sg-frozen">${nFrozen === n && whole ? "все" : `${nFrozen} из ${n}`}</span>`
                : ""}</td>
            <td data-label="Возраст" class="state-age">${fmtAge(b.age)}</td>
          </tr>
          ${b.rows.map(e => rowHtml(e, true)).join("")}
        </tbody>
      `;
    };

    // Заголовок получает только группа из РАЗНЫХ имён. chatgpt.com|4 и
    // chatgpt.com|6 — один сайт в двух семействах адресов, сворачивать там
    // нечего, а заголовок над парой одинаковых строк только прибавил бы шума.
    // Одиночные строки подряд собираются в общий tbody.
    const renderBlocks = (list, child = "") => {
      let out = "";
      let loose = "";
      for (const b of list) {
        if (b.names.size >= 2) {
          if (loose) { out += `<tbody${child}>${loose}</tbody>`; loose = ""; }
          out += groupHtml(b, child);
        } else {
          loose += b.rows.map(e => rowHtml(e, false)).join("");
        }
      }
      if (loose) out += `<tbody${child}>${loose}</tbody>`;
      return out;
    };

    // Заголовок группы человека. Строки под ним — обычные блоки таблицы с
    // меткой data-ug-of: вложить tbody в tbody HTML не даёт, поэтому
    // свёрнутость переключается меткой на каждом блоке группы.
    //
    // Сводка стратегий — только если вся группа в одном пуле. Номера плеч
    // живут внутри пула (у quic их девять, у gv_tcp двадцать два), и «1, 3» из
    // разных наборов читалось бы как одно и то же, чем оно не является.
    const ugHtml = (i, rows) => {
      const sec = ugView.sections[i];
      const open = query ? !searchCollapsed.has("ug:" + sec.name) : stateOpenUgroups.has(sec.name);
      const n = rows.length;
      const pools = Array.from(new Set(rows.map(e => String(e.key || "")))).sort();
      const nFrozen = rows.filter(e => e.mode === "frozen").length;
      const groupFrozen = nFrozen === n && n > 0;
      let age = null;
      for (const e of rows) { const a = meta.get(e).age; if (a !== null && (age === null || a < age)) age = a; }
      const countText = `${n} ${plural(n, "запись", "записи", "записей")}`;
      const whole = !query;
      const child = ` data-ug-of="${i}"${open ? "" : " data-ug-closed"}`;
      return `
        <tbody class="ug${open ? "" : " ug-closed"}" data-ug="${i}">
          <tr class="sg-head ug-head">
            <td data-label="" class="sg-lead">
              <button class="btn btn-danger btn-icon ug-reset" data-ug="${i}"
                      title="Сбросить подбор ${whole ? "для всей группы" : "для найденных в группе"} (${escapeHtml(countText)})"
                      aria-label="Сбросить подбор ${whole ? "для группы" : "для найденных в группе"} ${escapeHtml(sec.name)}">${_icons.close}</button>
            </td>
            <td data-label="Профиль">${escapeHtml(pools.join(", "))}</td>
            <td data-label="Домен" class="sg-title ug-title">
              <button type="button" class="sg-toggle ug-toggle" aria-expanded="${open}"
                      data-count="${escapeHtml(countText)}"
                      title="${open ? "Свернуть" : "Раскрыть"}: ${escapeHtml(countText)}">
                ${_icons.chevronDown}<span class="sg-name">${escapeHtml(sec.name)}</span><span class="sg-count" aria-label="${escapeHtml(countText)}">${n}</span>
              </button>
              <button type="button" class="btn-icon ug-edit" data-ug="${i}"
                      title="Изменить группу" aria-label="Изменить группу ${escapeHtml(sec.name)}">${_icons.edit}</button>
            </td>
            <td data-label="Стратегия"${pools.length > 1 ? ' title="Номера стратегий у разных пулов несопоставимы"' : ""}>${pools.length === 1 ? escapeHtml(strategySummary(rows)) : "—"}</td>
            <td data-label="Заморозка">
              <button class="btn btn-icon ug-freeze" data-ug="${i}"
                      data-frozen="${groupFrozen ? "1" : "0"}"
                      style="color:${nFrozen ? "var(--accent)" : "var(--text-muted)"}"
                      title="${groupFrozen
                        ? (whole ? "Вся группа заморожена — нажмите, чтобы вернуть авторотацию"
                                 : "Все найденные заморожены — нажмите, чтобы вернуть авторотацию")
                        : (whole ? "Заморозить всю группу на текущих стратегиях"
                                 : "Заморозить найденные на текущих стратегиях")}">${groupFrozen ? _icons.lockClosed : _icons.lockOpen}</button>
              ${nFrozen
                ? `<span class="sg-frozen">${nFrozen === n && whole ? "все" : `${nFrozen} из ${n}`}</span>`
                : ""}</td>
            <td data-label="Возраст" class="state-age">${fmtAge(age)}</td>
          </tr>
        </tbody>
        ${renderBlocks(buildStateBlocks(rows, meta), child)}
      `;
    };

    let html = "";
    ugParts.forEach((rows, i) => { if (rows.length) html += ugHtml(i, rows); });
    html += renderBlocks(blocks);

    const arrow = k => stateSort.key === k ? (stateSort.dir === "asc" ? " " + _icons.arrowUp : " " + _icons.arrowDown) : "";
    const th = (k, label) => `<th class="sortable" data-sort="${k}">${label}${arrow(k)}</th>`;
    const sortLabel = STATE_SORT_LABELS[stateSort.key] || "Профиль";
    const sortArrow = stateSort.dir === "asc" ? _icons.arrowUp : _icons.arrowDown;
    body.innerHTML = `
      <button type="button" class="sort-trigger" id="state-sort-btn"
              aria-haspopup="dialog" aria-expanded="false">
        Сортировка: ${sortLabel} ${sortArrow}
      </button>
      <div class="table-scroll">
      <table class="state-table${blocks.some(b => b.names.size >= 2) || ugParts.some(r => r.length) ? " sg-any" : ""}">
        <thead>
          <tr><th></th>${th("key","Профиль")}${th("host","Домен")}${th("strategy","Стратегия")}${th("frozen","Заморозка")}${th("age","Возраст")}</tr>
        </thead>
        ${html}
      </table>
      </div>
    `;
    body.querySelectorAll(".state-del").forEach(btn => {
      btn.addEventListener("click", () => stateDelete(btn.dataset.key, btn.dataset.host));
    });
    body.querySelectorAll(".state-strat-sel").forEach(sel => {
      // Changing the strategy applies immediately; data-mode preserves the
      // freeze state (frozen → re-pin at the new strategy; auto → rotation
      // continues from it, e.g. to skip a broken strategy).
      sel.addEventListener("change", () => stateSet(sel.dataset.key, sel.dataset.host, sel.value, sel.dataset.mode));
    });
    body.querySelectorAll(".state-freeze").forEach(btn => {
      btn.addEventListener("click", () => {
        const newMode = btn.dataset.frozen === "1" ? "auto" : "frozen";
        stateSet(btn.dataset.key, btn.dataset.host, btn.dataset.strategy, newMode);
      });
    });
    // Пакетные действия. stopPropagation обязателен: клик ловится на ВСЕЙ
    // строке заголовка (цель шире, чем имя), и без него нажатие на кнопку
    // заодно сворачивало бы группу — ровно в тот момент, когда человек
    // читает подтверждение.
    body.querySelectorAll(".sg-reset").forEach(btn => {
      btn.addEventListener("click", ev => {
        ev.stopPropagation();
        const tb = btn.closest("tbody.sg");
        if (tb) stateBulk("delete", tb);
      });
    });
    body.querySelectorAll(".sg-freeze").forEach(btn => {
      btn.addEventListener("click", ev => {
        ev.stopPropagation();
        const tb = btn.closest("tbody.sg");
        if (tb) stateBulk(btn.dataset.frozen === "1" ? "unfreeze" : "freeze", tb);
      });
    });
    // Раскрытие — без перерисовки и без сети: строки группы уже в разметке,
    // меняется только класс её tbody. Клик ловится на всей строке заголовка
    // (цель шире, чем имя), а кнопка внутри даёт клавиатуру и скринридер —
    // её собственный клик всплывает сюда же, поэтому обработчик один.
    body.querySelectorAll("tbody.sg").forEach(tb => {
      const head = tb.querySelector(".sg-head");
      if (!head) return;
      head.addEventListener("click", () => {
        const g = tb.dataset.group;
        // Считаем от НАРИСОВАННОГО, а не от запомненного. Во время поиска
        // группа раскрыта принудительно, и в stateOpenGroups её при этом нет:
        // «инвертировать запомненное» дало бы open=true у уже раскрытой
        // группы, то есть первый клик «свернуть» молча не сработал бы.
        // Класс на tbody — единственный источник, который всегда совпадает
        // с тем, что человек видит.
        const open = tb.classList.contains("sg-closed");
        if (query) {
          // Во время поиска — в эфемерный набор. Запись в stateOpenGroups
          // здесь СТИРАЛА БЫ раскрытие, поставленное до поиска: свернуть
          // группу в выдаче значит «сейчас не мешай», а не «забудь навсегда».
          if (open) searchCollapsed.delete(g); else searchCollapsed.add(g);
        } else {
          if (open) stateOpenGroups.add(g); else stateOpenGroups.delete(g);
          saveOpenGroups();
        }
        tb.classList.toggle("sg-closed", !open);
        const btn = tb.querySelector(".sg-toggle");
        if (btn) {
          btn.setAttribute("aria-expanded", String(open));
          btn.setAttribute("title", `${open ? "Свернуть" : "Раскрыть"}: ${btn.dataset.count}`);
        }
      });
    });
    // Группы человека. Обработчики — те же правила, что у автогрупп выше:
    // раскрытие без сети и без перерисовки, кнопки в заголовке гасят всплытие,
    // во время поиска свёрнутость живёт в эфемерном наборе.
    body.querySelectorAll("tbody.ug").forEach(tb => {
      const head = tb.querySelector(".ug-head");
      if (!head) return;
      head.addEventListener("click", () => {
        const i = tb.dataset.ug;
        const sec = ugView && ugView.sections[Number(i)];
        if (!sec) return;
        const open = tb.classList.contains("ug-closed");
        const memo = "ug:" + sec.name;
        if (query) {
          if (open) searchCollapsed.delete(memo); else searchCollapsed.add(memo);
        } else {
          if (open) stateOpenUgroups.add(sec.name); else stateOpenUgroups.delete(sec.name);
          saveOpenUgroups();
        }
        tb.classList.toggle("ug-closed", !open);
        body.querySelectorAll(`tbody[data-ug-of="${i}"]`).forEach(c => {
          if (open) c.removeAttribute("data-ug-closed"); else c.setAttribute("data-ug-closed", "");
        });
        const btn = tb.querySelector(".ug-toggle");
        if (btn) {
          btn.setAttribute("aria-expanded", String(open));
          btn.setAttribute("title", `${open ? "Свернуть" : "Раскрыть"}: ${btn.dataset.count}`);
        }
      });
    });
    body.querySelectorAll(".ug-reset, .ug-freeze").forEach(btn => {
      btn.addEventListener("click", ev => {
        ev.stopPropagation();
        const action = btn.classList.contains("ug-reset") ? "delete"
          : btn.dataset.frozen === "1" ? "unfreeze" : "freeze";
        ugBulk(action, btn.dataset.ug, body);
      });
    });
    body.querySelectorAll(".ug-edit").forEach(btn => {
      btn.addEventListener("click", ev => {
        ev.stopPropagation();
        const card = document.getElementById("ug-card");
        if (card) card.open = true;
        ugOpenEditor("group", Number(btn.dataset.ug));
      });
    });
    body.querySelectorAll(".ug-pick").forEach(box => {
      // Клик по галочке в заголовке автогруппы не должен её сворачивать.
      box.addEventListener("click", ev => ev.stopPropagation());
      box.addEventListener("change", () => {
        const d = box.dataset.domain;
        if (box.checked) ugPicked.add(d); else ugPicked.delete(d);
        // Тот же сайт может стоять несколькими строками (v4/v6, разные пулы).
        body.querySelectorAll(".ug-pick").forEach(o => { if (o.dataset.domain === d) o.checked = box.checked; });
        renderUgSelbar();
      });
    });
    renderUgSelbar();
    body.querySelectorAll(".ug-assign").forEach(btn => {
      btn.addEventListener("click", ev => {
        ev.stopPropagation();
        ugAssign(btn.dataset.domain);
      });
    });
    const sortBtn = document.getElementById("state-sort-btn");
    if (sortBtn) sortBtn.addEventListener("click", () => openSortSheet(resortState));
    body.querySelectorAll("th.sortable").forEach(th => {
      th.addEventListener("click", () => {
        const key = th.dataset.sort;
        if (stateSort.key === key) {
          stateSort.dir = stateSort.dir === "asc" ? "desc" : "asc";
        } else {
          stateSort.key = key;
          // Numeric columns default desc (largest first); strings asc.
          stateSort.dir = (key === "strategy") ? "desc" : "asc";
        }
        saveStateSort();
        resortState();
      });
    });
  } catch (e) {
    if (seq && _stale("state", seq)) return;
    // Кэш снимаем. С ним на руках остаются строки неизвестной свежести, а
    // любая перерисовка по кэшу молча заменила бы ими текст ошибки, выдав
    // устаревшее за текущее. Пока кэша не было у кого спросить, это никого
    // не жгло: единственной такой перерисовкой была сортировка, а её кнопка
    // живёт ВНУТРИ #state-body и вместе с таблицей исчезала. Поле поиска
    // лежит снаружи и переживает ошибку — то есть путь появился.
    // Без кэша resortState ничего не делает, и ошибка остаётся на экране
    // до следующего «Обновить».
    //
    // Гонку закрывает _stale строкой выше — ответ, обогнанный более свежим,
    // до сюда не доходит и чужой кэш не снимает. Линтер видит «запись после
    // await», но гейта не видит; то же подавление стоит и на записи кэша.
    // eslint-disable-next-line require-atomic-updates
    stateCache = null;
    updateVisibleFreezeButton();
    const counter = document.getElementById("state-search-count");
    if (counter) counter.textContent = "Не удалось загрузить записи";
    body.innerHTML = `<p style="color:var(--bad)">${errHtml(e)}</p>`;
  }
}

// Пакетная операция над группой. Хосты берём ИЗ РАЗМЕТКИ той же группы, а не
// из кэша ответа: на экране человек видит именно эти строки, и действие обязано
// совпадать с увиденным, даже если фоновый опрос успел принести другой срез.
async function stateBulk(action, tb) {
  const rows = Array.from(tb.querySelectorAll("tr.sg-member .state-del"));
  const hosts = rows.map(b => b.dataset.host).filter(Boolean);
  const key = rows.length ? rows[0].dataset.key : "";
  if (!key || !hosts.length) return;
  const name = tb.querySelector(".sg-name");
  const group = name ? name.textContent : "группы";
  const n = hosts.length;
  const word = { delete: "Сбросить подбор", freeze: "Заморозить", unfreeze: "Разморозить" }[action];
  const tail = action === "delete"
    ? "Подбор для этих доменов начнётся с первой стратегии при следующей попытке."
    : action === "freeze"
      ? "Каждая строка закрепится на СВОЕЙ текущей стратегии, ротация для них остановится."
      : "Ротация для этих строк продолжится с текущей стратегии.";
  if (!confirm(`${word}: ${group} (${key}), записей: ${n}?\n\n${tail}`)) return;
  let res;
  try {
    res = await apiPostText(`/state/bulk?action=${encodeURIComponent(action)}&key=${encodeURIComponent(key)}`,
                            hosts.join("\n") + "\n");
  } catch (e) {
    toastErr("Не получилось: ", e);
    return;
  }
  // «Сделано N из M» — не украшение: часть строк демон мог убрать сам, пока
  // человек читал подтверждение, и молчаливое «готово» в таком случае врёт.
  const done = Number(res && res.done) || 0;
  const total = Number(res && res.total) || n;
  toast(done === total ? `Готово: ${done}` : `Сделано ${done} из ${total}`);
  loadState();
}

// Пакетное действие над группой человека. Хосты — из разметки, как у
// автогрупп: действие обязано совпадать с тем, что на экране. Группа может
// жить в нескольких пулах, а /state/bulk работает с одним, поэтому запросы
// идут по пулу, и пулы названы в подтверждении: сброс в чужом пуле — ровно то,
// о чём человек должен знать до нажатия.
async function ugBulk(action, i, body) {
  const sec = ugView && ugView.sections[Number(i)];
  if (!sec) return;
  const rows = Array.from(body.querySelectorAll(`tbody[data-ug-of="${i}"] .state-del`));
  const byPool = new Map();
  for (const b of rows) {
    if (!b.dataset.key || !b.dataset.host) continue;
    if (!byPool.has(b.dataset.key)) byPool.set(b.dataset.key, []);
    byPool.get(b.dataset.key).push(b.dataset.host);
  }
  const n = Array.from(byPool.values()).reduce((k, h) => k + h.length, 0);
  if (!n) return;
  const word = { delete: "Сбросить подбор", freeze: "Заморозить", unfreeze: "Разморозить" }[action];
  const tail = action === "delete"
    ? "Подбор для этих доменов начнётся с первой стратегии при следующей попытке."
    : action === "freeze"
      ? "Каждая строка закрепится на СВОЕЙ текущей стратегии, ротация для них остановится."
      : "Ротация для этих строк продолжится с текущей стратегии.";
  if (!confirm(`${word}: ${sec.name}, записей: ${n}?\nПулы: ${Array.from(byPool.keys()).sort().join(", ")}.\n\n${tail}`)) return;
  let done = 0;
  try {
    for (const [key, hosts] of byPool) {
      const res = await apiPostText(`/state/bulk?action=${encodeURIComponent(action)}&key=${encodeURIComponent(key)}`,
                                    hosts.join("\n") + "\n");
      done += Number(res && res.done) || 0;
    }
    toast(done === n ? `Готово: ${done}` : `Сделано ${done} из ${n}`);
  } catch (e) {
    toastErr(`Сделано ${done} из ${n}. Не удалось завершить: `, e);
  }
  loadState();
}

// --- карточка «Группы доменов» ---------------------------------------------

function ugPlural(n) {
  const d = n % 10, h = n % 100;
  if (d === 1 && h !== 11) return "группа";
  if (d >= 2 && d <= 4 && (h < 12 || h > 14)) return "группы";
  return "групп";
}

function renderUgManager() {
  const box = document.getElementById("ug-body");
  const status = document.getElementById("ug-status");
  if (!box) return;
  // Карточка перерисовывается на каждой сетевой загрузке таблицы — «Обновить»,
  // правка строки, групповое действие. Открытый редактор при этом обязан
  // сохранить набранное: раньше он заново заполнялся из файла, и имя с
  // доменами молча пропадали.
  // Только в ТОТ ЖЕ редактор: открыв правку другой группы, человек не ждёт в
  // ней текст предыдущей.
  const edKey = ugEdit ? ugEdit.mode + ":" + ugEdit.index : "";
  const prevEd = document.getElementById("ug-editor");
  const typed = ugEdit && prevEd && !prevEd.hidden && prevEd.dataset.ed === edKey ? {
    name: document.getElementById("ug-name")?.value,
    body: document.getElementById("ug-domains")?.value,
    focus: document.activeElement && document.activeElement.id,
  } : null;
  if (!ugView) {
    if (status) status.textContent = ugError ? "Недоступны" : "Загрузка…";
    box.innerHTML = ugError
      ? `<p class="wl-error">Не удалось загрузить группы: ${escapeHtml(ugError)}</p>`
      : skeletonLines(2);
    return;
  }
  const secs = ugView.sections;
  if (status) status.textContent = secs.length ? `${secs.length} ${ugPlural(secs.length)}` : "Нет групп";
  // Сколько записей таблицы попало в группу: группа без единой записи — не
  // ошибка (сервис ещё не открывали), но человеку стоит это видеть, иначе
  // «я завёл группу, а в таблице её нет» выглядит как поломка.
  const hits = secs.map(() => 0);
  for (const e of stateCache || []) {
    if (hiddenStrategyPool(e.key) || e.host === "nohost") continue;
    const ug = entryUg(e);
    if (ug >= 0) hits[ug]++;
  }
  const list = secs.length ? `<ul class="ug-list">${secs.map((sec, i) => `
      <li>
        <span class="ug-list-name">${escapeHtml(sec.name)}</span>
        <span class="ug-list-meta">${sec.domains.length} ${plural3(sec.domains.length, "домен", "домена", "доменов")} · ${hits[i] ? `${hits[i]} ${plural3(hits[i], "запись", "записи", "записей")} в таблице` : "в таблице пока нет записей"}</span>
        <span class="ug-list-actions">
          <button type="button" class="btn ug-m-edit" data-ug="${i}">Изменить</button>
          <button type="button" class="btn btn-danger ug-m-del" data-ug="${i}">Удалить</button>
        </span>
      </li>`).join("")}</ul>`
    : `<p class="desc">Групп пока нет. Создайте группу здесь или нажмите значок папки рядом с доменом в таблице.</p>`;
  const ed = ugEdit;
  const sec = ed && ed.mode === "group" ? secs[ed.index] : null;
  const title = !ed ? "" : ed.mode === "new" ? "Новая группа" : ed.mode === "text" ? "Все группы текстом" : `Группа «${sec ? sec.name : ""}»`;
  const hint = !ed ? "" : ed.mode === "text"
    ? "Имя группы — в квадратных скобках, под ним домены по одному на строку. Строки с # — комментарии."
    : "Один домен на строку; поддомены входят автоматически. Строки с # — комментарии.";
  let bodyText = "";
  if (ed && ed.mode === "text") bodyText = ugView.text;
  else if (sec) {
    const { lines } = domainGroupSections(ugView.text);
    const raw = lines.slice(sec.start + 1, sec.end);
    while (raw.length && !raw[raw.length - 1].trim()) raw.pop();
    bodyText = raw.join("\n");
  }
  box.innerHTML = `
    ${list}
    <div class="btn-row ug-tools">
      <button type="button" class="btn btn-primary" id="ug-new">Новая группа</button>
      <button type="button" class="btn" id="ug-text">Редактировать как текст</button>
    </div>
    <section class="wl-editor ug-editor" id="ug-editor" data-ed="${escapeHtml(edKey)}"${ed ? "" : " hidden"} aria-labelledby="ug-editor-title">
      <h3 id="ug-editor-title">${escapeHtml(title)}</h3>
      <p class="desc">${escapeHtml(hint)}</p>
      ${ed && ed.mode !== "text" ? `<label class="field"><span class="field-label">Имя группы</span>
        <input id="ug-name" type="text" maxlength="48" autocomplete="off" placeholder="Например, Discord" value="${escapeHtml(sec ? sec.name : "")}"></label>` : ""}
      <label class="field"><span class="field-label">${ed && ed.mode === "text" ? "Файл групп" : "Домены"}</span>
        <textarea id="ug-domains" rows="${ed && ed.mode === "text" ? 14 : 8}" spellcheck="false" autocapitalize="off" placeholder="discord.com&#10;discord.media">${escapeHtml(bodyText)}</textarea></label>
      <p class="wl-error" id="ug-error" role="alert" hidden></p>
      <div class="wl-actions">
        <button type="button" class="btn btn-primary" id="ug-save">Сохранить</button>
        <button type="button" class="btn" id="ug-cancel">Отмена</button>
      </div>
    </section>
  `;
  if (typed) {
    const n = document.getElementById("ug-name");
    const d = document.getElementById("ug-domains");
    if (n && typeof typed.name === "string") n.value = typed.name;
    if (d && typeof typed.body === "string") d.value = typed.body;
    if (typed.focus === "ug-name" || typed.focus === "ug-domains") document.getElementById(typed.focus)?.focus();
  }
  const disable = () => box.querySelectorAll("button, input, textarea").forEach(el => { el.disabled = ugBusy; });
  disable();
  box.querySelectorAll(".ug-m-edit").forEach(b => b.addEventListener("click", () => ugOpenEditor("group", Number(b.dataset.ug))));
  box.querySelectorAll(".ug-m-del").forEach(b => b.addEventListener("click", () => ugDelete(Number(b.dataset.ug))));
  const on = (id, fn) => { const el = document.getElementById(id); if (el) el.addEventListener("click", fn); };
  on("ug-new", () => ugOpenEditor("new", -1));
  on("ug-text", () => ugOpenEditor("text", -1));
  on("ug-cancel", () => { ugEdit = null; renderUgManager(); });
  on("ug-save", ugSaveEditor);
}

function plural3(n, one, few, many) {
  const d = n % 10, h = n % 100;
  if (d === 1 && h !== 11) return one;
  if (d >= 2 && d <= 4 && (h < 12 || h > 14)) return few;
  return many;
}

function ugOpenEditor(mode, index) {
  if (!ugView || ugBusy) return;
  ugEdit = { mode, index };
  renderUgManager();
  const focus = document.getElementById(mode === "text" ? "ug-domains" : "ug-name");
  if (focus) focus.focus();
  const ed = document.getElementById("ug-editor");
  if (ed && ed.scrollIntoView) ed.scrollIntoView({ block: "nearest" });
}

function ugShowError(message) {
  const el = document.getElementById("ug-error");
  if (!el) { if (message) toast(message); return; }
  el.textContent = message || "";
  el.hidden = !message;
}

// Запись файла групп. Версию берём ту, от которой человек начал правку: если
// группы успели поменять с другого устройства, сервер ответит 409, и текст в
// редакторе останется на месте — его можно скопировать, а не набирать заново.
async function ugCommit(text, doneMsg, onError = ugShowError) {
  if (!ugView || ugBusy) return false;
  if (new TextEncoder().encode(text).length > 262144) { onError("Группы занимают больше 256 КБ."); return false; }
  ugBusy = true;
  ugGen++;
  renderUgManagerKeep();
  try {
    const saved = await apiPostText("/domain-groups/save?revision=" + encodeURIComponent(ugView.revision), text);
    // Сервер нормализует текст (регистр, повторы), поэтому перечитываем. Но
    // запись уже состоялась: если перечитать не вышло, держим отправленный
    // текст с ВЕРСИЕЙ ИЗ ОТВЕТА — иначе следующая правка ушла бы со старой
    // версией и получила ложный отказ про другое устройство.
    let fresh = null;
    try { fresh = await apiGet("/domain-groups"); } catch (_) { fresh = null; }
    if (fresh && typeof fresh.text === "string") setUgView(fresh.text, fresh.revision);
    else setUgView(text, saved && saved.revision);
    ugEdit = null;
    toast(doneMsg);
    return true;
  } catch (e) {
    onError(errMsg(e));
    return false;
  } finally {
    // Вход в функцию закрыт проверкой ugBusy: вторая запись не начнётся, пока
    // не кончилась эта. Линтер видит «запись после await», но не видит гейта.
    // eslint-disable-next-line require-atomic-updates
    ugBusy = false;
    ugGen++;
    // Успех — перерисовать карточку и таблицу по кэшу: строки /state не
    // менялись, а за ними на роутер ходить секунды. Отказ — оставить
    // редактор как есть, только вернуть кнопки.
    if (!ugEdit) { renderUgManager(); resortState(); }
    else document.querySelectorAll("#ug-body button, #ug-body input, #ug-body textarea").forEach(el => { el.disabled = false; });
  }
}

// Во время записи — заблокировать кнопки, не трогая набранный текст.
function renderUgManagerKeep() {
  document.querySelectorAll("#ug-body button, #ug-body input, #ug-body textarea").forEach(el => { el.disabled = true; });
}

async function ugSaveEditor() {
  const ed = ugEdit;
  if (!ed || !ugView) return;
  const area = document.getElementById("ug-domains");
  const body = area ? area.value : "";
  if (ed.mode === "text") {
    const problem = domainGroupsTextProblem(body);
    if (problem) { ugShowError(problem); return; }
    await ugCommit(body, "Группы сохранены");
    return;
  }
  const nameEl = document.getElementById("ug-name");
  const name = (nameEl ? nameEl.value : "").trim();
  const problem = domainGroupProblem(ugView.sections, ed.mode === "group" ? ed.index : -1, name, body);
  if (problem) { ugShowError(problem); return; }
  const old = ed.mode === "group" ? ugView.sections[ed.index] : null;
  const text = old ? domainGroupsReplace(ugView.text, ed.index, name, body) : domainGroupsAppend(ugView.text, name, body);
  // Переименование не должно сворачивать группу: память о раскрытии — по имени.
  if (await ugCommit(text, old ? "Группа сохранена" : `Группа «${name}» создана`) && old && old.name !== name &&
      stateOpenUgroups.delete(old.name)) {
    stateOpenUgroups.add(name);
    saveOpenUgroups();
  }
}

async function ugDelete(i) {
  const sec = ugView && ugView.sections[i];
  if (!sec || ugBusy) return;
  if (!confirm(`Удалить группу «${sec.name}»?\n\nДомены вернутся в общий список таблицы. Записи стратегий не меняются.`)) return;
  // Память раскрытия — по имени. Забываем её вместе с группой, иначе новая
  // группа с тем же именем рождалась бы развёрнутой.
  if (await ugCommit(domainGroupsReplace(ugView.text, i, "", ""), "Группа удалена") && stateOpenUgroups.delete(sec.name)) {
    saveOpenUgroups();
  }
}

// Панель отмеченного: сколько сайтов, «В группу…», «Снять отметки» и, пока
// задан поиск, «Отметить найденные». Живёт снаружи #state-body, как поле
// поиска: таблица перерисовывается на каждую букву, а панель — только по делу.
function renderUgSelbar() {
  const bar = document.getElementById("ug-selbar");
  if (!bar) return;
  // Отмеченное, что тем временем попало в группу (значком, редактором, с
  // другого устройства), из отметок уходит: у такой строки галочки уже нет, и
  // счётчик показывал бы то, что снять нельзя.
  if (ugView) for (const d of Array.from(ugPicked)) if (matchDomainGroup(ugView.index, d) >= 0) ugPicked.delete(d);
  const query = (document.getElementById("state-search")?.value || "").trim();
  const fresh = ugPickable.filter(d => !ugPicked.has(d));
  if (!ugView || (!ugPicked.size && !(query && fresh.length))) { bar.hidden = true; bar.innerHTML = ""; return; }
  bar.hidden = false;
  bar.innerHTML = `
    <span class="ug-selbar-count" role="status" aria-live="polite">${ugPicked.size
      ? `Отмечено доменов: ${ugPicked.size}` : "Ничего не отмечено"}</span>
    <div class="btn-row">
      ${query && fresh.length ? `<button type="button" class="btn" id="ug-pick-found">Отметить найденные · ${fresh.length}</button>` : ""}
      ${ugPicked.size ? `<button type="button" class="btn btn-primary" id="ug-pick-assign">В группу…</button>
      <button type="button" class="btn" id="ug-pick-clear">Снять отметки</button>` : ""}
    </div>`;
  const on = (id, fn) => { const el = document.getElementById(id); if (el) el.addEventListener("click", fn); };
  on("ug-pick-found", () => { fresh.forEach(d => ugPicked.add(d)); resortState(); });
  on("ug-pick-clear", () => { ugPicked.clear(); resortState(); });
  on("ug-pick-assign", () => ugAssign(Array.from(ugPicked).sort()));
}

// Окно «Добавить в группу». Построено как confirmModal (job.js): подложка,
// ловушка фокуса, Escape и клик мимо окна — отказ. Отмена носит id
// confirm-cancel: по нему навигация закрывает висящее окно штатно, а не
// вырывает его из DOM вместе с несброшенным обработчиком клавиатуры.
function ugAssign(domainOrList) {
  // Массив приходит только из панели отмеченного — и тогда после переноса
  // отметки снимаются, даже если отмечен был один домен.
  const fromPicked = Array.isArray(domainOrList);
  const many = fromPicked && domainOrList.length > 1;
  const list = Array.isArray(domainOrList) ? domainOrList : [domainOrList];
  const domain = list[0] || "";
  if (!ugView || ugBusy || document.querySelector(".modal-backdrop.ug-assign-modal")) return;
  // Открытый редактор группы перерисовался бы после записи и потерял набранное.
  if (ugEdit) { toast("Сначала сохраните или отмените правку в карточке «Группы доменов»"); return; }
  const secs = ugView.sections;
  const prevFocus = document.activeElement;
  const backdrop = document.createElement("div");
  backdrop.className = "modal-backdrop ug-assign-modal";
  backdrop.innerHTML = `
    <div class="modal" role="dialog" aria-modal="true" aria-labelledby="ug-assign-title">
      <h3 id="ug-assign-title">Добавить в группу</h3>
      ${many ? `<label class="field"><span class="field-label">Домены · по одному на строку</span>
        <textarea id="ug-assign-list" class="ug-assign-list" rows="${Math.min(list.length, 8)}" spellcheck="false" autocapitalize="off">${escapeHtml(list.join("\n"))}</textarea></label>
      <p class="desc">Поддомены попадут в группу вместе с ними. Имя общего сервиса
        (nvidia.com, античит) лучше оставить полным, чтобы не забрать в группу чужое.</p>`
      : `<label class="field"><span class="field-label">Домен</span>
        <input id="ug-assign-domain" type="text" autocomplete="off" autocapitalize="off" spellcheck="false" value="${escapeHtml(domain)}"></label>
      <p class="desc">Поддомены попадут в группу вместе с ним.</p>`}
      <label class="field"><span class="field-label">Группа</span>
        <select id="ug-assign-group">
          ${secs.map((s, i) => `<option value="${i}">${escapeHtml(s.name)}</option>`).join("")}
          <option value="-1">Новая группа…</option>
        </select></label>
      <label class="field" id="ug-assign-new"${secs.length ? " hidden" : ""}><span class="field-label">Имя новой группы</span>
        <input id="ug-assign-name" type="text" maxlength="48" autocomplete="off" placeholder="Например, Discord"></label>
      <p class="wl-error" id="ug-assign-error" role="alert" hidden></p>
      <div class="modal-footer">
        <button class="btn btn-primary" id="ug-assign-ok">Добавить</button>
        <button class="btn" id="confirm-cancel">Отмена</button>
      </div>
    </div>`;
  document.body.appendChild(backdrop);
  const q = sel => backdrop.querySelector(sel);
  const groupSel = q("#ug-assign-group");
  if (!secs.length) groupSel.value = "-1";
  const syncNew = () => { q("#ug-assign-new").hidden = groupSel.value !== "-1"; };
  groupSel.addEventListener("change", () => { syncNew(); if (groupSel.value === "-1") q("#ug-assign-name").focus(); });
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    document.removeEventListener("keydown", onKey);
    backdrop.remove();
    if (prevFocus && typeof prevFocus.focus === "function") prevFocus.focus();
  };
  const fail = msg => { const el = q("#ug-assign-error"); el.textContent = msg; el.hidden = !msg; };
  function onKey(e) {
    if (e.key === "Escape") { close(); return; }
    if (e.key === "Enter" && e.target && e.target.tagName === "INPUT") { e.preventDefault(); submit(); return; }
    if (e.key !== "Tab") return;
    const stops = Array.from(backdrop.querySelectorAll("input, select, textarea, button")).filter(el => !el.disabled && !el.closest("[hidden]"));
    if (!stops.length) return;
    const first = e.shiftKey ? stops[stops.length - 1] : stops[0];
    const last = e.shiftKey ? stops[0] : stops[stops.length - 1];
    if (document.activeElement === last || !backdrop.contains(document.activeElement)) { e.preventDefault(); first.focus(); }
  }
  async function submit() {
    const ds = many
      ? Array.from(new Set(q("#ug-assign-list").value.split("\n").map(x => x.trim().toLowerCase()).filter(x => x && x[0] !== "#")))
      : [q("#ug-assign-domain").value.trim().toLowerCase()];
    if (!ds.length || !ds[0]) { fail("Укажите хотя бы один домен."); return; }
    const idx = Number(groupSel.value);
    const sec = idx >= 0 ? ugView.sections[idx] : null;
    const name = sec ? sec.name : q("#ug-assign-name").value.trim();
    const problem = domainGroupProblem(ugView.sections, sec ? idx : -1, name,
      (sec ? sec.domains.join("\n") + "\n" : "") + ds.join("\n"));
    if (problem) { fail(problem); return; }
    q("#ug-assign-ok").disabled = true;
    let why = "";
    // Одна запись на всё отмеченное: десять сайтов — одна версия файла и
    // одно «сохранено», а не десять гонок за compare-and-swap.
    const text = ds.reduce((t, d) => domainGroupsAdd(t, name, d), ugView.text);
    const ok = await ugCommit(text, ds.length > 1 ? `В «${name}» добавлено доменов: ${ds.length}` : `${ds[0]} → «${name}»`,
                              m => { why = m; });
    if (closed) return;
    if (ok) { if (fromPicked) { ugPicked.clear(); renderUgSelbar(); } close(); }
    else { q("#ug-assign-ok").disabled = false; fail(why || "Не удалось сохранить группы."); }
  }
  q("#ug-assign-ok").addEventListener("click", submit);
  q("#confirm-cancel").addEventListener("click", close);
  backdrop.addEventListener("click", e => { if (e.target === backdrop) close(); });
  document.addEventListener("keydown", onKey);
  (secs.length ? groupSel : q("#ug-assign-name")).focus();
}

async function stateDelete(key, host) {
  const _h = String(host).replace(/\|4$/, " (IPv4)").replace(/\|6$/, " (IPv6)");
  if (!confirm(`Удалить запись для ${_h} (${key})?\n\nПодбор начнётся с первой стратегии при следующей попытке.`)) return;
  try {
    await apiPost("/state/delete", { key, host });
    toast("Удалено");
    loadState();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}

async function stateClearAll() {
  if (!confirm("Удалить все записи?\n\nКаждый домен начнёт подбор с первой стратегии при следующей попытке, заморозки тоже снимутся. Сервис перезапускать не нужно.")) return;
  try {
    await apiPost("/state/clear", {});
    toast("Весь state очищен");
    loadState();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}

// Pin / manually select a rotator row's strategy. mode=auto → adopt live and
// keep rotating; mode=frozen → adopt AND stop the rotator changing it. The
// engine adopts the edit within ~2s (reconcile) and persists it across
// reboot/auto-update.
async function stateSet(key, host, strategy, mode) {
  try {
    await apiPost("/state/set", { key, host, strategy: String(strategy), mode });
    toast(mode === "frozen" ? `Заморожено на стратегии ${strategy}` : `Стратегия ${strategy} выбрана`);
    loadState();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}
