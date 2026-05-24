// z2k webpanel frontend — vanilla JS, no build step, no framework.
// Hash-router SPA. ~500 lines, ~15 KB minified.

(() => {
  "use strict";

  const API = "/cgi-bin/api";
  const $app = document.getElementById("app");
  const $toast = document.getElementById("toast");
  const $nav = document.getElementById("nav");

  // ---------- Toast ----------
  let toastTimer;
  function toast(msg, kind = "ok") {
    $toast.textContent = msg;
    $toast.className = "toast " + kind;
    $toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { $toast.hidden = true; }, 2600);
  }

  // ---------- Fetch helpers ----------
  async function apiGet(path) {
    const r = await fetch(API + path, { credentials: "same-origin" });
    if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
    return r.json();
  }
  async function apiPost(path, params = {}) {
    const body = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) body.set(k, v);
    const r = await fetch(API + path, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    const data = await r.json().catch(() => ({ ok: false, error: `${r.status}` }));
    if (!r.ok || !data.ok) throw new Error(data.error || `${r.status}`);
    return data;
  }

  // ---------- Router ----------
  const routes = {
    dashboard: renderDashboard,
    toggles: renderToggles,
    whitelist: renderWhitelist,
    "extra-domains": renderExtraDomains,
    logs: renderLogs,
    state: renderState,
    diag: renderDiag,
    geosite: renderGeosite,
    credits: renderCredits,
  };
  function navigate() {
    const hash = location.hash.replace(/^#\//, "") || "dashboard";
    const name = routes[hash] ? hash : "dashboard";
    for (const a of $nav.querySelectorAll("a")) {
      a.classList.toggle("active", a.dataset.route === name);
    }
    $app.innerHTML = "";
    routes[name]();
  }
  window.addEventListener("hashchange", navigate);

  // ---------- Dashboard ----------
  async function renderDashboard() {
    $app.innerHTML = `
      <div id="update-banner" hidden></div>
      <h1 class="page-title">Дашборд</h1>
      <div class="card" id="status-card">
        <h3>Состояние <span class="status-spinner" id="status-spin" hidden></span></h3>
        <div class="status-grid" id="status-grid">Загрузка…</div>
      </div>
      <div class="card">
        <h3>Управление сервисом</h3>
        <p class="desc">Запуск, остановка и перезапуск nfqws2.</p>
        <div class="btn-row">
          <button class="btn btn-primary" data-svc="start" data-target="active">Запустить</button>
          <button class="btn" data-svc="restart" data-target="active">Перезапустить</button>
          <button class="btn btn-danger" data-svc="stop" data-target="stopped">Остановить</button>
        </div>
      </div>
    `;

    $app.querySelectorAll("[data-svc]").forEach(btn => {
      btn.addEventListener("click", async () => {
        const action = btn.dataset.svc;
        const titleByAction = { start: "Запуск сервиса", stop: "Остановка сервиса", restart: "Перезапуск сервиса" };
        const title = titleByAction[action] || ("Действие: " + action);
        let resp;
        try {
          resp = await apiPost("/service/" + action);
        } catch (e) {
          toast("Ошибка запуска: " + e.message, "bad");
          return;
        }
        // Backend теперь async — возвращает {ok, job:<id>}. Открываем
        // модалку с live-логом точно как при auto-update apply. После
        // завершения refreshStatus подтянет grid вверху.
        openJobModal(title, resp.job, {
          onDone: (d) => {
            setTimeout(refreshStatus, 500);
            if (d && d.exit !== 0) {
              toast("Команда завершилась с кодом " + d.exit, "bad");
            }
          },
        });
      });
    });

    refreshStatus();
    refreshUpdateBanner();
    _updateGlobalUILock();
  }

  // ---------- Update banner / apply ----------
  async function refreshUpdateBanner(opts = {}) {
    const banner = document.getElementById("update-banner");
    if (!banner) return;
    let d;
    try {
      const path = opts.force ? "/update/check" : "/update/status";
      d = opts.force ? await apiPost(path) : await apiGet(path);
    } catch (e) {
      // Silent — manifest fetch can fail (no internet, GH down). UI just
      // doesn't show banner; user can still hit "Проверить сейчас".
      banner.hidden = true;
      return;
    }
    const installed = d.installed || "?";
    const available = d.available || "?";
    const behind = Number(d.behind || 0);
    const ts = Number(d.last_check || 0);
    const ago = ts > 0 ? humanAgo(ts) : "—";

    // Resume button takes priority over Обновить when an apply is active.
    const activeJob = await getActiveApplyJob();

    if (activeJob) {
      banner.hidden = false;
      banner.className = "update-banner";
      banner.innerHTML = `
        <div class="update-banner-text">
          <strong>Обновление до ${escapeHtml(activeJob.target)} в процессе</strong>
          <span class="update-banner-meta">фоновый apply, клик для просмотра лога</span>
        </div>
        <div class="update-banner-actions">
          <button class="btn btn-primary" id="upd-resume">Показать лог</button>
        </div>
      `;
      const resumeBtn = document.getElementById("upd-resume");
      if (resumeBtn) resumeBtn.addEventListener("click", () => openApplyModal(activeJob.id, activeJob.target));
      return;
    }

    if (behind > 0 && available !== "?" && installed !== "?") {
      const pending = Array.isArray(d.pending) ? d.pending : [];
      banner.hidden = false;
      banner.className = "update-banner";
      banner.innerHTML = `
        <div class="update-banner-text">
          <strong>Доступно обновление: ${escapeHtml(available)}</strong>
          <span class="update-banner-meta">установлена ${escapeHtml(installed)} · отстаёт на ${behind} · проверено ${ago}</span>
        </div>
        <div class="update-banner-actions">
          <button class="btn btn-primary" id="upd-apply">Обновить</button>
          ${pending.length > 0 ? `<button class="btn" id="upd-changelog-btn" aria-expanded="false">Что нового ▾</button>` : ""}
          <button class="btn" id="upd-recheck">Проверить ещё раз</button>
        </div>
        ${pending.length > 0 ? `
          <div class="update-banner-body">
            <div class="upd-changelog" id="upd-changelog" hidden>
              ${pending.map(renderChangelogEntry).join("")}
            </div>
          </div>
        ` : ""}
      `;
      const clBtn = document.getElementById("upd-changelog-btn");
      const clBox = document.getElementById("upd-changelog");
      if (clBtn && clBox) {
        clBtn.addEventListener("click", () => {
          const open = !clBox.hidden;
          clBox.hidden = open;
          clBtn.setAttribute("aria-expanded", open ? "false" : "true");
          clBtn.textContent = open ? "Что нового ▾" : "Что нового ▴";
        });
      }
    } else {
      banner.hidden = false;
      banner.className = "update-banner update-banner-ok";
      banner.innerHTML = `
        <div class="update-banner-text">
          <span>Установлена последняя версия (${escapeHtml(installed)})</span>
          <span class="update-banner-meta">проверено ${ago}</span>
        </div>
        <div class="update-banner-actions">
          <button class="btn" id="upd-recheck">Проверить</button>
        </div>
      `;
    }

    const applyBtn = document.getElementById("upd-apply");
    if (applyBtn) applyBtn.addEventListener("click", () => applyUpdateFlow(available));
    const recheckBtn = document.getElementById("upd-recheck");
    if (recheckBtn) recheckBtn.addEventListener("click", async () => {
      recheckBtn.disabled = true;
      recheckBtn.textContent = "Проверяем…";
      await refreshUpdateBanner({ force: true });
    });
  }

  async function applyUpdateFlow(target) {
    const msg = `Применить обновление до ${target}?\n\n` +
                `Сервис nfqws2 перезапустится. Связь с веб-панелью может ` +
                `пропасть на 5–15 секунд во время рестарта lighttpd — это нормально, ` +
                `обнови страницу если зависнет.`;
    if (!confirm(msg)) return;
    let resp;
    try {
      resp = await apiPost("/update/apply");
    } catch (e) {
      toast("Ошибка запуска: " + e.message, "bad");
      return;
    }
    // Persist across "Скрыть" / page reload so the user can resume the
    // log view. sessionStorage survives tab reload but not tab-close —
    // which matches the desired behaviour: once user closes the tab,
    // they don't need to be nagged about an apply they explicitly walked
    // away from. onDone clears the key.
    sessionStorage.setItem("z2k_apply_job", JSON.stringify({ id: resp.job, target }));
    openApplyModal(resp.job, target);
    refreshUpdateBanner();
  }

  function openApplyModal(jobId, target) {
    openJobModal("Обновление до " + target, jobId, {
      warning: "Можно скрыть — обновление продолжит идти в фоне. При reinstall'е возможен короткий обрыв соединения с панелью — опрос лога продолжится автоматически.",
      tolerateOutage: true,
      onDone: () => {
        sessionStorage.removeItem("z2k_apply_job");
        setTimeout(() => refreshUpdateBanner({ force: true }), 500);
        setTimeout(refreshStatus, 1500);
      },
    });
  }

  // Check if a previously-launched apply is still in progress. Returns the
  // {id, target} object from sessionStorage if so, null otherwise. Cleans
  // up the key on a 404/finished state so a dead job doesn't poison the
  // banner forever.
  async function getActiveApplyJob() {
    const raw = sessionStorage.getItem("z2k_apply_job");
    if (!raw) return null;
    let job;
    try { job = JSON.parse(raw); } catch (e) { sessionStorage.removeItem("z2k_apply_job"); return null; }
    if (!job || !job.id) { sessionStorage.removeItem("z2k_apply_job"); return null; }
    try {
      const d = await apiGet("/job?id=" + encodeURIComponent(job.id));
      if (d.done) {
        sessionStorage.removeItem("z2k_apply_job");
        return null;
      }
      return job;
    } catch (e) {
      // Webpanel might be temporarily down (mid-restart). Keep the key,
      // user can manually resume later.
      return job;
    }
  }

  function humanAgo(tsSec) {
    const age = Math.max(0, Math.floor(Date.now() / 1000) - tsSec);
    if (age < 60) return age + " с назад";
    if (age < 3600) return Math.floor(age / 60) + " мин назад";
    if (age < 86400) return Math.floor(age / 3600) + " ч назад";
    return Math.floor(age / 86400) + " дн назад";
  }

  function formatChangelogDate(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    try {
      return d.toLocaleDateString("ru-RU", { day: "numeric", month: "long", year: "numeric" });
    } catch (_) {
      return iso.slice(0, 10);
    }
  }

  function summarizeDesc(desc) {
    if (!desc) return "";
    const dot = desc.search(/\.\s/);
    if (dot > 0 && dot < 160) return desc.slice(0, dot + 1);
    if (desc.length <= 160) return desc;
    return desc.slice(0, 160).replace(/\s+\S*$/, "") + "…";
  }

  function renderChangelogEntry(e) {
    const v = e && e.v ? String(e.v) : "?";
    const type = e && e.type ? String(e.type) : "patch";
    const ts = formatChangelogDate(e && e.ts);
    const desc = e && e.desc ? String(e.desc) : "(без описания)";
    const summary = summarizeDesc(desc);
    const hasMore = summary.length < desc.length;
    const typeCls = type === "reinstall" ? "upd-type-reinstall" : "upd-type-patch";
    const resetBadge = e && e.reset_state
      ? `<span class="upd-reset-state" title="Сбрасывает state.tsv после применения">сброс state</span>`
      : "";
    return `
      <div class="upd-entry">
        <div class="upd-entry-head">
          <span class="upd-tag">${escapeHtml(v)}</span>
          <span class="upd-type ${typeCls}">${escapeHtml(type)}</span>
          ${resetBadge}
          <span class="upd-date">${escapeHtml(ts)}</span>
        </div>
        <div class="upd-desc">${escapeHtml(summary)}</div>
        ${hasMore ? `
          <details class="upd-details">
            <summary>Подробнее</summary>
            <div class="upd-desc-full">${escapeHtml(desc)}</div>
          </details>
        ` : ""}
      </div>
    `;
  }

  // ---------- Status spinner / poll ----------
  function showStatusSpinner(msg) {
    const spin = document.getElementById("status-spin");
    if (!spin) return;
    spin.hidden = false;
    spin.textContent = msg || "Применяем…";
  }
  function hideStatusSpinner() {
    const spin = document.getElementById("status-spin");
    if (spin) spin.hidden = true;
  }

  // Poll /status until service.service matches target, or timeout. Returns
  // true if target reached. On the way refreshes the UI grid each tick so
  // the user sees the transition (stopped → active or vice versa).
  async function pollServiceUntil(target, timeoutMs) {
    const start = Date.now();
    const interval = 600;
    while (Date.now() - start < timeoutMs) {
      try {
        const s = await apiGet("/status");
        renderStatusGrid(s);
        if (s.service === target) return true;
      } catch (e) {
        // transient — webpanel may be in mid-restart if init scripts shake
        // up lighttpd. Just keep polling.
      }
      await new Promise(r => setTimeout(r, interval));
    }
    // timeout — surface last-known and let the user manually inspect logs.
    try { const s = await apiGet("/status"); renderStatusGrid(s); } catch (e) {}
    throw new Error("сервис не перешёл в состояние «" + target + "» за " + Math.round(timeoutMs/1000) + "с");
  }

  async function refreshStatus() {
    const grid = document.getElementById("status-grid");
    if (!grid) return;
    try {
      const s = await apiGet("/status");
      renderStatusGrid(s);
    } catch (e) {
      grid.innerHTML = `<div class="status-cell bad"><div class="label">Ошибка</div><div class="value">${escapeHtml(e.message)}</div></div>`;
    }
  }

  function renderStatusGrid(s) {
    const grid = document.getElementById("status-grid");
    if (!grid) return;
    const cells = [
      { label: "Установлен", value: s.installed ? "Да" : "Нет", kind: s.installed ? "good" : "bad" },
      { label: "Сервис", value: fmtSvc(s.service), kind: s.service === "active" ? "good" : (s.service === "stopped" ? "warn" : "bad") },
      { label: "Туннель ТГ", value: s.tunnel?.running ? "работает" : "остановлен", kind: s.tunnel?.running ? "good" : "warn" },
      { label: "RST фильтр", value: bool(s.toggles.rst_filter), kind: s.toggles.rst_filter === "1" ? "good" : "" },
      { label: "Silent fallback", value: bool(s.toggles.silent_fallback), kind: s.toggles.silent_fallback === "1" ? "warn" : "" },
      { label: "Игровой режим", value: gameModeLabel(s.toggles.game_mode, s.game_profile), kind: s.toggles.game_mode === "1" ? "good" : "" },
      { label: "custom.d", value: bool(s.toggles.customd), kind: "" },
    ];
    grid.innerHTML = cells.map(c =>
      `<div class="status-cell ${c.kind}"><div class="label">${c.label}</div><div class="value">${c.value}</div></div>`
    ).join("");
  }

  function bool(v) { return v === "1" ? "Вкл" : "Выкл"; }
  function fmtSvc(s) {
    return { active: "работает", stopped: "остановлен", not_installed: "не установлен" }[s] || s;
  }
  // Game mode is enabled/disabled via the game-mode toggle, but the
  // strategy backend (default vs legacy rotator) is selected by the
  // GAME_PROFILE config var. Surface it in the status cell so support
  // can see at a glance which backend is active without ssh-ing in.
  function gameModeLabel(enabled, profile) {
    if (enabled !== "1") return "Выкл";
    const prof = (profile === "legacy") ? "legacy" : "стандартный";
    return "Вкл (" + prof + ")";
  }

  // ---------- Toggles ----------
  const TOGGLE_DEFS = [
    { key: "rst_filter", name: "RST фильтр (пассивный DPI)",
      desc: "Блокирует поддельные TCP RST от ТСПУ через iptables raw/PREROUTING." },
    { key: "silent_fallback", name: "Silent fallback РКН",
      desc: "Детект «тихих чёрных дыр» РКН. Осторожно — возможны ложные срабатывания." },
    { key: "game_mode", name: "Игровой режим",
      desc: "TCP/UDP bypass для игровых сервисов (стандартный профиль — single-strategy bypass на игровом ipset). Для отката на старый ротатор: GAME_PROFILE=legacy в /opt/zapret2/config." },
    { key: "customd", name: "Скрипты custom.d",
      desc: "Дополнительные daemons из init.d/custom.d (50-stun4all, 50-discord-media)." },
    { key: "dynamic_ttl", name: "Динамический TTL",
      desc: "Инжекция фиксированного TTL в исходящий трафик — обход обнаружения tethering у мобильных операторов (МТС/Билайн с телефонной симкой). Если у роутера уже настроен NDM TTL-fix — отключи, чтобы избежать конфликта." },
  ];
  const TOGGLE_API_NAME = {
    rst_filter: "rst-filter",
    silent_fallback: "silent-fallback",
    game_mode: "game-mode",
    customd: "customd",
    dynamic_ttl: "dynamic-ttl",
  };

  async function renderToggles() {
    $app.innerHTML = `
      <h1 class="page-title">Режимы</h1>
      <div class="card">
        ${TOGGLE_DEFS.map(t => `
          <div class="toggle-row" data-key="${t.key}">
            <div class="t-text">
              <div class="t-name">${t.name}</div>
              <div class="t-desc">${t.desc}</div>
            </div>
            <label class="switch">
              <input type="checkbox" disabled>
              <span class="slider"></span>
            </label>
          </div>
        `).join("")}
      </div>
      <div class="card">
        <h3>Telegram туннель <span class="tg-state-badge" id="tg-state-badge" hidden></span></h3>
        <p class="desc">Прозрачный mux-прокси к Telegram DC через выделенный VPS-relay.</p>
        <div class="btn-row">
          <button class="btn btn-primary" id="tg-enable">Включить</button>
          <button class="btn btn-danger" id="tg-disable">Отключить</button>
        </div>
      </div>
    `;

    // Load current state and wire up switches.
    try {
      const s = await apiGet("/status");
      TOGGLE_DEFS.forEach(t => {
        const row = $app.querySelector(`[data-key="${t.key}"]`);
        const box = row.querySelector("input");
        box.checked = s.toggles[t.key] === "1";
        box.disabled = false;
        box.addEventListener("change", () => toggleClick(t.key, box));
      });
      // TG-tunnel state pill + button enable/disable matching reality.
      const tgRunning = s.tunnel && s.tunnel.running === true;
      const badge = $app.querySelector("#tg-state-badge");
      badge.hidden = false;
      badge.textContent = tgRunning ? "Включён" : "Остановлен";
      badge.className = "tg-state-badge " + (tgRunning ? "tg-state-on" : "tg-state-off");
      const enableBtn = $app.querySelector("#tg-enable");
      const disableBtn = $app.querySelector("#tg-disable");
      enableBtn.disabled = tgRunning;
      disableBtn.disabled = !tgRunning;
      enableBtn.title = tgRunning ? "Туннель уже запущен" : "";
      disableBtn.title = tgRunning ? "" : "Туннель уже остановлен";
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }

    async function tgAction(action, title) {
      let resp;
      try {
        resp = await apiPost("/tunnel/" + action);
      } catch (e) {
        toast("Ошибка: " + e.message, "bad");
        return;
      }
      const expectRunning = (action === "enable");
      // Wait until tunnel state actually matches what we asked for — init
      // script может тратить 1-2 сек на cleanup iptables / conntrack
      // после stop, и /status в это время ещё видит daemon alive. Без
      // polling renderToggles из onDone подхватывает stale=true state,
      // и badge показывает «ВКЛЮЧЁН» через секунду после клика
      // «Отключить» — юзер думает что не сработало.
      async function pollTgState() {
        const deadline = Date.now() + 10000;
        while (Date.now() < deadline) {
          try {
            const s = await apiGet("/status");
            if (s.tunnel && s.tunnel.running === expectRunning) return true;
          } catch (e) {
            // network blip — продолжим
          }
          await new Promise(r => setTimeout(r, 500));
        }
        return false;
      }

      // Backend returns either {ok:true,job:<id>} (async, new) or
      // {ok:true} (sync, old). Если есть job — открываем модалку с
      // live-логом; иначе toast + re-render toggles страницы.
      if (resp && resp.job) {
        openJobModal(title, resp.job, {
          onDone: async () => {
            await pollTgState();
            renderToggles();
          },
        });
      } else {
        toast(title + " — готово");
        await pollTgState();
        renderToggles();
      }
    }
    $app.querySelector("#tg-enable").addEventListener("click", () => tgAction("enable", "Запуск Telegram туннеля"));
    $app.querySelector("#tg-disable").addEventListener("click", () => tgAction("disable", "Остановка Telegram туннеля"));

    // Если уже бежит job (юзер пришёл с другой вкладки) — сразу заблочить
    // только что отрендеренные switches/buttons. Без этого глобал-лок
    // применился бы к старым DOM-элементам которых на этой странице нет.
    _updateGlobalUILock();
  }

  // Toggles that restart nfqws2 under the hood (see actions.sh:toggle_*).
  // After toggling we should wait for the service to come back to "active"
  // before clearing the indicator so the user sees the restart actually
  // completed and didn't silently die. rst-filter (raw iptables) is the
  // only one that doesn't bounce the daemon.
  const TOGGLES_RESTART_SERVICE = { silent_fallback: 1, game_mode: 1, customd: 1, dynamic_ttl: 1 };

  async function toggleClick(key, box) {
    const sw = box.closest(".switch");
    const wanted = box.checked ? "1" : "0";
    sw.classList.add("loading");
    box.disabled = true; // блок UI до завершения, не даём кликать ещё
    const restarts = TOGGLES_RESTART_SERVICE[key] === 1;
    const verb = wanted === "1" ? "Включаю" : "Отключаю";
    const niceName = {
      rst_filter: "RST-фильтр",
      silent_fallback: "Silent fallback",
      game_mode: "Игровой режим",
      customd: "custom.d",
      dynamic_ttl: "Динамический TTL",
    }[key] || key;

    let resp;
    try {
      resp = await apiPost("/toggle/" + TOGGLE_API_NAME[key], { value: wanted });
    } catch (e) {
      box.checked = !box.checked; // revert
      box.disabled = false;
      sw.classList.remove("loading");
      toast("Ошибка: " + e.message, "bad");
      return;
    }
    // Backend async — открываем модалку с live-логом. Состояние switch'а
    // (loading + disabled) держится до onDone — если юзер закрыл модалку
    // раньше, badge в углу позволит снова открыть, а UI блокировка не
    // даст думать что переключение уже применилось.
    openJobModal(verb + " " + niceName, resp.job, {
      onDone: (d) => {
        sw.classList.remove("loading");
        box.disabled = false;
        if (d && d.exit !== 0) {
          // Toggle failed — revert checkbox чтобы UI отражал реальное
          // состояние (старое значение сохранилось в config).
          box.checked = !box.checked;
          toast("Не получилось — вернул как было", "bad");
        } else {
          toast(wanted === "1" ? "Включено" : "Выключено");
        }
        if (restarts) setTimeout(refreshStatus, 500);
      },
    });
  }

  async function waitForServiceActive(timeoutMs) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      try {
        const s = await apiGet("/status");
        if (s.service === "active") return true;
      } catch (e) { /* webpanel itself may briefly hiccup; keep polling */ }
      await new Promise(r => setTimeout(r, 500));
    }
    return false;
  }

  // ---------- Whitelist ----------
  async function renderWhitelist() {
    $app.innerHTML = `
      <h1 class="page-title">Whitelist</h1>
      <div class="card">
        <h3>Исключённые домены</h3>
        <p class="desc">Эти домены не обрабатываются zapret2 (suffix-match). Изменения применяются после перезапуска сервиса.</p>
        <div class="wl-add">
          <input id="wl-input" type="text" placeholder="example.com" autocomplete="off" spellcheck="false">
          <button class="btn btn-primary" id="wl-add-btn">Добавить</button>
        </div>
        <ul class="wl-list" id="wl-list">Загрузка…</ul>
      </div>
    `;
    document.getElementById("wl-add-btn").addEventListener("click", wlAdd);
    document.getElementById("wl-input").addEventListener("keydown", e => {
      if (e.key === "Enter") wlAdd();
    });
    loadWhitelist();
  }

  async function loadWhitelist() {
    const list = document.getElementById("wl-list");
    try {
      const d = await apiGet("/whitelist");
      if (!d.domains.length) {
        list.innerHTML = `<li style="color:var(--text-muted)">(пусто)</li>`;
        return;
      }
      list.innerHTML = d.domains.map(dom => `
        <li><span>${escapeHtml(dom)}</span><button title="Удалить" data-del="${escapeHtml(dom)}">×</button></li>
      `).join("");
      list.querySelectorAll("button[data-del]").forEach(btn => {
        btn.addEventListener("click", () => wlDelete(btn.dataset.del));
      });
    } catch (e) {
      list.innerHTML = `<li style="color:var(--bad)">${escapeHtml(e.message)}</li>`;
    }
  }

  async function wlAdd() {
    const inp = document.getElementById("wl-input");
    const domain = inp.value.trim();
    if (!domain) return;
    try {
      await apiPost("/whitelist/add", { domain });
      inp.value = "";
      toast("Добавлено");
      loadWhitelist();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }
  }

  async function wlDelete(domain) {
    try {
      await apiPost("/whitelist/delete", { domain });
      toast("Удалено");
      loadWhitelist();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }
  }

  // ---------- Extra domains (live hostlist для autocircular) ----------
  async function renderExtraDomains() {
    $app.innerHTML = `
      <h1 class="page-title">Дополнительные домены</h1>
      <div class="card">
        <h3>Live-список для autocircular</h3>
        <p class="desc">
          Здесь — домены, которые z2k будет обрабатывать в дополнение к стандартным RKN/YouTube/Discord-спискам.
          Подбор рабочей стратегии происходит автоматически из существующего пула (~47 стратегий для TCP, 12+ для QUIC),
          результат закрепляется в state.tsv после первого успеха.
          <b>Изменения подхватываются сервисом без перезапуска</b> через несколько секунд.
        </p>
        <div class="wl-add">
          <input id="ed-input" type="text" placeholder="example.com" autocomplete="off" spellcheck="false">
          <button class="btn btn-primary" id="ed-add-btn">Добавить</button>
        </div>
        <ul class="wl-list" id="ed-list">Загрузка…</ul>
      </div>
    `;
    document.getElementById("ed-add-btn").addEventListener("click", edAdd);
    document.getElementById("ed-input").addEventListener("keydown", e => {
      if (e.key === "Enter") edAdd();
    });
    loadExtraDomains();
  }

  async function loadExtraDomains() {
    const list = document.getElementById("ed-list");
    try {
      const d = await apiGet("/extra-domains");
      if (!d.domains.length) {
        list.innerHTML = `<li style="color:var(--text-muted)">(пусто)</li>`;
        return;
      }
      list.innerHTML = d.domains.map(dom => `
        <li><span>${escapeHtml(dom)}</span><button title="Удалить" data-del="${escapeHtml(dom)}">×</button></li>
      `).join("");
      list.querySelectorAll("button[data-del]").forEach(btn => {
        btn.addEventListener("click", () => edDelete(btn.dataset.del));
      });
    } catch (e) {
      list.innerHTML = `<li style="color:var(--bad)">${escapeHtml(e.message)}</li>`;
    }
  }

  async function edAdd() {
    const inp = document.getElementById("ed-input");
    const domain = inp.value.trim();
    if (!domain) return;
    try {
      await apiPost("/extra-domains/add", { domain });
      inp.value = "";
      toast("Добавлено");
      loadExtraDomains();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }
  }

  async function edDelete(domain) {
    try {
      await apiPost("/extra-domains/delete", { domain });
      toast("Удалено");
      loadExtraDomains();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }
  }

  // ---------- Logs ----------
  async function renderLogs() {
    $app.innerHTML = `
      <h1 class="page-title">Логи</h1>
      <div class="card">
        <h3>Сервисный лог</h3>
        <div class="btn-row" style="margin-bottom:10px">
          <button class="btn" id="log-refresh">Обновить</button>
          <button class="btn btn-primary" id="hc-run">Запустить healthcheck</button>
        </div>
        <pre class="log" id="log-view">Загрузка…</pre>
      </div>
    `;
    document.getElementById("log-refresh").addEventListener("click", loadLog);
    document.getElementById("hc-run").addEventListener("click", runHealthcheck);
    loadLog();
  }

  async function loadLog() {
    const el = document.getElementById("log-view");
    try {
      const d = await apiGet("/logs/service?n=200");
      el.textContent = d.log || "(лог пуст)";
    } catch (e) {
      el.textContent = "Ошибка: " + e.message;
    }
  }

  async function runHealthcheck() {
    let resp;
    try {
      resp = await apiPost("/healthcheck/run");
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
      return;
    }
    openJobModal("Healthcheck", resp.job);
  }

  // ---------- Job modal ----------
  // Registry of currently-running jobs. Each entry survives modal close
  // (user clicks "Скрыть") and powers the bottom-right badge — click on
  // the badge re-opens the modal with the same jobId so user can check
  // progress again.
  const _activeJobs = new Map(); // jobId → { title, opts }
  // Background pollers — независимы от модалки. Запускаются при первом
  // openJobModal, продолжают работать даже если юзер закрыл модалку. На
  // done централизованно дёргают onDone, чистят registry и разлочивают UI.
  // Модалка — это просто «вью» подписанное на тик через attachers.
  const _jobPollers = new Map(); // jobId → poller state

  function _renderJobBadges() {
    let container = document.getElementById("job-badges");
    if (!container) {
      container = document.createElement("div");
      container.id = "job-badges";
      container.className = "job-badges";
      document.body.appendChild(container);
    }
    container.innerHTML = "";
    for (const [jobId, info] of _activeJobs) {
      const b = document.createElement("button");
      b.className = "job-badge";
      b.title = "Кликни чтобы открыть лог снова";
      b.innerHTML = `<span class="job-badge-dot"></span>${escapeHtml(info.title)}`;
      b.addEventListener("click", () => openJobModal(info.title, jobId, info.opts));
      container.appendChild(b);
    }
    _updateGlobalUILock();
  }

  // Пока есть хотя бы один active job — блокируем ВСЕ toggle switches и
  // service-кнопки. Любое новое действие порождало бы конкурентный
  // restart сервиса с непредсказуемым итогом.
  //
  // Visual treatment (ui-ux рекомендация 2026-05-24): browser default
  // disabled state слишком subtle — юзер видел просто чуть-серый
  // элемент и думал что нажал «не туда». Применяем per-card locked
  // treatment: каждая карточка с интерактивными элементами получает
  // opacity-reduce + большую пилюлю «⏳ Операция выполняется…» в углу.
  // Это immediately visible без hover. Tooltip остаётся для precision.
  function _updateGlobalUILock() {
    const busy = _activeJobs.size > 0;
    const lockMsg = "Дождитесь завершения текущей операции";
    document.querySelectorAll(".switch input[type=\"checkbox\"]").forEach(cb => {
      if (busy) {
        if (!cb.dataset.lockBackup) {
          cb.dataset.lockBackup = cb.disabled ? "1" : "0";
          cb.disabled = true;
          cb.closest(".switch")?.setAttribute("title", lockMsg);
        }
      } else {
        if (cb.dataset.lockBackup !== undefined) {
          cb.disabled = cb.dataset.lockBackup === "1";
          delete cb.dataset.lockBackup;
          cb.closest(".switch")?.removeAttribute("title");
        }
      }
    });
    document.querySelectorAll("[data-svc], #tg-enable, #tg-disable").forEach(btn => {
      if (busy) {
        if (!btn.dataset.lockBackup) {
          btn.dataset.lockBackup = btn.disabled ? "1" : "0";
          btn.disabled = true;
          btn.setAttribute("title", lockMsg);
        }
      } else {
        if (btn.dataset.lockBackup !== undefined) {
          btn.disabled = btn.dataset.lockBackup === "1";
          delete btn.dataset.lockBackup;
          btn.removeAttribute("title");
        }
      }
    });
    // Card-level treatment: добавим класс на карточки которые содержат
    // блокируемые элементы (toggles или service buttons). CSS дальше
    // дамптит opacity и рисует pill «⏳ Операция выполняется…».
    document.querySelectorAll(".card").forEach(card => {
      const hasLockableControl = card.querySelector(".switch input[type=\"checkbox\"], [data-svc], #tg-enable, #tg-disable");
      if (!hasLockableControl) return;
      if (busy) {
        card.classList.add("card-locked");
      } else {
        card.classList.remove("card-locked");
      }
    });
  }

  // Background poller для одного jobId. Живёт независимо от модалки —
  // поэтому даже если юзер кликнул «Скрыть», job дойдёт до done, UI
  // разлочится, opts.onDone сработает. Модалка просто подписывается через
  // attachers и снимает подписку на close.
  function _startJobPoller(jobId, opts) {
    const existing = _jobPollers.get(jobId);
    if (existing) return existing;
    const state = {
      jobId,
      opts: opts || {},
      stopped: false,
      lastLog: "Запуск…",
      lastData: null,
      consecutiveErrors: 0,
      lastOutageWarn: 0,
      attachers: new Set(),  // (log, done, data) callbacks
    };
    _jobPollers.set(jobId, state);

    const MAX_ERRORS = state.opts.tolerateOutage ? 300 : 5;
    const POLL_OK_MS = 1000;
    const POLL_ERR_MS = state.opts.tolerateOutage ? 2000 : 1000;

    const notify = (log, done, data) => {
      state.lastLog = log;
      if (data) state.lastData = data;
      for (const cb of state.attachers) {
        try { cb(log, done, data); } catch (_) {}
      }
    };

    const finish = (d) => {
      state.stopped = true;
      _jobPollers.delete(jobId);
      _activeJobs.delete(jobId);
      _renderJobBadges();  // также дёрнет _updateGlobalUILock — кнопки разлочатся
      if (typeof state.opts.onDone === "function") {
        try { state.opts.onDone(d); } catch (_) {}
      }
    };

    async function tick() {
      if (state.stopped) return;
      try {
        const d = await apiGet("/job?id=" + encodeURIComponent(jobId));
        const recovered = state.consecutiveErrors > 0;
        state.consecutiveErrors = 0;
        const baseLog = d.log || "(нет вывода)";
        const log = recovered ? baseLog + "\n[панель снова на связи]" : baseLog;
        notify(log, !!d.done, d);
        if (d.done) { finish(d); return; }
      } catch (e) {
        state.consecutiveErrors++;
        if (state.consecutiveErrors >= MAX_ERRORS) {
          const log = state.lastLog + "\n[опрос прерван: " + e.message + "]";
          notify(log, true, { exit: -1, log, done: true });
          finish({ exit: -1, log, done: true });
          return;
        }
        if (state.consecutiveErrors === 2 || (state.consecutiveErrors - state.lastOutageWarn) >= 30) {
          const secsWaiting = Math.round(state.consecutiveErrors * POLL_ERR_MS / 1000);
          const cleanLog = state.lastLog.replace(/\n\[панель временно недоступна.*\]$/g, "");
          const log = cleanLog + `\n[панель временно недоступна, ждём… ${secsWaiting}с]`;
          notify(log, false, null);
          state.lastOutageWarn = state.consecutiveErrors;
        }
      }
      setTimeout(tick, state.consecutiveErrors > 0 ? POLL_ERR_MS : POLL_OK_MS);
    }
    tick();
    return state;
  }

  function openJobModal(title, jobId, opts = {}) {
    // Если уже есть открытая модалка для этого job — не плодить вторую.
    if (document.querySelector(`.modal-backdrop[data-job-id="${jobId}"]`)) {
      return;
    }
    // Зарегистрировать job так чтобы badge отображался даже если юзер
    // закроет модалку. Background poller начнёт жить независимо.
    if (!_activeJobs.has(jobId)) {
      _activeJobs.set(jobId, { title, opts });
      _renderJobBadges();
    }
    const poller = _startJobPoller(jobId, opts);

    const warning = opts.warning ? `<div class="modal-warning">${escapeHtml(opts.warning)}</div>` : "";
    const backdrop = document.createElement("div");
    backdrop.className = "modal-backdrop";
    backdrop.dataset.jobId = jobId;
    backdrop.innerHTML = `
      <div class="modal">
        <h3>${escapeHtml(title)}</h3>
        ${warning}
        <pre class="log" id="job-log">${escapeHtml(poller.lastLog || "Запуск…")}</pre>
        <div class="modal-footer">
          <button class="btn" id="job-close">Скрыть</button>
        </div>
      </div>
    `;
    document.body.appendChild(backdrop);
    const logEl = backdrop.querySelector("#job-log");
    const closeBtn = backdrop.querySelector("#job-close");
    logEl.scrollTop = logEl.scrollHeight;

    // Модалка — подписчик на background poller. На done меняет текст
    // кнопки на «Готово»/«Закрыть». Если юзер закроет до done — мы
    // снимаем подписку, poller продолжит крутиться и сам разлочит UI.
    const onTick = (log, done, d) => {
      logEl.textContent = log;
      logEl.scrollTop = logEl.scrollHeight;
      if (done) {
        const isLockHeld = (log || "").includes("lock held by pid=");
        if (d && d.exit === 0) {
          closeBtn.textContent = "Готово";
        } else if (isLockHeld) {
          closeBtn.textContent = "ОК — обновление уже идёт";
        } else {
          closeBtn.textContent = "Закрыть";
        }
      }
    };
    poller.attachers.add(onTick);

    // Если poller уже завершился до того как мы повторно открыли модалку
    // через badge — мгновенно отрисуем финальное состояние.
    if (poller.stopped && poller.lastData) {
      onTick(poller.lastLog, true, poller.lastData);
    }

    closeBtn.addEventListener("click", () => {
      poller.attachers.delete(onTick);
      backdrop.remove();
    });
  }

  // ---------- Rotator state (Phase 3) ----------
  // Sort state shared across loadState() invocations so a refresh
  // (manual button or after delete) preserves the chosen column.
  // Defaults: profile asc — same order as the previous unsorted view.
  let stateSort = { key: "key", dir: "asc" };

  async function renderState() {
    $app.innerHTML = `
      <h1 class="page-title">Rotator state</h1>
      <div class="card">
        <h3>Выбранные стратегии по доменам</h3>
        <p class="desc">
          autocircular запоминает для каждого ключ/домен какая стратегия
          сейчас используется. Застрял на неработающей — кнопка × слева
          удалит запись, rotator стартанёт с первой стратегии при
          следующей попытке.
        </p>
        <div class="btn-row" style="margin-bottom:10px">
          <button class="btn" id="state-refresh">Обновить</button>
        </div>
        <div id="state-body">Загрузка…</div>
      </div>
    `;
    document.getElementById("state-refresh").addEventListener("click", loadState);
    loadState();
  }

  async function loadState() {
    const body = document.getElementById("state-body");
    if (!body) return;
    try {
      const d = await apiGet("/state");
      if (!d.entries || !d.entries.length) {
        body.innerHTML = `<p style="color:var(--text-muted)">state.tsv пуст или отсутствует</p>`;
        return;
      }
      const nowSec = Math.floor(Date.now() / 1000);

      // Sort a shallow copy — never mutate the cached server response.
      const sorted = d.entries.slice().sort((a, b) => {
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
        return `
          <tr>
            <td>
              <button class="btn btn-danger state-del"
                      data-key="${escapeHtml(e.key)}"
                      data-host="${escapeHtml(e.host)}">×</button>
            </td>
            <td>${escapeHtml(e.key)}</td>
            <td>${escapeHtml(e.host)}</td>
            <td class="state-strategy">${escapeHtml(e.strategy)}</td>
            <td class="state-age">${ageStr}</td>
          </tr>
        `;
      }).join("");

      const arrow = k => stateSort.key === k ? (stateSort.dir === "asc" ? " ↑" : " ↓") : "";
      const th = (k, label) => `<th class="sortable" data-sort="${k}">${label}${arrow(k)}</th>`;
      body.innerHTML = `
        <table class="state-table">
          <thead>
            <tr><th></th>${th("key","Профиль")}${th("host","Домен")}${th("strategy","Стратегия")}${th("age","Возраст")}</tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      `;
      body.querySelectorAll(".state-del").forEach(btn => {
        btn.addEventListener("click", () => stateDelete(btn.dataset.key, btn.dataset.host));
      });
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
          loadState();
        });
      });
    } catch (e) {
      body.innerHTML = `<p style="color:var(--bad)">${escapeHtml(e.message)}</p>`;
    }
  }

  async function stateDelete(key, host) {
    if (!confirm(`Удалить запись rotator для ${host} (${key})?\n\nrotator стартанёт с первой стратегии при следующей попытке.`)) return;
    try {
      await apiPost("/state/delete", { key, host });
      toast("Удалено");
      loadState();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }
  }

  // ---------- Diag (Phase 3) ----------
  async function renderDiag() {
    $app.innerHTML = `
      <h1 class="page-title">Диагностика</h1>
      <div class="card">
        <h3>Сводка z2k-diag</h3>
        <p class="desc">
          Снимок всего, что мы обычно спрашиваем при траблшутинге: версия,
          архитектура, сервис, iptables, tunnel, rotator state, последние
          логи. Скопируй и пришли в чат проекта когда что-то не работает.
        </p>
        <div class="btn-row" style="margin-bottom:10px">
          <button class="btn" id="diag-refresh">Обновить</button>
          <button class="btn" id="diag-copy">Копировать</button>
        </div>
        <pre class="log" id="diag-output">Загрузка…</pre>
      </div>
    `;
    document.getElementById("diag-refresh").addEventListener("click", loadDiag);
    document.getElementById("diag-copy").addEventListener("click", () => {
      const text = document.getElementById("diag-output").textContent;
      if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(() => toast("Скопировано")).catch(() => toast("Не удалось скопировать", "bad"));
      } else {
        toast("Clipboard API недоступен (старый браузер)", "bad");
      }
    });
    loadDiag();
  }

  async function loadDiag() {
    const el = document.getElementById("diag-output");
    if (!el) return;
    el.textContent = "Загрузка…";
    try {
      const d = await apiGet("/diag");
      el.textContent = d.diag || "(пусто)";
    } catch (e) {
      el.textContent = "Ошибка: " + e.message;
    }
  }

  // ---------- Geosite (Phase 3) ----------
  async function renderGeosite() {
    $app.innerHTML = `
      <h1 class="page-title">Geosite</h1>
      <div class="card">
        <h3>runetfreedom/russia-blocked-geosite</h3>
        <p class="desc">
          Production-списки для RKN / YouTube / Discord тянутся из
          runetfreedom каждый день через z2k-scheduler (+ force refresh
          при install). RAM-адаптивный выбор RKN-варианта: ≥900 MB RAM →
          ru-blocked-all (~700k доменов), иначе ru-blocked (~80k).
          Фича всегда включена — toggle удалён в Phase 12.
        </p>
        <div id="geosite-status">Загрузка…</div>
        <div class="btn-row" style="margin-top:12px">
          <button class="btn btn-primary" id="geosite-fetch">Принудительно обновить сейчас</button>
        </div>
      </div>
    `;
    document.getElementById("geosite-fetch").addEventListener("click", geositeFetch);
    loadGeositeStatus();
  }

  async function loadGeositeStatus() {
    const st = document.getElementById("geosite-status");
    if (!st) return;
    try {
      const d = await apiGet("/geosite/status");
      st.innerHTML = `
        <p>
          Статус: <strong>всегда включено</strong><br>
          Production-списков в /opt/zapret2/extra_strats/: <strong>${d.staging_count}</strong>
        </p>
      `;
    } catch (e) {
      st.innerHTML = `<p style="color:var(--bad)">${escapeHtml(e.message)}</p>`;
    }
  }

  async function geositeFetch() {
    let resp;
    try {
      resp = await apiPost("/geosite/update");
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
      return;
    }
    openJobModal("Geosite fetch", resp.job);
    setTimeout(loadGeositeStatus, 2000);
  }

  // renderProbe()/probeStart() removed in r-15 (Phase 1 cleanup of the
  // detection stack). Backend route /probe/run now
  // returns 410 Gone; nav-entry and SPA route are gone so a stale
  // browser cache pointing at #/probe falls through to the dashboard.

  // ---------- Credits ----------
  function renderCredits() {
    $app.innerHTML = `
      <h1 class="page-title">Благодарности</h1>
      <p class="credits-intro">
        Проект живёт благодаря людям, которые вкладывают в него время и ресурсы.
      </p>

      <div class="credits-grid">
        <div class="card credits-card tester-card">
          <div class="credits-badge tester-badge">★ Главный тестировщик</div>
          <div class="credits-name">AusterusJ</div>
          <p class="desc">
            Бесконечные часы живых тестов на роутерах, отлов регрессий ещё
            до релиза и терпение, с которым он проверяет каждую
            экспериментальную стратегию. Без него z2k был бы сильно менее
            стабильным.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">♥ Спонсор проекта</div>
          <div class="credits-name">SupWgeneral</div>
          <p class="desc">
            Материальная поддержка, благодаря которой у z2k есть выделенный
            VPS под Telegram-туннель и возможность развиваться дальше.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">♥ Спонсор проекта</div>
          <div class="credits-name">Alexey</div>
          <p class="desc">
            Материальная поддержка проекта — спасибо за веру в z2k и
            помощь в развитии.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">♥ Спонсор проекта</div>
          <div class="credits-name">Jet_sk_ya</div>
          <p class="desc">
            Материальная поддержка проекта — спасибо за поддержку z2k.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">♥ Спонсор проекта</div>
          <div class="credits-name">Suharik39</div>
          <p class="desc">
            Материальная поддержка проекта — спасибо за поддержку z2k.
          </p>
        </div>
      </div>
    `;
  }

  // ---------- Utils ----------
  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, c => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]));
  }

  // ---------- Boot ----------
  if (!location.hash) location.hash = "#/dashboard";
  navigate();
})();
