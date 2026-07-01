// z2k webpanel frontend — vanilla JS, no build step, no framework.
// Hash-router SPA. ~500 lines, ~15 KB minified.

(() => {
  "use strict";

  const API = "/cgi-bin/api";
  const $app = document.getElementById("app");
  const $toastStack = document.getElementById("toast-stack");
  const $nav = document.getElementById("nav");

  // ---------- Toast (stack, max 3, FIFO eviction, 3.5s auto-dismiss) ----------
  // Skill rule toast-dismiss: 3-5s. New toasts push old ones up; if more
  // than MAX_TOASTS are visible the oldest is evicted immediately. Each
  // toast has its own dismiss timer so a fast burst doesn't double-fire.
  const MAX_TOASTS = 3;
  const TOAST_TTL_MS = 3500;
  function toast(msg, kind = "ok") {
    if (!$toastStack) return;
    const el = document.createElement("div");
    el.className = "toast-item toast-" + kind;
    el.setAttribute("role", "status");
    el.textContent = msg;
    $toastStack.appendChild(el);
    // FIFO eviction: keep at most MAX_TOASTS visible.
    while ($toastStack.children.length > MAX_TOASTS) {
      $toastStack.firstElementChild.remove();
    }
    // Fade-in next frame so transition fires.
    requestAnimationFrame(() => el.classList.add("is-visible"));
    setTimeout(() => {
      el.classList.remove("is-visible");
      el.classList.add("is-leaving");
      setTimeout(() => el.remove(), 250);
    }, TOAST_TTL_MS);
  }

  // ---------- Clipboard (secure-context-safe) ----------
  // navigator.clipboard exists ONLY in a secure context (HTTPS or
  // localhost). The webpanel is served over plain HTTP on a LAN IP
  // (http://192.168.x.x:<port>), which is NOT a secure context, so
  // navigator.clipboard is undefined in EVERY modern browser — not a
  // "old browser" issue. Fall back to the legacy execCommand("copy")
  // path, which works on non-secure origins, via a temporary textarea.
  function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text)
        .then(() => toast("Скопировано"))
        .catch(() => legacyCopy(text));
    } else {
      legacyCopy(text);
    }
  }

  function legacyCopy(text) {
    let ok = false;
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      // Keep it off-screen but selectable; readonly avoids the mobile
      // keyboard popping up. position:fixed avoids a scroll jump.
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "0";
      ta.style.left = "0";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      ta.setSelectionRange(0, text.length); // iOS needs the explicit range
      ok = document.execCommand("copy");
      document.body.removeChild(ta);
    } catch (e) {
      ok = false;
    }
    toast(ok ? "Скопировано" : "Не удалось скопировать", ok ? "ok" : "bad");
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
  // Active route highlight для всех `<a>` в #nav (primary + overflow).
  // Highlight «...» кнопки делается через CSS :has() — не нужен JS sync.
  // Page title — per-route, формат "PageName · Z2K" (GitHub/Linear style).
  const ROUTE_TITLES = {
    dashboard:       "Дашборд",
    toggles:         "Режимы",
    whitelist:       "Whitelist",
    "extra-domains": "Доп. домены",
    state:           "Rotator",
    logs:            "Логи",
    diag:            "Диагностика",
    geosite:         "Geosite",
    credits:         "Благодарности",
  };
  function navigate() {
    const hash = location.hash.replace(/^#\//, "") || "dashboard";
    const name = routes[hash] ? hash : "dashboard";
    for (const a of $nav.querySelectorAll("a")) {
      a.classList.toggle("active", a.dataset.route === name);
    }
    const pageTitle = ROUTE_TITLES[name] || "antiDPI для Keenetic";
    document.title = `${pageTitle} · Z2K`;
    closeNavMore();
    $app.innerHTML = "";
    routes[name]();
  }
  window.addEventListener("hashchange", navigate);

  // ---------- Sidebar collapse (desktop only) ----------
  // localStorage key z2k-sidebar = "expanded" | "collapsed".
  // Sidebar только на desktop (≥768px / >500h height); на mobile drawer
  // показывает все items — collapse button скрыт.
  const SIDEBAR_KEY = "z2k-sidebar";
  function initSidebar() {
    const btn = document.getElementById("sidebar-collapse");
    if (!btn) return;
    try {
      const saved = localStorage.getItem(SIDEBAR_KEY);
      if (saved === "collapsed") document.body.setAttribute("data-sidebar", "collapsed");
    } catch (_) {}
    btn.addEventListener("click", () => {
      const isCollapsed = document.body.getAttribute("data-sidebar") === "collapsed";
      if (isCollapsed) {
        document.body.removeAttribute("data-sidebar");
        try { localStorage.setItem(SIDEBAR_KEY, "expanded"); } catch (_) {}
        btn.setAttribute("aria-label", "Свернуть боковую панель");
      } else {
        document.body.setAttribute("data-sidebar", "collapsed");
        try { localStorage.setItem(SIDEBAR_KEY, "collapsed"); } catch (_) {}
        btn.setAttribute("aria-label", "Развернуть боковую панель");
      }
    });
  }
  // No-op stub — closeNavMore вызывается в navigate(), удалили overflow concept
  function closeNavMore() {}

  // ---------- Dashboard ----------
  async function renderDashboard() {
    $app.innerHTML = `
      <div id="update-banner" hidden></div>
      <h1 class="page-title">Дашборд</h1>
      <div class="card" id="status-card">
        <h3>Состояние <span class="status-spinner" id="status-spin" hidden></span></h3>
        <div class="status-grid" id="status-grid">${skeletonBlocks(7)}</div>
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
          ${pending.length > 0 ? `<button class="btn btn-disclosure" id="upd-changelog-btn" aria-expanded="false"><span>Что нового</span>${_icons.chevronDown}</button>` : ""}
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
          clBtn.classList.toggle("is-open", !open);
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
          <details class="upd-details disclosure">
            <summary>Подробнее</summary>
            <div class="disclosure-body"><div class="upd-desc-full">${escapeHtml(desc)}</div></div>
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
    grid.innerHTML = cells.map(c => {
      const icon = statusIcon(c.kind);
      return `<div class="status-cell ${c.kind}"><div class="label">${c.label}</div><div class="value">${icon ? `<span class="status-ico">${icon}</span>` : ""}${c.value}</div></div>`;
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
    { key: "rst_filter", name: "RST-фильтр (пассивный DPI)",
      desc: "Блокирует поддельные TCP RST от ТСПУ через nfqws — 3 эвристики (pre-response RST, multi-RST burst, TTL mismatch). Не требует kernel-модулей. Может задеть редкие edge cases у Cloudflare — отключите если заметили проблемы с reconnect'ом." },
    { key: "silent_fallback", name: "Silent fallback РКН",
      desc: "Детект «тихих чёрных дыр» РКН. Осторожно — возможны ложные срабатывания." },
    { key: "game_mode", name: "Игровой режим",
      desc: "TCP/UDP bypass для игровых сервисов (стандартный профиль — single-strategy bypass на игровом ipset). Для отката на старый ротатор: GAME_PROFILE=legacy в /opt/zapret2/config." },
    { key: "customd", name: "Скрипты custom.d",
      desc: "Дополнительные daemons из init.d/custom.d (50-stun4all, 50-discord-media)." },
    { key: "dynamic_ttl", name: "Динамический TTL",
      desc: "Инжекция фиксированного TTL в исходящий трафик — обход обнаружения tethering у мобильных операторов (МТС/Билайн с телефонной симкой). Если у роутера уже настроен NDM TTL-fix — отключи, чтобы избежать конфликта." },
    { key: "stats", name: "Сбор статистики (анонимно)",
      desc: "Раз в сутки шлёт на сервер проекта обезличенный срез: какая стратегия активна в каждом пуле и как долго держится — чтобы двигать лучшие стратегии в начало. НЕ уходит: сайты/домены, IP, провайдер, регион, любой ID устройства. Только: имя пула, номер стратегии, время удержания. Выключите, если не хотите участвовать." },
    { key: "ppe", name: "Аппаратный offload: per-flow исключение",
      desc: "На Keenetic (MediaTek) аппаратный ускоритель уводит поток в железо после первого пакета, и роутер не видит повторные ClientHello — стратегия залипает для блокировок без RST (mailsuite и т.п.). Эта опция держит окно рукопожатия на CPU только для нужных портов (родной firmware-механизм -j PPE), поэтому подбор стратегии снова работает, а общий трафик остаётся ускоренным. Работает только на совместимых Keenetic. Выключите, чтобы вернуть прежнее поведение." },
  ];
  const TOGGLE_API_NAME = {
    rst_filter: "rst-filter",
    silent_fallback: "silent-fallback",
    game_mode: "game-mode",
    customd: "customd",
    dynamic_ttl: "dynamic-ttl",
    stats: "stats",
    ppe: "ppe",
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
      <div class="card" id="policy-card">
        <h3>Политика доступа Keenetic</h3>
        <label class="field">
          <span class="field-label">Имя политики</span>
          <input id="policy-name" type="text" placeholder="nfqws"
                 inputmode="text" autocomplete="off" autocapitalize="off"
                 spellcheck="false" autocorrect="off" maxlength="32">
        </label>
        <div class="policy-status" id="policy-status">
          <span class="policy-status-dot"></span>
          <span class="policy-status-text">Проверка…</span>
        </div>
        <div class="field-label" style="margin-top:14px">Применяется к устройствам</div>
        <div class="segmented" id="policy-mode" role="radiogroup" aria-label="Применяется к устройствам">
          <button type="button" class="seg-btn" data-exclude="0" role="radio" aria-checked="true">Только в политике</button>
          <button type="button" class="seg-btn" data-exclude="1" role="radio" aria-checked="false">Все, кроме политики</button>
        </div>
        <div class="btn-row" style="margin-top:14px;justify-content:space-between;align-items:center">
          <details class="policy-help disclosure">
            <summary>Как создать политику</summary>
            <div class="disclosure-body">
              <div class="how-to">
                <ol class="steps">
                  <li>
                    <span class="step-num">1</span>
                    <div class="step-body">
                      <div class="step-title">Откройте раздел приоритетов</div>
                      <div class="step-desc">В админке Keenetic: <b>Интернет → Приоритеты подключений</b>.</div>
                    </div>
                  </li>
                  <li>
                    <span class="step-num">2</span>
                    <div class="step-body">
                      <div class="step-title">Создайте политику</div>
                      <div class="step-desc">Вкладка <b>«Конфигурация политик»</b> → кнопка <b>«+ Добавить политику»</b>.</div>
                    </div>
                  </li>
                  <li>
                    <span class="step-num">3</span>
                    <div class="step-body">
                      <div class="step-title">Задайте имя</div>
                      <div class="step-desc">Имя должно <b>точно совпадать</b> с тем, что введено выше — по умолчанию <code>nfqws</code>. Регистр учитывается.</div>
                    </div>
                  </li>
                  <li>
                    <span class="step-num">4</span>
                    <div class="step-body">
                      <div class="step-title">Выберите подключение</div>
                      <div class="step-desc">В колонке «Подключение» оставьте галки на тех интерфейсах, которыми пользуются эти устройства (обычно ваше текущее подключение к интернету).</div>
                    </div>
                  </li>
                  <li>
                    <span class="step-num">5</span>
                    <div class="step-body">
                      <div class="step-title">Привяжите устройства</div>
                      <div class="step-desc">Вкладка <b>«Привязка устройств к профилям»</b> → включите <b>«Показать все объекты»</b> → перетащите нужные устройства на созданную политику.</div>
                    </div>
                  </li>
                  <li>
                    <span class="step-num">6</span>
                    <div class="step-body">
                      <div class="step-title">Примените у нас</div>
                      <div class="step-desc">Вернитесь сюда и нажмите <b>«Сохранить и применить»</b>. Статус выше должен загореться зелёным.</div>
                    </div>
                  </li>
                </ol>
                <div class="how-to-note">
                  <b>Нет раздела «Приоритеты подключений»?</b><br>
                  Установите компонент: <b>Управление → Общие настройки → Изменить набор компонентов</b>, найдите «Приоритеты подключений (PBR)» и установите. После перезагрузки роутера раздел появится в меню «Интернет».
                </div>
              </div>
            </div>
          </details>
          <button class="btn btn-primary" id="policy-save-btn">Сохранить и применить</button>
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

    // ----- Policy access section -----
    const nameInput = $app.querySelector("#policy-name");
    const statusEl  = $app.querySelector("#policy-status");
    const segGroup  = $app.querySelector("#policy-mode");
    const saveBtn   = $app.querySelector("#policy-save-btn");
    const NAME_RE   = /^[A-Za-z0-9_-]{0,32}$/;

    function setPolicyStatus(state, text) {
      // state: good | warn | muted | error
      statusEl.dataset.state = state;
      statusEl.querySelector(".policy-status-text").textContent = text;
    }
    function setPolicyMode(exclude) {
      segGroup.querySelectorAll(".seg-btn").forEach(b => {
        const on = b.dataset.exclude === String(exclude);
        b.classList.toggle("seg-on", on);
        b.setAttribute("aria-checked", String(on));
      });
    }
    async function loadPolicyStatus() {
      try {
        const d = await apiGet("/policy/status");
        nameInput.value = d.name || "";
        setPolicyMode(d.exclude === "1" ? 1 : 0);
        if (!d.name) {
          setPolicyStatus("muted", "Поле пусто — фильтр выключен");
        } else if (d.exists === 1 || d.exists === true) {
          setPolicyStatus("good", `Политика «${d.name}» найдена в Keenetic`);
        } else {
          setPolicyStatus("warn", `Политика «${d.name}» не найдена — фильтр игнорируется, обрабатывается весь трафик`);
        }
      } catch (e) {
        setPolicyStatus("error", "Ошибка: " + e.message);
      }
    }
    loadPolicyStatus();

    // Validate + (опционально) повторный status check на blur
    nameInput.addEventListener("blur", () => {
      const v = nameInput.value.trim();
      if (!NAME_RE.test(v)) {
        setPolicyStatus("error", "Имя: только буквы/цифры/«_»/«-», 1–32 символа");
        return;
      }
      // Запрос свежего status'а с currently-saved конфигом — input не сохранит
      // ничего пока юзер не нажмёт «Сохранить». Если хочется live-проверки
      // existence без save — на будущее можно добавить отдельный endpoint
      // /policy/check?name=. Сейчас: оставляем статус до Save.
    });

    segGroup.addEventListener("click", (e) => {
      const btn = e.target.closest(".seg-btn");
      if (!btn) return;
      setPolicyMode(parseInt(btn.dataset.exclude, 10));
    });

    saveBtn.addEventListener("click", async () => {
      const v = nameInput.value.trim();
      if (!NAME_RE.test(v)) {
        toast("Имя политики: только буквы/цифры/«_»/«-», 1–32 символа", "bad");
        nameInput.focus();
        return;
      }
      const exclude = segGroup.querySelector(".seg-btn.seg-on")?.dataset.exclude || "0";
      let resp;
      try {
        resp = await apiPost("/policy/save", { name: v, exclude });
      } catch (e) {
        toast("Ошибка: " + e.message, "bad");
        return;
      }
      if (resp && resp.job) {
        openJobModal("Применение политики доступа", resp.job, {
          onDone: () => { setTimeout(loadPolicyStatus, 500); }
        });
      } else {
        toast("Применено");
        loadPolicyStatus();
      }
    });

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
  const TOGGLES_RESTART_SERVICE = { silent_fallback: 1, game_mode: 1, customd: 1, dynamic_ttl: 1, ppe: 1 };

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
      stats: "Сбор статистики",
      ppe: "PPE de-offload",
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
        <p class="desc">Эти домены не обрабатываются zapret2 (suffix-match). <b>Изменения подхватываются сервисом без перезапуска</b> через несколько секунд.</p>
        <div class="wl-add">
          <label class="field">
            <span class="field-label">Новый домен</span>
            <input id="wl-input" type="text" placeholder="example.com"
                   inputmode="url" autocomplete="off" autocapitalize="off"
                   spellcheck="false" autocorrect="off">
          </label>
          <button class="btn btn-primary" id="wl-add-btn">Добавить</button>
          <button class="btn" id="wl-import-btn" title="Импорт списка из текстового файла (одна строка — один домен)">Импорт из файла</button>
          <input type="file" id="wl-import-file" accept=".txt,text/plain" hidden>
        </div>
        <ul class="wl-list" id="wl-list">${skeletonLines(5)}</ul>
      </div>
    `;
    document.getElementById("wl-add-btn").addEventListener("click", wlAdd);
    document.getElementById("wl-input").addEventListener("keydown", e => {
      if (e.key === "Enter") wlAdd();
    });
    document.getElementById("wl-import-btn").addEventListener("click", () => {
      document.getElementById("wl-import-file").click();
    });
    document.getElementById("wl-import-file").addEventListener("change", wlImport);
    loadWhitelist();
  }

  async function wlImport(e) {
    const file = e.target.files && e.target.files[0];
    e.target.value = ""; // allow re-select same file
    if (!file) return;
    // Safeguard: lighttpd default body limit ~ 2 MB; держим запас.
    if (file.size > 1024 * 1024) {
      toast("Файл слишком большой (>1 МБ)", "bad");
      return;
    }
    let text;
    try { text = await file.text(); }
    catch (err) { toast("Не удалось прочитать файл: " + err.message, "bad"); return; }
    try {
      const r = await fetch(API + "/whitelist/import", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "text/plain;charset=utf-8" },
        body: text,
      });
      const data = await r.json().catch(() => ({ ok: false, error: `${r.status}` }));
      if (!r.ok || !data.ok) throw new Error(data.error || `${r.status}`);
      const parts = [`+${data.added}`];
      if (data.skipped_duplicate > 0) parts.push(`дублей: ${data.skipped_duplicate}`);
      if (data.skipped_invalid > 0) parts.push(`невалидных: ${data.skipped_invalid}`);
      toast("Импорт: " + parts.join(", "));
      loadWhitelist();
    } catch (err) {
      toast("Ошибка импорта: " + err.message, "bad");
    }
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
        <li><span>${escapeHtml(dom)}</span><button class="btn-icon" title="Удалить" aria-label="Удалить ${escapeHtml(dom)}" data-del="${escapeHtml(dom)}">${_icons.close}</button></li>
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
          <label class="field">
            <span class="field-label">Новый домен</span>
            <input id="ed-input" type="text" placeholder="example.com"
                   inputmode="url" autocomplete="off" autocapitalize="off"
                   spellcheck="false" autocorrect="off">
          </label>
          <button class="btn btn-primary" id="ed-add-btn">Добавить</button>
        </div>
        <ul class="wl-list" id="ed-list">${skeletonLines(5)}</ul>
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
        <li><span>${escapeHtml(dom)}</span><button class="btn-icon" title="Удалить" aria-label="Удалить ${escapeHtml(dom)}" data-del="${escapeHtml(dom)}">${_icons.close}</button></li>
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
        <pre class="log" id="log-view"><span class="skel-text">${skeletonLines(8)}</span></pre>
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
    // Dimmed cards — signal что заблокировано на каждой карточке с
    // контролами. Без overlay'а — content виден полностью.
    document.querySelectorAll(".card").forEach(card => {
      const hasLockableControl = card.querySelector(".switch input[type=\"checkbox\"], [data-svc], #tg-enable, #tg-disable");
      if (!hasLockableControl) return;
      if (busy) card.classList.add("card-locked");
      else card.classList.remove("card-locked");
    });

    // Single page-level pill в строке h1.page-title — не дублируется на
    // каждую карточку, не оверлайит content. Job-badge в углу показывает
    // конкретное имя операции; этот pill — общий statement что страница
    // в busy состоянии.
    const pageTitle = document.querySelector(".page-title");
    if (pageTitle) {
      let pill = pageTitle.querySelector(":scope > .page-locked-pill");
      if (busy && !pill) {
        pill = document.createElement("span");
        pill.className = "page-locked-pill";
        pill.setAttribute("aria-hidden", "true");
        pill.innerHTML = _icons.hourglass + "<span>Операция выполняется…</span>";
        pageTitle.appendChild(pill);
      } else if (!busy && pill) {
        pill.remove();
      }
    }
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
  let statePools = {};   // key -> strategy-pool size, from GET /pools (live nfqws2)

  async function renderState() {
    $app.innerHTML = `
      <h1 class="page-title">Rotator state</h1>
      <div class="card">
        <h3>Discord войс — выбор стратегии</h3>
        <p class="desc">
          Голосовой пул Discord (STUN) не привязан к домену и сам по себе в
          таблице ниже не появляется. Здесь можно выбрать стратегию вручную или
          заморозить рабочую, чтобы ротатор её не менял.
        </p>
        <div class="btn-row" id="discord-voice-controls">${skeletonLines(1)}</div>
      </div>
      <div class="card">
        <h3>Выбранные стратегии по доменам</h3>
        <p class="desc">
          autocircular запоминает для каждого ключ/домен текущую стратегию.
          В каждой строке:
        </p>
        <ul class="desc" style="margin:4px 0 10px 18px;padding:0">
          <li><b>выпадающий список</b> — выбрать стратегию вручную (ротация
              продолжится с неё, удобно проскочить нерабочую);</li>
          <li><b>замок в столбце «Заморозка»</b> — открытый замок значит идёт
              авторотация; нажмите, чтобы заморозить (замок закроется) и ротатор
              перестанет менять стратегию; нажмите закрытый замок — разморозить;</li>
          <li><b>× слева</b> — удалить запись (старт с первой стратегии).</li>
        </ul>
        <div class="btn-row" style="margin-bottom:10px">
          <button class="btn" id="state-refresh">Обновить</button>
          <button class="btn btn-danger" id="state-clear-all">Удалить все записи</button>
        </div>
        <div id="state-body">${skeletonLines(6)}</div>
      </div>
    `;
    document.getElementById("state-refresh").addEventListener("click", loadState);
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

  async function loadState() {
    const body = document.getElementById("state-body");
    if (!body) return;
    try {
      // /pools may fail if nfqws2 isn't running — tolerate it (dropdowns then
      // fall back to the row's own strategy as the max).
      const [d, poolsResp] = await Promise.all([
        apiGet("/state"),
        apiGet("/pools").catch(() => ({ pools: {} })),
      ]);
      statePools = (poolsResp && poolsResp.pools) || {};
      const entries = d.entries || [];

      // Discord-voice panel first — it must populate even with empty rotator state.
      renderDiscordVoicePanel(entries);

      if (!entries.length) {
        body.innerHTML = `<p style="color:var(--text-muted)">состояние ротатора пусто (стратегии ещё не закреплены)</p>`;
        return;
      }
      const nowSec = Math.floor(Date.now() / 1000);
      // Sort a shallow copy — never mutate the cached server response.
      const sorted = entries.slice().sort((a, b) => {
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
        // data-label attrs feed the mobile card layout (CSS pseudo-elements)
        return `
          <tr${frozen ? ' style="background:rgba(120,140,255,0.10)"' : ''}>
            <td data-label="">
              <button class="btn btn-danger btn-icon state-del"
                      title="Удалить запись rotator"
                      aria-label="Удалить ${escapeHtml(e.host)}"
                      data-key="${escapeHtml(e.key)}"
                      data-host="${escapeHtml(e.host)}">${_icons.close}</button>
            </td>
            <td data-label="Профиль">${escapeHtml(e.key)}</td>
            <td data-label="Домен">${escapeHtml(e.host)}</td>
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
      body.innerHTML = `
        <table class="state-table">
          <thead>
            <tr><th></th>${th("key","Профиль")}${th("host","Домен")}${th("strategy","Стратегия")}<th>Заморозка</th>${th("age","Возраст")}</tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
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

  async function stateClearAll() {
    if (!confirm("Удалить ВСЕ записи rotator?\n\nВесь сохранённый state очистится: каждый домен стартанёт с первой стратегии при следующей попытке, заморозки тоже снимутся. Сервис перезапускать не нужно.")) return;
    try {
      await apiPost("/state/clear", {});
      toast("Весь state очищен");
      loadState();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
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
        <pre class="log" id="diag-output"><span class="skel-text">${skeletonLines(10)}</span></pre>
      </div>
    `;
    document.getElementById("diag-refresh").addEventListener("click", loadDiag);
    document.getElementById("diag-copy").addEventListener("click", () => {
      copyToClipboard(document.getElementById("diag-output").textContent);
    });
    loadDiag();
  }

  async function loadDiag() {
    const el = document.getElementById("diag-output");
    if (!el) return;
    el.innerHTML = `<span class="skel-text">${skeletonLines(10)}</span>`;
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
        <div id="geosite-status">${skeletonLines(2)}</div>
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
          <div class="credits-badge tester-badge">${_icons.star} Главный тестировщик</div>
          <div class="credits-name">AusterusJ</div>
          <p class="desc">
            Бесконечные часы живых тестов на роутерах, отлов регрессий ещё
            до релиза и терпение, с которым он проверяет каждую
            экспериментальную стратегию. Без него z2k был бы сильно менее
            стабильным.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">SupWgeneral</div>
          <p class="desc">
            Материальная поддержка, благодаря которой у z2k есть выделенный
            VPS под Telegram-туннель и возможность развиваться дальше.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Alexey</div>
          <p class="desc">
            За каждым стабильным релизом стоит не только код — стоят и
            спонсоры вроде Alexey, которые держат проект на плаву между
            апдейтами.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Jet_sk_ya</div>
          <p class="desc">
            Без таких людей z2k оставался бы pet-проектом одного-двух
            разработчиков. Спасибо, что вкладываешь в инструмент, которым
            пользуются сотни.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Suharik39</div>
          <p class="desc">
            Без таких сторонников z2k быстро остался бы без независимого
            источника финансирования. Спасибо за вклад в свободу
            пользователей.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">ZyaK&lt;-</div>
          <p class="desc">
            За весомый вклад в развитие проекта и веру в свободный интернет.
            Спасибо, что держишь Z2K на плаву!
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Алексей Стрельцов</div>
          <p class="desc">
            Поддержка, которая приходит тихо и по делу: благодаря таким, как
            Алексей, туннель остаётся бесплатным для всех, а проект —
            независимым от рекламы и площадок. Спасибо за веру в свободный
            интернет.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Diman86RUS</div>
          <p class="desc">
            Новый спонсор проекта. Благодаря таким людям, как Diman86RUS, z2k
            продолжает развиваться, а Telegram-туннель остаётся бесплатным для
            всех. Спасибо, что вкладываешься в свободный интернет!
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

  // Inline SVG icons — single source of truth.
  // Skill compliance (Common Rules > Icons & Visual Elements):
  //   - Consistent Icon Sizing: all stroke icons = 16×16 (one size token).
  //     Filled glyphs (star, heart) also 16×16 для visual parity.
  //   - Stroke Consistency: stroke-width=2 везде (skill: "1.5px or 2px").
  //   - Style: outline/stroke for UI icons, fill only for award badges
  //     (star/heart on Credits) — clear semantic separation.
  //   - SVG vector, не emoji (no-emoji-icons rule).
  // class="icon" + .icon-sm modifier для 12px inline-в-pill контекстов.
  const _icons = {
    close:        '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>',
    chevronDown:  '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 9 12 15 18 9"/></svg>',
    arrowUp:      '<svg class="icon icon-sm" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 15 12 9 18 15"/></svg>',
    arrowDown:    '<svg class="icon icon-sm" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 9 12 15 18 9"/></svg>',
    star:         '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26"/></svg>',
    heart:        '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
    statusGood:   '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>',
    statusWarn:   '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>',
    statusBad:    '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>',
    hourglass:    '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 22h14M5 2h14M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22M17 2v4.172a2 2 0 0 1-.586 1.414L12 12 7.586 7.586A2 2 0 0 1 7 6.172V2"/></svg>',
    // Lucide lock-keyhole / lock-keyhole-open (MIT, no attribution). Closed = frozen,
    // open = auto-rotating. Drawn at 17px to read a touch larger than the row text.
    lockClosed:   '<svg class="icon" viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="10" width="18" height="12" rx="2"/><path d="M7 10V7a5 5 0 0 1 10 0v3"/><circle cx="12" cy="16" r="1"/></svg>',
    lockOpen:     '<svg class="icon" viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="10" width="18" height="12" rx="2"/><path d="M7 10V7a5 5 0 0 1 9.33-2.5"/><circle cx="12" cy="16" r="1"/></svg>',
  };

  // Status icon picker for the dashboard cells. "" kind = no icon (neutral).
  function statusIcon(kind) {
    if (kind === "good") return _icons.statusGood;
    if (kind === "warn") return _icons.statusWarn;
    if (kind === "bad")  return _icons.statusBad;
    return "";
  }

  // Skeleton placeholders for >300ms fetches (Skill rule: loading-states).
  // skeletonLines(n) — variable-width pulsing bars; skeletonBlocks(n) — taller
  // cards for grid/table loads. Both reserve space so the page doesn't jump
  // when real content arrives (Core Web Vitals: CLS).
  function skeletonLines(n = 4) {
    const widths = ["68%", "92%", "54%", "80%", "44%", "76%"];
    let out = "";
    for (let i = 0; i < n; i++) {
      out += `<div class="skel-line" style="width:${widths[i % widths.length]}"></div>`;
    }
    return out;
  }
  function skeletonBlocks(n = 4) {
    let out = "";
    for (let i = 0; i < n; i++) out += `<div class="skel-block"></div>`;
    return out;
  }

  // ---------- Theme switcher ----------
  // Tri-state: "light" | "dark" | "auto" (default). "auto" слушает
  // prefers-color-scheme и обновляется live при системном переключении.
  // No-FOUC bootstrap (inline <script> в <head>) уже выставил
  // data-theme до загрузки CSS — здесь только UI sync + listeners.
  const THEME_KEY = "z2k-theme";
  function _getThemeMode() {
    try { return localStorage.getItem(THEME_KEY) || "auto"; }
    catch (_) { return "auto"; }
  }
  function _applyTheme() {
    const mode = _getThemeMode();
    const resolved = mode === "auto"
      ? (window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark")
      : mode;
    if (resolved === "light") {
      document.documentElement.setAttribute("data-theme", "light");
    } else {
      document.documentElement.removeAttribute("data-theme");
    }
    // Sync button aria-pressed.
    document.querySelectorAll("[data-theme-btn]").forEach(b => {
      b.setAttribute("aria-pressed", String(b.dataset.themeBtn === mode));
    });
  }
  function _setTheme(mode) {
    try { localStorage.setItem(THEME_KEY, mode); } catch (_) {}
    _applyTheme();
  }
  function initTheme() {
    document.querySelectorAll("[data-theme-btn]").forEach(b => {
      b.addEventListener("click", () => _setTheme(b.dataset.themeBtn));
    });
    // Live-react на смену system theme когда юзер в "auto".
    const mq = window.matchMedia("(prefers-color-scheme: light)");
    if (mq.addEventListener) {
      mq.addEventListener("change", () => {
        if (_getThemeMode() === "auto") _applyTheme();
      });
    }
    _applyTheme();
  }

  // ---------- Hamburger drawer (mobile) ----------
  // На мобиле topbar = [z2k] _ [☰]. Клик — open right-slide drawer.
  // Содержит все nav links + theme-toggle. Closes на: click outside,
  // click backdrop, click nav link, Escape.
  function initDrawer() {
    const btn = document.getElementById("menu-toggle");
    const nav = document.getElementById("nav");
    const backdrop = document.getElementById("menu-backdrop");
    const theme = document.querySelector(".topbar > .theme-toggle");
    if (!btn || !nav || !backdrop) return;

    function openDrawer() {
      nav.classList.add("menu-open");
      if (theme) theme.classList.add("menu-open");
      backdrop.hidden = false;
      requestAnimationFrame(() => backdrop.classList.add("menu-open"));
      btn.setAttribute("aria-expanded", "true");
      document.body.style.overflow = "hidden";
    }
    function closeDrawer() {
      nav.classList.remove("menu-open");
      if (theme) theme.classList.remove("menu-open");
      backdrop.classList.remove("menu-open");
      btn.setAttribute("aria-expanded", "false");
      document.body.style.overflow = "";
      setTimeout(() => { backdrop.hidden = true; }, 220);
    }

    btn.addEventListener("click", () => {
      if (nav.classList.contains("menu-open")) closeDrawer();
      else openDrawer();
    });
    backdrop.addEventListener("click", closeDrawer);
    // X-кнопка в drawer header — visible close affordance (skill: modal-escape)
    const xBtn = document.getElementById("nav-drawer-close");
    if (xBtn) xBtn.addEventListener("click", closeDrawer);
    // Close on nav link click (mobile UX: kbgo куда нажал)
    nav.addEventListener("click", (e) => {
      if (e.target.closest("a[data-route]")) closeDrawer();
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && nav.classList.contains("menu-open")) closeDrawer();
    });
  }

  // ---------- Boot ----------
  initTheme();
  initSidebar();
  initDrawer();
  if (!location.hash) location.hash = "#/dashboard";
  navigate();
})();
