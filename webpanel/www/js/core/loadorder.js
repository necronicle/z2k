import { apiGet, errHtml } from "./api.js";
import { $app, escapeHtml, statusIcon } from "./dom.js";

// mod_cgi обслуживает запросы ПАРАЛЛЕЛЬНО, и ответы приходят не в том
// порядке, в каком уходили: /state на роутере занимает ~2.4 с, и ответ,
// ушедший первым, приходит последним. Без этого счётчика более старый
// снимок дорисовывался поверх свежего — удалённая строка «воскресала»
// сразу после тоста «Удалено», а кэш оставался отравленным. Рисует только
// тот вызов загрузчика, который стартовал последним.
const _loadSeq = {};

export function _newLoad(name) { _loadSeq[name] = (_loadSeq[name] || 0) + 1; return _loadSeq[name]; }

export function _stale(name, seq) { return _loadSeq[name] !== seq; }

export async function refreshStatus() {
  const grid = document.getElementById("status-grid");
  if (!grid) return;
  const seq = _newLoad("status");
  try {
    const s = await apiGet("/status");
    if (_stale("status", seq)) return;
    renderStatusGrid(s);
  } catch (e) {
    if (_stale("status", seq)) return;
    // ОТКАЗ ЧТЕНИЯ — НЕ ПОВОД ОСТАВИТЬ ЧЕЛОВЕКА БЕЗ ДЕЙСТВИЙ.
    //
    // Здесь рисовалась одна ячейка со словом «Ошибка», а syncServiceButtons
    // в этой ветке не вызывался вовсе — то есть при неизвестном состоянии
    // оставались видны все три кнопки сразу, и «Запустить» уходило на роутер
    // посреди переустановки. Вдобавок для 404/502/503/504 сообщение
    // намеренно пустое (в этот момент отвечает lighttpd, а не наш CGI) —
    // человек видел «Ошибка» и пустоту. Автоповтора у страницы нет: сюда
    // попадали на всё время обновления и до перезагрузки вкладки.
    //
    // Правка была сделана в r-75.7 и потерялась при возврате прежней
    // раскладки — она к раскладке отношения не имеет.
    const why = errHtml(e);
    grid.innerHTML =
      '<div class="status-cell warn">' +
        '<div class="label">Состояние роутера</div>' +
        '<div class="value">Не удалось прочитать</div>' +
      '</div>' +
      '<p class="desc" id="status-why">' + why + '</p>' +
      '<div class="btn-row"><button class="btn" id="status-retry" type="button">Повторить</button></div>';
    const retry = document.getElementById("status-retry");
    if (retry) retry.addEventListener("click", () => {
      retry.disabled = true;
      retry.textContent = "Читаю…";
      refreshStatus();
    });
    // Кнопки сервиса не прячем: когда отвалился именно CGI состояния,
    // «Перезапустить» — ровно то, что помогает. Вердикт при этом честный.
    syncServiceButtons(undefined);
  }
}

function renderStatusGrid(s) {
  const grid = document.getElementById("status-grid");
  if (!grid) return;
  const cells = [
    { label: "Установлен", value: s.installed ? "Да" : "Нет", kind: s.installed ? "good" : "bad" },
    { label: "Сервис", value: fmtSvc(s.service), kind: s.service === "active" ? "good" : (s.service === "stopped" ? "warn" : "bad") },
    { label: "Туннель ТГ", value: s.tunnel?.running ? "работает" : "остановлен", kind: s.tunnel?.running ? "good" : "warn" },
    { label: "RST фильтр", value: rstIsOn(s.toggles.rst_filter) ? (rstIsAggressive(s.toggles.rst_filter) ? "Вкл (агрессивный)" : "Вкл") : "Выкл", kind: rstIsOn(s.toggles.rst_filter) ? "good" : "" },
    { label: "Silent fallback", value: bool(s.toggles.silent_fallback), kind: s.toggles.silent_fallback === "1" ? "warn" : "" },
    { label: "WARP", value: bool(s.toggles.game_warp), kind: s.toggles.game_warp === "1" ? "good" : "" },
    { label: "Автообновление", value: bool(s.toggles.auto_update), kind: s.toggles.auto_update === "1" ? "good" : "warn" },
    { label: "custom.d", value: bool(s.toggles.customd), kind: "" },
  ];
  grid.innerHTML = cells.map(c => {
    const icon = statusIcon(c.kind);
    return `<div class="status-cell ${c.kind}"><div class="label">${c.label}</div><div class="value">${icon ? `<span class="status-ico">${icon}</span>` : ""}${escapeHtml(c.value)}</div></div>`;
  }).join("");
  syncServiceButtons(s.service);
}

// Скрываем / показываем service-кнопки по реальному состоянию:
// active        → «Перезапустить» + «Остановить»; «Запустить» скрыта
// stopped       → только «Запустить»
// not_installed → все три скрыты (нечего управлять)
//
// Используем style.display а не hidden attribute, потому что
// `.btn { display: inline-block }` переопределяет [hidden] {display:none}
// по специфичности (one-class > attribute).
function syncServiceButtons(svc) {
  const startBtn   = $app.querySelector('[data-svc="start"]');
  const restartBtn = $app.querySelector('[data-svc="restart"]');
  const stopBtn    = $app.querySelector('[data-svc="stop"]');
  if (!startBtn || !restartBtn || !stopBtn) return;
  const show = (el, on) => { el.style.display = on ? "" : "none"; };
  if (svc === "active") {
    show(startBtn, false);
    show(restartBtn, true);
    show(stopBtn, true);
  } else if (svc === "stopped") {
    show(startBtn, true);
    show(restartBtn, false);
    show(stopBtn, false);
  } else {
    show(startBtn, false);
    show(restartBtn, false);
    show(stopBtn, false);
  }
}

function bool(v) { return v === "1" ? "Вкл" : "Выкл"; }

// RST filter is a plain on/off switch in the panel, but the CLI menu can also
// set "aggressive" (a narrow-TTL ON mode). Both values mean ENABLED — the panel
// must not render "Выкл" for aggressive. Mirrors lib/menu.sh RST_FILTER matching
// (1|on|true|yes|aggressive|agg|aggro).
export function rstIsOn(v) { v = String(v || "").toLowerCase(); return v === "1" || v === "on" || v === "true" || v === "yes" || v === "aggressive" || v === "agg" || v === "aggro"; }

function rstIsAggressive(v) { v = String(v || "").toLowerCase(); return v === "aggressive" || v === "agg" || v === "aggro"; }

function fmtSvc(s) {
  return { active: "работает", stopped: "остановлен", not_installed: "не установлен" }[s] || s;
}
