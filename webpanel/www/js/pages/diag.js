import { apiGet, apiGetText, apiPost, errHtml, errMsg, setUnauthorizedHandler, toastErr } from "../core/api.js";
import { showLoginScreen } from "../core/auth.js";
import { copyToClipboard } from "../core/clipboard.js";
import { $app, escapeHtml, skeletonLines } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";

// ЭКРАН ВХОДА.
//
// Показывается не «когда мы решили», а когда бекенд прислал needauth: только
// он знает, включён ли пароль и жива ли сессия. Страница про это не гадает.
//
// Экран заменяет собой всё, а не всплывает поверх: под ним нет ничего, что
// человек мог бы сделать без входа, и полупрозрачная модалка над пустым
// интерфейсом только создавала бы вид, будто данные уже загружены.
// Признак «форма уже на экране» — ПРОВЕРКА DOM, а не переменная.
//
// С булевой переменной форма исчезала навсегда: она ставилась один раз, а
// роутер страницы при любой смене адреса безусловно затирает $app. После
// первого же перехода по меню человек оставался с пустыми скелетонами и без
// единого поля для пароля — то самое состояние, из которого нет выхода.
// DOM врать не может: нет поля — рисуем заново.
// Регистрация рядом с самим экраном, а не в общем запуске: при выносе входа
// в отдельный файл связка обязана уехать вместе с ним, иначе транспорт
// молча останется с пустым обработчиком и форма перестанет появляться.
setUnauthorizedHandler((msg) => showLoginScreen(msg));

// ПРОВЕРКА ДОМЕНА — аналог пункта [Y] терминального меню.
//
// Отчёт приходит текстом от z2k-detect. Разбираем его на поля и рисуем
// стадиями, а не вываливаем как есть: человеку нужно увидеть, ГДЕ оборвалось,
// а не читать четыре строки подряд. Полный текст остаётся под спойлером —
// его пересылают в чат, и он должен быть дословным.
//
// Формат вывода наш собственный и закреплён тестом; если он поедет, разбор
// отдаст пустые стадии, а текст покажется целиком — деградация мягкая.
function parseProbeReport(text) {
  const out = { stages: [], ips: "", code: "", reason: "", verdict: "", advice: "", latency: "" };
  for (const line of String(text || "").split("\n")) {
    let m;
    if ((m = line.match(/^Probe:\s+(.*?)\s+\((\d+)ms\)/))) {
      out.latency = m[2];
      for (const part of m[1].trim().split(/\s+/)) {
        const kv = part.split("=");
        if (kv.length === 2) out.stages.push({ name: kv[0], state: kv[1] });
      }
    } else if ((m = line.match(/^IPs:\s+(.*)$/)))     out.ips = m[1].trim();
    else if ((m = line.match(/^Code:\s+(.*)$/)))      out.code = m[1].trim();
    else if ((m = line.match(/^Reason:\s+(.*)$/)))    out.reason = m[1].trim();
    else if ((m = line.match(/^Verdict:\s+(.*)$/)))   out.verdict = m[1].trim();
    else if (out.verdict && /^\s+→/.test(line))       out.advice += (out.advice ? " " : "") + line.trim().replace(/^→\s*/, "");
  }
  return out;
}

// «HOT» и «IGNORE» — внутренние ярлыки классификатора. Человеку они не
// говорят ничего, а цвет плашки передаёт ровно то же самое. В полном отчёте
// ниже они остаются дословно: его пересылают в чат, и там ярлык нужен.
function verdictText(v) {
  const t = String(v).replace(/^(HOT|IGNORE|WARM|COLD)\s*—\s*/, "").trim();
  return t ? t.charAt(0).toUpperCase() + t.slice(1) : v;
}

function renderProbeReport(text) {
  const r = parseProbeReport(text);
  // Вердикт красим по смыслу: HOT — блокируют, это ожидаемо и не «ошибка
  // панели»; всё остальное значит, что до DPI дело не дошло.
  const hot = /^HOT/.test(r.verdict);
  const chips = r.stages.map(st => {
    const cls = st.state === "ok" ? "good" : (st.state === "skip" ? "muted" : "bad");
    return `<span class="probe-stage ${cls}">${escapeHtml(st.name)}<b>${escapeHtml(st.state)}</b></span>`;
  }).join("");
  return `
    <div class="probe-report">
      <div class="probe-stages">${chips}${r.latency ? `<span class="probe-lat">${escapeHtml(r.latency)} мс</span>` : ""}</div>
      ${r.ips ? `<div class="probe-line"><span>Адреса</span><code>${escapeHtml(r.ips)}</code></div>` : ""}
      ${r.reason ? `<div class="probe-line"><span>Причина</span><code>${escapeHtml(r.reason)}</code></div>` : ""}
      ${r.verdict ? `<div class="probe-verdict ${hot ? "hot" : "calm"}">${escapeHtml(verdictText(r.verdict))}</div>` : ""}
      ${r.advice ? `<p class="desc">${escapeHtml(r.advice)}</p>` : ""}
      <details class="probe-raw">
        <summary>Полный отчёт</summary>
        <pre class="log">${escapeHtml(text)}</pre>
      </details>
    </div>`;
}

