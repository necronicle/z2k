import { apiGet, apiGetText, apiPost, apiPostText, errHtml, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, humanAgo, skeletonBlocks, skeletonLines, statusIcon } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { JOB_FAIL, _updateGlobalUILock, awaitPanelBack, foreignJobsActive, jobOutcome, jobUnresolved, openJobModal, setLockAware, trackJob, unresolvedMsg } from "../job.js";

// Раздел «WARP»: туннель Cloudflare WARP на нашем движке z2k-warpd
// (WireGuard, при полном UDP-блоке — MASQUE по TCP 443). Три действия —
// Установить / тумблер / Удалить: без намерения юзера на роутере нет ни
// движка, ни демона. Что идёт в туннель: адреса из списков (игровые +
// свои) и целые устройства по IP/MAC. Всё — файлы в /opt/zapret2/lists/warp/.
let _warpLists = [];

// Транспорт туннеля: автомат или выбор вручную. Порядок — от умолчания к
// частным случаям. Подсказка говорит, чем выбор обернётся на плохой линии:
// ради этого выбор и делают.
const WARP_MODES = [
  { id: "auto", label: "Автоматически",
    hint: "Сначала WireGuard, если его режут — MASQUE через TCP 443. На MASQUE раз в 10 минут проверяется, не заработал ли WireGuard снова." },
  { id: "wg", label: "WireGuard",
    hint: "Только WireGuard, на MASQUE не переключается. Если провайдер режет WireGuard, туннель не поднимется." },
  { id: "h2", label: "MASQUE",
    hint: "Только MASQUE через TCP 443. Трафик идёт поверх TCP, поэтому на линии с потерями он медленнее WireGuard." },
];
let _warpMode = "auto";

// Текущее действие с туннелем (включение, выключение, смена транспорта).
// Новое нажатие не ждёт старое: сервер прерывает предыдущее (код 3), а панель
// просто перестаёт слушать его итог — владеет состоянием последнее нажатие.
let _warpJob = null;
let _warpJobTitle = "";
let _warpReqs = 0;          // запросы, ещё не получившие id задачи
let _warpPoll = null;       // перечитывание статуса, пока действие идёт

function warpReqBegin() { _warpReqs++; }
function warpReqEnd() { _warpReqs = Math.max(0, _warpReqs - 1); }
function warpActing() { return !!_warpJob || _warpReqs > 0; }

// Последняя содержательная строка лога задачи — для тоста о неудаче: модалки
// с логом у этих действий нет, а причина нужна сразу. Рамки и отметки
// времени обёртки задачи (svc_action_async) пропускаются.
function jobReason(d) {
  const lines = String((d && d.log) || "").split("\n").map(l => l.trim())
    .filter(l => l && !/^─+$/.test(l) && !/^\[\d\d:\d\d:\d\d\]/.test(l));
  return lines.length ? lines[lines.length - 1].replace(/^\[z2k-warp\]\s*/, "") : "причина в логе задачи";
}

function warpPendingUI() {
  const el = document.getElementById("warp-pending");
  if (el) {
    el.hidden = !_warpJob;
    if (_warpJob) {
      // Подсказка — ровно о том, что стало можно: не ждать, а перебить.
      el.innerHTML = `<span class="status-ico">${_icons.hourglass}</span>${escapeHtml(_warpJobTitle)}… ` +
        "Если зависло — выключите тумблер или выберите другой транспорт, это прервёт текущее действие.";
    }
  }
  clearInterval(_warpPoll);
  _warpPoll = null;
  if (_warpJob) {
    _warpPoll = setInterval(() => {
      if (!document.getElementById("warp-status-grid")) { clearInterval(_warpPoll); _warpPoll = null; return; }
      loadWarpStatus();
    }, 3000);
  }
}

// Запуск действия без модалки. onFinal зовётся только для ПОСЛЕДНЕГО
// действия: итог перебитого никого не интересует, и откатывать по нему
// тумблер значило бы отменить нажатие, которое его перебило.
function warpTrack(title, jobId, onFinal) {
  _warpJob = jobId;
  _warpJobTitle = title;
  warpPendingUI();
  trackJob(title, jobId, {
    lockGroup: "warp",
    onDone: (d) => {
      if (_warpJob !== jobId) return;
      _warpJob = null;
      warpPendingUI();
      const outcome = jobOutcome(d);
      if (jobUnresolved(outcome)) {
        const m = unresolvedMsg(outcome);
        if (m) toast(m, "bad");
        awaitPanelBack().then(() => loadWarpStatus());
        return;
      }
      // Код 3 у последнего действия — его перебили из другой вкладки или с
      // другого устройства. Сказать нечего, состояние перечитаем.
      if (!(d && d.exit === 3)) onFinal(outcome, d);
      loadWarpStatus();
    },
  });
}

// Коды last_error движка → текст. Движок пишет код, панель — смысл.
const WARP_ERRORS = {
  register_blocked: "Cloudflare не отвечает на регистрацию — ни напрямую, ни через релей. Попробуйте позже.",
  device_revoked: "Cloudflare отозвал устройство — регистрирую заново.",
  no_endpoint: "Ни один адрес Cloudflare не отвечает — провайдер блокирует WARP целиком.",
  tun_failed: "Прошивка не даёт создать туннельный интерфейс.",
  no_transit:
    "Туннель встаёт, но не возит трафик — перебираю адреса Cloudflare. " +
    "Игровой трафик пока идёт напрямую.",
};

function warpNameValid(n) {
  return /^[A-Za-z0-9._-]{1,64}$/.test(n) && !/^[.-]/.test(n);
}

