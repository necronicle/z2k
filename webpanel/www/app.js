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
  // Адрес приёмника статистики. Продублирован из files/z2k-stats-upload.sh
  // намеренно: карточка обязана называть адрес, а тянуть его с бекенда ради
  // одной строки — лишняя ручка. Расходятся они только если кто-то поменяет
  // ENDPOINT и забудет здесь; это ловит tests/test_stats_ack.sh.
  const STATS_ENDPOINT = "http://213.176.74.63:8088/stats";
  const MAX_TOASTS = 3;
  const TOAST_TTL_MS = 3500;
  function toast(msg, kind = "ok") {
    if (!$toastStack) return;
    // Пустой текст — это осознанное молчание, а не недосмотр вызывающего.
    // Так гасятся временные ответы во время переустановки: дерево переезжает,
    // каждый фоновый загрузчик об него спотыкается, и без этого человек
    // получает очередь красных плашек про то, что ничего не сломалось.
    // Единственная точка, где такой текст рождается пустым, — httpError.
    if (!msg || !String(msg).trim()) return;
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
  // Every API call carries X-Z2K-Panel. The backend (cgi/auth.sh) treats it as
  // proof the request came from this page: a cross-origin form cannot set a
  // header, and a cross-origin fetch that sets one is held back by a CORS
  // preflight the panel never answers. Do not drop it from any call site.
  const PANEL_HDR = { "X-Z2K-Panel": "1" };

  // «Панель не ответила» и «панель ответила отказом» — разные события, и
  // путать их дорого: обрыв связи поллер задачи обязан терпеть минутами
  // (рестарт трясёт тот же канал, через который открыта панель), а 403/400/500
  // — это определённый ответ, ждать после него нечего. Признак второго —
  // поле httpStatus у ошибки; текст сообщения при этом не меняется.
  // Временные статусы, означающие «панель сейчас переезжает или поднимается».
  // Держим ОДНИМ списком: isRefusal ниже и текст сообщения обязаны совпадать,
  // иначе получится ровно то, что и получилось — опрос ждёт, а страница
  // одновременно кричит про ошибку.
  const TRANSIENT_HTTP = { 404: 1, 502: 1, 503: 1, 504: 1 };

  function httpError(status, statusText, message) {
    // Текст для ЧЕЛОВЕКА, а не код протокола.
    //
    // Исходная беда была не в том, что панель показывает ошибки, а в том, что
    // она показывает их словами «404 Not Found» там, где на самом деле идёт
    // штатная переустановка: lighttpd жив, но корень и CGI лежат внутри
    // /opt/zapret2, которое на время переезжает. Классификацию я починил
    // (90823e8), но только в опросе задачи и awaitPanelBack — а сырой текст
    // ошибки печатает 41 место в этом файле, и все они продолжали пугать людей
    // кодом 404 весь день.
    //
    // Чинить 41 обработчик по одному незачем: сообщение рождается здесь, и
    // достаточно, чтобы оно рождалось человеческим. Настоящие отказы (403, 500)
    // текст сохраняют — их прятать нельзя.
    // ВРЕМЕННЫЙ СТАТУС — ЭТО НЕ СОБЫТИЕ ДЛЯ ЧЕЛОВЕКА, И ТЕКСТА У НЕГО НЕТ.
    //
    // Наш код 404 не возвращает нигде и никогда. Тот, что видели люди, —
    // ответ самого lighttpd: он остаётся жив, а корень и CGI лежат внутри
    // /opt/zapret2, которое на пятом шаге переустановки переезжает. То есть
    // панель показывала чужой ответ как свой и сообщала об ошибке там, где
    // ничего не сломалось.
    //
    // Раньше я чинил это классификацией: 404 объявлялся временным, текст
    // смягчался. Классификация была верной, а решение — нет: сообщение всё
    // равно всплывало, просто другими словами, и пугало ровно так же.
    // Поэтому сообщения здесь больше НЕТ ВООБЩЕ. Пустой текст молча гасится
    // и в тостах, и в логе задачи — человек видит идущую установку, а не
    // разговор про коды ответов.
    //
    // Настоящие отказы (403, 500) текст сохраняют: их прятать нельзя.
    let msg = "";
    if (!TRANSIENT_HTTP[status]) {
      msg = message || `${status} ${statusText}`;
    }
    const e = new Error(msg);
    e.httpStatus = status;
    e.transient = !!TRANSIENT_HTTP[status];
    return e;
  }
  function isHttpError(e) { return !!e && typeof e.httpStatus === "number"; }

  // Отказ ли это на самом деле.
  //
  // Раньше отказом считался ЛЮБОЙ числовой статус, и это было ошибкой: при
  // переустановке lighttpd не останавливается, а корень и CGI лежат внутри
  // /opt/zapret2, которое на пятом шаге переезжает. Живой сервер без файлов
  // отвечает 404 — и опрос, вместо того чтобы переждать переезд, объявлял
  // «панель ответила ошибкой, чем кончилась задача, неизвестно» через ТРИ
  // попытки, то есть через четыре секунды. При этом обрыв связи терпелся
  // десять минут: мягкая ветка была ровно для этого случая, но он в неё не
  // попадал.
  //
  // 404 — «этого сейчас нет», 502/503 — «сервер поднимается». Всё это
  // временное и обязано пережидаться. Настоящий отказ — 403 (origin-гейт
  // отверг) и 5xx кроме перечисленных.
  function isRefusal(e) {
    if (!isHttpError(e)) return false;
    return !TRANSIENT_HTTP[e.httpStatus];
  }

  async function apiGet(path, opts = {}) {
    const r = await fetch(API + path, { credentials: "same-origin", headers: PANEL_HDR, signal: opts.signal });
    if (!r.ok) {
      // Тело ошибки РАЗБИРАЕМ, как это давно делает apiPost. Раньше здесь
      // стоял голый httpError(status, statusText), то есть ответ выбрасывался
      // целиком — а бекенд кладёт в него внятную русскую причину («панель не
      // отвечает на этот адрес», «обращение с другого сайта»). Человеку
      // доставалось «403 Forbidden» без единой подсказки, и это на 22 из 48
      // вызовов, то есть на загрузке всех страниц.
      const data = await r.json().catch(() => null);
      throw httpError(r.status, r.statusText, (data && data.error) || undefined);
    }
    return r.json();
  }
  async function apiPost(path, params = {}) {
    const body = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) body.set(k, v);
    const r = await fetch(API + path, {
      method: "POST",
      credentials: "same-origin",
      headers: { ...PANEL_HDR, "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    const data = await r.json().catch(() => ({ ok: false, error: `${r.status}` }));
    if (!r.ok) throw httpError(r.status, r.statusText, data.error || `${r.status}`);
    if (!data.ok) throw new Error(data.error || `${r.status}`);
    return data;
  }
  // GET, отдающий сырой текст (не JSON) — /warp/list. Ошибки бекенд шлёт
  // JSON'ом с не-200 статусом, поэтому на !ok пробуем вытащить .error.
  async function apiGetText(path) {
    const r = await fetch(API + path, { credentials: "same-origin", headers: PANEL_HDR });
    if (!r.ok) {
      let msg = `${r.status} ${r.statusText}`;
      try { const d = await r.json(); if (d && d.error) msg = d.error; } catch (_) {}
      throw httpError(r.status, r.statusText, msg);
    }
    return r.text();
  }
  // POST с сырым текстовым телом (как /whitelist/import) — /warp/list/save.
  async function apiPostText(path, text) {
    const r = await fetch(API + path, {
      method: "POST",
      credentials: "same-origin",
      headers: { ...PANEL_HDR, "Content-Type": "text/plain;charset=utf-8" },
      body: text,
    });
    const data = await r.json().catch(() => ({ ok: false, error: `${r.status}` }));
    if (!r.ok) throw httpError(r.status, r.statusText, data.error || `${r.status}`);
    if (!data.ok) throw new Error(data.error || `${r.status}`);
    return data;
  }

  // ---------- Router ----------
  const routes = {
    dashboard: renderDashboard,
    toggles: renderToggles,
    warp: renderWarp,
    // «Исключения» — одна страница с двумя подвкладками. Два маршрута, потому
    // что подвкладка обязана быть адресом: её можно дать ссылкой и она
    // переживает перезагрузку страницы. Имена маршрутов оставлены прежними,
    // чтобы старая закладка открывала ровно то, что на ней лежало: #/whitelist
    // — «Домены», #/exclude — «Адреса».
    whitelist: renderExcludeDomains,
    exclude: renderExcludeAddresses,
    "extra-domains": renderExtraDomains,
    // Подвкладка «Автохостлист» — отдельным маршрутом по той же причине, что и
    // у «Исключений»: на неё можно дать ссылку и она переживает перезагрузку.
    autohostlist: renderAutohostlistDomains,
    state: renderState,
    strategies: renderStrategies,
    diag: renderDiag,
    credits: renderCredits,
  };
  // Active route highlight для всех `<a>` в #nav (primary + overflow).
  // Highlight «...» кнопки делается через CSS :has() — не нужен JS sync.
  // Page title — per-route, формат "PageName · Z2K" (GitHub/Linear style).
  const ROUTE_TITLES = {
    dashboard:       "Дашборд",
    toggles:         "Режимы",
    warp:            "WARP",
    // Обе подвкладки «Исключений» — один раздел, значит и один заголовок.
    whitelist:       "Исключения",
    exclude:         "Исключения",
    "extra-domains": "Доп. домены",
    // «Стратегии» — одна дверь, два вида внутри. Маршрут `state` остался жив
    // ради старых ссылок и закладок: он открывает ту же страницу на вкладке
    // «Автоподбор». Поэтому и заголовок у него тот же — раньше здесь
    // стояло «Rotator», из-за чего один раздел назывался четырьмя разными
    // именами (меню, маршрут, заголовок страницы, README).
    state:           "Стратегии",
    strategies:      "Стратегии",
    diag:            "Диагностика",
    credits:         "Благодарности",
  };
  // Маршрут → пункт меню, который он подсвечивает. Только для маршрутов,
  // которые являются подвкладками чужого раздела.
  const NAV_OF_ROUTE = {
    state: "strategies",
    whitelist: "exclude",
  };
  function navigate() {
    const hash = location.hash.replace(/^#\//, "") || "dashboard";
    const name = routes[hash] ? hash : "dashboard";
    // Маршрутов больше, чем пунктов меню: подвкладка — тоже адрес, но своего
    // пункта у неё нет. Без подмены переход на такой адрес не подсвечивал бы
    // в меню ничего.
    const navName = NAV_OF_ROUTE[name] || name;
    for (const a of $nav.querySelectorAll("a")) {
      a.classList.toggle("active", a.dataset.route === navName);
    }
    // Имя экрана в DOM: по нему стилям видно, где мы находимся. Нужно
    // ровно одному правилу — экран стратегий снимает кап ширины, потому что
    // это таблица на сотни строк, а не текст.
    document.body.setAttribute("data-page", name);
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
      <div id="stats-notice" hidden></div>
      <h1 class="page-title">Дашборд</h1>
      <div class="card" id="status-card">
        <h3>Состояние</h3>
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
      <!-- ОТДЕЛЬНАЯ КАРТОЧКА, А НЕ ЧЕТВЁРТАЯ КНОПКА В РЯДУ ВЫШЕ.
           «Остановить» обратимо и делается каждый день; удаление необратимо и
           делается один раз. В одном ряду они получили бы одинаковый вес и
           отличались бы только подписью — так и промахиваются. -->
      <div class="card card-danger" id="uninstall-card">
        <h3>Удаление z2k</h3>
        <p class="desc">
          Снимает z2k с роутера полностью: сервис, правила обхода, настройки,
          подобранные стратегии и саму эту панель. Отмены нет — вернуть можно
          только установкой заново, с нуля.
        </p>
        <div class="btn-row">
          <button class="btn btn-danger" id="uninstall-btn">Удалить z2k</button>
        </div>
      </div>
    `;

    // querySelectorAll().forEach, а не querySelector().addEventListener — тем же
    // приёмом, что и обработчик [data-svc] выше. Пустая выборка просто ничего не
    // делает, а обращение к .addEventListener у null роняет весь рендер
    // страницы: дашборд собирается одной строкой innerHTML, и любой сторонний
    // рендер этой же разметки (тестовый харнесс, будущая подстраница) уронил бы
    // не кнопку, а экран целиком.
    $app.querySelectorAll("#uninstall-btn").forEach(btn => btn.addEventListener("click", async () => {
      const ok = await confirmTypedModal(
        "Удалить z2k с роутера",
        [
          "Будут удалены: служба обхода и её автозапуск, все правила iptables, " +
            "настройки, списки доменов и подобранные для них стратегии.",
          "Вместе с ними исчезнет и эта панель — страница перестанет отвечать " +
            "примерно на середине, и это нормальный конец, а не сбой.",
          "Интернет продолжит работать, но уже без обхода блокировок.",
        ],
        "УДАЛИТЬ",
        "Удалить z2k"
      );
      if (!ok) return;
      let resp;
      try {
        resp = await apiPost("/uninstall", { confirm: "УДАЛИТЬ" });
      } catch (e) {
        toast("Не удалось запустить удаление: " + e.message, "bad");
        return;
      }
      openJobModal("Удаление z2k", resp.job, {
        tolerateOutage: true,
        // Панель входит в удаляемое и обратно не поднимется. Без этого флага
        // опрос честно ждал бы её возвращения десять минут и всё это время
        // писал «ждём…» — про сервер, которого больше нет.
        expectGone: true,
      });
    }));

    $app.querySelectorAll("[data-svc]").forEach(btn => {
      btn.addEventListener("click", async () => {
        if (btn.disabled) return;
        const action = btn.dataset.svc;
        const titleByAction = { start: "Запуск сервиса", stop: "Остановка сервиса", restart: "Перезапуск сервиса" };
        const title = titleByAction[action] || ("Действие: " + action);
        // Глобальный лок включается только когда придёт id задачи, а до тех
        // пор кнопка кликабельна: второй клик по «Перезапустить» запускал
        // второй конкурентный S99zapret2 restart.
        btn.disabled = true;
        let resp;
        try {
          resp = await apiPost("/service/" + action);
        } catch (e) {
          btn.disabled = false;
          toast("Ошибка запуска: " + e.message, "bad");
          return;
        }
        // Кнопку возвращаем в исходное состояние ДО openJobModal: лок
        // запоминает текущее disabled как «правильное» и после задачи вернул
        // бы её навсегда выключенной.
        btn.disabled = false;
        // Backend теперь async — возвращает {ok, job:<id>}. Открываем
        // модалку с live-логом точно как при auto-update apply. После
        // завершения refreshStatus подтянет grid вверху.
        openJobModal(title, resp.job, {
          // Старт/стоп/рестарт бьют по тому же iptables, через который открыта
          // панель — короткий обрыв здесь штатный, а не отказ команды.
          tolerateOutage: true,
          onDone: (d) => {
            const outcome = jobOutcome(d);
            if (outcome === JOB_FAIL) {
              toast("Команда завершилась с кодом " + d.exit, "bad");
            } else {
              const m = unresolvedMsg(outcome);
              if (m) toast(m, "bad");
            }
            if (jobUnresolved(outcome)) awaitPanelBack().then(() => refreshStatus());
            else setTimeout(refreshStatus, 500);
          },
        });
      });
    });

    refreshStatus();
    refreshUpdateBanner();
    renderStatsNotice();
    _updateGlobalUILock();
  }

  // ---------- Уведомление о телеметрии ----------
  //
  // Телеметрия включена по умолчанию — это решение владельца. Но «включено по
  // умолчанию» и «ушло раньше, чем человек успел узнать» — разные вещи.
  // Аплоадер молчит, пока Z2K_STATS_ACK=0 (не дольше трёх суток), а эта
  // карточка снимает гейт, показав, ЧТО именно уходит и куда.
  //
  // Согласия не спрашиваем — спрашивать было бы враньём, раз выключить можно
  // и после. Показываем состав и даём выключить в один шаг прямо отсюда.
  async function renderStatsNotice() {
    const host = document.getElementById("stats-notice");
    if (!host) return;
    let t;
    try {
      t = await apiGet("/toggles");
    } catch (_) {
      return; // не смогли — не мешаем дашборду
    }
    if (!t || t.stats_ack !== "0") return;

    host.hidden = false;
    host.className = "card";
    host.innerHTML = `
      <h3>z2k отправляет обезличенную статистику</h3>
      <p class="desc">
        Раз в сутки уходит срез ротации: <strong>имя пула</strong>
        (yt_quic, rkn_tcp…), <strong>номер стратегии</strong> и
        <strong>как долго она держится</strong> — округлённо.
        Доменов, посещённых адресов и идентификатора роутера в посылке нет.
      </p>
      <p class="desc">
        Адрес: <code>${escapeHtml(STATS_ENDPOINT)}</code>. Сейчас без TLS —
        содержимое видно вашему провайдеру. Подробности в README.
      </p>
      <div class="row">
        <button class="btn" id="stats-ack-ok">Понятно</button>
        <button class="btn" id="stats-ack-off">Выключить сбор</button>
      </div>
    `;
    const done = () => { host.hidden = true; host.innerHTML = ""; };
    document.getElementById("stats-ack-ok").addEventListener("click", async () => {
      try { await apiPost("/stats/ack"); toast("Понятно, больше не показываем"); }
      catch (e) { toast("Ошибка: " + e.message, "bad"); }
      done();
    });
    document.getElementById("stats-ack-off").addEventListener("click", async () => {
      try {
        await apiPost("/toggle/stats", { value: "0" });
        await apiPost("/stats/ack");
        toast("Сбор статистики выключен");
      } catch (e) { toast("Ошибка: " + e.message, "bad"); }
      done();
    });
  }

  // ---------- Update banner / apply ----------
  async function refreshUpdateBanner(opts = {}) {
    const banner = document.getElementById("update-banner");
    if (!banner) return;
    let d = null;
    let err = null;
    try {
      const path = opts.force ? "/update/check" : "/update/status";
      d = opts.force ? await apiPost(path) : await apiGet(path);
    } catch (e) {
      // Прятать весь блок нельзя: кнопку «Проверить ещё раз» жмут именно
      // отсюда, и вместе с баннером она пропадала до перезагрузки страницы.
      err = e;
    }
    const installed = (d && d.installed) || "?";
    const available = (d && d.available) || "?";
    const behind = Number((d && d.behind) || 0);
    const ts = Number((d && d.last_check) || 0);
    const ago = ts > 0 ? humanAgo(ts) : "—";
    // Манифест мог не скачаться (нет интернета, GH лежит) — тогда бекенд
    // отдаёт пустое available. Неизвестно ≠ «последняя версия»: утверждать
    // второе на основании отсутствия данных нельзя.
    const unknown = err !== null || available === "?" || installed === "?";

    // Случай, который до 2026-08-08 был неотличим от нормы: манифест НЕ
    // скачался, но на диске лежит протухший кэш, поэтому available непустой,
    // unknown=false, и панель уверенно писала «установлена актуальная версия»
    // при полностью мёртвом канале обновлений. Возраст показывался мелким
    // текстом рядом и ничего не сигналил.
    //
    // Порог 72 часа: планировщик ходит за манифестом ежедневно, так что трое
    // суток без единой удачной проверки — это уже не «связь моргнула».
    const STALE_AFTER = 72 * 3600;
    const fetchFailed = !!(d && d.fetch_failed);
    const checkAge = Number((d && d.check_age) != null ? d.check_age : -1);
    const channelDead = !unknown && fetchFailed && (checkAge < 0 || checkAge > STALE_AFTER);

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

    if (!unknown && behind > 0) {
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
    } else if (unknown) {
      const why = err ? escapeHtml(err.message) : "список версий не скачался";
      const known = installed !== "?" ? `установлена ${escapeHtml(installed)} · ` : "";
      banner.hidden = false;
      banner.className = "update-banner";
      banner.innerHTML = `
        <div class="update-banner-text">
          <strong>Не удалось проверить обновления</strong>
          <span class="update-banner-meta">${known}${why} · последняя удачная проверка ${ago}</span>
        </div>
        <div class="update-banner-actions">
          <button class="btn" id="upd-recheck">Проверить ещё раз</button>
        </div>
      `;
    } else if (channelDead) {
      // Версии сравнились, но сравнились с ПРОТУХШИМ списком: последняя
      // попытка скачать его провалилась, и удачной не было трое суток.
      // Говорить «установлена последняя версия» здесь нельзя — мы не знаем,
      // последняя ли она, мы знаем только, что новее в старом списке нет.
      const staleFor = checkAge > 0 ? humanDuration(checkAge) : "неизвестно сколько";
      banner.hidden = false;
      banner.className = "update-banner";
      banner.innerHTML = `
        <div class="update-banner-text">
          <strong>Обновления не проверяются</strong>
          <span class="update-banner-meta">установлена ${escapeHtml(installed)} · список версий не удаётся скачать уже ${escapeHtml(staleFor)} · показано по устаревшим данным</span>
        </div>
        <div class="update-banner-actions">
          <button class="btn" id="upd-recheck">Проверить ещё раз</button>
        </div>
      `;
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
      const label = recheckBtn.textContent;
      recheckBtn.disabled = true;
      recheckBtn.textContent = "Проверяем…";
      try {
        await refreshUpdateBanner({ force: true });
      } finally {
        // Обычно баннер перерисован целиком и этой кнопки уже нет в DOM. Если
        // же перерисовки не случилось (ушли со страницы), она иначе осталась
        // бы навсегда выключенной с текстом «Проверяем…».
        if (recheckBtn.isConnected) {
          recheckBtn.disabled = false;
          recheckBtn.textContent = label;
        }
      }
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
  // {id, target} object from sessionStorage if so, null otherwise.
  // Ключ снимаем и когда задача завершилась, и когда её больше НЕТ
  // (status unknown: файлы подчистил job_reap или роутер перезагрузился).
  // Без второго случая баннер навечно показывал «обновление в процессе» с
  // единственной кнопкой «Показать лог».
  async function getActiveApplyJob() {
    const raw = sessionStorage.getItem("z2k_apply_job");
    if (!raw) return null;
    let job;
    try { job = JSON.parse(raw); } catch (e) { sessionStorage.removeItem("z2k_apply_job"); return null; }
    if (!job || !job.id) { sessionStorage.removeItem("z2k_apply_job"); return null; }
    try {
      const d = await apiGet("/job?id=" + encodeURIComponent(job.id));
      if (d.done || d.status === "unknown") {
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

  // Длительность как таковая («уже 4 дн»), в отличие от humanAgo, который
  // говорит про момент в прошлом («4 дн назад»).
  function humanDuration(sec) {
    const s = Math.max(0, Math.floor(sec));
    if (s < 3600) return Math.max(1, Math.floor(s / 60)) + " мин";
    if (s < 86400) return Math.floor(s / 3600) + " ч";
    return Math.floor(s / 86400) + " дн";
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

  // ---------- Load ordering ----------
  // mod_cgi обслуживает запросы ПАРАЛЛЕЛЬНО, и ответы приходят не в том
  // порядке, в каком уходили: /state на роутере занимает ~2.4 с, и ответ,
  // ушедший первым, приходит последним. Без этого счётчика более старый
  // снимок дорисовывался поверх свежего — удалённая строка «воскресала»
  // сразу после тоста «Удалено», а кэш оставался отравленным. Рисует только
  // тот вызов загрузчика, который стартовал последним.
  const _loadSeq = {};
  function _newLoad(name) { _loadSeq[name] = (_loadSeq[name] || 0) + 1; return _loadSeq[name]; }
  function _stale(name, seq) { return _loadSeq[name] !== seq; }

  async function refreshStatus() {
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
      const why = (e && e.message)
        ? escapeHtml(e.message)
        : "Панель сейчас не отвечает — обычно так выглядит идущее обновление.";
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
  function rstIsOn(v) { v = String(v || "").toLowerCase(); return v === "1" || v === "on" || v === "true" || v === "yes" || v === "aggressive" || v === "agg" || v === "aggro"; }
  function rstIsAggressive(v) { v = String(v || "").toLowerCase(); return v === "aggressive" || v === "agg" || v === "aggro"; }
  function fmtSvc(s) {
    return { active: "работает", stopped: "остановлен", not_installed: "не установлен" }[s] || s;
  }

  // ---------- Toggles ----------
  const TOGGLE_DEFS = [
    { key: "rst_filter", name: "RST-фильтр (пассивный DPI)",
      desc: "Блокирует поддельные TCP RST от ТСПУ через nfqws — 3 эвристики (pre-response RST, multi-RST burst, TTL mismatch). Не требует kernel-модулей. Может задеть редкие edge cases у Cloudflare — отключите если заметили проблемы с reconnect'ом." },
    { key: "silent_fallback", name: "Silent fallback РКН",
      desc: "Детект «тихих чёрных дыр» РКН. Осторожно — возможны ложные срабатывания." },
    // game_warp переехал в собственный раздел «WARP» (renderWarp) вместе с
    // управлением списками адресов — здесь его больше нет.
    { key: "customd", name: "Скрипты custom.d",
      desc: "Дополнительные daemons из init.d/custom.d (50-stun4all, 50-discord-media)." },
    { key: "dynamic_ttl", name: "Динамический TTL",
      desc: "Инжекция фиксированного TTL в исходящий трафик — обход обнаружения tethering у мобильных операторов (МТС/Билайн с телефонной симкой). Если у роутера уже настроен NDM TTL-fix — отключи, чтобы избежать конфликта." },
    { key: "stats", name: "Сбор статистики (анонимно)",
      desc: "Раз в сутки шлёт на сервер проекта обезличенный срез: какая стратегия активна в каждом пуле и как долго держится — чтобы двигать лучшие стратегии в начало. НЕ уходит: сайты/домены, IP, провайдер, регион, любой ID устройства. Только: имя пула, номер стратегии, время удержания. Выключите, если не хотите участвовать." },
    { key: "ppe", name: "Аппаратный offload: per-flow исключение",
      desc: "На Keenetic (MediaTek) аппаратный ускоритель уводит поток в железо после первого пакета, и роутер не видит повторные ClientHello — стратегия залипает для блокировок без RST (mailsuite и т.п.). Эта опция держит окно рукопожатия на CPU только для нужных портов (родной firmware-механизм -j PPE), поэтому подбор стратегии снова работает, а общий трафик остаётся ускоренным. Работает только на совместимых Keenetic. Выключите, чтобы вернуть прежнее поведение." },
    { key: "autohostlist", name: "Автохостлист",
      desc: "Обычно обходятся только домены из списков. С этой опцией движок сам замечает, что домен не открывается, и добавляет его — найденное попадает в основной список и подхватывается штатно. Плюс: сайты вне списков начинают работать без ручных добавлений. Минус: движок судит по поведению соединения и иногда ошибается, в список может попасть домен, который просто лежал сам по себе. Это смена принципа отбора трафика целиком, поэтому по умолчанию выключено." },
    { key: "auto_update", name: "Автообновление",
      desc: "Ночью в 02:00 роутер сам проверяет обновления и устанавливает их. Выключите, если хотите обновляться только вручную — кнопка «Обновить» продолжит работать, и панель по-прежнему покажет, что доступна новая версия." },
  ];
  const TOGGLE_API_NAME = {
    rst_filter: "rst-filter",
    silent_fallback: "silent-fallback",
    customd: "customd",
    dynamic_ttl: "dynamic-ttl",
    stats: "stats",
    ppe: "ppe",
    auto_update: "auto-update",
    autohostlist: "autohostlist",
  };

  async function renderToggles() {
    $app.innerHTML = `
      <h1 class="page-title">Режимы</h1>
      <div class="card">
        <div id="toggles-error" hidden></div>
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

    // Load current state and wire up switches. Шаблон рендерит все свитчи
    // disabled, включаются они только здесь — поэтому упавший /status обязан
    // сказать об этом и дать повтор: иначе страница выглядит нормальной, но
    // не кликается ни один тумблер, и понять это можно только методом тыка.
    const errBox = $app.querySelector("#toggles-error");
    // Джоб завершается через 10-20 секунд, юзер за это время успевает уйти на
    // другую страницу. renderToggles() без проверки молча подменял бы $app
    // содержимым «Режимов», оставив адрес и подсветку меню от чужой страницы.
    // Она же отвечает на вопрос «мы ещё здесь?» для ответов, пришедших после
    // ухода: _stale ловит только более свежую загрузку, но не смену маршрута.
    const onTogglesPage = () => !!document.getElementById("tg-state-badge");

    async function loadTogglesState() {
      const seq = _newLoad("toggles");
      let s;
      try {
        s = await apiGet("/status");
      } catch (e) {
        if (_stale("toggles", seq) || !onTogglesPage()) return;
        if (!errBox) return;
        // Сообщение обещает, что переключатели заблокированы — значит и кнопки
        // туннеля тоже: под ними реальные запуск и останов, а панель сейчас не
        // знает даже, что включено. Свитчи глушим тем же проходом — после
        // удачной загрузки они уже разлочены, и повторный провал оставил бы их
        // живыми под текстом «заблокированы».
        TOGGLE_DEFS.forEach(t => {
          const row = $app.querySelector(`[data-key="${t.key}"]`);
          if (row) setLockAware(row.querySelector("input"), true);
        });
        setLockAware($app.querySelector("#tg-enable"), true);
        setLockAware($app.querySelector("#tg-disable"), true);
        errBox.hidden = false;
        errBox.innerHTML = `
          <p class="desc" style="color:var(--bad)">Не удалось прочитать состояние: ${escapeHtml(e.message)}.
             Переключатели заблокированы — панель не знает, что сейчас включено.</p>
          <div class="btn-row" style="margin-bottom:10px">
            <button class="btn btn-primary" id="toggles-retry">Повторить</button>
          </div>`;
        const retry = $app.querySelector("#toggles-retry");
        if (retry) retry.addEventListener("click", () => {
          retry.disabled = true;
          retry.textContent = "Читаю…";
          loadTogglesState();
        });
        return;
      }
      if (_stale("toggles", seq)) return;
      // /status мог вернуться уже после ухода со страницы: $app очищен, ни
      // одного из этих элементов больше нет, и обращение к badge.hidden роняло
      // весь остаток renderToggles — вместе с привязкой кнопок туннеля,
      // секцией политики и глобальным локом.
      const badge = $app.querySelector("#tg-state-badge");
      if (!badge) return;
      if (errBox) { errBox.hidden = true; errBox.innerHTML = ""; }
      TOGGLE_DEFS.forEach(t => {
        const row = $app.querySelector(`[data-key="${t.key}"]`);
        if (!row) return;
        const box = row.querySelector("input");
        box.checked = t.key === "rst_filter" ? rstIsOn(s.toggles[t.key]) : s.toggles[t.key] === "1";
        setLockAware(box, false);
        // Повторная загрузка не должна вешать второй обработчик: два POST'а
        // на один клик — два конкурентных рестарта сервиса.
        if (!box.dataset.wired) {
          box.dataset.wired = "1";
          box.addEventListener("change", () => toggleClick(t.key, box));
        }
      });
      // TG-tunnel state pill + button enable/disable matching reality.
      const tgRunning = s.tunnel && s.tunnel.running === true;
      badge.hidden = false;
      badge.textContent = tgRunning ? "Включён" : "Остановлен";
      badge.className = "tg-state-badge " + (tgRunning ? "tg-state-on" : "tg-state-off");
      const enableBtn = $app.querySelector("#tg-enable");
      const disableBtn = $app.querySelector("#tg-disable");
      setLockAware(enableBtn, tgRunning);
      setLockAware(disableBtn, !tgRunning);
      if (enableBtn) enableBtn.title = tgRunning ? "Туннель уже запущен" : "";
      if (disableBtn) disableBtn.title = tgRunning ? "" : "Туннель уже остановлен";
    }
    await loadTogglesState();
    // Пока читался /status, юзер мог уйти — вешать обработчики уже некуда, а
    // querySelector вернёт null и уронит остаток функции.
    if (!onTogglesPage()) return;

    async function tgAction(action, title) {
      const btns = [$app.querySelector("#tg-enable"), $app.querySelector("#tg-disable")];
      const wasDisabled = btns.map(b => b && b.disabled);
      const restoreBtns = () => btns.forEach((b, i) => { if (b) b.disabled = wasDisabled[i]; });
      // Глобальный лок включится только с приходом id задачи; до тех пор обе
      // кнопки кликабельны, и второй клик поднимал второй tunnel_enable.
      btns.forEach(b => { if (b) b.disabled = true; });
      let resp;
      try {
        resp = await apiPost("/tunnel/" + action);
      } catch (e) {
        restoreBtns();
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
        // Исходное состояние возвращаем ДО openJobModal: лок запоминает
        // текущее disabled как «правильное» и вернул бы кнопку выключенной.
        restoreBtns();
        openJobModal(title, resp.job, {
          onDone: async () => {
            await pollTgState();
            if (onTogglesPage()) renderToggles();
          },
        });
      } else {
        toast(title + " — готово");
        await pollTgState();
        if (onTogglesPage()) renderToggles();
        else restoreBtns();
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
      const seq = _newLoad("policy");
      try {
        const d = await apiGet("/policy/status");
        if (_stale("policy", seq)) return;
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
        if (_stale("policy", seq)) return;
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
      if (saveBtn.disabled) return;
      const v = nameInput.value.trim();
      if (!NAME_RE.test(v)) {
        toast("Имя политики: только буквы/цифры/«_»/«-», 1–32 символа", "bad");
        nameInput.focus();
        return;
      }
      const exclude = segGroup.querySelector(".seg-btn.seg-on")?.dataset.exclude || "0";
      // Кнопка не входит в глобальный лок, а под ней рестарт сервиса: без
      // этого второй клик в окне ожидания ответа запускал вторую задачу.
      saveBtn.disabled = true;
      let resp;
      try {
        resp = await apiPost("/policy/save", { name: v, exclude });
      } catch (e) {
        saveBtn.disabled = false;
        toast("Ошибка: " + e.message, "bad");
        return;
      }
      if (resp && resp.job) {
        openJobModal("Применение политики доступа", resp.job, {
          onDone: () => { saveBtn.disabled = false; setTimeout(loadPolicyStatus, 500); }
        });
      } else {
        saveBtn.disabled = false;
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
  // Must mirror what the backend actually does: a toggle whose handler calls
// restart_service_if_running has to be listed here, or the user gets a silent
// blip in the bypass with no indication it happened. Asserted in the suite.
  const TOGGLES_RESTART_SERVICE = { rst_filter: 1, silent_fallback: 1, customd: 1, dynamic_ttl: 1, ppe: 1, autohostlist: 1 };

  // Автохостлист меняет принцип отбора трафика целиком, и промах движка
  // выглядит для юзера как «сайт сломался после обновления». Формулировка
  // согласована — правке не подлежит.
  const AUTOHOSTLIST_WARNING =
    "Включая автохостлист вы рискуете что будут попадать левые адреса и что-то перестанет работать. " +
    "Жалобы на прекративший работу сайт после включения автохостлиста не принимаются.";

  async function toggleClick(key, box) {
    const sw = box.closest(".switch");
    const wanted = box.checked ? "1" : "0";
    if (key === "autohostlist" && wanted === "1") {
      // Тумблер блокируем на время вопроса. Подложка модалки перехватывает
      // мышь, но не клавиатуру: без этого Tab уводил фокус из модалки обратно
      // на чекбокс, пробел давал второй change, и запрос уходил на бэкенд мимо
      // подтверждения — в итоге в конфиге было включено, а галочка снята.
      box.disabled = true;
      const go = await confirmModal("Включить автохостлист?", AUTOHOSTLIST_WARNING,
                                    "Включать", "Не включать");
      // Пока висел вопрос, страницу могла перерисовать чужая фоновая задача
      // (например завершившийся туннель зовёт renderToggles): тогда наш box
      // уже отцеплен от документа, и запись в него ничего не покажет. Ответ
      // при этом остаётся в силе — состояние подтянет следующий /status.
      if (typeof document.body.contains === "function" && !document.body.contains(box)) return;
      box.disabled = false;
      if (!go) {
        // Событие change уже переставило чекбокс — возвращаем его сами.
        box.checked = false;
        return;
      }
    }
    sw.classList.add("loading");
    box.disabled = true; // блок UI до завершения, не даём кликать ещё
    const restarts = TOGGLES_RESTART_SERVICE[key] === 1;
    const verb = wanted === "1" ? "Включаю" : "Отключаю";
    const niceName = {
      rst_filter: "RST-фильтр",
      silent_fallback: "Silent fallback",
      customd: "custom.d",
      dynamic_ttl: "Динамический TTL",
      stats: "Сбор статистики",
      ppe: "PPE de-offload",
      auto_update: "Автообновление",
      autohostlist: "Автохостлист",
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
      // Рестарт nfqws2 перетряхивает iptables на канале, по которому открыта
      // сама панель: обрыв на десятки секунд здесь норма, и обрывать опрос
      // через пять секунд значит объявить провалом штатный ход операции.
      tolerateOutage: restarts,
      onDone: (d) => {
        sw.classList.remove("loading");
        box.disabled = false;
        const outcome = jobOutcome(d);
        if (outcome === JOB_FAIL) {
          // Toggle failed — revert checkbox чтобы UI отражал реальное
          // состояние (старое значение сохранилось в config).
          box.checked = !box.checked;
          toast("Не получилось — вернул как было", "bad");
        } else if (jobUnresolved(outcome)) {
          // Итог неизвестен: в конфиге ничего не откатывалось, поэтому не
          // трогаем чекбокс и не обещаем, что вернули как было.
          const m = unresolvedMsg(outcome);
          if (m) toast(m, "bad");
          resyncToggle(key, box);
        } else {
          toast(wanted === "1" ? "Включено" : "Выключено");
        }
        if (restarts && !jobUnresolved(outcome)) setTimeout(refreshStatus, 500);
      },
    });
  }

  // Дождаться панели и взять фактическое значение из конфига, а не гадать.
  async function resyncToggle(key, box) {
    const s = await awaitPanelBack();
    if (!s || !s.toggles) return;
    // За время ожидания юзер мог запустить новую задачу — её результат
    // свежее нашего чтения, не затираем.
    if (_activeJobs.size) return;
    const on = key === "rst_filter" ? rstIsOn(s.toggles[key]) : s.toggles[key] === "1";
    box.checked = on;
    toast("Связь есть — фактически " + (on ? "включено" : "выключено"));
    refreshStatus();
  }

  // ---------- WARP ----------
  // Раздел «WARP»: тумблер включения (бывший «Игровой режим (WARP)» со
  // страницы «Режимы») + пользовательские списки IPv4/CIDR, которые целиком
  // грузятся в ipset z2k_warp и маршрутизируются через туннель Cloudflare
  // WARP (usque/MASQUE). Списки — файлы /opt/zapret2/lists/warp/*.txt,
  // редактируются здесь же (textarea), экспорт/импорт — обычный .txt.
  let _warpLists = [];  // кэш последнего GET /warp/lists — для проверок имени при создании/импорте

  function warpNameValid(n) {
    return /^[A-Za-z0-9._-]{1,64}$/.test(n) && !/^[.-]/.test(n);
  }

  function fmtSize(b) {
    b = Number(b) || 0;
    if (b < 1024) return b + " Б";
    if (b < 1048576) return Math.round(b / 1024) + " КБ";
    return (b / 1048576).toFixed(1) + " МБ";
  }

  async function renderWarp() {
    $app.innerHTML = `
      <h1 class="page-title">WARP</h1>
      <div class="card">
        <div class="toggle-row" data-key="game_warp">
          <div class="t-text">
            <div class="t-name">WARP-туннель</div>
            <div class="t-desc">Заворачивает трафик к адресам из списков ниже в туннель
              Cloudflare WARP (usque/MASQUE по TCP 443 — работает из РФ, где нативный
              WireGuard-WARP по UDP режут). Помогает сервисам, заблокированным по IP:
              игровым серверам, хостингам, диапазонам Cloudflare/AWS из списка РКН.
              Это не десинк, а туннель — трафик к этим адресам идёт через Cloudflare
              и может быть медленнее прямого.</div>
          </div>
          <label class="switch">
            <input type="checkbox" disabled>
            <span class="slider"></span>
          </label>
        </div>
        <div class="status-grid" id="warp-status-grid">${skeletonBlocks(3)}</div>
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
      host.innerHTML = `<p class="desc">Не удалось загрузить: ${escapeHtml(e.message)}</p>`;
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
      toast("Ошибка: " + e.message, "bad");
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
      grid.innerHTML = `<div class="status-cell bad"><div class="label">Ошибка</div><div class="value">${escapeHtml(e.message)}</div></div>`;
      return;
    }
    if (_stale("warpStatus", seq)) return;
    const enabled = d.enabled === "1";
    const box = $app.querySelector('[data-key="game_warp"] input');
    if (box) {
      // Checked-состояние синкаем ВСЕГДА. С disabled аккуратнее: если сейчас
      // идёт job, свитч залочен _updateGlobalUILock'ом — не раслочиваем его в
      // обход лока, а поправляем lockBackup, чтобы разлочка после job'а
      // вернула enabled (шаблон рендерит <input disabled>, и лок иначе
      // запоминает это исходное disabled как «правильное» состояние).
      box.checked = enabled;
      if (_activeJobs.size) {
        if (box.dataset.lockBackup !== undefined) box.dataset.lockBackup = "0";
      } else {
        box.disabled = false;
      }
    }
    // Туннель — три состояния, не два. d.live это результат сквозной проверки (запрос к
    // Cloudflare ЧЕРЕЗ интерфейс): true = трафик реально ходит, false = интерфейс поднят,
    // но туннель мёртв, null = ещё не проверялось. Раньше здесь было только «есть адрес»,
    // а адрес роутер выдаёт интерфейсу независимо от того, установилось ли соединение с
    // Cloudflare — поэтому панель показывала «работает» на полностью мёртвом туннеле.
    let tunnelValue, tunnelKind;
    if (!d.tunnel_up) {
      tunnelValue = "не запущен";
      tunnelKind = enabled ? "bad" : "";
    } else if (d.live === false) {
      tunnelValue = "поднят, но трафик не идёт";
      tunnelKind = "bad";
    } else if (d.live === true) {
      tunnelValue = "работает" + (d.addr ? " · " + d.addr : "");
      tunnelKind = "good";
    } else {
      tunnelValue = "поднят, проверяется" + (d.addr ? " · " + d.addr : "");
      tunnelKind = "";
    }
    const cells = [
      { label: "Туннель", value: tunnelValue, kind: tunnelKind },
      { label: "Клиент usque", value: d.installed ? "установлен" : "ставится при первом включении",
        kind: d.installed ? "good" : "" },
      { label: "Адресов в маршрутизации", value: enabled ? String(d.entries) : "—",
        kind: enabled && Number(d.entries) > 0 ? "good" : "" },
    ];
    grid.innerHTML = cells.map(c => {
      const icon = statusIcon(c.kind);
      return `<div class="status-cell ${c.kind}"><div class="label">${c.label}</div><div class="value">${icon ? `<span class="status-ico">${icon}</span>` : ""}${escapeHtml(c.value)}</div></div>`;
    }).join("");
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
      toast("Ошибка: " + e.message, "bad");
      return;
    }
    openJobModal((wanted === "1" ? "Включаю" : "Отключаю") + " WARP-туннель", resp.job, {
      onDone: (d) => {
        sw.classList.remove("loading");
        box.disabled = false;
        const outcome = jobOutcome(d);
        if (outcome === JOB_FAIL) {
          box.checked = !box.checked;
          toast("Не получилось — вернул как было", "bad");
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
      list.innerHTML = `<li style="color:var(--bad)">${escapeHtml(e.message)}</li>`;
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
        toast("Не удалось загрузить список: " + e.message, "bad");
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
      toast("Ошибка: " + e.message, "bad");
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
      toast("Ошибка экспорта: " + e.message, "bad");
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
      toast("Ошибка: " + e.message, "bad");
    }
  }

  // ---------- Исключения: «Домены» + «Адреса» ----------
  //
  // Два способа сказать «сюда не лезь», и они разные по существу, а не по
  // удобству. Домен исключается по имени и только там, где имя вообще видно в
  // запросе. Адрес исключается по получателю пакета — поэтому работает и там,
  // где имени нет: камеры, домофоны, звонки, игры.
  //
  // Одна страница, две подвкладки — тем же приёмом, что «Стратегии»: подвкладка
  // это адрес, значит на неё можно сослаться и она переживает перезагрузку
  // страницы. Маршруты остались историческими (#/whitelist — «Домены»,
  // #/exclude — «Адреса»), чтобы старые закладки открывали то же содержимое.
  const EXCLUDE_TABS = [
    { id: "domains", route: "whitelist", label: "Домены",
      hint: "Исключить сайт по его имени — сразу со всеми поддоменами" },
    { id: "addresses", route: "exclude", label: "Адреса",
      hint: "Исключить по адресу получателя — там, где имени в запросе нет: камеры, домофоны, звонки" },
  ];

  function excludeShell(activeId, bodyHtml) {
    const tabs = EXCLUDE_TABS.map(t => `
      <a href="#/${t.route}" class="strat-tab${t.id === activeId ? " active" : ""}"
         role="tab" aria-selected="${t.id === activeId}" title="${escapeHtml(t.hint)}">
        ${escapeHtml(t.label)}
      </a>`).join("");
    const active = EXCLUDE_TABS.find(t => t.id === activeId) || EXCLUDE_TABS[0];
    return `
      <h1 class="page-title">Исключения</h1>
      <div class="strat-tabs" role="tablist" aria-label="Виды исключений">${tabs}</div>
      <p class="desc strat-tabhint">${escapeHtml(active.hint)}</p>
      ${bodyHtml}
    `;
  }

  async function renderExcludeAddresses() {
    $app.innerHTML = excludeShell("addresses", `
      <div class="card">
        <h3>Не трогать эти адреса</h3>
        <p class="desc">
          Всё, что идёт на перечисленные здесь адреса, z2k пропускает как есть —
          как будто обход для них выключен. Исключение работает по адресу
          получателя, поэтому помогает и там, где имени сайта в запросе нет
          вообще: камеры и домофоны, звонки и видеосвязь, игры и обмен данными
          между устройствами напрямую.
        </p>
        <p class="desc">
          Вписывать нужно <b>адрес</b> (например <code>203.0.113.7</code>) или
          <b>подсеть</b> (например <code>203.0.113.0/24</code>). Работает сразу
          и остаётся в силе после перезагрузки роутера. Имя сайта здесь не
          сработает — для него вкладка <a href="#/whitelist">«Домены»</a>.
        </p>
        <p class="desc">
          Локальная сеть (192.168.x, 10.x, 172.16–31.x и подобные) исключена
          всегда и без этого списка — добавлять её сюда не нужно.
        </p>
        <div class="wl-add">
          <label class="field">
            <span class="field-label">Адрес или подсеть</span>
            <input id="ex-input" type="text" placeholder="203.0.113.7 или 203.0.113.0/24"
                   inputmode="url" autocomplete="off" autocapitalize="off"
                   spellcheck="false" autocorrect="off">
          </label>
          <button class="btn btn-primary" id="ex-add-btn">Добавить</button>
        </div>
        <ul class="wl-list" id="ex-list">${skeletonLines(5)}</ul>
      </div>
      <div id="ex-legacy"></div>
    `);
    document.getElementById("ex-add-btn").addEventListener("click", exAdd);
    document.getElementById("ex-input").addEventListener("keydown", e => {
      if (e.key === "Enter") exAdd();
    });
    loadExclude();
  }

  async function loadExclude() {
    const list = document.getElementById("ex-list");
    const seq = _newLoad("exclude");
    try {
      const d = await apiGet("/exclude");
      if (_stale("exclude", seq)) return;
      const entries = d.entries || [];
      if (!entries.length) {
        list.innerHTML = `<li style="color:var(--text-muted)">(пусто)</li>`;
      } else {
        list.innerHTML = entries.map(en => `
          <li><span>${escapeHtml(en)}</span><button class="btn-icon" title="Удалить" aria-label="Удалить ${escapeHtml(en)}" data-del="${escapeHtml(en)}">${_icons.close}</button></li>
        `).join("");
        list.querySelectorAll("button[data-del]").forEach(btn => {
          btn.addEventListener("click", () => exDelete(btn.dataset.del));
        });
      }
      renderExcludeLegacy(d.legacy_domains || []);
    } catch (e) {
      if (_stale("exclude", seq)) return;
      list.innerHTML = `<li style="color:var(--bad)">${escapeHtml(e.message)}</li>`;
    }
  }

  // Имена сайтов, осевшие в адресном списке, пока панель их сюда принимала.
  // Они не действовали ни дня, но и молча прятать их нельзя — человек вписывал
  // их осознанно и считает, что они работают. Блок появляется только когда
  // такие записи есть.
  function renderExcludeLegacy(domains) {
    const box = document.getElementById("ex-legacy");
    if (!box) return;
    if (!domains.length) { box.innerHTML = ""; return; }
    box.innerHTML = `
      <div class="card">
        <h3>Эти записи ничего не делают</h3>
        <p class="desc">
          Раньше сюда можно было вписать и имя сайта. По имени здесь ничего не
          исключается, поэтому такие записи просто лежат в списке и ни на что
          не влияют. Чтобы они заработали, добавьте их на вкладке
          <a href="#/whitelist">«Домены»</a>, а отсюда удалите.
        </p>
        <ul class="wl-list" id="ex-legacy-list">${domains.map(dom => `
          <li><span>${escapeHtml(dom)}</span><button class="btn-icon" title="Удалить" aria-label="Удалить ${escapeHtml(dom)}" data-del="${escapeHtml(dom)}">${_icons.close}</button></li>
        `).join("")}</ul>
      </div>
    `;
    box.querySelectorAll("button[data-del]").forEach(btn => {
      btn.addEventListener("click", () => exDelete(btn.dataset.del));
    });
  }

  async function exAdd() {
    const inp = document.getElementById("ex-input");
    const entry = inp.value.trim();
    if (!entry) return;
    try {
      await apiPost("/exclude/add", { entry });
      inp.value = "";
      toast("Добавлено");
      loadExclude();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }
  }

  async function exDelete(entry) {
    try {
      await apiPost("/exclude/delete", { entry });
      toast("Удалено");
      loadExclude();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }
  }

  async function renderExcludeDomains() {
    $app.innerHTML = excludeShell("domains", `
      <div class="card">
        <h3>Не трогать эти сайты</h3>
        <p class="desc">
          Всё, что идёт на перечисленные здесь сайты, z2k пропускает как есть.
          Так исключают то, что ломается от вмешательства в трафик: банки и
          госуслуги, рабочие сервисы, магазины игр. Достаточно одного имени —
          <code>example.com</code> закрывает и все его поддомены.
        </p>
        <p class="desc">
          <b>Изменения вступают в силу за несколько секунд, перезапускать
          сервис не нужно.</b> Имя работает там, где оно видно в запросе; если
          приложение ходит без имени — камеры, домофоны, звонки — исключать его
          нужно на вкладке <a href="#/exclude">«Адреса»</a>.
        </p>
        <div class="wl-add">
          <label class="field">
            <span class="field-label">Новый сайт</span>
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
    `);
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
        headers: { ...PANEL_HDR, "Content-Type": "text/plain;charset=utf-8" },
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
    const seq = _newLoad("whitelist");
    try {
      const d = await apiGet("/whitelist");
      if (_stale("whitelist", seq)) return;
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
      if (_stale("whitelist", seq)) return;
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
  // «Дополнительные домены» — одна страница, две подвкладки. Вторая появляется
  // только при включённом автохостлисте: пока он выключен, показывать там
  // нечего, а пустая вкладка читается как «функция сломана».
  //
  // Состояние тумблера берём из /status, а не из адреса: страницу открывают по
  // прямой ссылке, и вкладка обязана быть честной сразу, без промежуточного
  // «есть/нет».
  async function extraShell(activeId, bodyHtml) {
    let autoOn = false;
    try {
      const st = await apiGet("/status");
      autoOn = String(st?.toggles?.autohostlist || "0") === "1";
    } catch (e) { autoOn = activeId === "auto"; }
    const tabs = [
      { id: "own", route: "extra-domains", label: "Свои",
        hint: "Домены, которые вы добавили вручную" },
    ];
    if (autoOn || activeId === "auto") {
      tabs.push({ id: "auto", route: "autohostlist", label: "Автохостлист",
        hint: "Домены, которые автохостлист определил как заблокированные сам" });
    }
    const active = tabs.find(t => t.id === activeId) || tabs[0];
    const tabsHtml = tabs.map(t => `
      <a href="#/${t.route}" class="strat-tab${t.id === activeId ? " active" : ""}"
         role="tab" aria-selected="${t.id === activeId}" title="${escapeHtml(t.hint)}">
        ${escapeHtml(t.label)}
      </a>`).join("");
    return `
      <h1 class="page-title">Дополнительные домены</h1>
      ${tabs.length > 1 ? `<div class="strat-tabs" role="tablist" aria-label="Виды доменов">${tabsHtml}</div>
      <p class="desc strat-tabhint">${escapeHtml(active.hint)}</p>` : ""}
      ${bodyHtml}
    `;
  }

  async function renderAutohostlistDomains() {
    $app.innerHTML = await extraShell("auto", `
      <div class="card">
        <h3>Найдено автохостлистом</h3>
        <p class="desc">
          Автохостлист сам определяет, какие сайты у вас блокируются, и добавляет их
          в обработку. Здесь видно, что он набрал. Список сохраняется и переживает
          обновление основного списка блокировок.
          Если сюда попал сайт, которому обход не нужен — удалите его,
          и он больше не вернётся.
        </p>
        <ul class="wl-list" id="ah-list">${skeletonLines(5)}</ul>
      </div>
    `);
    loadAutohostlistDomains();
  }

  async function loadAutohostlistDomains() {
    const list = document.getElementById("ah-list");
    if (!list) return;
    const seq = _newLoad("autohostDomains");
    try {
      const d = await apiGet("/autohostlist-domains");
      if (_stale("autohostDomains", seq)) return;
      if (!d.domains.length) {
        list.innerHTML = `<li style="color:var(--text-muted)">(пока ничего не найдено)</li>`;
        return;
      }
      list.innerHTML = d.domains.map(dom => `
        <li><span>${escapeHtml(dom)}</span><button class="btn-icon" title="Удалить" aria-label="Удалить ${escapeHtml(dom)}" data-del="${escapeHtml(dom)}">${_icons.close}</button></li>
      `).join("");
      list.querySelectorAll("button[data-del]").forEach(btn => {
        btn.addEventListener("click", () => ahDelete(btn.dataset.del));
      });
    } catch (e) {
      if (_stale("autohostDomains", seq)) return;
      list.innerHTML = `<li style="color:var(--bad)">${escapeHtml(e.message)}</li>`;
    }
  }

  async function ahDelete(domain) {
    try {
      await apiPost("/autohostlist-domains/delete", { domain });
      toast("Удалено");
      loadAutohostlistDomains();
    } catch (e) {
      toast("Ошибка: " + e.message, "bad");
    }
  }

  async function renderExtraDomains() {
    $app.innerHTML = await extraShell("own", `
      <div class="card">
        <h3>Живой список доменов</h3>
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
    `);
    document.getElementById("ed-add-btn").addEventListener("click", edAdd);
    document.getElementById("ed-input").addEventListener("keydown", e => {
      if (e.key === "Enter") edAdd();
    });
    loadExtraDomains();
  }

  async function loadExtraDomains() {
    const list = document.getElementById("ed-list");
    const seq = _newLoad("extraDomains");
    try {
      const d = await apiGet("/extra-domains");
      if (_stale("extraDomains", seq)) return;
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
      if (_stale("extraDomains", seq)) return;
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

  // ---------- Job modal ----------
  // Registry of currently-running jobs. Each entry survives modal close
  // (user clicks "Скрыть") and powers the bottom-right badge — click on
  // the badge re-opens the modal with the same jobId so user can check
  // progress again.
  const _activeJobs = new Map(); // jobId → { title, opts }

  // Чем кончилась фоновая задача. Провал и «мы не знаем, чем кончилось» —
  // разные вещи: во втором случае в конфиге ничего не откатывалось, и
  // говорить «вернул как было» нельзя, это прямая ложь.
  const JOB_OK = "ok";
  const JOB_FAIL = "fail";
  const JOB_GONE = "gone";        // записи о задаче больше нет (job_reap / ребут)
  const JOB_OFFLINE = "offline";  // панель перестала отвечать, итог не узнали
  // JOB_REFUSED больше нет. Он означал «панель на связи и ответила отказом»,
  // но на практике им становился 404 от lighttpd во время переустановки —
  // то есть штатный переезд дерева подавался человеку как отказ.
  function jobOutcome(d) {
    if (!d) return JOB_GONE;
    if (d.outcome) return d.outcome;
    // status==="unknown" трактуем терминально САМИ, не полагаясь на done в
    // ответе: роутер мог не обновиться, и старый бекенд на неизвестный id
    // отдаёт HTTP 200 с done:false — поллер тогда крутится вечно.
    if (d.status === "unknown") return JOB_GONE;
    return d.exit === 0 ? JOB_OK : JOB_FAIL;
  }
  // Итог не получен: откатывать UI нельзя, надо перечитать состояние.
  function jobUnresolved(o) { return o === JOB_GONE || o === JOB_OFFLINE; }
  // Про неопределённый исход человеку НЕ СООБЩАЕТСЯ ничего.
  //
  // Здесь стояли «Связь с панелью пропала» и «Панель ответила ошибкой» — оба
  // с хвостом «чем кончилось, пока неизвестно». Во время переустановки они
  // выпадали каждому: панель на три минуты уезжает вместе с деревом, и это
  // норма, а не происшествие. Текст пустой — toast() такой молча гасит, а UI
  // просто перечитывает состояние (см. jobUnresolved).
  function unresolvedMsg(_o) { return ""; }

  // Ждём, пока панель снова начнёт отвечать. Рестарт nfqws2 перетряхивает
  // iptables на том же канале, через который открыта панель, — обрыв на
  // десятки секунд здесь штатный, поэтому ждём долго и молча.
  async function awaitPanelBack(timeoutMs = 120000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      try { return await apiGet("/status"); }
      catch (e) {
        // Панель ответила отказом — она на связи, ждать её «возвращения»
        // бессмысленно: так можно простоять все две минуты на ровном месте.
        // Но 404 и 5xx-«поднимаюсь» отказом НЕ считаются: при переустановке
        // корень и CGI переезжают вместе с /opt/zapret2, и живой lighttpd без
        // файлов отвечает именно 404. Ждать тут как раз и надо.
        if (isRefusal(e)) return null;
        if (Date.now() >= deadline) return null;
        await new Promise(r => setTimeout(r, 2000));
      }
    }
  }

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
  // Пока лок держит элемент, его настоящее состояние лежит в lockBackup, а
  // .disabled принудительно true. Прямая запись в .disabled в это время
  // теряется: снятие лока вернёт значение, снятое ДО перечитывания статуса.
  // Поэтому загрузчики состояния пишут через эту обёртку.
  function setLockAware(el, disabled) {
    if (!el) return;
    if (el.dataset.lockBackup !== undefined) el.dataset.lockBackup = disabled ? "1" : "0";
    else el.disabled = disabled;
  }

  function _updateGlobalUILock() {
    const busy = _activeJobs.size > 0;
    const lockMsg = "Дождитесь завершения текущей операции";
    // Сравнение именно с undefined: lockBackup === "0" — валидный бэкап
    // («был включён»), но строка "0" ложна, и на !dataset.lockBackup вторая
    // задача перезаписывала бэкап уже залоченным значением "1". После неё
    // элемент оставался выключенным навсегда — до перезагрузки страницы.
    document.querySelectorAll(".switch input[type=\"checkbox\"]").forEach(cb => {
      if (busy) {
        if (cb.dataset.lockBackup === undefined) {
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
    // #uninstall-btn ОБЯЗАН быть в этом списке. Без него кнопка удаления
    // оставалась живой во время чужой фоновой задачи: можно было запустить
    // снос дерева параллельно идущей переустановке — общего замка у них нет,
    // и `rm -rf` гонялся бы с записью файлов установщиком. Тем же путём второй
    // клик по самой кнопке в первые секунды порождал второе удаление.
    document.querySelectorAll("[data-svc], #tg-enable, #tg-disable, #uninstall-btn").forEach(btn => {
      if (busy) {
        if (btn.dataset.lockBackup === undefined) {
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
      // Тот же список, что и у лока выше — иначе карточка удаления гасила бы
      // кнопку, но сама оставалась яркой, и выключенная кнопка выглядела бы
      // поломкой, а не занятостью.
      const hasLockableControl = card.querySelector(".switch input[type=\"checkbox\"], [data-svc], #tg-enable, #tg-disable, #uninstall-btn");
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
      httpErrors: 0,
      attachers: new Set(),      // (log, done, data) callbacks
    };
    _jobPollers.set(jobId, state);

    // Потолок опроса — предохранитель от вечного цикла, а не срок, после
    // которого «всё пропало». С tolerateOutage это 300 × 2 с ≈ десять минут:
    // с запасом перекрывает трёхминутную переустановку.
    const MAX_ERRORS = state.opts.tolerateOutage ? 300 : 5;
    // Три попытки — запас на разовый промах CGI, который на роутере под
    // памятью может не форкнуться. Больше держать определённый отказ незачем.
    const MAX_HTTP_ERRORS = 3;
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
        state.lastOutageWarn = 0;
        // Задачи нет: файлы подчистил job_reap или роутер перезагрузился
        // посреди операции. Ответ при этом успешный (HTTP 200), счётчик
        // сетевых ошибок его не поймает — терминальность решается здесь.
        if (jobOutcome(d) === JOB_GONE) {
          const log = (d.log || state.lastLog || "") +
            "\n[задача не найдена — роутер перезагрузился или запись о ней уже удалена]";
          const fin = { done: true, exit: null, status: "unknown", outcome: JOB_GONE, log };
          notify(log, true, fin);
          toast("Фоновая задача не найдена — проверьте состояние сервиса", "bad");
          finish(fin);
          return;
        }
        // «Снова на связи» не пишем: мы не говорили, что связь пропадала.
        const baseLog = d.log || "(нет вывода)";
        // Возврат связи отмечаем В ЛОГЕ — так было до p-73.2.
        const log = recovered ? baseLog + "\n[панель снова на связи]" : baseLog;
        notify(log, !!d.done, d);
        if (d.done) { finish(d); return; }
      } catch (e) {
        // НЕДОСТУПНАЯ ПАНЕЛЬ — ЭТО НЕ ИСХОД ЗАДАЧИ.
        //
        // Задача выполняется на роутере и от браузера не зависит: он всего
        // лишь смотрит на неё. Пока смотреть не получается, честный ответ —
        // «пока не знаю», а не «задача кончилась неизвестно чем».
        //
        // Раньше здесь стояло обратное: три неудачных опроса подряд объявляли
        // задачу законченной и дописывали в лог «панель ответила ошибкой».
        // Во время переустановки это срабатывало ВСЕГДА — дерево переезжает,
        // lighttpd остаётся жив и отвечает 404 — то есть человек ровно
        // посреди штатной установки получал сообщение о поломке, которой нет.
        // Ветки больше нет: временная недоступность просто пережидается.
        //
        // Настоящий отказ никуда не делся: 403 и 5xx приносят свой текст и
        // всплывают там, где их обрабатывают. Здесь они не превращают идущую
        // задачу в проваленную.
        state.consecutiveErrors++;
        // Определённый отказ (403, 5xx кроме «поднимаюсь») — это ОТВЕТ, а не
        // переезд: ждать его «возвращения» бессмысленно, и держать из-за него
        // весь UI залоченным десять минут нельзя. Такой опрос прекращаем
        // быстро — но так же молча: что произошло на самом деле, человеку
        // покажет перечитанное с роутера состояние, а не наша догадка.
        if (isRefusal(e)) state.httpErrors++; else state.httpErrors = 0;
        // ЗАДАЧА, КОТОРАЯ УБИВАЕТ САМУ ПАНЕЛЬ.
        //
        // Для удаления пропажа сервера — не «переезд, переждём», а ожидаемый
        // финал: lighttpd гасится вместе со всем деревом и не поднимется.
        // Ждать его «возвращения» здесь означало бы врать десять минут подряд,
        // а потом всё равно закончить молчанием.
        //
        // Порог небольшой, но не единичный: одиночный промах CGI на роутере
        // под памятью бывает и без всякого удаления, и объявлять по нему
        // «z2k удалён» нельзя. Десять подряд по две секунды — это двадцать
        // секунд тишины, столько штатная пауза не длится.
        if (state.opts.expectGone && state.consecutiveErrors >= 10) {
          const clean = String(state.lastLog || "").replace(/\n\[панель.*\]$/g, "");
          // ИТОГ НЕ ОБЪЯВЛЯЕТСЯ УСПЕШНЫМ, И ЭТО ВАЖНО.
          //
          // Молчание сервера говорит ровно одно: панели больше нет. Про то,
          // чем кончилось удаление, оно не говорит ничего — а панель гасится
          // ВТОРЫМ действием, задолго до чистки правил, сноса дерева и
          // конфига. Всё, что упадёт после (носитель ушёл в read-only,
          // коробку перезагрузили), случится уже за нашей спиной.
          //
          // Здесь стояло exit: 0 и «z2k удалён». Это была догадка, поданная
          // как факт: человек читал «удалён», закрывал вкладку, а дерево и
          // правила оставались на месте, и проверить было уже нечем —
          // журнал задачи лежит в /tmp и доступен только по SSH.
          //
          // Поэтому статус unknown: опрос прекращается, UI разблокируется,
          // но успех не заявлен. В логе — что известно и что делать дальше.
          const log = clean +
            "\n[панель выключилась — так и должно быть, она удаляется вместе с z2k]" +
            "\n[дальше удаление идёт без неё, и результат отсюда уже не виден]" +
            "\n[если z2k остался, откройте меню в терминале — пункт 5]";
          const fin = { done: true, exit: null, status: "unknown", log };
          notify(log, true, fin);
          finish(fin);
          return;
        }
        if (state.httpErrors >= MAX_HTTP_ERRORS || state.consecutiveErrors >= MAX_ERRORS) {
          // В лог не дописываем ничего: jobUnresolved заставит UI перечитать
          // состояние, и человек увидит факт вместо жалобы.
          finish({ done: true, exit: null, outcome: JOB_OFFLINE, log: state.lastLog });
          return;
        }
      }
        // ПРИЗНАК ЖИЗНИ, ПОКА ПАНЕЛЬ НЕ ОТВЕЧАЕТ.
        //
        // Лог во время переезда дерева замирает на последней строке, и
        // молчание неотличимо от зависшей установки — именно на это и
        // пожаловались: «ни логов, ни того, что панель скоро вернётся».
        // До p-73.2 счётчик ожидания здесь был; его снесли ЗАОДНО с ложными
        // вердиктами («панель ответила ошибкой… чем кончилась задача,
        // неизвестно»). Вердикты убраны правильно, счётчик — нет: он ничего
        // не утверждает о судьбе задачи, он показывает, что мы ещё ждём.
        // Предыдущую строку затираем, чтобы лог не рос столбиком.
        if (state.consecutiveErrors === 2
            || (state.consecutiveErrors - state.lastOutageWarn) >= 15) {
          const secs = Math.round(state.consecutiveErrors * POLL_ERR_MS / 1000);
          const clean = String(state.lastLog || "").replace(/\n\[панель.*\]$/g, "");
          // При удалении панель не «пока не отвечает», а выключается насовсем —
          // и обещать её возвращение нельзя.
          notify(clean + (state.opts.expectGone
            ? "\n[панель выключается вместе с z2k… " + secs + "с]"
            : "\n[панель пока не отвечает, ждём… " + secs + "с]"), false, null);
          state.lastOutageWarn = state.consecutiveErrors;
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

  // Подтверждение со своими подписями кнопок. Нативный confirm() тут не
  // годится: его кнопки всегда OK/Отмена, а вопрос вида «Включать /
  // Не включать» ответом «ОК» не описывается.
  // Разметка — те же классы, что у openJobModal: своих в style.css нет.
  // Подтверждение НАБОРОМ СЛОВА — для единственного необратимого действия.
  //
  // Обычная модалка «Да/Отмена» здесь не годится: она отделяет от катастрофы
  // одним кликом, а к кликам «Да» в диалогах у всех выработан рефлекс. Набор
  // слова требует прочитать, что именно произойдёт, и физически это набрать.
  // Приём стандартный для необратимых операций (так спрашивают об удалении
  // репозитория на GitHub и проекта в Vercel), и здесь он уместен ровно по той
  // же причине: восстановления нет, есть только установка заново.
  //
  // То же слово проверяет и сервер: панель работает без авторизации и доверяет
  // всей локальной сети, поэтому единственный необратимый вызов в API не должен
  // срабатывать от голого POST.
  function confirmTypedModal(title, lines, word, okLabel) {
    return new Promise(resolve => {
      const prevFocus = document.activeElement;
      const backdrop = document.createElement("div");
      backdrop.className = "modal-backdrop";
      backdrop.innerHTML = `
        <div class="modal" role="dialog" aria-modal="true"
             aria-labelledby="typed-title" aria-describedby="typed-text">
          <h3 id="typed-title">${escapeHtml(title)}</h3>
          <div class="modal-warning" id="typed-text">
            ${lines.map(l => `<p>${escapeHtml(l)}</p>`).join("")}
          </div>
          <label class="typed-confirm-label" for="typed-input">
            Наберите <b>${escapeHtml(word)}</b>, чтобы подтвердить
          </label>
          <input type="text" id="typed-input" class="typed-confirm-input"
                 autocomplete="off" autocapitalize="characters" spellcheck="false">
          <div class="modal-footer">
            <button class="btn btn-danger" id="typed-ok" disabled>${escapeHtml(okLabel)}</button>
            <button class="btn btn-primary" id="typed-cancel">Отмена</button>
          </div>
        </div>
      `;
      document.body.appendChild(backdrop);
      const input = backdrop.querySelector("#typed-input");
      const okBtn = backdrop.querySelector("#typed-ok");
      const cancelBtn = backdrop.querySelector("#typed-cancel");

      let answered = false;
      function finish(answer) {
        if (answered) return;
        answered = true;
        document.removeEventListener("keydown", onKey);
        backdrop.remove();
        if (prevFocus && typeof prevFocus.focus === "function") prevFocus.focus();
        resolve(answer);
      }
      // Сверяем без учёта регистра и краевых пробелов: требование — прочитать и
      // осознанно набрать, а не попасть в раскладку и Caps Lock.
      const matches = () => input.value.trim().toLocaleUpperCase("ru") === word;
      const sync = () => { okBtn.disabled = !matches(); };
      // Начальное состояние выставляем КОДОМ, а не только атрибутом в разметке:
      // атрибут легко потерять при правке шаблона, и тогда кнопка удаления
      // окажется активной с первой миллисекунды — ровно то, от чего диалог и
      // защищает. Плюс браузер может восстановить значение поля при возврате
      // на страницу, и тогда состояние кнопки обязано ему соответствовать.
      sync();
      input.addEventListener("input", sync);
      function onKey(e) {
        if (e.key === "Escape") { finish(false); return; }
        if (e.key === "Enter" && document.activeElement === input) {
          // Enter в поле подтверждает, только если слово уже совпало — иначе
          // это просто попытка отправить полупустую форму.
          if (matches()) { e.preventDefault(); finish(true); }
          return;
        }
        if (e.key !== "Tab") return;
        const stops = [input, okBtn, cancelBtn];
        const first = e.shiftKey ? stops[stops.length - 1] : stops[0];
        const last = e.shiftKey ? stops[0] : stops[stops.length - 1];
        if (document.activeElement === last || !backdrop.contains(document.activeElement)) {
          e.preventDefault();
          first.focus();
        }
      }
      okBtn.addEventListener("click", () => { if (matches()) finish(true); });
      cancelBtn.addEventListener("click", () => finish(false));
      backdrop.addEventListener("click", (e) => { if (e.target === backdrop) finish(false); });
      document.addEventListener("keydown", onKey);
      // Фокус в поле: диалог не подталкивает к согласию — кнопка выключена,
      // пока слово не набрано, — но и не заставляет искать, куда печатать.
      input.focus();
    });
  }

  function confirmModal(title, text, okLabel, cancelLabel) {
    return new Promise(resolve => {
      const prevFocus = document.activeElement;
      const backdrop = document.createElement("div");
      backdrop.className = "modal-backdrop";
      // role/aria — по образцу sort-sheet ниже по файлу. Без них скринридер не
      // объявляет ни факт открытия диалога, ни сам текст предупреждения, ради
      // которого диалог и существует: озвучивалось только «кнопка».
      // Акцентной покрашена БЕЗОПАСНАЯ кнопка, а не «Включать»: визуальный
      // дефолт обязан совпадать с клавиатурным, иначе диалог подталкивает
      // ровно к тому действию, от которого предостерегает.
      backdrop.innerHTML = `
        <div class="modal" role="dialog" aria-modal="true"
             aria-labelledby="confirm-title" aria-describedby="confirm-text">
          <h3 id="confirm-title">${escapeHtml(title)}</h3>
          <div class="modal-warning" id="confirm-text">${escapeHtml(text)}</div>
          <div class="modal-footer">
            <button class="btn" id="confirm-ok">${escapeHtml(okLabel)}</button>
            <button class="btn btn-primary" id="confirm-cancel">${escapeHtml(cancelLabel)}</button>
          </div>
        </div>
      `;
      document.body.appendChild(backdrop);
      const okBtn = backdrop.querySelector("#confirm-ok");
      const cancelBtn = backdrop.querySelector("#confirm-cancel");

      let answered = false;
      function finish(answer) {
        // Escape и клик по кнопке могут прийти в одном кадре — промис резолвим
        // ровно один раз, второй ответ молча отбрасываем.
        if (answered) return;
        answered = true;
        document.removeEventListener("keydown", onKey);
        backdrop.remove();
        if (prevFocus && typeof prevFocus.focus === "function") prevFocus.focus();
        resolve(answer);
      }
      // Ловушка фокуса. Подложка position:fixed останавливает мышь, но Tab
      // из неё выходит на страницу — оттуда можно было повторно дёрнуть тот же
      // контрол и получить ВТОРУЮ модалку поверх первой, с теми же id.
      function onKey(e) {
        if (e.key === "Escape") { finish(false); return; }
        if (e.key !== "Tab") return;
        // Строго в порядке DOM: список задом наперёд ломает ровно то, ради чего
        // ловушка сделана — с изначально сфокусированной кнопки первый же Tab
        // не считался «последним» и уходил на страницу под диалогом.
        const stops = [okBtn, cancelBtn];
        const first = e.shiftKey ? stops[stops.length - 1] : stops[0];
        const last = e.shiftKey ? stops[0] : stops[stops.length - 1];
        if (document.activeElement === last || !backdrop.contains(document.activeElement)) {
          e.preventDefault();
          first.focus();
        }
      }

      okBtn.addEventListener("click", () => finish(true));
      cancelBtn.addEventListener("click", () => finish(false));
      // Клик мимо окна = отказ; клик внутри окна не закрывает ничего.
      backdrop.addEventListener("click", (e) => { if (e.target === backdrop) finish(false); });
      document.addEventListener("keydown", onKey);
      // Фокус на ОТКАЗЕ: это предупреждение, и случайный Enter обязан не
      // включить ничего.
      cancelBtn.focus();
    });
  }

  // ---------- Rotator state (Phase 3) ----------
  // Sort state shared across loadState() invocations so a refresh
  // (manual button or after delete) preserves the chosen column.
  // Defaults: profile asc — same order as the previous unsorted view.
  //
  // Persisted per browser under z2k-state-sort, next to z2k-sidebar and the
  // theme key: it is a display preference, not router configuration, and one
  // value is shared by the desktop headers and the mobile sheet — two different
  // orders on the same screen surprise more than they help.
  const STATE_SORT_KEY = "z2k-state-sort";
  // The labels double as the mobile sheet's option list, so the set of sortable
  // keys is declared once and cannot drift between the two controls.
  const STATE_SORT_LABELS = { key: "Профиль", host: "Домен", strategy: "Стратегия", age: "Возраст" };

  function loadStateSort() {
    // Anything unrecognised falls back to the default. A stale value (a column
    // renamed in a later release) would otherwise leave the table sorted by
    // nothing at all, which reads as a broken load rather than a stale setting.
    const fallback = { key: "key", dir: "asc" };
    try {
      const raw = localStorage.getItem(STATE_SORT_KEY);
      if (!raw) return fallback;
      const v = JSON.parse(raw);
      if (!v || !STATE_SORT_LABELS[v.key]) return fallback;
      if (v.dir !== "asc" && v.dir !== "desc") return fallback;
      return { key: v.key, dir: v.dir };
    } catch (_) { return fallback; }
  }
  function saveStateSort() {
    try { localStorage.setItem(STATE_SORT_KEY, JSON.stringify(stateSort)); } catch (_) {}
  }

  let stateSort = loadStateSort();
  let statePools = {};   // key -> strategy-pool size, from GET /pools (live nfqws2)

  // ---------- «Стратегии»: одна дверь, два вида ----------
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

  function strategiesShell(activeId, bodyHtml) {
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

  async function renderState() {
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
        statePools = (poolsResp && poolsResp.pools) || {};
        entries = d.entries || [];
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
      const sortBtn = document.getElementById("state-sort-btn");
      if (sortBtn) sortBtn.addEventListener("click", openSortSheet);
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
      body.innerHTML = `<p style="color:var(--bad)">${escapeHtml(e.message)}</p>`;
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
      toast("Ошибка: " + e.message, "bad");
    }
  }

  async function stateClearAll() {
    if (!confirm("Удалить все записи?\n\nКаждый домен начнёт подбор с первой стратегии при следующей попытке, заморозки тоже снимутся. Сервис перезапускать не нужно.")) return;
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
      toast("Не удалось скачать отчёт: " + e.message, "bad");
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
      el.textContent = "Ошибка: " + e.message;
    }
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

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Alex</div>
          <p class="desc">
            Счета за VPS приходят каждый месяц — независимо от того, помнит
            о них кто-нибудь или нет. В этот раз их закрыл ты, и Telegram-туннель
            продолжил работать для всех, кто о существовании этих счетов даже
            не догадывается. Спасибо.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">GRM</div>
          <p class="desc">
            Спасибо, что не прошёл мимо. Сам обход работает на роутере, а всё
            вокруг него — Telegram-туннель, зеркала для обновлений, служебные
            сервисы — живёт на сервере, и за него приходят счета. Проект
            складывается из вложенного в него времени и из таких вот взносов:
            ты закрыл ту часть, которую временем не закроешь.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Dez</div>
          <p class="desc">
            Спасибо, Dez. Поддержать проект никто не обязан, и каждый раз, когда
            это всё же происходит, работать дальше становится легче.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">hoaxx</div>
          <p class="desc">
            Спасибо, hoaxx. Такая поддержка делает проект устойчивее, а работу
            над ним — спокойнее.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Mansurchick</div>
          <p class="desc">
            Спасибо, Mansurchick. Часть обхода живёт не на роутере: чтобы найти
            рабочий адрес заблокированного сайта, нужен взгляд из-за границы —
            и сервер, который этим занят, держится в том числе на таких взносах.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">Dkarloff - SEO отец</div>
          <p class="desc">
            Спасибо за поддержку проекта. Такие взносы держат на плаву всё, что
            вокруг обхода — туннель, зеркала обновлений и служебные сервисы, —
            и позволяют развивать z2k дальше.
          </p>
        </div>

        <div class="card credits-card sponsor-card">
          <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
          <div class="credits-name">KIBERPANK</div>
          <p class="desc">
            Спасибо, KIBERPANK. У проекта нет ни рекламы, ни платных версий —
            он держится ровно на таких людях, и благодаря им остаётся
            бесплатным для всех остальных.
          </p>
        </div>
      </div>
    `;
  }

  const STRATEGY_POOL_NAMES = {
    rkn_tcp: "Заблокированные сайты (TCP)",
    yt_tcp:  "YouTube (TCP)",
    gv_tcp:  "YouTube видео (TCP)",
    yt_quic: "YouTube (QUIC/UDP)",
  };

  async function renderStrategies() {
    $app.innerHTML = strategiesShell("config", `
      <div class="card">
        <p class="desc">
          Обычно z2k подбирает стратегию сам: пробует варианты по очереди и
          закрепляет ту, что заработала. Здесь можно взять любой пул под себя и
          задать свою строку параметров — тогда для него подбор выключается и
          работает ровно то, что вы написали. Остальные пулы продолжат
          подбираться автоматически.
        </p>
        <p class="desc">
          <b>Свои строки переживают обновления и переустановку.</b> Перед
          сохранением строка проверяется движком: непрошедшая проверку не
          применяется, потому что одна ошибка в ней останавливает обход целиком,
          а не только этот пул.
        </p>
        <p class="desc">
          Нужно не на весь пул, а разово поправить один домен — это на вкладке
          <a href="#/state">«Автоподбор»</a>.
        </p>
      </div>
      <div id="strategy-pools">${skeletonBlocks(4)}</div>
    `);
    loadStrategyPools();
    _updateGlobalUILock();
  }

  async function loadStrategyPools() {
    const host = document.getElementById("strategy-pools");
    if (!host) return;
    const seq = _newLoad("strategyPools");
    let d;
    try {
      d = await apiGet("/strategy/pools");
    } catch (e) {
      if (_stale("strategyPools", seq)) return;
      host.innerHTML = `<p class="desc">Не удалось загрузить: ${escapeHtml(e.message)}</p>`;
      return;
    }
    if (_stale("strategyPools", seq)) return;
    const pools = (d && d.pools) || [];
    host.innerHTML = pools.map(p => {
      const custom = p.custom === 1 || p.custom === "1";
      const title = STRATEGY_POOL_NAMES[p.pool] || p.pool;
      return `
        <div class="card" data-pool="${escapeHtml(p.pool)}">
          <div class="toggle-row">
            <div class="t-text">
              <div class="t-name">${escapeHtml(title)}</div>
              <div class="t-desc">${custom
                ? "Своя стратегия — автоподбор для этого пула выключен"
                : "Автоподбор: стратегия выбирается и меняется автоматически"}</div>
            </div>
            <button type="button" class="btn ${custom ? "" : "btn-primary"}" data-act="mode">
              ${custom ? "Вернуть авто" : "Своя стратегия"}
            </button>
          </div>
          <div class="strategy-editor" hidden>
            <textarea class="strategy-text" rows="6" spellcheck="false"
              placeholder="--lua-desync=fake:dir=out:repeats=2 …"></textarea>
            <div class="btn-row" style="margin-top:10px">
              <button type="button" class="btn" data-act="check">Проверить</button>
              <button type="button" class="btn btn-primary" data-act="save">Сохранить и применить</button>
            </div>
            <p class="desc strategy-msg" hidden></p>
          </div>
        </div>`;
    }).join("");

    host.querySelectorAll("[data-pool]").forEach(card => {
      const pool = card.getAttribute("data-pool");
      const ed   = card.querySelector(".strategy-editor");
      const ta   = card.querySelector(".strategy-text");
      const msg  = card.querySelector(".strategy-msg");
      const say = (text, good) => {
        msg.hidden = false;
        msg.textContent = text;
        msg.style.color = good ? "var(--good)" : "var(--bad)";
      };

      const isCustom = card.querySelector('[data-act="mode"]').textContent.trim() === "Вернуть авто";
      if (isCustom) { ed.hidden = false; loadStrategyText(pool, ta, say); }

      card.querySelector('[data-act="mode"]').addEventListener("click", async () => {
        if (isCustom) {
          if (!confirm(`Вернуть «${STRATEGY_POOL_NAMES[pool] || pool}» на автоподбор?\n\nВаша строка будет удалена.`)) return;
          try { await apiPost("/strategy/pool/reset", { pool }); }
          catch (e) { toast("Ошибка: " + e.message, "bad"); return; }
          toast("Пул вернулся на автоподбор");
          loadStrategyPools();
        } else {
          ed.hidden = !ed.hidden;
          if (!ed.hidden && !ta.value) loadStrategyText(pool, ta, say);
        }
      });

      card.querySelector('[data-act="check"]').addEventListener("click", async () => {
        say("Проверяю…", true);
        try {
          const r = await apiPostText("/strategy/pool/validate?pool=" + encodeURIComponent(pool), ta.value);
          if (r && r.valid) say("Строка корректна — можно сохранять", true);
          else say("Не принято движком: " + (r && r.error ? r.error : "неизвестная ошибка"), false);
        } catch (e) { say("Ошибка проверки: " + e.message, false); }
      });

      card.querySelector('[data-act="save"]').addEventListener("click", async () => {
        // Пустое поле — это либо неудавшееся чтение, либо ничего не введено.
        // И то и другое ушло бы на бекенд пустым телом поверх рабочей строки.
        if (!ta.value.trim()) {
          say("Строка пустая — сохранять нечего. Чтобы отключить свою строку, вернитесь на автоподбор.", false);
          return;
        }
        say("Проверяю и применяю…", true);
        try {
          await apiPostText("/strategy/pool/save?pool=" + encodeURIComponent(pool), ta.value);
        } catch (e) {
          // The line was rejected — nothing was applied and the previous state
          // is untouched, which is exactly what the message must convey.
          say("Не сохранено: " + e.message, false);
          return;
        }
        toast("Стратегия применена, сервис перезапущен — автоподбор для пула выключен");
        loadStrategyPools();
      });
    });
  }

  async function loadStrategyText(pool, ta, say) {
    try {
      ta.value = await apiGetText("/strategy/pool?pool=" + encodeURIComponent(pool));
    } catch (e) {
      // Молчаливая пустая textarea читается как «строка пропала»: юзер жмёт
      // «Сохранить и применить», и на бекенд уходит пустое тело поверх
      // работающей строки. Поэтому — сказать вслух и не подсовывать пустоту.
      ta.value = "";
      if (say) say("Не удалось прочитать текущую строку: " + e.message +
                   ". Не сохраняйте, пока она не загрузится — отправится пустая.", false);
    }
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
    // Lucide pencil / download (MIT) — WARP list row actions.
    edit:         '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg>',
    download:     '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>',
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

  // ---------- Sort sheet (mobile) ----------
  // The mobile breakpoint hides the table head (style.css: .state-table thead
  // { display: none }) and turns rows into cards — which removed the ONLY sort
  // control there was, since sorting lives in the column headers. This is the
  // mobile equivalent.
  //
  // A bottom sheet rather than a <select>: it keeps the list visible behind it,
  // gives finger-sized targets, and avoids what native selects do to long option
  // lists on a phone. NN/g's rules for sheets are followed — a visible close
  // button, dismissal by Escape/Back and by tapping the scrim, and never
  // stacked on top of another sheet.
  //
  // Direction is a SECOND tap on the already-selected option, mirroring the
  // second click on a desktop header. One control instead of two, same mental
  // model, and the arrow on the row says which way it currently goes.
  function ensureSortSheet() {
    let sheet = document.getElementById("sort-sheet");
    if (sheet) return sheet;
    const wrap = document.createElement("div");
    wrap.innerHTML = `
      <div class="sheet-backdrop" id="sort-sheet-backdrop" hidden></div>
      <div class="sheet" id="sort-sheet" role="dialog" aria-modal="true"
           aria-labelledby="sort-sheet-title" hidden>
        <div class="sheet-header">
          <span id="sort-sheet-title">Сортировка</span>
          <button type="button" class="sheet-close" id="sort-sheet-close" aria-label="Закрыть">${_icons.close || "\u2715"}</button>
        </div>
        <div class="sheet-body" id="sort-sheet-options"></div>
      </div>`;
    while (wrap.firstElementChild) document.body.appendChild(wrap.firstElementChild);
    sheet = document.getElementById("sort-sheet");
    document.getElementById("sort-sheet-backdrop").addEventListener("click", closeSortSheet);
    document.getElementById("sort-sheet-close").addEventListener("click", closeSortSheet);
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !sheet.hidden) closeSortSheet();
    });
    return sheet;
  }

  function renderSortOptions() {
    const box = document.getElementById("sort-sheet-options");
    if (!box) return;
    box.innerHTML = Object.keys(STATE_SORT_LABELS).map(k => {
      const active = stateSort.key === k;
      const arrow = active ? (stateSort.dir === "asc" ? _icons.arrowUp : _icons.arrowDown) : "";
      return `<button type="button" class="sheet-option${active ? " active" : ""}"
                      data-sort="${k}" aria-pressed="${active}">
                <span>${STATE_SORT_LABELS[k]}</span><span class="sheet-option-arrow">${arrow}</span>
              </button>`;
    }).join("");
    box.querySelectorAll("[data-sort]").forEach(btn => {
      btn.addEventListener("click", () => {
        const key = btn.dataset.sort;
        if (stateSort.key === key) {
          stateSort.dir = stateSort.dir === "asc" ? "desc" : "asc";
        } else {
          stateSort.key = key;
          // Same default as the desktop header: numeric column starts largest-first.
          stateSort.dir = (key === "strategy") ? "desc" : "asc";
        }
        saveStateSort();
        renderSortOptions();   // reflect the new arrow before closing
        closeSortSheet();
        resortState();
      });
    });
  }

  function openSortSheet() {
    const sheet = ensureSortSheet();
    const backdrop = document.getElementById("sort-sheet-backdrop");
    renderSortOptions();
    sheet.hidden = false;
    backdrop.hidden = false;
    requestAnimationFrame(() => {
      sheet.classList.add("sheet-open");
      backdrop.classList.add("sheet-open");
    });
    const trigger = document.getElementById("state-sort-btn");
    if (trigger) trigger.setAttribute("aria-expanded", "true");
    document.body.style.overflow = "hidden";
  }

  function closeSortSheet() {
    const sheet = document.getElementById("sort-sheet");
    const backdrop = document.getElementById("sort-sheet-backdrop");
    if (!sheet) return;
    sheet.classList.remove("sheet-open");
    if (backdrop) backdrop.classList.remove("sheet-open");
    const trigger = document.getElementById("state-sort-btn");
    if (trigger) trigger.setAttribute("aria-expanded", "false");
    document.body.style.overflow = "";
    setTimeout(() => {
      sheet.hidden = true;
      if (backdrop) backdrop.hidden = true;
    }, 220);
  }

  // ---------- Boot ----------
  initTheme();
  initSidebar();
  initDrawer();
  if (!location.hash) location.hash = "#/dashboard";
  navigate();
})();
