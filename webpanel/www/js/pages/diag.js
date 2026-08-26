import { apiGet, apiGetText, apiPost, apiPostText, errHtml, errMsg, setUnauthorizedHandler, toastErr } from "../core/api.js";
import { showLoginScreen } from "../core/auth.js";
import { copyToClipboard } from "../core/clipboard.js";
import { $app, escapeHtml, skeletonLines } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { JOB_FAIL, awaitPanelBack, jobOutcome, jobUnresolved, openJobModal, unresolvedMsg } from "../job.js";
import { toast } from "../core/toast.js";

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

    <!-- Проверка DNS идёт следом за проверкой домена: оба отвечают на «почему
         не открывается», только эта — про слой имён. Сводка ниже, она для
         пересылки в чат, а не для чтения здесь. -->
    <div class="card">
      <div class="row-between">
        <div>
          <h3>Проверка DNS</h3>
          <p class="desc">
            Проверяем три пути к каждому серверу: <b>обычный DNS</b> (порт 53,
            без шифрования), <b>DoH</b> (внутри HTTPS) и <b>DoT</b> (внутри TLS,
            порт 853). Быстрый
            ответ ещё не значит правдивый: перехваченный запрос возвращается
            быстрее всех, потому что отвечает не тот, кого спросили. Ничего не
            меняет, занимает около минуты.
          </p>
        </div>
        <button class="btn btn-primary" id="dns-run">Проверить</button>
      </div>
      <div id="dns-result"></div>
      <div class="dns-own">
        <label for="dns-own-text">Свои серверы</label>
        <textarea id="dns-own-text" spellcheck="false" autocapitalize="none"
                  placeholder="1.1.1.2&#10;https://dns.example.org/dns-query"></textarea>
        <p class="desc" style="margin:6px 0 10px">
          По одному в строке: адрес для обычного DNS или ссылка для DoH.
          Проверяются вместе с остальными.
        </p>
        <button class="btn" id="dns-own-save">Сохранить</button>
      </div>
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
  document.getElementById("dns-run").addEventListener("click", dnsRun);
  document.getElementById("dns-own-save").addEventListener("click", dnsOwnSave);
  loadDnsLast();

  document.getElementById("diag-refresh").addEventListener("click", loadDiag);
  document.getElementById("diag-copy").addEventListener("click", () => {
    // Пока на месте скелет, копировать нечего: кнопка отдавала пустую строку и
    // рапортовала «Скопировано». Человек вставлял пустоту в чат поддержки и был
    // уверен, что отправил отчёт.
    const out = document.getElementById("diag-output");
    if (out.querySelector(".skel-text") || !out.textContent.trim()) return;
    copyToClipboard(out.textContent);
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


// ---- проверка DNS -----------------------------------------------------------
//
// Раскладка «сначала вывод»: крупная строка о том, что происходит, под ней три
// группы — работают / подменяют / молчат. Человек приходит сюда с вопросом
// «что мне делать», а не «покажи таблицу»; цифры доступны, но не первыми.

// ГРУППИРУЕМ ПО ПУТИ, А НЕ ПО СЕРВЕРУ.
//
// Сначала группы были «доходят целыми / ответы подменяются», то есть про
// сервер, а состояние в строке — про путь. Quad9 с подменённым обычным ответом
// и целым DoH попадал в «доходят целыми», и заголовок спорил с собственным
// содержимым: «доходят целыми» напротив «ответ подменён».
//
// Спорить нечему, когда группа и строка говорят об одном. Путь — это и есть
// то, что проверяется и что человек меняет: обычный DNS отравлен, шифрованный
// цел, и вывод «включите DoH» читается прямо из структуры, а не из сносок.

const DNS_STATE = {
  works: { cls: "good", label: "честно" },
  spoof: { cls: "bad", label: "ответ подменён" },
  silent: { cls: "warn", label: "не ответил" },
};

function dnsPathGroup(title, sub, list, openIt) {
  if (!list.length) return "";
  const bad = list.filter(x => x.state === "spoof").length;
  const mute = list.filter(x => x.state === "silent").length;
  const ok = list.filter(x => x.state === "works").length;

  // Состояние группы — по её содержимому: если целых нет вовсе, путь мёртв.
  const cls = ok === 0 ? (bad ? "bad" : "warn") : bad ? "bad" : "good";
  const tally = [
    ok ? `${ok} целых` : "",
    bad ? `${bad} подменено` : "",
    mute ? `${mute} без ответа` : "",
  ].filter(Boolean).join(" · ");

  const rows = list.map(x => {
    const st = DNS_STATE[x.state] || DNS_STATE.silent;
    const ms = x.ms != null ? ` <span class="dns-metric">${x.ms} мс</span>` : "";
    const tag = x.current ? ` <span class="dns-cur">используется сейчас</span>` : "";
    // Отдельная пометка: сервер жив и честен, но адреса для ютуба не даёт.
    // Снаружи это выглядит как «интернет есть, а видео не открывается», и по
    // состоянию пути такое не видно — путь-то в порядке.
    const yt = x.yt === "empty" ? ` <span class="dns-yt">нет адреса для youtube.com</span>` : "";
    return `<li>
      <span>${escapeHtml(x.name)}${tag}${yt}</span>
      <span class="dns-state dns-${st.cls}">${st.label}${ms}</span>
    </li>`;
  }).join("");

  return `
    <details class="dns-group"${openIt ? " open" : ""}>
      <summary>
        <span class="dns-path">${escapeHtml(title)}</span>
        <span class="dns-count">${escapeHtml(sub)}</span>
        <span class="dns-tally dns-${cls}">${escapeHtml(tally)}</span>
      </summary>
      <ul>${rows}</ul>
    </details>`;
}

function renderDnsResult(d) {
  const host = document.getElementById("dns-result");
  if (!host) return;
  if (!d) {
    host.innerHTML = `<p class="desc" style="margin-top:12px">Проверка ещё не запускалась.</p>`;
    return;
  }
  const srv = d.servers || [];
  // У обычного DNS время появилось: его печатает dig, если он установлен
  // (пакет bind-dig, ставится отдельно). Нет dig — приходит null, и строка
  // выглядит как раньше, без числа. Своими руками UDP-запрос с роутера не
  // послать, а время nslookup врёт на порядок: он делает обратный запрос на
  // каждый адрес ответа.
  const plain = srv.filter(s => s.udp !== "none").map(s => ({ name: s.name, state: s.udp, ms: s.udp_ms, current: s.current, yt: s.yt }));
  const doh = srv.filter(s => s.doh !== "none").map(s => ({ name: s.name, state: s.doh, ms: s.doh_ms, current: s.current, yt: s.yt }));
  // У DoT время ЕСТЬ: счётчик опросов с шагом 10 мс меряет полный обмен —
  // TCP, TLS и сам запрос. Раньше здесь стоял null, потому что я счёл
  // измерение невозможным; невозможен был только посекундный опрос.
  const dot = srv.filter(s => s.dot !== "none").map(s => ({ name: s.name, state: s.dot, ms: s.dot_ms, current: s.current, yt: s.yt }));

  // Сводного блока здесь БОЛЬШЕ НЕТ, и это снятие, а не пропажа.
  //
  // Он повторял то, что и так стоит в заголовках групп: сколько путей целы,
  // сколько подменено. Свой резолвер помечен прямо в строке, ютуб — ярлыком у
  // имени. Единственный факт, которого больше нигде не было, — адрес заглушки;
  // он переехал в подпись группы обычного DNS, где и объясняет её состояние.
  const stubNote = d.stub ? `порт 53, без шифрования · заглушка ${escapeHtml(d.stub)}` : "порт 53, без шифрования";
  host.innerHTML = `
    ${dnsPathGroup("Обычный DNS", stubNote, plain, false)}
    ${dnsPathGroup("Шифрованный DoH", "запрос внутри HTTPS", doh, false)}
    ${dnsPathGroup("Шифрованный DoT", "запрос внутри TLS, порт 853", dot, false)}`;
}

async function loadDnsLast() {
  const seq = _newLoad("dnsCheck");
  let d;
  try {
    d = await apiGet("/dns/check");
  } catch (e) {
    return;
  }
  if (_stale("dnsCheck", seq)) return;
  const ta = document.getElementById("dns-own-text");
  if (ta && typeof d.own === "string") ta.value = d.own;
  renderDnsResult(d.result);
}

async function dnsRun() {
  const btn = document.getElementById("dns-run");
  btn.disabled = true;
  let resp;
  try {
    resp = await apiPost("/dns/check", {});
  } catch (e) {
    btn.disabled = false;
    toastErr("Не удалось запустить проверку: ", e);
    return;
  }
  openJobModal("Проверяю серверы имён", resp.job, {
    onDone: (d) => {
      btn.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) toast("Проверка не прошла — причина в логе выше", "bad");
      else if (jobUnresolved(outcome)) {
        const m = unresolvedMsg(outcome);
        if (m) toast(m, "bad");
        awaitPanelBack().then(() => loadDnsLast());
        return;
      }
      loadDnsLast();
    },
  });
}

async function dnsOwnSave() {
  const btn = document.getElementById("dns-own-save");
  const ta = document.getElementById("dns-own-text");
  btn.disabled = true;
  try {
    const r = await apiPostText("/dns/own", ta.value);
    toast("Сохранено");
    if (r && r.saved) {
      const dropped = /dropped=(\d+)/.exec(r.saved);
      if (dropped && dropped[1] !== "0") toast(`Строк отброшено: ${dropped[1]} — не адрес и не ссылка`, "bad");
    }
  } catch (e) {
    toastErr("Не сохранилось: ", e);
  } finally {
    btn.disabled = false;
  }
}