// «1 адрес, 2 адреса, 5 адресов» — а не скобочная форма.
function plural(n, one, few, many) {
  n = Math.abs(Number(n) || 0);
  const m10 = n % 10, m100 = n % 100;
  if (m10 === 1 && m100 !== 11) return `${n} ${one}`;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return `${n} ${few}`;
  return `${n} ${many}`;
}
const addrs = n => plural(n, "адрес", "адреса", "адресов");
const warpEntries = n => plural(n, "запись", "записи", "записей");
const warpDomains = n => plural(n, "домен", "домена", "доменов");

function fmtSize(b) {
  b = Number(b) || 0;
  if (b < 1024) return b + " Б";
  if (b < 1048576) return Math.round(b / 1024) + " КБ";
  return (b / 1048576).toFixed(1) + " МБ";
}

export async function renderWarp() {
  $app.innerHTML = `
    <h1 class="page-title">WARP</h1>
    <div class="card" data-lock-group="warp">
      <div class="toggle-row" data-key="game_warp">
        <div class="t-text">
          <div class="t-name">WARP-туннель</div>
          <div class="t-desc">Туннель Cloudflare для игр и сервисов, заблокированных по IP.
            В него идут адреса из списков ниже и выбранные устройства; остальной трафик — напрямую.</div>
        </div>
        <label class="switch" id="warp-switch" hidden>
          <input type="checkbox" disabled>
          <span class="slider"></span>
        </label>
      </div>
      <p class="desc warp-pending" id="warp-pending" role="status" hidden></p>
      <div class="status-grid" id="warp-status-grid" hidden></div>
      <div class="warp-transport" id="warp-transport" hidden>
        <div class="t-name" id="warp-transport-label">Выбор транспорта</div>
        <div class="segmented" id="warp-transport-seg" role="radiogroup" aria-labelledby="warp-transport-label">
          ${WARP_MODES.map(m => `<button type="button" class="seg-btn" data-mode="${m.id}" role="radio" aria-checked="false">${m.label}</button>`).join("")}
        </div>
        <p class="desc" id="warp-transport-hint"></p>
      </div>
      <div class="warp-plus" id="warp-plus" hidden>
        <label class="t-name" for="warp-plus-key">Ключ WARP+</label>
        <p class="desc" id="warp-plus-state"></p>
        <div class="warp-plus-row">
          <input type="password" id="warp-plus-key" autocomplete="off" autocapitalize="off"
                 spellcheck="false" maxlength="64" placeholder="xxxxxxxx-xxxxxxxx-xxxxxxxx">
          <button class="btn" id="warp-plus-apply">Применить ключ</button>
        </div>
        <p class="desc">Свой ключ из приложения 1.1.1.1 (Account → Key). Роутер станет одним
          из устройств вашего аккаунта — у аккаунта их не больше пяти.</p>
      </div>
      <div class="btn-row" id="warp-actions" style="margin-top:12px;align-items:center;flex-wrap:wrap" hidden>
        <button class="btn btn-primary" id="warp-install-btn" hidden>Установить WARP</button>
        <span class="desc" id="warp-install-note" style="margin:0" hidden>~7 МБ; регистрирует устройство у Cloudflare. Ничего не запускается, пока не включите тумблер.</span>
        <button class="btn btn-danger" id="warp-remove-btn" hidden>Удалить WARP</button>
        <button class="btn btn-danger" id="warp-rereg-btn" hidden>Перерегистрировать устройство</button>
      </div>
    </div>
    <div class="card">
      <h3>Игровые списки</h3>
      <p class="desc">
        Готовые списки доменов и адресов по играм и сервисам из
        <a href="https://github.com/YOZH3G/ru-gaming-blocklist" target="_blank" rel="noopener noreferrer">YOZH3G/ru-gaming-blocklist</a>,
        обновляются автоматически.
        <b>По умолчанию не включён ни один</b> — включайте только то, что вам нужно:
        чем меньше направлений в туннеле, тем меньше на него завязано. Списки только для
        чтения; свои домены и адреса добавляйте ниже, отдельным списком.
      </p>
      <div id="warp-games" class="warp-games">${skeletonBlocks(3)}</div>
      <div class="warp-own" id="warp-own" hidden>
        <h4 class="warp-own-title">Свои списки</h4>
        <div id="warp-own-list" class="warp-games"></div>
      </div>
    </div>
    <div class="card" id="warp-devices-card" hidden>
      <h3>Устройства</h3>
      <p class="desc">Включите устройство — и весь его трафик пойдёт через WARP, независимо от
        списков. Удобно для консоли или телефона. <b>Применяется сразу.</b></p>
      <div id="warp-neighbors" class="warp-games">${skeletonBlocks(2)}</div>
      <details class="disclosure warp-manual">
        <summary>Вручную: IP или MAC по строке</summary>
        <p class="desc">Для устройств, которых нет в списке выше: <code>192.168.1.50</code> или
          <code>aa:bb:cc:dd:ee:ff</code>. Переключатели выше пишут сюда же.</p>
        <textarea id="warp-devices" class="warp-editor warp-devices" spellcheck="false"
                  autocomplete="off" autocapitalize="off" autocorrect="off"
                  placeholder="192.168.1.50"></textarea>
        <div class="btn-row" style="margin-top:10px">
          <button class="btn btn-primary" id="warp-devices-save">Сохранить</button>
        </div>
      </details>
    </div>
    <div class="card">
      <h3>Списки адресов и доменов</h3>
      <p class="desc">
        Каждый список — текстовый файл: один IPv4-адрес, CIDR-подсеть или домен на строку
        (<code>8.8.8.8</code>, <code>8.8.8.0/24</code>, <code>example.com</code> или
        <code>*.example.com</code>; строки с <code>#</code> — комментарии).
        <code>*.example.com</code> охватывает поддомены, но не сам <code>example.com</code>.
        Через WARP идёт трафик к адресам из включённых списков;
        включают и выключают их тумблеры в карточке выше.
        <b>Изменения применяются сразу</b>, без перезапуска, и переживают переустановку z2k.
      </p>
      <p class="desc">Для доменов устройство должно получать обычные DNS-ответы через DNS роутера
        или через роутер. DoH/DoT и IPv6 здесь не перехватываются; международные имена вводите
        в ASCII/Punycode. Если несколько сайтов делят один IP, другое соединение этого же
        устройства к нему тоже может пройти через WARP.</p>
      <p class="desc" id="warp-domain-state"></p>
      <div class="btn-row" style="margin-bottom:10px">
        <button class="btn btn-primary" id="warp-new-btn">Новый список</button>
        <button class="btn" id="warp-import-btn" title="Загрузить список адресов и доменов из текстового файла">Импорт из txt</button>
        <input type="file" id="warp-import-file" accept=".txt,text/plain" hidden>
      </div>
      <ul class="wl-list" id="warp-lists">${skeletonLines(3)}</ul>
    </div>
    <div class="card" id="warp-editor-card" hidden>
      <h3 id="warp-editor-title"></h3>
      <p class="desc">Один IPv4-адрес, подсеть или домен на строку. IPv6 и невалидные строки
        отбрасываются; после сохранения покажем их количество.</p>
      <textarea id="warp-editor" class="warp-editor" spellcheck="false"
                autocomplete="off" autocapitalize="off" autocorrect="off"
                placeholder="203.0.113.0/24"></textarea>
      <div class="btn-row" style="margin-top:10px">
        <button class="btn btn-primary" id="warp-editor-save">Сохранить</button>
        <button class="btn" id="warp-editor-cancel">Отмена</button>
      </div>
    </div>
  `;
  const box = $app.querySelector('[data-key="game_warp"] input');
  box.addEventListener("change", () => warpToggle(box));
  document.getElementById("warp-install-btn").addEventListener("click", warpInstall);
  document.getElementById("warp-remove-btn").addEventListener("click", warpRemove);
  document.getElementById("warp-rereg-btn").addEventListener("click", warpReregister);
  document.getElementById("warp-plus-apply").addEventListener("click", warpLicenseApply);
  document.getElementById("warp-plus-key").addEventListener("keydown", (e) => {
    if (e.key === "Enter") warpLicenseApply();
  });
  document.getElementById("warp-transport-seg").addEventListener("click", (e) => {
    const btn = e.target.closest(".seg-btn");
    if (btn) warpTransportPick(btn.dataset.mode);
  });
  document.getElementById("warp-devices-save").addEventListener("click", warpDevicesSave);
  document.getElementById("warp-new-btn").addEventListener("click", warpNewList);
  document.getElementById("warp-import-btn").addEventListener("click", () => {
    document.getElementById("warp-import-file").click();
  });
  document.getElementById("warp-import-file").addEventListener("change", warpImport);
  document.getElementById("warp-editor-save").addEventListener("click", warpEditorSave);
  document.getElementById("warp-editor-cancel").addEventListener("click", () => {
    document.getElementById("warp-editor-card").hidden = true;
  });
  loadWarpStatus();
  loadWarpGames();
  loadWarpLists();
  loadWarpNeighbors();
  loadWarpDevices();
  _updateGlobalUILock();
}

