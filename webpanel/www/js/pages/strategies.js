import { openSortSheet } from "../chrome.js";
import { apiGet, apiPost, apiPostText, errHtml, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, skeletonLines } from "../core/dom.js";
import { JOB_FAIL, confirmModal, jobOutcome, jobUnresolved, openJobModal, unresolvedMsg } from "../job.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { STATE_SORT_LABELS, groupDomain, saveOpenGroups, saveStateSort, setStatePools, stateOpenGroups, statePools, stateSort } from "../state-model.js";

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
    <section class="card unique-set-card" aria-labelledby="unique-set-title">
      <div class="unique-set-topline"><span class="unique-set-badge">ЭКСПЕРИМЕНТАЛЬНО!!!</span></div>
      <h3 id="unique-set-title">Уникальный набор стратегий</h3>
      <p class="desc">Стратегии будут подобраны и применены специально для вашего провайдера.</p>
      <div class="btn-row">
        <button class="btn btn-primary" id="unique-set-start" type="button">Создать уникальный набор</button>
        <button class="btn btn-danger" id="unique-set-reset-all" type="button">Вернуть все категории к автоматике</button>
      </div>
      <p class="desc unique-set-status" id="unique-set-status" role="status" aria-live="polite"></p>
    </section>
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
    <div class="card">
      <h3>Стратегии по доменам</h3>
      <details class="state-help"><summary>Как управлять?</summary>
      <p class="desc">
        Для каждого домена z2k запоминает стратегию, которая на нём заработала.
        В каждой строке:
      </p>
      <ul class="desc" style="margin:4px 0 10px 18px;padding:0">
        <li><b>выпадающий список</b> — выбрать стратегию вручную (подбор
            продолжится с неё, удобно проскочить нерабочую);</li>
        <li><b>замок в столбце «Заморозка»</b> — открытый замок значит идёт
            автоподбор; нажмите, чтобы заморозить (замок закроется) и стратегия
            перестанет меняться; нажмите закрытый замок — разморозить;</li>
        <li><b>× слева</b> — удалить запись (старт с первой стратегии);</li>
        <li><b>домен со стрелкой</b> — записи его поддоменов собраны вместе;
            нажмите, чтобы раскрыть или свернуть.</li>
      </ul>
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
          <button class="btn" id="state-refresh">Обновить</button>
          <button class="btn btn-danger" id="state-clear-all">Удалить все записи</button>
        </div>
      </div>
      <div id="state-body">${skeletonLines(6)}</div>
    </div>
  `);
  // Wrapped, NOT passed directly: an event handler receives the Event object as
  // its first argument, which would land in useCache — truthy — and turn the
  // «Обновить» button into a no-op that re-renders stale rows.
  document.getElementById("state-refresh").addEventListener("click", () => loadState());
  document.getElementById("state-clear-all").addEventListener("click", stateClearAll);
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
  initUniqueStrategySet();
  loadState();
}

const UNIQUE_SET_POOLS = ["yt_tcp", "gv_tcp", "quic", "rkn_tcp"];

function initUniqueStrategySet() {
  const btn = document.getElementById("unique-set-start");
  const resetBtn = document.getElementById("unique-set-reset-all");
  if (btn) btn.addEventListener("click", () => startUniqueStrategySet(btn));
  if (resetBtn) resetBtn.addEventListener("click", () => resetAllStrategyPools(resetBtn));
  loadUniqueStrategySetResult();
}

function formatUniqueSetDuration(value) {
  const total = Number(value);
  if (!Number.isFinite(total) || total < 0) return "";
  const seconds = Math.floor(total);
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const remainder = seconds % 60;
  if (hours) return `${hours} ч ${minutes} мин`;
  if (minutes) return `${minutes} мин ${remainder} с`;
  return `${remainder} с`;
}

async function loadUniqueStrategySetResult() {
  const status = document.getElementById("unique-set-status");
  if (!status) return;
  try {
    const response = await apiGet("/strategy/unique-set");
    const result = response && response.result;
    const duration = result && result.ok && formatUniqueSetDuration(result.elapsed_seconds);
    if (duration && !status.textContent.trim()) status.textContent = `Последний подбор занял ${duration}.`;
  } catch (_) {
    // A missing prior result is normal on first use; it must not disturb the page.
  }
}

async function startUniqueStrategySet(btn) {
  const status = document.getElementById("unique-set-status");
  const resetBtn = document.getElementById("unique-set-reset-all");
  btn.disabled = true;
  if (resetBtn) resetBtn.disabled = true;
  try {
    const poolsData = await apiGet("/strategy/pools");
    const custom = (poolsData.pools || []).filter(p => UNIQUE_SET_POOLS.includes(p.pool) && p.custom);
    if (custom.length) {
      const names = custom.map(p => p.pool).join(", ");
      const accepted = await confirmModal(
        "Заменить свои стратегии?",
        `Будут заменены пользовательские пулы: ${names}. Набор задаёт стратегию каждому пулу целиком, а не только тестовым доменам. Продолжить?`,
        "Продолжить",
        "Отмена",
      );
      if (!accepted) { btn.disabled = false; if (resetBtn) resetBtn.disabled = false; return; }
    }
    if (status) status.textContent = "Запускаю последовательные замеры. Прогресс будет в журнале задачи.";
    const response = await apiPost("/strategy/unique-set", {});
    const startedAt = Date.now();
    openJobModal("Создание уникального набора стратегий", response.job, {
      onDone: async data => {
        btn.disabled = false;
        if (resetBtn) resetBtn.disabled = false;
        const clientDuration = formatUniqueSetDuration((Date.now() - startedAt) / 1000);
        const outcome = jobOutcome(data);
        if (jobUnresolved(outcome)) {
          const message = unresolvedMsg(outcome);
          if (message) toast(message, "bad");
          if (status) status.textContent = "Исход задачи не удалось подтвердить; проверь журнал.";
          return;
        }
        if (outcome === JOB_FAIL) {
          if (status) status.textContent = `Набор не применён. Подбор занял ${clientDuration}. Причина указана в журнале задачи.`;
          return;
        }
        let duration = clientDuration;
        try {
          const saved = await apiGet("/strategy/unique-set");
          const savedDuration = saved && saved.result && saved.result.ok
            ? formatUniqueSetDuration(saved.result.elapsed_seconds) : "";
          if (savedDuration) duration = savedDuration;
        } catch (_) {}
        if (status) status.textContent = `Набор применён. Подбор занял ${duration}.`;
      },
    });
  } catch (error) {
    btn.disabled = false;
    if (resetBtn) resetBtn.disabled = false;
    if (status) status.textContent = "Не удалось запустить набор.";
    toastErr("Не удалось запустить набор: ", error);
  }
}

async function resetAllStrategyPools(btn) {
  const status = document.getElementById("unique-set-status");
  const startBtn = document.getElementById("unique-set-start");
  const accepted = await confirmModal(
    "Вернуть все категории к автоматике?",
    "Будут удалены все пользовательские стратегии во всех категориях, включая Discord. Затем z2k пересоберёт конфиг и перезапустит сервис один раз.",
    "Вернуть автоматику",
    "Отмена",
  );
  if (!accepted) return;

  btn.disabled = true;
  if (startBtn) startBtn.disabled = true;
  if (status) status.textContent = "Возвращаю все категории к автоматике…";
  try {
    await apiPost("/strategy/pools/reset-all", {});
    if (status) status.textContent = "Все категории возвращены к автоматике.";
  } catch (error) {
    if (status) status.textContent = "Не удалось вернуть автоматику. Проверьте сообщение об ошибке.";
    toastErr("Не удалось вернуть автоматику: ", error);
  } finally {
    btn.disabled = false;
    if (startBtn) startBtn.disabled = false;
  }
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
      const [d, poolsResp] = await Promise.all([
        apiGet("/state", { signal }),
        apiGet("/pools", { signal }).catch(() => ({ pools: {} })),
      ]);
      // Ответ более старого вызова, обогнавший свежий, не должен ни
      // рисовать таблицу, ни отравлять stateCache: иначе только что
      // удалённая строка «воскресала» сразу после тоста «Удалено», а
      // последующие пересортировки шли уже по мусорному кэшу.
      if (_stale("state", seq)) return;
      setStatePools(poolsResp && poolsResp.pools);
      entries = d.entries || [];
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
    const all = entries.filter(e => e.host !== "nohost");

    const counter = document.getElementById("state-search-count");
    if (!all.length) {
      if (counter) counter.textContent = "Записей: 0";
      body.innerHTML = `<p style="color:var(--text-muted)">пока пусто — ни одна стратегия ещё не закреплена</p>`;
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
    const visible = query
      ? all.filter(e => splitFamily(e.host).name.toLowerCase().includes(query))
      : all;
    if (counter) counter.textContent = query
      ? `Найдено записей: ${visible.length} из ${all.length}`
      : `Записей: ${all.length}`;
    // Поле очистили — сессия поиска кончилась, ручные сворачивания внутри неё
    // забываются, и таблица возвращается к тому, что помнит stateOpenGroups.
    if (!query) searchCollapsed = new Set();

    if (!visible.length) {
      body.innerHTML = `<p style="color:var(--text-muted)">Ничего не найдено. Измените поисковый запрос.</p>`;
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
      return [e, { name: hf.name, fam: hf.fam, group: dom,
                   gkey: String(e.key || "") + GKEY_SEP + dom }];
    }));
    // Sort a shallow copy — never mutate the cached server response.
    const sorted = visible.slice().sort((a, b) => {
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
        // 'age' sorts by age value (= now - ts). Asc → freshest first
        // (small age), which matches what we'd want by default when
        // a user clicks «Возраст» — "what's been moving recently".
        case "age":      av = nowSec - (Number(a.ts) || 0); bv = nowSec - (Number(b.ts) || 0); break;
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

    const fmtAge = (age) => age < 60 ? age + "с" :
                            age < 3600 ? Math.floor(age / 60) + "м" :
                            age < 86400 ? Math.floor(age / 3600) + "ч" :
                            Math.floor(age / 86400) + "д";

    const rowHtml = (e, inGroup) => {
      const m = meta.get(e);
      const ageStr = fmtAge(nowSec - Number(e.ts || 0));
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
          <td data-label="Домен" class="state-host${inGroup ? " sg-leaf" : ""}">${nameHtml}${m.fam ? ` <span class="fam-tag">${m.fam}</span>` : ""}</td>
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

    // Группа встаёт туда, где в текущей сортировке оказалась её первая строка,
    // и внутри держит тот же порядок. Так сортировка по возрасту поднимает
    // наверх группу со свежей записью, а по стратегии — группу, где подбор
    // ушёл дальше всех, и сводка в заголовке говорит ровно об этой строке.
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

    const groupHtml = (b) => {
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
      const freshest = Math.min(...b.rows.map(e => nowSec - Number(e.ts || 0)));
      const countText = `${n} ${plural(n, "запись", "записи", "записей")}`;
      // ВО ВРЕМЯ ПОИСКА В ГРУППЕ ВИДНЫ ТОЛЬКО СОВПАВШИЕ СТРОКИ, и пакетные
      // кнопки действуют ровно на них — они забирают строки из нарисованного
      // tbody. Значит слова обязаны это признавать: «вся группа» над тремя
      // строками из ста — неправда, а кнопка рядом необратима. Сужаем не
      // действие (сужать его незачем: человек видит, что жмёт), а подпись.
      const whole = !query;
      return `
        <tbody class="sg${open ? "" : " sg-closed"}" data-group="${escapeHtml(b.gkey)}">
          <tr class="sg-head">
            <td data-label="" class="sg-lead">
              <button class="btn btn-danger btn-icon sg-reset"
                      title="Сбросить подбор ${whole ? "для всей группы" : "для найденных в группе"} (${escapeHtml(String(n))} ${escapeHtml(plural(n, "записи", "записей", "записей"))})"
                      aria-label="Сбросить подбор ${whole ? "для группы" : "для найденных в группе"} ${escapeHtml(b.group)}"
                      data-gkey="${escapeHtml(b.gkey)}">${_icons.close}</button>
            </td>
            <td data-label="Профиль">${escapeHtml(keys.join(", "))}</td>
            <td data-label="Домен" class="sg-title">
              <button type="button" class="sg-toggle" aria-expanded="${open}"
                      data-count="${escapeHtml(countText)}"
                      title="${open ? "Свернуть" : "Раскрыть"}: ${escapeHtml(countText)}">
                ${_icons.chevronDown}<span class="sg-name">${escapeHtml(b.group)}</span><span class="sg-count" aria-label="${escapeHtml(countText)}">${n}</span>
              </button>
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
            <td data-label="Возраст" class="state-age">${fmtAge(freshest)}</td>
          </tr>
          ${b.rows.map(e => rowHtml(e, true)).join("")}
        </tbody>
      `;
    };

    // Заголовок получает только группа из РАЗНЫХ имён. chatgpt.com|4 и
    // chatgpt.com|6 — один сайт в двух семействах адресов, сворачивать там
    // нечего, а заголовок над парой одинаковых строк только прибавил бы шума.
    // Одиночные строки подряд собираются в общий tbody.
    let html = "";
    let loose = "";
    for (const b of blocks) {
      if (b.names.size >= 2) {
        if (loose) { html += `<tbody>${loose}</tbody>`; loose = ""; }
        html += groupHtml(b);
      } else {
        loose += b.rows.map(e => rowHtml(e, false)).join("");
      }
    }
    if (loose) html += `<tbody>${loose}</tbody>`;

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
      <table class="state-table${blocks.some(b => b.names.size >= 2) ? " sg-any" : ""}">
        <thead>
          <tr><th></th>${th("key","Профиль")}${th("host","Домен")}${th("strategy","Стратегия")}<th>Заморозка</th>${th("age","Возраст")}</tr>
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
