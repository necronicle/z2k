import { apiGet, apiGetText, apiPost, apiPostText, errHtml, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, humanAgo, skeletonBlocks, skeletonLines, statusIcon } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { JOB_FAIL, _activeJobs, _updateGlobalUILock, awaitPanelBack, jobOutcome, jobUnresolved, openJobModal, unresolvedMsg } from "../job.js";

// Раздел «WARP»: туннель Cloudflare WARP на нашем движке z2k-warpd
// (WireGuard, при полном UDP-блоке — MASQUE по TCP 443). Три действия —
// Установить / тумблер / Удалить: без намерения юзера на роутере нет ни
// движка, ни демона. Что идёт в туннель: адреса из списков (игровые +
// свои) и целые устройства по IP/MAC. Всё — файлы в /opt/zapret2/lists/warp/.
let _warpLists = [];

// Коды last_error движка → текст. Движок пишет код, панель — смысл.
const WARP_ERRORS = {
  register_blocked: "Cloudflare не отвечает на регистрацию — ни напрямую, ни через релей. Попробуйте позже.",
  device_revoked: "Cloudflare отозвал устройство — регистрирую заново.",
  no_endpoint: "Ни один адрес Cloudflare не отвечает — провайдер блокирует WARP целиком.",
  tun_failed: "Прошивка не даёт создать туннельный интерфейс.",
};

function warpNameValid(n) {
  return /^[A-Za-z0-9._-]{1,64}$/.test(n) && !/^[.-]/.test(n);
}

function fmtSize(b) {
  b = Number(b) || 0;
  if (b < 1024) return b + " Б";
  if (b < 1048576) return Math.round(b / 1024) + " КБ";
  return (b / 1048576).toFixed(1) + " МБ";
}

export async function renderWarp() {
  $app.innerHTML = `
    <h1 class="page-title">WARP</h1>
    <div class="card">
      <div class="toggle-row" data-key="game_warp">
        <div class="t-text">
          <div class="t-name">WARP-туннель</div>
          <div class="t-desc">Заворачивает трафик к адресам из списков ниже и к выбранным
            устройствам в туннель Cloudflare WARP. Помогает сервисам, заблокированным
            по IP: игровым серверам, хостингам, диапазонам Cloudflare/AWS из списка РКН.
            Транспорт выбирается сам: WireGuard, а если провайдер режет UDP —
            MASQUE по TCP 443. Это не десинк, а туннель: трафик к этим адресам идёт
            через Cloudflare и может быть медленнее прямого.</div>
        </div>
        <label class="switch" id="warp-switch" hidden>
          <input type="checkbox" disabled>
          <span class="slider"></span>
        </label>
      </div>
      <div class="status-grid" id="warp-status-grid">${skeletonBlocks(3)}</div>
      <div class="btn-row" id="warp-actions" style="margin-top:10px" hidden>
        <button class="btn btn-primary" id="warp-install-btn" hidden>Установить WARP</button>
        <span class="desc" id="warp-install-note" hidden>Скачает движок (~7 МБ) и зарегистрирует
          устройство у Cloudflare. Ничего не запускается, пока не включите тумблер.</span>
        <button class="btn btn-danger" id="warp-remove-btn" hidden>Удалить WARP</button>
      </div>
    </div>
    <div class="card">
      <h3>Игровые списки</h3>
      <p class="desc">
        Готовые списки адресов по играм и сервисам, обновляются автоматически.
        <b>По умолчанию не включён ни один</b> — включайте только то, что вам нужно:
        чем меньше адресов в туннеле, тем меньше на него завязано. Списки только для
        чтения; свои адреса добавляйте ниже, отдельным списком.
      </p>
      <div id="warp-games">${skeletonBlocks(3)}</div>
    </div>
    <div class="card" id="warp-devices-card" hidden>
      <h3>Устройства</h3>
      <p class="desc">
        Весь трафик устройства — в WARP, независимо от списков. Одна строка —
        один IP (<code>192.168.1.50</code>) или MAC (<code>aa:bb:cc:dd:ee:ff</code>);
        MAC удобнее: адрес может меняться. <b>Применяется сразу.</b>
      </p>
      <textarea id="warp-devices" class="warp-editor" spellcheck="false"
                autocomplete="off" autocapitalize="off" autocorrect="off"
                placeholder="192.168.1.50"></textarea>
      <div class="btn-row" style="margin-top:10px">
        <button class="btn btn-primary" id="warp-devices-save">Сохранить</button>
      </div>
    </div>
    <div class="card">
      <h3>Списки адресов</h3>
      <p class="desc">
        Каждый список — текстовый файл: один IPv4-адрес или CIDR-подсеть на строку
        (<code>203.0.113.7</code> или <code>203.0.113.0/24</code>; строки с <code>#</code> —
        комментарии). Через WARP идёт трафик ко всем адресам из всех списков.
        <b>Изменения применяются сразу</b>, без перезапуска, и переживают
        переустановку z2k.
      </p>
      <div class="btn-row" style="margin-bottom:10px">
        <button class="btn btn-primary" id="warp-new-btn">Новый список</button>
        <button class="btn" id="warp-import-btn" title="Загрузить список из текстового файла (одна строка — один адрес/CIDR)">Импорт из txt</button>
        <input type="file" id="warp-import-file" accept=".txt,text/plain" hidden>
      </div>
      <ul class="wl-list" id="warp-lists">${skeletonLines(3)}</ul>
    </div>
    <div class="card" id="warp-editor-card" hidden>
      <h3 id="warp-editor-title"></h3>
      <p class="desc">Один адрес или подсеть на строку. Невалидные строки (в т.ч. IPv6 —
        туннель ходит только по IPv4) при сохранении отбрасываются, счётчик покажет сколько.</p>
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
  loadWarpDevices();
  _updateGlobalUILock();
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
      ? "Сейчас не включён ни один список — через туннель не идёт ничего."
      : `Включено списков: ${on} из ${games.length}.`}</p>
    ${games.map(g => `
      <div class="toggle-row" data-game="${escapeHtml(g.name)}">
        <div class="t-text">
          <div class="t-name">${escapeHtml(g.name)}</div>
          <div class="t-desc">${Number(g.entries) || 0} адрес(ов)</div>
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

  // Три состояния раздела — из одного ответа. Не установлен: одна кнопка, без
  // тумблера и статуса (нечего показывать). Установлен: тумблер + статус +
  // «Удалить». Списки и устройства видны всегда — это данные юзера.
  const sw = document.getElementById("warp-switch");
  const actions = document.getElementById("warp-actions");
  const installBtn = document.getElementById("warp-install-btn");
  const installNote = document.getElementById("warp-install-note");
  const removeBtn = document.getElementById("warp-remove-btn");
  sw.hidden = !installed;
  actions.hidden = false;
  installBtn.hidden = installed;
  installNote.hidden = installed;
  removeBtn.hidden = !installed;
  document.getElementById("warp-devices-card").hidden = false;

  const box = $app.querySelector('[data-key="game_warp"] input');
  if (box) {
    // Checked-состояние синкаем ВСЕГДА. С disabled аккуратнее: если сейчас
    // идёт job, свитч залочен _updateGlobalUILock'ом — не раслочиваем его в
    // обход лока, а поправляем lockBackup, чтобы разлочка после job'а
    // вернула enabled.
    box.checked = enabled;
    if (_activeJobs.size) {
      if (box.dataset.lockBackup !== undefined) box.dataset.lockBackup = "0";
    } else {
      box.disabled = false;
    }
  }

  if (!installed) {
    grid.innerHTML = `<div class="status-cell"><div class="label">Движок</div><div class="value">не установлен</div></div>`;
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
  } else if (d.error) {
    tunnelValue = WARP_ERRORS[d.error] || d.error;
    tunnelKind = "bad";
  } else {
    tunnelValue = "поднимается";
    tunnelKind = "";
  }
  const transport = d.transport === "wg" ? "WireGuard" : d.transport === "h2" ? "MASQUE (TCP 443)" : "—";
  const cells = [
    { label: "Туннель", value: tunnelValue, kind: tunnelKind },
    { label: "Транспорт", value: d.ready ? transport + (d.endpoint ? " · " + d.endpoint : "") : "—",
      kind: d.ready ? "good" : "" },
    { label: "Адресов в маршрутизации", value: enabled ? String(d.entries) : "—",
      kind: enabled && Number(d.entries) > 0 ? "good" : "" },
    { label: "Устройств целиком", value: enabled ? String(d.devices) : "—",
      kind: enabled && Number(d.devices) > 0 ? "good" : "" },
  ];
  grid.innerHTML = cells.map(c => {
    const icon = statusIcon(c.kind);
    return `<div class="status-cell ${c.kind}"><div class="label">${c.label}</div><div class="value">${icon ? `<span class="status-ico">${icon}</span>` : ""}${escapeHtml(c.value)}</div></div>`;
  }).join("");
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
    loadWarpStatus();
  } catch (e) {
    toastErr("Не сохранилось: ", e);
  } finally {
    btn.disabled = false;
  }
}