// Устройства в сети — из Keenetic (имя, которое дали роутеру, иначе hostname).
// Тумблер пишет MAC в devices.txt; остальное там не трогается.
async function loadWarpNeighbors() {
  const host = document.getElementById("warp-neighbors");
  if (!host) return;
  const seq = _newLoad("warpNeighbors");
  let d;
  try {
    d = await apiGet("/warp/neighbors");
  } catch (e) {
    if (_stale("warpNeighbors", seq)) return;
    host.innerHTML = `<p class="desc">Не удалось получить список устройств: ${errHtml(e)}</p>`;
    return;
  }
  if (_stale("warpNeighbors", seq)) return;
  const devs = (d && d.devices) || [];
  if (!devs.length) {
    host.innerHTML = `<p class="desc">Роутер не отдал список устройств — добавьте вручную ниже.</p>`;
    return;
  }
  const row = x => `
    <div class="toggle-row" data-mac="${escapeHtml(x.mac)}">
      <div class="t-text">
        <div class="t-name" title="${escapeHtml(x.mac)}">${escapeHtml(x.label)}</div>
        <div class="t-desc">${escapeHtml(x.ip || "—")}${x.net ? " · " + escapeHtml(x.net) : ""}</div>
      </div>
      <label class="switch">
        <input type="checkbox" ${x.on ? "checked" : ""}>
        <span class="slider"></span>
      </label>
    </div>`;
  // Онлайн — сразу; не в сети (обычно десятки старых записей) — под
  // раскрывашкой, но включённые показываем всегда: человек должен видеть,
  // что его выключенная консоль уже настроена.
  const online = devs.filter(x => x.active || x.on);
  const offline = devs.filter(x => !x.active && !x.on);
  host.innerHTML = online.map(row).join("") + (offline.length ? `
    <details class="disclosure warp-offline">
      <summary>Не в сети: ${offline.length}</summary>
      <div class="warp-games">${offline.map(row).join("")}</div>
    </details>` : "");
  host.querySelectorAll("[data-mac] input").forEach(box => {
    box.addEventListener("change", () => warpNeighborToggle(box));
  });
}

async function warpNeighborToggle(box) {
  const row = box.closest("[data-mac]");
  const mac = row.dataset.mac;
  const wanted = box.checked ? "1" : "0";
  box.disabled = true;
  try {
    await apiPost("/warp/devices/toggle", { mac, value: wanted });
    toast(wanted === "1" ? `${row.querySelector(".t-name").textContent} — через WARP` : `${row.querySelector(".t-name").textContent} — напрямую`);
    loadWarpDevices();
    loadWarpStatus();
  } catch (e) {
    box.checked = !box.checked;
    toastErr("Не сохранилось: ", e);
  } finally {
    box.disabled = false;
  }
}