function wireDomainProbe() {
  const input = document.getElementById("probe-domain");
  const btn = document.getElementById("probe-run");
  const box = document.getElementById("probe-result");
  if (!input || !btn || !box) return;

  const run = async () => {
    const domain = input.value.trim().replace(/^https?:\/\//i, "").replace(/\/.*$/, "");
    if (!domain) { input.focus(); return; }
    btn.disabled = true;
    const label = btn.textContent;
    btn.textContent = "Проверяю…";
    box.innerHTML = `<div class="probe-report"><span class="skel-text">${skeletonLines(3)}</span></div>`;
    try {
      const d = await apiPost("/diag/probe", { domain: domain });
      box.innerHTML = renderProbeReport(d.report || "");
    } catch (e) {
      // Причину показываем как есть: её пишет бекенд человеческим текстом
      // (недопустимые символы, модуль не установлен, не уложились в 20 с).
      box.innerHTML = `<div class="probe-report"><div class="probe-verdict hot">${errHtml(e)}</div></div>`;
    }
    btn.disabled = false;
    btn.textContent = label;
  };

  btn.addEventListener("click", run);
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); run(); } });
}

export async function renderDiag() {
  $app.innerHTML = `
    <h1 class="page-title">Диагностика</h1>

    <!-- Проверка домена стоит ПЕРВОЙ, до общей сводки, и это не про красоту.
         Сюда приходят с вопросом «почему не открывается вот этот сайт», а не
         «покажите снимок системы». Сводка — для пересылки в чат, проверка —
         для ответа здесь и сейчас. -->
    <div class="card">
      <h3>Проверка домена</h3>
      <p class="desc">
        Одна проба конкретного адреса мимо обхода: видно, на какой стадии всё
        обрывается — имя не резолвится, соединение не устанавливается, TLS
        рвут, — и блокирует ли его DPI. Ничего не меняет и никуда не
        записывает.
      </p>
      <div class="probe-row">
        <input type="text" id="probe-domain" placeholder="например, rutracker.org"
               autocomplete="off" autocapitalize="none" spellcheck="false">
        <button class="btn btn-primary" id="probe-run">Проверить</button>
      </div>
      <div id="probe-result"></div>
    </div>

    <div class="card">
      <h3>Сводка z2k-diag</h3>
      <p class="desc">
        Снимок всего, что мы обычно спрашиваем при траблшутинге: что именно не
        так, версия, архитектура, сервис, iptables, состояние диска и памяти,
        модули прошивки, резолв, туннель, выбранные стратегии и ошибки из всех
        логов. Когда что-то не работает — пришли это в чат проекта.
        <b>«Скачать файл»</b> даёт полный отчёт с логами: его отправляют
        вложением, потому что в одно сообщение он не помещается.
      </p>
      <div class="btn-row" style="margin-bottom:10px">
        <button class="btn" id="diag-refresh">Обновить</button>
        <button class="btn" id="diag-copy">Копировать</button>
        <button class="btn btn-primary" id="diag-download">Скачать файл</button>
      </div>
      <pre class="log" id="diag-output"><span class="skel-text">${skeletonLines(10)}</span></pre>
    </div>
  `;
  document.getElementById("diag-refresh").addEventListener("click", loadDiag);
  document.getElementById("diag-copy").addEventListener("click", () => {
    copyToClipboard(document.getElementById("diag-output").textContent);
  });
  document.getElementById("diag-download").addEventListener("click", diagDownload);
  wireDomainProbe();
  loadDiag();
}

// Fetched rather than linked: a plain <a href> is a navigation and cannot
// carry X-Z2K-Panel, so on a browser too old for Sec-Fetch-Site the download
// would come back 403. Same blob trick as warpExport.
async function diagDownload(ev) {
  const btn = ev.currentTarget;
  const label = btn.textContent;
  btn.disabled = true;
  btn.textContent = "Готовим…";
  try {
    const text = await apiGetText("/diag/download");
    const stamp = new Date().toISOString().slice(0, 16).replace(/[-:]/g, "").replace("T", "-");
    const blob = new Blob([text], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `z2k-diag-${stamp}.txt`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (e) {
    toastErr("Не удалось скачать отчёт: ", e);
  } finally {
    btn.disabled = false;
    btn.textContent = label;
  }
}

async function loadDiag() {
  const el = document.getElementById("diag-output");
  if (!el) return;
  const seq = _newLoad("diag");
  el.innerHTML = `<span class="skel-text">${skeletonLines(10)}</span>`;
  try {
    const d = await apiGet("/diag");
    if (_stale("diag", seq)) return;
    el.textContent = d.diag || "(пусто)";
  } catch (e) {
    if (_stale("diag", seq)) return;
    el.textContent = "Ошибка: " + errMsg(e);
  }
}
