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
      <h1 class="page-title">Дашборд</h1>
      <div class="card" id="status-card">
        <h3>Состояние</h3>
        <div class="status-grid" id="status-grid">Загрузка…</div>
      </div>
      <div class="card">
        <h3>Управление сервисом</h3>
        <p class="desc">Запуск, остановка и перезапуск nfqws2.</p>
        <div class="btn-row">
          <button class="btn btn-primary" data-svc="start">Запустить</button>
          <button class="btn" data-svc="restart">Перезапустить</button>
          <button class="btn btn-danger" data-svc="stop">Остановить</button>
        </div>
      </div>
    `;

    $app.querySelectorAll("[data-svc]").forEach(btn => {
      btn.addEventListener("click", async () => {
        btn.disabled = true;
        try {
          await apiPost("/service/" + btn.dataset.svc);
          toast("Сервис: " + btn.dataset.svc);
          setTimeout(refreshStatus, 800);
        } catch (e) {
          toast("Ошибка: " + e.message, "bad");
        } finally {
          btn.disabled = false;
        }
      });
    });

    refreshStatus();
  }

  async function refreshStatus() {
    const grid = document.getElementById("status-grid");
    if (!grid) return;
    try {
      const s = await apiGet("/status");
      const cells = [
        { label: "Установлен", value: s.installed ? "Да" : "Нет", kind: s.installed ? "good" : "bad" },
        { label: "Сервис", value: fmtSvc(s.service), kind: s.service === "active" ? "good" : (s.service === "stopped" ? "warn" : "bad") },
        { label: "Туннель ТГ", value: s.tunnel?.running ? "работает" : "остановлен", kind: s.tunnel?.running ? "good" : "warn" },
        { label: "Austerusj", value: bool(s.toggles.austerusj), kind: s.toggles.austerusj === "1" ? "warn" : "" },
        { label: "RST фильтр", value: bool(s.toggles.rst_filter), kind: s.toggles.rst_filter === "1" ? "good" : "" },
        { label: "Silent fallback", value: bool(s.toggles.silent_fallback), kind: s.toggles.silent_fallback === "1" ? "warn" : "" },
        { label: "Игровой режим", value: bool(s.toggles.game_mode), kind: s.toggles.game_mode === "1" ? "good" : "" },
        { label: "custom.d", value: bool(s.toggles.customd), kind: "" },
      ];
      grid.innerHTML = cells.map(c =>
        `<div class="status-cell ${c.kind}"><div class="label">${c.label}</div><div class="value">${c.value}</div></div>`
      ).join("");
    } catch (e) {
      grid.innerHTML = `<div class="status-cell bad"><div class="label">Ошибка</div><div class="value">${escapeHtml(e.message)}</div></div>`;
    }
  }

  function bool(v) { return v === "1" ? "Вкл" : "Выкл"; }
  function fmtSvc(s) {
    return { active: "работает", stopped: "остановлен", not_installed: "не установлен" }[s] || s;
  }

  // ---------- Toggles ----------
  const TOGGLE_DEFS = [
    { key: "austerusj", name: "Режим Austerusj (без хостлистов)",
      desc: "Простые стратегии ко ВСЕМУ трафику 80/443. Заменяет все профили z2k." },
    { key: "rst_filter", name: "RST фильтр (пассивный DPI)",
      desc: "Блокирует поддельные TCP RST от ТСПУ через iptables raw/PREROUTING." },
    { key: "silent_fallback", name: "Silent fallback РКН",
      desc: "Детект «тихих чёрных дыр» РКН. Осторожно — возможны ложные срабатывания." },
    { key: "game_mode", name: "Игровой режим (Roblox и др.)",
      desc: "UDP bypass для игровых портов 1024-65535 через z2k_game_udp." },
    { key: "customd", name: "Скрипты custom.d",
      desc: "Дополнительные daemons из init.d/custom.d (50-stun4all, 50-discord-media)." },
  ];
  const TOGGLE_API_NAME = {
    austerusj: "austerusj",
    rst_filter: "rst-filter",
    silent_fallback: "silent-fallback",
    game_mode: "game-mode",
    customd: "customd",
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
        <h3>Telegram туннель</h3>
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
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }

    $app.querySelector("#tg-enable").addEventListener("click", async () => {
      try { await apiPost("/tunnel/enable"); toast("Туннель запущен"); }
      catch (e) { toast("Ошибка: " + e.message, "bad"); }
    });
    $app.querySelector("#tg-disable").addEventListener("click", async () => {
      try { await apiPost("/tunnel/disable"); toast("Туннель остановлен"); }
      catch (e) { toast("Ошибка: " + e.message, "bad"); }
    });
  }

  async function toggleClick(key, box) {
    const sw = box.closest(".switch");
    const wanted = box.checked ? "1" : "0";
    sw.classList.add("loading");
    try {
      await apiPost("/toggle/" + TOGGLE_API_NAME[key], { value: wanted });
      toast(wanted === "1" ? "Включено" : "Выключено");
    } catch (e) {
      box.checked = !box.checked; // revert
      toast("Ошибка: " + e.message, "bad");
    } finally {
      sw.classList.remove("loading");
    }
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
  function openJobModal(title, jobId) {
    const backdrop = document.createElement("div");
    backdrop.className = "modal-backdrop";
    backdrop.innerHTML = `
      <div class="modal">
        <h3>${escapeHtml(title)}</h3>
        <pre class="log" id="job-log">Запуск…</pre>
        <div class="modal-footer">
          <button class="btn" id="job-close" disabled>Закрыть</button>
        </div>
      </div>
    `;
    document.body.appendChild(backdrop);
    const logEl = backdrop.querySelector("#job-log");
    const closeBtn = backdrop.querySelector("#job-close");
    closeBtn.addEventListener("click", () => backdrop.remove());

    let stopped = false;
    async function poll() {
      if (stopped) return;
      try {
        const d = await apiGet("/job?id=" + encodeURIComponent(jobId));
        logEl.textContent = d.log || "(нет вывода)";
        logEl.scrollTop = logEl.scrollHeight;
        if (d.done) {
          closeBtn.disabled = false;
          closeBtn.textContent = d.exit === 0 ? "Готово" : "Закрыть (exit=" + d.exit + ")";
          stopped = true;
          return;
        }
      } catch (e) {
        logEl.textContent = "Ошибка опроса: " + e.message;
        closeBtn.disabled = false;
        stopped = true;
        return;
      }
      setTimeout(poll, 1000);
    }
    poll();
  }

  // ---------- Rotator state (Phase 3) ----------
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
      const rows = d.entries.map(e => {
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
      body.innerHTML = `
        <table class="state-table">
          <thead>
            <tr><th></th><th>Профиль</th><th>Домен</th><th>Стратегия</th><th>Возраст</th></tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      `;
      body.querySelectorAll(".state-del").forEach(btn => {
        btn.addEventListener("click", () => stateDelete(btn.dataset.key, btn.dataset.host));
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
          runetfreedom каждый день через cron (+ force refresh при
          install). RAM-адаптивный выбор RKN-варианта: ≥900 MB RAM →
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