// Upstream per-game lists: switches only. They are refreshed wholesale from
// upstream, so editing them here would be undone by the next refresh.
async function loadWarpGames() {
  const host = document.getElementById("warp-games");
  if (!host) return;
  const seq = _newLoad("warpGames");
  let d;
  try {
    d = await apiGet("/warp/games");
  } catch (e) {
    if (_stale("warpGames", seq)) return;
    host.innerHTML = `<p class="desc">Не удалось загрузить: ${errHtml(e)}</p>`;
    return;
  }
  if (_stale("warpGames", seq)) return;
  const games = (d && d.games) || [];
  if (!games.length) {
    // Lists are pulled during the update itself, so being here means that
    // fetch did not get through — not that the user has to wait a day.
    host.innerHTML = `<p class="desc">Списки не загрузились — источник был недоступен.
      Они подтянутся при следующем обновлении списков; свои адреса можно добавить
      ниже уже сейчас.</p>`;
    return;
  }
  const on = games.filter(g => g.enabled === 1 || g.enabled === "1").length;
  host.innerHTML = `
    <p class="desc" id="warp-games-summary">${on === 0
      ? "Не включён ни один игровой список."
      : `Включено игровых списков: ${on} из ${games.length}.`}</p>
    ${games.map(g => `
      <div class="toggle-row" data-game="${escapeHtml(g.name)}">
        <div class="t-text">
          <div class="t-name" title="${escapeHtml(g.name)}">${escapeHtml(g.name.replace(/_/g, " "))}</div>
          <div class="t-desc">${warpEntries(g.entries)}</div>
        </div>
        <label class="switch">
          <input type="checkbox" ${(g.enabled === 1 || g.enabled === "1") ? "checked" : ""}>
          <span class="slider"></span>
        </label>
      </div>`).join("")}`;
  host.querySelectorAll("[data-game] input").forEach(box => {
    box.addEventListener("change", () => warpGameToggle(box));
  });
}

async function warpGameToggle(box) {
  const row = box.closest("[data-game]");
  const name = row.getAttribute("data-game");
  const wanted = box.checked ? "1" : "0";
  box.disabled = true;
  try {
    await apiPost("/warp/games/toggle", { name: name, value: wanted });
  } catch (e) {
    box.checked = !box.checked;   // revert: the server did not accept it
    toastErr("Ошибка: ", e);
    box.disabled = false;
    return;
  }
  box.disabled = false;
  toast(wanted === "1" ? `${name} включён` : `${name} выключен`);
  loadWarpGames();
}