// Аналог toggleClick, но со своим onDone: после переключения обновляем
// статус-грид раздела (туннель/ipset), а не дашборд.
async function warpToggle(box) {
  const sw = box.closest(".switch");
  const wanted = box.checked ? "1" : "0";
  sw.classList.add("loading");
  box.disabled = true;
  let resp;
  try {
    resp = await apiPost("/toggle/game-warp", { value: wanted });
  } catch (e) {
    box.checked = !box.checked;
    box.disabled = false;
    sw.classList.remove("loading");
    toastErr("Ошибка: ", e);
    return;
  }
  openJobModal((wanted === "1" ? "Включаю" : "Отключаю") + " WARP-туннель", resp.job, {
    onDone: (d) => {
      sw.classList.remove("loading");
      box.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) {
        box.checked = !box.checked;
        toast("Не включилось — причина в логе выше", "bad");
      } else if (jobUnresolved(outcome)) {
        // Не знаем, чем кончилось — не откатываем чекбокс и не врём.
        // loadWarpStatus сам вернёт фактическое состояние, когда панель
        // снова ответит.
        const m = unresolvedMsg(outcome);
        if (m) toast(m, "bad");
        awaitPanelBack().then(() => loadWarpStatus());
        return;
      } else {
        toast(wanted === "1" ? "Включено" : "Выключено");
      }
      loadWarpStatus();
    },
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
    if (!_warpLists.length) {
      list.innerHTML = `<li style="color:var(--text-muted)">(нет списков — создайте новый или импортируйте .txt)</li>`;
      return;
    }
    list.innerHTML = _warpLists.map(l => `
      <li>
        <span class="warp-item">
          <span class="warp-item-name">${escapeHtml(l.name)}.txt</span>
          <span class="warp-item-meta">адресов: ${Number(l.entries) || 0} · ${fmtSize(l.size)}${Number(l.mtime) > 0 ? " · изменён " + humanAgo(Number(l.mtime)) : ""}</span>
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
    let msg = "Сохранено, адресов: " + d.saved;
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
    let msg = "Импортировано адресов: " + d.saved;
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
