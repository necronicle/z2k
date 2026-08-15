import { openSortSheet } from "../chrome.js";
import { apiGet, apiPost, errHtml, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, skeletonLines } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { STATE_SORT_LABELS, saveStateSort, setStatePools, statePools, stateSort } from "../state-model.js";

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

export async function renderState() {
  $app.innerHTML = strategiesShell("live", `
    <div class="card">
      <h3>Discord, голосовые каналы</h3>
      <p class="desc">
        Голосовой пул Discord не привязан к домену, поэтому в таблице ниже его
        нет: там показано то, что уже происходило, а здесь стратегию можно
        выбрать заранее — до первого звонка. Её так же можно заморозить, чтобы
        не менялась.
      </p>
      <div class="btn-row" id="discord-voice-controls">${skeletonLines(1)}</div>
    </div>
    <div class="card">
      <h3>Выбранные стратегии по доменам</h3>
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
        <li><b>× слева</b> — удалить запись (старт с первой стратегии).</li>
      </ul>
      <p class="desc">
        Пул, которому вы задали <a href="#/strategies">свою стратегию</a>, здесь
        не появится: подбор для него выключен, а работает ровно ваша строка.
      </p>
      <div class="btn-row" style="margin-bottom:10px">
        <button class="btn" id="state-refresh">Обновить</button>
        <button class="btn btn-danger" id="state-clear-all">Удалить все записи</button>
      </div>
      <div id="state-body">${skeletonLines(6)}</div>
    </div>
  `);
  // Wrapped, NOT passed directly: an event handler receives the Event object as
  // its first argument, which would land in useCache — truthy — and turn the
  // «Обновить» button into a no-op that re-renders stale rows.
  document.getElementById("state-refresh").addEventListener("click", () => loadState());
  document.getElementById("state-clear-all").addEventListener("click", stateClearAll);
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

// Запрос, который ещё в полёте. Новый вызов его отменяет: /state стоит
// ~2.4 с шелл-CGI на роутере, и два параллельных прогона соревнуются за
// тот же CPU ради ответа, который всё равно будет отброшен.
let _stateAbort = null;

// Re-render with the rows already in hand. Falls back to a real load if the
// cache is empty (first paint, or an error cleared it).
function resortState() { return loadState(true); }

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
    renderDiscordVoicePanel(entries);

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
    const visible = entries.filter(e => e.host !== "nohost");

    if (!visible.length) {
      body.innerHTML = `<p style="color:var(--text-muted)">пока пусто — ни одна стратегия ещё не закреплена</p>`;
      return;
    }
    const nowSec = Math.floor(Date.now() / 1000);
    // Sort a shallow copy — never mutate the cached server response.
    const sorted = visible.slice().sort((a, b) => {
      let av, bv;
      switch (stateSort.key) {
        case "key":      av = String(a.key  || ""); bv = String(b.key  || ""); break;
        case "host":     av = String(a.host || ""); bv = String(b.host || ""); break;
        case "strategy": av = Number(a.strategy) || 0; bv = Number(b.strategy) || 0; break;
        // 'age' sorts by age value (= now - ts). Asc → freshest first
        // (small age), which matches what we'd want by default when
        // a user clicks «Возраст» — "what's been moving recently".
        case "age":      av = nowSec - (Number(a.ts) || 0); bv = nowSec - (Number(b.ts) || 0); break;
        default:         return 0;
      }
      if (av < bv) return stateSort.dir === "asc" ? -1 : 1;
      if (av > bv) return stateSort.dir === "asc" ?  1 : -1;
      return 0;
    });

    const rows = sorted.map(e => {
      const age = nowSec - Number(e.ts || 0);
      const ageStr = age < 60 ? age + "с" :
                     age < 3600 ? Math.floor(age / 60) + "м" :
                     age < 86400 ? Math.floor(age / 3600) + "ч" :
                     Math.floor(age / 86400) + "д";
      const frozen = e.mode === "frozen";
      // Pool size from the live nfqws2 cmdline; fall back to the row's own
      // strategy so a stale/larger pinned value still appears in the dropdown.
      const N = Math.max(Number(statePools[e.key] || 0), Number(e.strategy) || 1);
      let opts = "";
      for (let i = 1; i <= N; i++) {
        opts += `<option value="${i}"${i === Number(e.strategy) ? " selected" : ""}>${i}</option>`;
      }
      // data-host в атрибутах остаётся СЫРЫМ ключом: это идентификатор
      // записи для API, его резать нельзя. Делим только видимое человеку.
      const _hf = splitFamily(e.host);
      // data-label attrs feed the mobile card layout (CSS pseudo-elements)
      return `
        <tr${frozen ? ' style="background:rgba(120,140,255,0.10)"' : ''}>
          <td data-label="">
            <button class="btn btn-danger btn-icon state-del"
                    title="Удалить запись"
                    aria-label="Удалить ${escapeHtml(_hf.name)}${_hf.fam ? ", " + _hf.fam : ""}"
                    data-key="${escapeHtml(e.key)}"
                    data-host="${escapeHtml(e.host)}">${_icons.close}</button>
          </td>
          <td data-label="Профиль">${escapeHtml(e.key)}</td>
          <td data-label="Домен">${escapeHtml(_hf.name)}${_hf.fam ? ` <span class="fam-tag">${_hf.fam}</span>` : ""}</td>
          <td data-label="Стратегия">
            <select class="state-strat-sel"
                    data-key="${escapeHtml(e.key)}"
                    data-host="${escapeHtml(e.host)}"
                    data-mode="${frozen ? "frozen" : "auto"}">${opts}</select>
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
    }).join("");

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
      <table class="state-table">
        <thead>
          <tr><th></th>${th("key","Профиль")}${th("host","Домен")}${th("strategy","Стратегия")}<th>Заморозка</th>${th("age","Возраст")}</tr>
        </thead>
        <tbody>${rows}</tbody>
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
    body.innerHTML = `<p style="color:var(--bad)">${errHtml(e)}</p>`;
  }
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