async function loadWarpStatus() {
  const grid = document.getElementById("warp-status-grid");
  if (!grid) return;
  const seq = _newLoad("warpStatus");
  let d;
  try {
    d = await apiGet("/warp/status");
  } catch (e) {
    if (_stale("warpStatus", seq)) return;
    grid.innerHTML = `<div class="status-cell bad"><div class="label">Ошибка</div><div class="value">${errHtml(e)}</div></div>`;
    return;
  }
  if (_stale("warpStatus", seq)) return;
  const enabled = d.enabled === "1";
  const installed = !!d.installed;
  const domainState = document.getElementById("warp-domain-state");
  if (domainState) {
    domainState.textContent = !enabled ? "Доменные правила выключены вместе с WARP."
      : d.domain_active ? `Доменные правила: ${Number(d.domain_rules) || 0}; активных пар устройство/IP: ${Number(d.domain_pairs) || 0}.`
      : "Доменные правила сейчас недоступны; адреса и устройства продолжают работать.";
  }

  // Три состояния раздела — из одного ответа. Не установлен: одна кнопка, без
  // тумблера и статуса (нечего показывать). Установлен: тумблер + статус +
  // «Удалить». Списки и устройства видны всегда — это данные юзера.
  const sw = document.getElementById("warp-switch");
  const actions = document.getElementById("warp-actions");
  const installBtn = document.getElementById("warp-install-btn");
  const installNote = document.getElementById("warp-install-note");
  const removeBtn = document.getElementById("warp-remove-btn");
  sw.hidden = !installed;
  grid.hidden = !installed;
  actions.hidden = false;
  installBtn.hidden = installed;
  installNote.hidden = installed;
  removeBtn.hidden = !installed;
  // Перерегистрация имеет смысл только когда устройство есть.
  //
  // ПРЕДУПРЕЖДЕНИЕ ЖИВЁТ В ОКНЕ ПОДТВЕРЖДЕНИЯ, А НЕ СБОКУ ОТ КНОПКИ. Строка
  // рядом стояла в одном ряду с «Удалить WARP», и ряд читался как сплошной
  // запрет: три опасных элемента подряд, к какому относится текст — неясно.
  // Текст, объясняющий цену действия, нужен ровно в момент нажатия, и там он
  // и стоит.
  const reregBtn = document.getElementById("warp-rereg-btn");
  if (reregBtn) reregBtn.hidden = !installed;
  document.getElementById("warp-devices-card").hidden = false;

  const box = $app.querySelector('[data-key="game_warp"] input');
  // ПОКА ДЕЙСТВИЕ ИДЁТ, ТУМБЛЕР И ВЫБОР ТРАНСПОРТА ПОКАЗЫВАЮТ НАЖАТОЕ, А НЕ
  // КОНФИГ. Статус перечитывается каждые три секунды, а флаг в конфиге
  // меняется не сразу: выключение пишет его последним шагом. Синхронизация
  // «всегда» возвращала тумблер во «вкл» через секунду после того, как его
  // выключили, — ровно в тот момент, когда им прерывают зависшее включение.
  if (box) {
    if (!warpActing()) box.checked = enabled;
    // Под чужой задачей тумблер заперт замком — правим его запомненное
    // состояние, а не .disabled напрямую (иначе снятие замка вернёт старое).
    setLockAware(box, false);
  }

  const transportBox = document.getElementById("warp-transport");
  if (transportBox) transportBox.hidden = !installed;
  const plusBox = document.getElementById("warp-plus");
  if (plusBox) plusBox.hidden = !installed;
  const plusState = document.getElementById("warp-plus-state");
  if (plusState) plusState.textContent = warpPlanText(d);
  if (!warpActing()) {
    _warpMode = WARP_MODES.some(m => m.id === d.transport_mode) ? d.transport_mode : "auto";
    setWarpMode(_warpMode);
  }

  if (!installed) {
    grid.innerHTML = "";
    return;
  }
  // Туннель — три состояния. ready = движок доказал, что трафик ходит
  // (handshake + счётчики + при сомнении сквозная проба), а не «интерфейс
  // есть». При включённом режиме и не-ready показываем причину кодом → текст.
  let tunnelValue, tunnelKind;
  if (d.ready) {
    tunnelValue = "работает" + (d.addr ? " · " + d.addr : "");
    tunnelKind = "good";
  } else if (!enabled) {
    tunnelValue = "выключен";
    tunnelKind = "";
  } else if (d.error === "no_endpoint" && _warpMode !== "auto") {
    // Выбран один транспорт — и молчит именно он. «Провайдер блокирует WARP
    // целиком» здесь было бы неправдой: второй транспорт никто не пробовал.
    tunnelValue = "На выбранном транспорте ни один адрес Cloudflare не отвечает — попробуйте «Автоматически».";
    tunnelKind = "bad";
  } else if (d.error) {
    tunnelValue = WARP_ERRORS[d.error] || d.error;
    tunnelKind = "bad";
  } else {
    tunnelValue = "поднимается";
    tunnelKind = "";
  }
  const transport = d.transport === "wg" ? "WireGuard" : d.transport === "h2" ? "MASQUE (TCP 443)" : "—";
  // Две ячейки, не четыре: счётчики адресов и устройств и так видны в своих
  // карточках ниже, а пустые «—» только раздували шапку.
  const cells = [
    { label: "Туннель", value: tunnelValue, kind: tunnelKind },
    { label: "Транспорт", value: d.ready ? transport + (d.endpoint ? " · " + d.endpoint : "") : "—",
      kind: d.ready ? "good" : "" },
  ];
  if (d.ready && d.transport === "wg") {
    const edge = [d.edge_colo, d.edge_country].filter(Boolean).join(" · ");
    const rtt = Number(d.edge_rtt_ms) > 0 ? `${Math.round(Number(d.edge_rtt_ms))} мс` : "";
    cells.push({ label: "Узел Cloudflare", value: [edge || "география не определена", rtt].filter(Boolean).join(" · "), kind: edge ? "good" : "" });
  }
  // Память движка — только пока он запущен. Растёт с трафиком, не со списком;
  // после правки буферов норма 20–40 МБ. Выше 96 МБ — предупреждение: на
  // роутере с 512 МБ движок убивало ровно на этой отметке (замер 2026-09-02).
  const memKb = Number(d.mem_kb) || 0;
  if (memKb > 0) {
    cells.push({ label: "Память движка", value: Math.round(memKb / 1024) + " МБ", kind: memKb > 96 * 1024 ? "warn" : "" });
  }
  grid.innerHTML = cells.map(c => {
    const icon = statusIcon(c.kind);
    return `<div class="status-cell ${c.kind}"><div class="label">${c.label}</div><div class="value">${icon ? `<span class="status-ico">${icon}</span>` : ""}${escapeHtml(c.value)}</div></div>`;
  }).join("");
}

function setWarpMode(mode) {
  const seg = document.getElementById("warp-transport-seg");
  if (!seg) return;
  seg.querySelectorAll(".seg-btn").forEach(b => {
    const on = b.dataset.mode === mode;
    b.classList.toggle("seg-on", on);
    b.setAttribute("aria-checked", String(on));
  });
  const hint = document.getElementById("warp-transport-hint");
  const m = WARP_MODES.find(x => x.id === mode);
  if (hint && m) hint.textContent = m.hint;
}

// Смена транспорта у включённого WARP перезапускает движок — задача без
// модалки, со значком в углу; туннель на секунды пропадает. У выключенного
// сохраняется только выбор, ждать нечего. Нажатие во время идущего действия
// его прерывает (см. warpTrack).
async function warpTransportPick(mode) {
  if (!WARP_MODES.some(m => m.id === mode) || mode === _warpMode) return;
  if (foreignJobsActive("warp")) { toast("Дождитесь завершения текущей операции", "bad"); return; }
  const label = (WARP_MODES.find(m => m.id === mode) || {}).label;
  _warpMode = mode;
  setWarpMode(mode);
  warpReqBegin();
  let resp;
  try {
    resp = await apiPost("/warp/transport", { value: mode });
  } catch (e) {
    warpReqEnd();
    toastErr("Ошибка: ", e);
    loadWarpStatus();
    return;
  }
  warpReqEnd();
  if (!resp || !resp.job) {
    toast(`Выбран ${label}. Применится при включении WARP`);
    loadWarpStatus();
    return;
  }
  warpTrack("Переключаю транспорт WARP", resp.job, (outcome, d) => {
    if (outcome === JOB_FAIL) toast(`Не переключилось: ${jobReason(d)}`, "bad");
    else toast(`Транспорт переключён: ${label}`);
  });
}

// Тип аккаунта словами. Признак подписки — account_type: у бесплатной записи
// Cloudflare тоже отдаёт warp_plus:true (замер 2026-09-14), и на нём панель
// показала бы WARP+ всем подряд.
const WARP_PLANS = { free: "бесплатный", limited: "WARP+", unlimited: "WARP+ Unlimited", team: "Zero Trust" };

function warpPlanText(d) {
  if (d.plan_error) {
    return "Ключ сохранён, но к новой записи устройства не привязался — введите его и примените ещё раз.";
  }
  const plan = WARP_PLANS[d.plan];
  if (!plan) return d.license ? "Ключ сохранён; тип аккаунта ещё не проверялся." : "Ключ не задан — работает бесплатный WARP.";
  return `Аккаунт: ${plan}` + (d.license ? ", ключ сохранён." : ".");
}

// Ключ уходит задачей с модалкой: ответ Cloudflare нужен человеку словами
// («неверный ключ», «слишком много устройств»), и лог задачи его показывает.
// Поле очищается сразу после отправки — ключ не должен висеть на странице.
async function warpLicenseApply() {
  const input = document.getElementById("warp-plus-key");
  const btn = document.getElementById("warp-plus-apply");
  const key = (input.value || "").trim();
  if (!/^[A-Za-z0-9-]{8,64}$/.test(key)) {
    toast("Ключ WARP+ — латинские буквы, цифры и дефисы", "bad");
    input.focus();
    return;
  }
  if (foreignJobsActive("warp") || warpActing()) { toast("Дождитесь завершения текущей операции", "bad"); return; }
  btn.disabled = true;
  let resp;
  try {
    resp = await apiPost("/warp/license", { key });
  } catch (e) {
    btn.disabled = false;
    toastErr("Ошибка: ", e);
    return;
  }
  input.value = "";
  openJobModal("Применяю ключ WARP+", resp.job, {
    onDone: (d) => {
      btn.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) toast(jobReason(d), "bad");
      else if (!jobUnresolved(outcome)) toast("Ключ применён");
      loadWarpStatus();
    },
  });
}

// Установить / Удалить — долгие действия, идут job'ом с модалкой, как
// тумблеры. Названия совпадают на кнопке, в модалке и в тосте.
async function warpInstall() {
  const btn = document.getElementById("warp-install-btn");
  btn.disabled = true;
  let resp;
  try {
    resp = await apiPost("/warp/install", {});
  } catch (e) {
    btn.disabled = false;
    toastErr("Ошибка: ", e);
    return;
  }
  openJobModal("Устанавливаю WARP", resp.job, {
    onDone: (d) => {
      btn.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) toast("Не установился — причина в логе выше", "bad");
      else if (!jobUnresolved(outcome)) toast("Установлено. Включите тумблером");
      else { const m = unresolvedMsg(outcome); if (m) toast(m, "bad"); awaitPanelBack().then(() => loadWarpStatus()); return; }
      loadWarpStatus();
    },
  });
}

// Перерегистрация — рычаг на один конкретный случай: в записи устройства стоит
// адрес из диапазона, который режут провайдеры, и починить его нечем — «Удалить
// WARP» ключ намеренно сохраняет, поэтому переустановка возвращает ту же
// мёртвую запись. Цена — одно устройство из лимита Cloudflare, поэтому
// предупреждение прямое, а не «вы уверены?».
async function warpReregister() {
  if (!confirm(
    "Перерегистрировать устройство у Cloudflare?\n\n" +
    "Нажимайте только по согласованию в чате поддержки.\n\n" +
    "Действие тратит одно устройство из лимита вашего аккаунта Cloudflare и нужно ровно в одном случае: " +
    "когда выданный адрес попал в диапазон, который блокируют провайдеры. " +
    "Обычные обрывы и медленная работа лечатся не этим.")) return;
  const btn = document.getElementById("warp-rereg-btn");
  btn.disabled = true;
  let resp;
  try {
    resp = await apiPost("/warp/reregister", {});
  } catch (e) {
    btn.disabled = false;
    toastErr("Ошибка: ", e);
    return;
  }
  openJobModal("Перерегистрирую устройство", resp.job, {
    onDone: (d) => {
      btn.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) toast("Не перерегистрировалось — причина в логе выше", "bad");
      else if (!jobUnresolved(outcome)) toast("Устройство перерегистрировано");
      else { const m = unresolvedMsg(outcome); if (m) toast(m, "bad"); awaitPanelBack().then(() => loadWarpStatus()); return; }
      loadWarpStatus();
    },
  });
}

async function warpRemove() {
  if (!confirm("Удалить WARP?\n\nДвижок будет удалён, туннель выключен. Ключ устройства и ваши списки сохранятся — повторная установка не заведёт новое устройство у Cloudflare.")) return;
  const btn = document.getElementById("warp-remove-btn");
  btn.disabled = true;
  let resp;
  try {
    resp = await apiPost("/warp/remove", {});
  } catch (e) {
    btn.disabled = false;
    toastErr("Ошибка: ", e);
    return;
  }
  openJobModal("Удаляю WARP", resp.job, {
    onDone: (d) => {
      btn.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) toast("Не удалилось — причина в логе выше", "bad");
      else if (!jobUnresolved(outcome)) toast("Удалено");
      else { const m = unresolvedMsg(outcome); if (m) toast(m, "bad"); awaitPanelBack().then(() => loadWarpStatus()); return; }
      loadWarpStatus();
    },
  });
}

// Устройства «всё в WARP»: text/plain, как списки адресов.
async function loadWarpDevices() {
  const ta = document.getElementById("warp-devices");
  if (!ta) return;
  const seq = _newLoad("warpDevices");
  try {
    const text = await apiGetText("/warp/devices");
    if (_stale("warpDevices", seq)) return;
    ta.value = text;
  } catch (e) {
    if (_stale("warpDevices", seq)) return;
    toastErr("Устройства: ", e);
  }
}

async function warpDevicesSave() {
  const ta = document.getElementById("warp-devices");
  const btn = document.getElementById("warp-devices-save");
  btn.disabled = true;
  try {
    const d = await apiPostText("/warp/devices/save", ta.value);
    toast(`Сохранено: ${Number(d.entries) || 0}` + (Number(d.dropped) > 0 ? `, отброшено строк: ${d.dropped}` : ""));
    loadWarpDevices();
    loadWarpNeighbors();
    loadWarpStatus();
  } catch (e) {
    toastErr("Не сохранилось: ", e);
  } finally {
    btn.disabled = false;
  }
}

// Включение и выключение туннеля. Без модалки и без замка на тумблере: если
// включение зависло, его прерывают тем же тумблером (или выбором транспорта).
// .disabled — только на время самого запроса, id задачи приходит за доли
// секунды; класс .loading не ставится, он снимает с тумблера клики.
async function warpToggle(box) {
  const wanted = box.checked ? "1" : "0";
  box.disabled = true;
  warpReqBegin();
  let resp;
  try {
    resp = await apiPost("/toggle/game-warp", { value: wanted });
  } catch (e) {
    warpReqEnd();
    box.checked = !box.checked;
    box.disabled = false;
    toastErr("Ошибка: ", e);
    return;
  }
  warpReqEnd();
  box.disabled = false;
  warpTrack((wanted === "1" ? "Включаю" : "Отключаю") + " WARP-туннель", resp.job, (outcome, d) => {
    if (outcome === JOB_FAIL) {
      box.checked = wanted !== "1";
      toast((wanted === "1" ? "Не включилось: " : "Не выключилось: ") + jobReason(d), "bad");
    } else {
      toast(wanted === "1" ? "Включено" : "Выключено");
    }
  });
}

async function loadWarpLists() {
  const list = document.getElementById("warp-lists");
  if (!list) return;
  const seq = _newLoad("warpLists");
  try {
    const d = await apiGet("/warp/lists");
    if (_stale("warpLists", seq)) return;
    _warpLists = d.lists || [];
    renderOwnToggles(_warpLists);
    if (!_warpLists.length) {
      list.innerHTML = `<li style="color:var(--text-muted)">(нет списков — создайте новый или импортируйте .txt)</li>`;
      return;
    }
    list.innerHTML = _warpLists.map(l => `
      <li>
        <span class="warp-item">
          <span class="warp-item-name">${escapeHtml(l.name)}.txt</span>
          <span class="warp-item-meta">${warpEntries(l.entries)} · ${fmtSize(l.size)}${Number(l.mtime) > 0 ? " · изменён " + humanAgo(Number(l.mtime)) : ""}${listOn(l) ? "" : " · выключен"}</span>
        </span>
        <span class="warp-item-actions">
          <button class="btn-icon" title="Редактировать" aria-label="Редактировать ${escapeHtml(l.name)}" data-edit="${escapeHtml(l.name)}">${_icons.edit}</button>
          <button class="btn-icon" title="Скачать .txt" aria-label="Скачать ${escapeHtml(l.name)}" data-export="${escapeHtml(l.name)}">${_icons.download}</button>
          <button class="btn-icon" title="Удалить" aria-label="Удалить ${escapeHtml(l.name)}" data-del="${escapeHtml(l.name)}">${_icons.close}</button>
        </span>
      </li>
    `).join("");
    list.querySelectorAll("button[data-edit]").forEach(b => {
      b.addEventListener("click", () => warpEditOpen(b.dataset.edit));
    });
    list.querySelectorAll("button[data-export]").forEach(b => {
      b.addEventListener("click", () => warpExport(b.dataset.export));
    });
    list.querySelectorAll("button[data-del]").forEach(b => {
      b.addEventListener("click", () => warpDelete(b.dataset.del));
    });
  } catch (e) {
    if (_stale("warpLists", seq)) return;
    list.innerHTML = `<li style="color:var(--bad)">${errHtml(e)}</li>`;
  }
}

// Свой список включён, пока его явно не выключили: старый роутер поля «on»
// не отдаёт, и все его списки работают — так их и показываем.
function listOn(l) { return !(l.on === 0 || l.on === "0"); }

// Тумблеры своих списков — под игровыми, в той же карточке и той же разметкой:
// «что идёт через туннель» человек включает в одном месте. Редактирование,
// импорт и удаление остаются в карточке «Списки адресов».
function renderOwnToggles(lists) {
  const box = document.getElementById("warp-own");
  const host = document.getElementById("warp-own-list");
  if (!box || !host) return;
  box.hidden = !lists.length;
  host.innerHTML = lists.map(l => `
      <div class="toggle-row" data-own="${escapeHtml(l.name)}">
        <div class="t-text">
          <div class="t-name" title="${escapeHtml(l.name)}">${escapeHtml(l.name)}</div>
          <div class="t-desc">${warpEntries(l.entries)}</div>
        </div>
        <label class="switch">
          <input type="checkbox" ${listOn(l) ? "checked" : ""} aria-label="Список ${escapeHtml(l.name)} через WARP">
          <span class="slider"></span>
        </label>
      </div>`).join("");
  host.querySelectorAll("[data-own] input").forEach(cb => {
    cb.addEventListener("change", () => warpOwnToggle(cb));
  });
}

async function warpOwnToggle(box) {
  const row = box.closest("[data-own]");
  const name = row.getAttribute("data-own");
  const wanted = box.checked ? "1" : "0";
  box.disabled = true;
  try {
    await apiPost("/warp/list/toggle", { name, value: wanted });
  } catch (e) {
    box.checked = !box.checked;
    toastErr("Ошибка: ", e);
    box.disabled = false;
    return;
  }
  box.disabled = false;
  toast(wanted === "1" ? `${name} включён` : `${name} выключен`);
  loadWarpLists();
}

async function warpEditOpen(name, prefill) {
  const card = document.getElementById("warp-editor-card");
  const ta = document.getElementById("warp-editor");
  const title = document.getElementById("warp-editor-title");
  card.dataset.name = name;
  // «Новый список» сохраняется с mode=create: сервер откажется затирать
  // существующий файл, даже если локальный кэш имён был неполным.
  card.dataset.mode = prefill !== undefined ? "create" : "replace";
  if (prefill !== undefined) {
    title.textContent = "Новый список: " + name + ".txt";
    ta.value = prefill;
  } else {
    title.textContent = "Редактирование: " + name + ".txt";
    ta.value = "";
    card.hidden = false;
    let text;
    try {
      text = await apiGetText("/warp/list?name=" + encodeURIComponent(name));
    } catch (e) {
      toastErr("Не удалось загрузить список: ", e);
      if (card.dataset.name === name) card.hidden = true;
      return;
    }
    // Пока грузили, юзер мог открыть другой список — не подкладываем
    // чужой контент в его редактор (сохранение перезаписало бы список).
    if (card.dataset.name !== name) return;
    ta.value = text;
  }
  card.hidden = false;
  card.scrollIntoView({ behavior: "smooth", block: "start" });
  ta.focus();
}

async function warpEditorSave() {
  const card = document.getElementById("warp-editor-card");
  const name = card.dataset.name;
  const mode = card.dataset.mode === "create" ? "create" : "replace";
  if (!warpNameValid(name)) { toast("Некорректное имя списка", "bad"); return; }
  const btn = document.getElementById("warp-editor-save");
  if (btn.disabled) return;
  btn.disabled = true;
  try {
    const d = await apiPostText("/warp/list/save?name=" + encodeURIComponent(name) + "&mode=" + mode,
      document.getElementById("warp-editor").value);
    let msg = `Сохранено: ${addrs(d.saved_ip ?? d.saved)}, ${warpDomains(d.saved_domain || 0)}`;
    if (d.skipped_invalid > 0) msg += " (отброшено невалидных строк: " + d.skipped_invalid + ")";
    toast(msg);
    card.hidden = true;
    loadWarpLists();
    loadWarpStatus();
  } catch (e) {
    toastErr("Ошибка: ", e);
  } finally {
    btn.disabled = false;
  }
}

// Освежить кэш имён перед проверкой на дубликат: со stale/пустым кэшем
// (например, первый GET /warp/lists упал) «новый список» мог бы молча
// открыть пустой редактор поверх существующего файла. Сервер всё равно
// подстрахует (mode=create), но лучше поймать до открытия редактора.
async function warpRefreshNames() {
  try {
    const d = await apiGet("/warp/lists");
    _warpLists = d.lists || [];
  } catch (_) { /* сеть лежит — доверимся серверному mode=create */ }
}

async function warpNewList() {
  let name = prompt("Имя нового списка (латиница/цифры/точка/дефис/подчёркивание):", "");
  if (name === null) return;
  name = name.trim().replace(/\.txt$/i, "");
  if (!warpNameValid(name)) {
    toast("Имя: 1–64 символа [A-Za-z0-9._-], не с точки/дефиса", "bad");
    return;
  }
  await warpRefreshNames();
  if (_warpLists.some(l => l.name === name)) {
    toast("Список уже существует — открываю его");
    warpEditOpen(name);
    return;
  }
  warpEditOpen(name, "");
}

async function warpImport(e) {
  const file = e.target.files && e.target.files[0];
  e.target.value = ""; // allow re-select same file
  if (!file) return;
  if (file.size > 2 * 1024 * 1024) {
    toast("Файл слишком большой (>2 МБ)", "bad");
    return;
  }
  let text;
  try { text = await file.text(); }
  catch (err) { toast("Не удалось прочитать файл: " + err.message, "bad"); return; }
  const suggested = (file.name.replace(/\.txt$/i, "").replace(/[^A-Za-z0-9._-]/g, "-").replace(/^[.-]+/, "") || "list").slice(0, 64);
  let name = prompt("Имя списка для импорта:", suggested);
  if (name === null) return;
  name = name.trim().replace(/\.txt$/i, "");
  if (!warpNameValid(name)) {
    toast("Имя: 1–64 символа [A-Za-z0-9._-], не с точки/дефиса", "bad");
    return;
  }
  await warpRefreshNames();
  const exists = _warpLists.some(l => l.name === name);
  if (exists &&
      !confirm(`Список «${name}.txt» уже существует.\n\nЗаменить его содержимое импортируемым файлом?`)) {
    return;
  }
  const btn = document.getElementById("warp-import-btn");
  if (btn) btn.disabled = true;
  try {
    // Незатронутое существование подтверждено свежим списком: replace только
    // после явного confirm, иначе create (сервер откажет, если имя заняли).
    const mode = exists ? "replace" : "create";
    const d = await apiPostText("/warp/list/save?name=" + encodeURIComponent(name) + "&mode=" + mode, text);
    let msg = `Импортировано: ${addrs(d.saved_ip ?? d.saved)}, ${warpDomains(d.saved_domain || 0)}`;
    if (d.skipped_invalid > 0) msg += " (невалидных строк: " + d.skipped_invalid + ")";
    toast(msg);
    loadWarpLists();
    loadWarpStatus();
  } catch (err) {
    toast("Ошибка импорта: " + err.message, "bad");
  } finally {
    if (btn) btn.disabled = false;
  }
}

async function warpExport(name) {
  try {
    const text = await apiGetText("/warp/list?name=" + encodeURIComponent(name));
    const blob = new Blob([text], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = name + ".txt";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (e) {
    toastErr("Ошибка экспорта: ", e);
  }
}

async function warpDelete(name) {
  if (!confirm(`Удалить список «${name}.txt»?\n\nАдреса из него сразу перестанут ходить через WARP.`)) return;
  try {
    await apiPost("/warp/list/delete", { name });
    toast("Удалено");
    const card = document.getElementById("warp-editor-card");
    if (card && card.dataset.name === name) card.hidden = true;
    loadWarpLists();
    loadWarpStatus();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}
