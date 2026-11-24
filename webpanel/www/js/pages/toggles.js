import { apiGet, apiPost, errHtml, errMsg, toastErr } from "../core/api.js";
import { $app } from "../core/dom.js";
import { _newLoad, _stale, refreshStatus } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { JOB_FAIL, _activeJobs, _updateGlobalUILock, awaitPanelBack, confirmModal, jobOutcome, jobUnresolved, openJobModal, setLockAware, unresolvedMsg } from "../job.js";
import { AUTOHOSTLIST_WARNING, TOGGLES_RESTART_SERVICE, resyncToggle } from "./policy.js";

const TOGGLE_DEFS = [
  { key: "category_youtube", name: "YouTube", category: true,
    desc: "YouTube и Googlevideo, включая QUIC." },
  { key: "category_rkn", name: "RKN", category: true,
    desc: "Сайты из списков РКН и автоподбор новых доменов." },
  { key: "category_discord_voice", name: "Discord Voice / STUN", category: true,
    desc: "Голос Discord и STUN, в том числе в звонках других приложений." },
  // game_warp переехал в собственный раздел «WARP» (renderWarp) вместе с
  // управлением списками адресов — здесь его больше нет.
  { key: "customd", name: "Скрипты custom.d",
    desc: "Дополнительные daemons из init.d/custom.d (50-stun4all, 50-discord-media)." },
  // ТЕКСТ БЫЛ НЕ ПРОСТО НЕЯСНЫМ, А НЕВЕРНЫМ. Здесь стояло «инжекция
  // ФИКСИРОВАННОГО TTL» — ровно наоборот: смысл опции в том, что значение
  // динамическое. И назначением был назван обход обнаружения раздачи, хотя
  // раздача — единственная причина опцию ВЫКЛЮЧИТЬ. Люди сравнивали с README и
  // говорили, что там понятнее; там и было правильно.
  { key: "dynamic_ttl", name: "Динамический TTL",
    desc: "Пакеты-обманки, которыми z2k пробивает блокировку, по умолчанию уходят с одним и тем же счётчиком переходов. У настоящих пакетов с вашего роутера он другой — и по этому расхождению обманку несложно отличить от обычного трафика. Опция подгоняет счётчик под настоящий, и обманка перестаёт выделяться. Выключайте в одном случае: если на роутере включён TTL-fix Keenetic для раздачи мобильного интернета. Там счётчик всё равно переписывает прошивка, наша правка до провода не доживает и только тратит процессор." },
  { key: "autohostlist", name: "Автохостлист",
    desc: "Обычно обходятся только домены из списков. С этой опцией движок сам замечает, что домен не открывается, и добавляет его — найденное попадает в основной список и подхватывается штатно. Плюс: сайты вне списков начинают работать без ручных добавлений. Минус: движок судит по поведению соединения и иногда ошибается, в список может попасть домен, который просто лежал сам по себе. Это смена принципа отбора трафика целиком, поэтому по умолчанию выключено." },
  // Час не зашит в текст: он настраивается ниже, и описание, называющее
  // «02:00» у человека, выбравшего 05:00, врало бы прямо над селектором.
  { key: "auto_update", name: "Автообновление",
    desc: "Ночью роутер сам проверяет обновления и устанавливает их. Выключите, если хотите обновляться только вручную — кнопка «Обновить» продолжит работать, и панель по-прежнему покажет, что доступна новая версия.",
    extra: `
      <div class="t-sub" id="au-hour-row" hidden>
        <label class="t-sub-label" for="au-hour">Время</label>
        <select class="t-sub-select" id="au-hour" disabled></select>
        <span class="t-sub-note" id="au-hour-note"></span>
      </div>` },
];

// Разброс запуска: z2k-auto-update.sh сдвигает старт на 0..60 минут
// (z2k_host_jitter 3600) — одинаково для конкретного роутера, но по флоту
// врассыпную, иначе тысяча роутеров придёт к GitHub в одну секунду.
const AU_JITTER_MIN = 60;

const PANEL_SESSION_TTLS = new Set(["7200", "43200", "86400", "604800"]);

async function loadPanelSessionTtl() {
  const sel = document.getElementById("panel-session-ttl");
  const note = document.getElementById("panel-session-ttl-note");
  if (!sel) return;
  try {
    const data = await apiGet("/auth/session-ttl");
    if (!sel.isConnected) return;
    const value = String(data && data.seconds);
    sel.value = PANEL_SESSION_TTLS.has(value) ? value : "86400";
    sel.dataset.saved = sel.value;
    sel.disabled = false;
    if (note) note.textContent = "Настройка будет действовать после следующего входа. Текущая сессия сохранит прежний срок.";
    if (!sel.dataset.wired) {
      sel.dataset.wired = "1";
      sel.addEventListener("change", () => savePanelSessionTtl(sel, note));
    }
  } catch (error) {
    if (!sel.isConnected) return;
    sel.disabled = true;
    if (note) note.textContent = "Не удалось прочитать настройку срока сессии.";
    toastErr("Не удалось прочитать срок сессии: ", error);
  }
}

async function savePanelSessionTtl(sel, note) {
  const value = sel.value;
  const previous = sel.dataset.saved || "86400";
  if (!PANEL_SESSION_TTLS.has(value) || value === previous) return;
  sel.disabled = true;
  try {
    await apiPost("/auth/session-ttl", { seconds: value });
    sel.dataset.saved = value;
    if (note) note.textContent = "Срок сохранён и начнёт действовать после следующего входа; текущая сессия завершится по прежнему сроку.";
    toast("Срок сессии изменён");
  } catch (error) {
    sel.value = previous;
    if (note) note.textContent = "Не удалось сохранить срок; оставлено прежнее значение.";
    toastErr("Не удалось сохранить срок сессии: ", error);
  } finally {
    if (sel.isConnected) sel.disabled = false;
  }
}

function auWindowText(hour) {
  const h = Number(hour);
  if (!Number.isInteger(h) || h < 0 || h > 23) return "";
  const end = (h * 60 + AU_JITTER_MIN) % (24 * 60);
  const pad = n => String(n).padStart(2, "0");
  return `обновится между ${pad(h)}:00 и ${pad(Math.floor(end / 60))}:${pad(end % 60)} — разброс, чтобы все роутеры не пришли за обновлением одновременно`;
}

// Выбор времени имеет смысл только при включённом автообновлении, поэтому
// строка следует за тумблером. Живёт отдельной функцией, а не внутри
// обработчика: то же самое делает загрузка состояния и откат неудавшегося
// переключения в toggleClick — иначе строка осталась бы от прошлого ответа.
function auHourSync(box) {
  const row = document.getElementById("au-hour-row");
  if (!row || !box) return;
  row.hidden = !box.checked;
}

// Часы, а не часы с минутами: разброс в час делает минутную точность
// обещанием, которого механизм не даёт.
function wireAuHour(hour, box) {
  const sel = document.getElementById("au-hour");
  const note = document.getElementById("au-hour-note");
  if (!sel) return;
  // children, а не options: список заполняется один раз, а повторный
  // /status приходит на ту же страницу — 24 варианта не должны удваиваться.
  if (!sel.children.length) {
    for (let h = 0; h < 24; h++) {
      const v = String(h).padStart(2, "0");
      const o = document.createElement("option");
      o.value = v;
      o.textContent = `${v}:00`;
      sel.appendChild(o);
    }
  }
  const cur = /^([01][0-9]|2[0-3])$/.test(String(hour || "")) ? String(hour) : "02";
  sel.value = cur;
  // Сохранённое значение держим на самом элементе: с него откатывается
  // выбор, если запись в конфиг не прошла.
  sel.dataset.saved = cur;
  setLockAware(sel, false);
  if (note) note.textContent = auWindowText(cur);
  if (!sel.dataset.wired) {
    sel.dataset.wired = "1";
    sel.addEventListener("change", () => saveAuHour(sel, note));
  }
  auHourSync(box);
}

async function saveAuHour(sel, note) {
  const val = sel.value;
  const prev = sel.dataset.saved || "02";
  if (val === prev) return;
  sel.disabled = true;
  try {
    await apiPost("/update/schedule", { hour: val });
  } catch (e) {
    // Показанный час обязан совпадать с тем, что лежит в конфиге: иначе
    // человек уходит со страницы уверенным, что выбрал время, а ночью
    // сработает старое.
    sel.value = prev;
    if (note) note.textContent = auWindowText(prev);
    toastErr("Не удалось сохранить время: ", e);
    return;
  } finally {
    sel.disabled = false;
  }
  sel.dataset.saved = val;
  if (note) note.textContent = auWindowText(val);
  toast(`Автообновление в ${val}:00`);
}

const TOGGLE_API_NAME = {
  category_youtube: "category-youtube",
  category_rkn: "category-rkn",
  category_discord_voice: "category-discord-voice",
  yt_autopilot: "yt-autopilot",
  gv_preflight: "gv-preflight",
  yt_quic_off: "yt-quic-off",
  quic_off: "quic-off",
  customd: "customd",
  dynamic_ttl: "dynamic-ttl",
  auto_update: "auto-update",
  autohostlist: "autohostlist",
};

const AP_OVERRIDE_DEFS = [
  { key: "gv_preflight", name: "Обход по ответу сервера (Preflight)", video: true,
    desc: "«Авто» проверяет адреса по политике автопилота; «Вкл» запускает пробу перед каждым соединением; «Выкл» отключает пробу без остановки службы замеров." },
  { key: "yt_quic_off", name: "YouTube без QUIC", video: true,
    desc: "«Авто» пропускает QUIC только для узлов, прошедших проверку 2/2; «Вкл» всегда отправляет отказ; «Выкл» запрещает автопилоту резать QUIC YouTube." },
  { key: "quic_off", name: "Весь QUIC через TCP", video: false,
    desc: "«Авто» отключает QUIC глобально только при выявлении блокировки на сети; «Вкл» режет весь QUIC (кроме исключений); «Выкл» отключает авто-блокировку." },
];

function normalizeOverrideVal(key, raw, apOn) {
  const v = String(raw || "");
  if (v === "1" || v === "off" || v === "auto") return v;
  if (key === "gv_preflight") return v === "0" ? "off" : "auto";
  if (v === "0") return apOn ? "auto" : "off";
  return "auto";
}

function formatApTime(tsSec) {
  const n = Number(tsSec);
  if (!Number.isFinite(n) || n <= 0) return "";
  try {
    return new Date(n * 1000).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
  } catch (_) {
    return "";
  }
}

function renderAutopilotCard() {
  const overrideRows = AP_OVERRIDE_DEFS.map(o => `
    <div class="toggle-row ap-override-row" data-key="${o.key}">
      <div class="t-text">
        <div class="t-name">${o.name}</div>
        <div class="t-desc">${o.desc}</div>
        ${o.video ? '<div class="t-desc yt-off-note" hidden>Недоступно: обход YouTube выключен.</div>' : ""}
      </div>
      <select class="t-sub-select ap-override-select" id="ap-sel-${o.key}"
              data-override="${o.key}" data-lock-select="1"
              aria-label="${o.name}" disabled>
        <option value="auto">Авто (по умолчанию)</option>
        <option value="1">Принудительно Вкл</option>
        <option value="off">Принудительно Выкл</option>
      </select>
    </div>`).join("");
  return `
    <div class="card card-compact" id="autopilot-card">
      <div class="toggle-row ap-master-row" data-key="yt_autopilot">
        <div class="t-text">
          <div class="ap-title-row">
            <h3 style="margin:0">Автопилот видео YouTube</h3>
            <span class="tg-state-badge" id="ap-state-badge" hidden></span>
          </div>
          <div class="t-desc">
            Сам измеряет доступность кэшей YouTube и Google Play, отсеивает мёртвые узлы, калибрует тайминги под ваш канал и управляет QUIC / preflight.
          </div>
          <div class="t-desc yt-off-note" id="ap-yt-off-note" hidden>Недоступно: обход YouTube выключен.</div>
        </div>
        <label class="switch" title="Автоматическое управление видео YouTube">
          <input type="checkbox" id="ap-master-switch" aria-label="Автопилот видео YouTube" disabled>
          <span class="slider"></span>
        </label>
      </div>
      <div class="ap-telemetry" id="ap-telemetry">
        <div class="ap-metric" id="ap-metric-caches">
          <div class="ap-metric-label">Кэши видео</div>
          <div class="ap-metric-value" id="ap-caches-val">—</div>
          <div class="ap-metric-sub" id="ap-caches-sub">Загружаю данные автопилота…</div>
        </div>
        <div class="ap-metric" id="ap-metric-quic">
          <div class="ap-metric-label">QUIC HTTP/3</div>
          <div class="ap-metric-value" id="ap-quic-val">—</div>
          <div class="ap-metric-sub" id="ap-quic-sub">—</div>
        </div>
        <div class="ap-metric" id="ap-metric-rtt">
          <div class="ap-metric-label">Самокалибровка канала</div>
          <div class="ap-metric-value" id="ap-rtt-val">—</div>
          <div class="ap-metric-sub" id="ap-rtt-sub">—</div>
        </div>
        <div class="ap-metric" id="ap-metric-fuse">
          <div class="ap-metric-label">Safety Fuse</div>
          <div class="ap-metric-value" id="ap-fuse-val">—</div>
          <div class="ap-metric-sub" id="ap-fuse-sub">—</div>
        </div>
      </div>
      <details class="ap-debug disclosure" id="ap-debug">
        <summary>Ручное переопределение (для отладки)</summary>
        <div class="disclosure-body">
          <div class="ap-debug-inner">
            <p class="desc ap-debug-note">
              По умолчанию всё работает в режиме «Авто». Меняйте отдельные параметры только при отладке на проблемной сети.
            </p>
            <div class="t-desc yt-off-note" id="ap-manual-note" hidden>Автопилот выключен — в ручном режиме доступно только «Принудительно Вкл» или «Принудительно Выкл».</div>
            ${overrideRows}
          </div>
        </div>
      </details>
    </div>`;
}

function syncAutopilotBadge(ytOn, apOn, gvsubEnabled) {
  const badge = $app.querySelector("#ap-state-badge");
  if (!badge) return;
  badge.hidden = false;
  if (gvsubEnabled !== undefined) {
    badge.dataset.gvsub = gvsubEnabled === false ? "0" : "1";
  }
  const gvsubOk = badge.dataset.gvsub !== "0";
  if (!ytOn) {
    badge.textContent = "Недоступно: обход YouTube выключен";
    badge.className = "tg-state-badge tg-state-off";
  } else if (apOn && !gvsubOk) {
    badge.textContent = "Без замеров: gvsub выключен";
    badge.className = "tg-state-badge ap-state-manual";
  } else if (apOn) {
    badge.textContent = "Автопилот активен";
    badge.className = "tg-state-badge tg-state-on";
  } else {
    badge.textContent = "Ручной режим";
    badge.className = "tg-state-badge ap-state-manual";
  }
}

function syncAutopilotModeControls(apOn) {
  const manualNote = $app.querySelector("#ap-manual-note");
  if (manualNote) manualNote.hidden = apOn;
  AP_OVERRIDE_DEFS.forEach(o => {
    const sel = $app.querySelector(`#ap-sel-${o.key}`);
    if (!sel) return;
    const autoOpt = sel.querySelector('option[value="auto"]');
    if (autoOpt) autoOpt.disabled = !apOn;
  });
}

function updateAutopilotCard(s) {
  const t = (s && s.toggles) || {};
  const ap = (s && s.autopilot) || {};
  const ytOn = t.category_youtube === "1";
  const apOn = t.yt_autopilot !== "0";
  const gvsubEnabled = ap.gvsub_enabled !== false;

  syncAutopilotBadge(ytOn, apOn, gvsubEnabled);

  const masterBox = $app.querySelector("#ap-master-switch");
  if (masterBox) {
    masterBox.checked = apOn;
    setLockAware(masterBox, false);
  }

  const ytNote = $app.querySelector("#ap-yt-off-note");
  if (ytNote) ytNote.hidden = ytOn;

  const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
  const setMetric = (valId, subId, valText, subText, tone) => {
    const valEl = $app.querySelector("#" + valId);
    const subEl = $app.querySelector("#" + subId);
    if (valEl) {
      valEl.textContent = valText;
      valEl.className = "ap-metric-value" + (tone ? " ap-tone-" + tone : "");
    }
    if (subEl) subEl.textContent = subText;
  };

  if (ap.policy_present) {
    const v4 = num(ap.usable_v4);
    const v6 = num(ap.usable_v6);
    const ispGood = num(ap.isp_good);
    const ispDead = num(ap.isp_dead);
    const gGood = num(ap.google_good);
    const gByp = num(ap.google_bypassable);
    const gBad = num(ap.google_unbypassable) + num(ap.google_dead);
    const play = num(ap.play_count);
    const pfx = num(ap.prefixes_total);
    const ips = num(ap.ips_total);
    const qok = num(ap.quic_ok_count);
    const obs = num(ap.observed_count);

    setMetric(
      "ap-caches-val",
      "ap-caches-sub",
      `${v4} IPv4 · ${v6} IPv6 рабочих`,
      `ISP GGC: ${ispGood} раб. / ${ispDead} отсеяно · Google: ${gGood} чист. / ${gByp} обход. / ${gBad} недост.` +
        ` · Play: ${play} (преф. ${pfx}, IP ${ips})`,
      (v4 + v6 >= 1) ? "good" : "bad"
    );

    const ytQuicMode = normalizeOverrideVal("yt_quic_off", t.yt_quic_off, apOn);
    const allQuicMode = normalizeOverrideVal("quic_off", t.quic_off, apOn);
    let quicTitle;
    let quicTone = "";
    if (allQuicMode === "1") {
      quicTitle = "Весь QUIC → TCP (вручную)";
      quicTone = "warn";
    } else if (ap.global_quic_blocked && allQuicMode !== "off") {
      quicTitle = "Сеть режет QUIC → TCP";
      quicTone = "warn";
    } else if (qok > 0) {
      quicTitle = `HTTP/3 2/2: ${qok} узл.`;
      quicTone = "good";
    } else {
      quicTitle = "HTTP/3 2/2: нет рабочих";
      quicTone = "muted";
    }
    const ytQuicHint = ytQuicMode === "1"
      ? "YouTube QUIC: отказ (Вкл)"
      : ytQuicMode === "off"
        ? "YouTube QUIC: не трогать (Выкл)"
        : `YouTube QUIC 2/2: ${qok} из ${ips}`;
    const allQuicHint = allQuicMode === "off"
      ? "глобальный отказ отключён"
      : (ap.global_quic_blocked ? "выявлен общий блок QUIC" : "общего блока нет");
    setMetric("ap-quic-val", "ap-quic-sub", quicTitle, `${ytQuicHint} · ${allQuicHint}`, quicTone);

    const brtt = num(ap.baseline_rtt_ms);
    const grtt = num(ap.ggc_rtt_ms);
    const resyn = num(ap.resyn_delay_ms);
    const giveup = num(ap.preflight_giveup_ms);
    const stall = num(ap.ggc_stall_guard_ms);
    const sni = ap.preflight_sni ? String(ap.preflight_sni) : "—";
    setMetric(
      "ap-rtt-val",
      "ap-rtt-sub",
      `База ${brtt} мс · GGC ${grtt} мс`,
      `reSYN ${resyn} мс · giveup ${giveup} мс · stall ${stall} мс · SNI: ${sni}` +
        (obs > 0 ? ` · DoH/DoT: ${obs}` : ""),
      ""
    );

    const timeStr = formatApTime(ap.updated);
    const fuseVal = ap.stale
      ? "Устарело (fail-open)"
      : ap.safety_fuse_ok
        ? "Активен"
        : "Fail-open";
    const fuseTone = ap.stale ? "warn" : (ap.safety_fuse_ok ? "good" : "warn");
    const fuseSub = (ap.safety_fuse_ok
      ? `Рабочих кэшей ${v4 + v6} ≥ 1 — отсев и защита включены`
      : "Рабочих кэшей < 1 — активный сброс отключён во избежание обрыва") +
      (timeStr ? ` · обновлено ${timeStr}` : "");
    setMetric("ap-fuse-val", "ap-fuse-sub", fuseVal, fuseSub, fuseTone);
  } else {
    const obs = num(ap.observed_count);
    setMetric(
      "ap-caches-val",
      "ap-caches-sub",
      "Нет замеров",
      !gvsubEnabled
        ? "Служба замеров gvsub отключена (Z2K_GV_SERVER_REPLY2=0). Переключите «Автопилот видео YouTube» выкл → вкл, чтобы запустить замеры."
        : ap.gvsub_present
          ? "Служба gvsub запущена — ждём первых обращений к YouTube."
          : "Файл политики появится после запуска обхода и DNS-запросов YouTube.",
      !gvsubEnabled ? "warn" : "muted"
    );
    setMetric("ap-quic-val", "ap-quic-sub", "Не проверен", "Данные о прохождении HTTP/3 ещё не собраны.", "muted");
    setMetric(
      "ap-rtt-val",
      "ap-rtt-sub",
      "Ожидает калибровки",
      obs > 0 ? `DoH/DoT наблюдений: ${obs}` : "Замеры задержек появятся после первых обращений.",
      "muted"
    );
    setMetric(
      "ap-fuse-val",
      "ap-fuse-sub",
      "Ожидание (fail-open)",
      "Пока нет политики, автопилот не вмешивается в соединения.",
      "muted"
    );
  }

  syncAutopilotModeControls(apOn);
  AP_OVERRIDE_DEFS.forEach(o => {
    const sel = $app.querySelector(`#ap-sel-${o.key}`);
    if (!sel) return;
    const norm = normalizeOverrideVal(o.key, t[o.key], apOn);
    sel.value = norm;
    sel.dataset.saved = norm;
    setLockAware(sel, o.video ? !ytOn : false);
    const row = sel.closest(".ap-override-row");
    const note = row ? row.querySelector(".yt-off-note") : null;
    if (note) note.hidden = !o.video || ytOn;
  });
}

// Без категории YouTube профилей YouTube нет, и включённый тумблер обещал бы
// то, чего не происходит. Само значение при этом хранится и вернётся вместе с ней.
function syncGvPreflight(youtubeOn) {
  const ytNote = $app.querySelector("#ap-yt-off-note");
  if (ytNote) ytNote.hidden = youtubeOn;
  const masterBox = $app.querySelector("#ap-master-switch");
  if (masterBox) syncAutopilotBadge(youtubeOn, masterBox.checked);
  for (const key of ["gv_preflight", "yt_quic_off"]) {
    const sel = $app.querySelector(`#ap-sel-${key}`);
    if (sel) setLockAware(sel, !youtubeOn);
    const row = $app.querySelector(`.toggle-row[data-key="${key}"]`);
    const note = row ? row.querySelector(".yt-off-note") : null;
    if (note) note.hidden = youtubeOn;
  }
}

function toggleRows(defs) {
  return defs.map(t => `
        <div class="toggle-row" data-key="${t.key}">
          <div class="t-text">
            <div class="t-name">${t.name}</div>
            <div class="t-desc">${t.desc}</div>
            ${t.extra || ""}
          </div>
          <label class="switch">
            <input type="checkbox" aria-label="${t.name}" disabled>
            <span class="slider"></span>
          </label>
        </div>
`).join("");
}

export async function renderToggles() {
  $app.innerHTML = `
    <h1 class="page-title">Режимы</h1>
    <div class="probe-row" style="margin-bottom:14px">
      <input type="search" id="toggles-search" placeholder="Поиск по настройкам"
             autocomplete="off" autocapitalize="none" spellcheck="false">
    </div>
    <div class="card card-compact">
      <div id="toggles-error" hidden></div>
      <h3>Категории обхода</h3>
      <p class="desc">Изменение кратковременно перезапускает работающий обход.</p>
      ${toggleRows(TOGGLE_DEFS.filter(t => t.category))}
    </div>
    ${renderAutopilotCard()}
    <div class="card">
      <h3>Другие настройки</h3>
      ${toggleRows(TOGGLE_DEFS.filter(t => !t.category))}
    </div>
    <div class="card" id="panel-session-ttl-card">
      <h3>Срок входа в веб-панель</h3>
      <label class="field" for="panel-session-ttl">
        <span class="field-label">Запрашивать пароль снова через</span>
        <select class="t-sub-select" id="panel-session-ttl" disabled>
          <option value="7200">2 часа</option>
          <option value="43200">12 часов</option>
          <option value="86400">24 часа</option>
          <option value="604800">7 дней</option>
        </select>
      </label>
      <p class="desc" id="panel-session-ttl-note" role="status" aria-live="polite">Загружаю настройку…</p>
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
      setLockAware($app.querySelector("#ap-master-switch"), true);
      $app.querySelectorAll("[data-override]").forEach(sel => setLockAware(sel, true));
      setLockAware($app.querySelector("#tg-enable"), true);
      setLockAware($app.querySelector("#tg-disable"), true);
      // Селектор времени — тот же класс: не зная состояния, панель не знает
      // и текущего часа, а запись вслепую затёрла бы выбранный.
      setLockAware($app.querySelector("#au-hour"), true);
      errBox.hidden = false;
      errBox.innerHTML = `
        <p class="desc" style="color:var(--bad)">Не удалось прочитать состояние: ${errHtml(e)}.
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
    applyTogglesStatus(s);
  }

  function applyTogglesStatus(s) {
    // /status мог вернуться уже после ухода со страницы: $app очищен, ни
    // одного из этих элементов больше нет, и обращение к badge.hidden роняло
    // весь остаток renderToggles — вместе с привязкой кнопок туннеля,
    // секцией политики и глобальным локом.
    const badge = $app.querySelector("#tg-state-badge");
    if (!badge) return;
    if (!s || !s.toggles) return;
    if (errBox) { errBox.hidden = true; errBox.innerHTML = ""; }
    const onApplyRefresh = (nextStatus) => {
      if (!onTogglesPage()) return;
      if (nextStatus) applyTogglesStatus(nextStatus);
      else loadTogglesState();
    };
    // Чекбокс автообновления ловим здесь же: строка с временем ходит за ним,
    // и искать его вторым, другим селектором — способ однажды поехать врозь.
    let auBox = null;
    TOGGLE_DEFS.forEach(t => {
      const row = $app.querySelector(`[data-key="${t.key}"]`);
      if (!row) return;
      const box = row.querySelector("input");
      if (t.key === "auto_update") auBox = box;
      box.checked = s.toggles[t.key] === "1";
      setLockAware(box, false);
      // Повторная загрузка не должна вешать второй обработчик: два POST'а
      // на один клик — два конкурентных рестарта сервиса.
      if (!box.dataset.wired) {
        box.dataset.wired = "1";
        box.addEventListener("change", () => {
          // Строку времени показываем сразу по клику, не дожидаясь конца
          // джоба: ответ придёт через десяток секунд, а тумблер уже стоит
          // в новом положении — расхождение выглядело бы как залипание.
          if (t.key === "auto_update") auHourSync(box);
          toggleClick(t.key, box, t.key === "category_youtube" ? onApplyRefresh : null);
        });
      }
    });
    const masterBox = $app.querySelector("#ap-master-switch");
    if (masterBox && !masterBox.dataset.wired) {
      masterBox.dataset.wired = "1";
      masterBox.addEventListener("change", () => toggleClick("yt_autopilot", masterBox, onApplyRefresh));
    }
    AP_OVERRIDE_DEFS.forEach(o => {
      const sel = $app.querySelector(`#ap-sel-${o.key}`);
      if (!sel || sel.dataset.wired) return;
      sel.dataset.wired = "1";
      sel.addEventListener("change", () => overrideSelectChange(o.key, sel, onApplyRefresh));
    });
    updateAutopilotCard(s);
    wireAuHour(s.toggles && s.toggles.au_hour, auBox);
    syncGvPreflight(Boolean(s.toggles && s.toggles.category_youtube === "1"));
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
  loadPanelSessionTtl();

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
      toastErr("Ошибка: ", e);
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
        await new Promise(r => { setTimeout(r, 500); });
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

  const searchInput = $app.querySelector("#toggles-search");
  const apDebug = $app.querySelector("#ap-debug");
  let apSearchLock = false;
  if (apDebug) {
    apDebug.addEventListener("toggle", () => {
      if (!apSearchLock) apDebug.dataset.userOpen = apDebug.open ? "1" : "0";
    });
  }
  if (searchInput) {
    searchInput.addEventListener("input", () => {
      const q = searchInput.value.trim().toLowerCase();
      $app.querySelectorAll(".toggle-row[data-key]").forEach(row => {
        const text = (row.textContent || "").toLowerCase();
        row.hidden = q.length > 0 && !text.includes(q);
      });
      if (apDebug) {
        const hasHit = q.length > 0 && Array.from(apDebug.querySelectorAll(".ap-override-row[data-key]")).some(r => !r.hidden);
        apSearchLock = true;
        apDebug.open = q.length > 0 ? hasHit : apDebug.dataset.userOpen === "1";
        apSearchLock = false;
      }
    });
  }

  // ----- Policy access section -----
  const nameInput = $app.querySelector("#policy-name");
  const statusEl  = $app.querySelector("#policy-status");
  const segGroup  = $app.querySelector("#policy-mode");
  const saveBtn   = $app.querySelector("#policy-save-btn");
  // ПРАВИЛО ЗДЕСЬ ОБЯЗАНО СОВПАДАТЬ С СЕРВЕРНЫМ, И РАНЬШЕ НЕ СОВПАДАЛО.
  //
  // Стояло /^[A-Za-z0-9_-]{0,32}$/ — то есть латиница и всё. На сервере это
  // давно исправлено: политики Keenetic люди называют по-русски и с пробелами
  // («Незарегистрированные клиенты», «Через ВПН»), и обработчик их принимает.
  // А форма отбивала такое имя ДО отправки, поэтому серверная правка выглядела
  // сделанной, но пользователю по-прежнему было нельзя.
  //
  // Запрещаем ровно то же, что и сервер, и ровно по тем же причинам:
  //   " $ ` \ ;  — ломают `. config`, куда имя попадает через set_flag;
  //   '            — set_flag экранирует апостроф как '\'', а обратно это не
  //                  разворачивается: имя портится навсегда при первой же
  //                  перегенерации конфига;
  //   |            — policy_status отдаёт «name=%s|exclude=%s», и на чтении
  //                  назад имя срезалось бы по разделителю;
  //   перевод строки — по той же причине, что и всё выше.
  const NAME_BAD_RE = /["$`\\;'|\n\r]/;
  // Длина в СИМВОЛАХ, а не в кодовых единицах: '…'.length считает UTF-16, и
  // на суррогатных парах цифра разошлась бы с серверной, где считаются
  // символы UTF-8. Пустая строка валидна: сервер по ней выключает фильтр.
  const nameLen = (v) => Array.from(v).length;
  const nameOk  = (v) => !NAME_BAD_RE.test(v) && nameLen(v) <= 32;
  const NAME_HINT = "Имя политики: до 32 символов, нельзя \" $ ` \\ ; \u0027 |";

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
      setPolicyStatus("error", "Ошибка: " + errMsg(e));
    }
  }
  loadPolicyStatus();

  // Validate + (опционально) повторный status check на blur
  nameInput.addEventListener("blur", () => {
    const v = nameInput.value.trim();
    if (!nameOk(v)) {
      setPolicyStatus("error", NAME_HINT);
      return;
    }
    if (!v) {
      setPolicyStatus("muted", "Поле пусто — нажмите «Сохранить и применить», чтобы выключить фильтр");
    }
  });

  segGroup.addEventListener("click", (e) => {
    const btn = e.target.closest(".seg-btn");
    if (!btn) return;
    setPolicyMode(parseInt(btn.dataset.exclude, 10));
  });

  saveBtn.addEventListener("click", async () => {
    if (saveBtn.disabled) return;
    const v = nameInput.value.trim();
    if (!nameOk(v)) {
      toast(NAME_HINT, "bad");
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
      toastErr("Ошибка: ", e);
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

async function overrideSelectChange(key, sel, onReload) {
  const val = sel.value;
  const prev = sel.dataset.saved || "auto";
  if (val === prev) return;
  sel.disabled = true;
  const restarts = TOGGLES_RESTART_SERVICE[key] === 1;
  const labels = {
    gv_preflight: "обход по ответу сервера",
    yt_quic_off: "YouTube без QUIC",
    quic_off: "весь QUIC через TCP",
  };
  const verbs = {
    auto: "Перевожу в Авто:",
    1: "Принудительно включаю",
    off: "Принудительно отключаю",
  };
  const doneTexts = {
    auto: "Режим: Авто",
    1: "Принудительно включено",
    off: "Принудительно выключено",
  };
  let resp;
  try {
    resp = await apiPost("/toggle/" + TOGGLE_API_NAME[key], { value: val });
  } catch (e) {
    sel.value = prev;
    setLockAware(sel, false);
    toastErr("Ошибка: ", e);
    return;
  }
  // Снимаем локальный disable до openJobModal (как в tgAction): иначе
  // _updateGlobalUILock запомнит disabled=true в lockBackup и оставит селектор
  // заблокированным на время async awaitPanelBack() при обрыве связи.
  setLockAware(sel, false);
  openJobModal((verbs[val] || "Переключаю") + " " + (labels[key] || key), resp.job, {
    tolerateOutage: restarts,
    onDone: async (d) => {
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) {
        sel.value = prev;
        toast("Не получилось — вернул как было", "bad");
      } else if (jobUnresolved(outcome)) {
        const m = unresolvedMsg(outcome);
        if (m) toast(m, "bad");
        const s = await awaitPanelBack();
        if (!sel.isConnected) return;
        if (s && !_activeJobs.size) {
          toast("Связь с панелью восстановлена — состояние обновлено");
          refreshStatus();
          if (onReload) onReload(s);
        }
      } else {
        sel.dataset.saved = val;
        toast(doneTexts[val] || "Сохранено");
      }
      if (!sel.isConnected) return;
      const ytBox = $app.querySelector('[data-key="category_youtube"] input');
      const ytLocked = (key === "gv_preflight" || key === "yt_quic_off") && ytBox && !ytBox.checked;
      setLockAware(sel, !!ytLocked);
      if (restarts && !jobUnresolved(outcome)) {
        setTimeout(() => {
          refreshStatus();
          if (onReload) onReload();
        }, 500);
      }
    },
  });
}

async function toggleClick(key, box, onApplied) {
  const sw = box.closest(".switch");
  const wanted = key === "yt_autopilot" ? (box.checked ? "auto" : "0") : (box.checked ? "1" : "0");
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
  const verb = wanted === "0" ? "Отключаю" : "Включаю";
  const niceName = {
    category_youtube: "YouTube",
    category_rkn: "RKN",
    category_discord_voice: "Discord Voice / STUN",
    yt_autopilot: "автопилот видео YouTube",
    gv_preflight: "обход по ответу сервера для видео YouTube",
    yt_quic_off: "YouTube без QUIC",
    quic_off: "весь QUIC через TCP",
    customd: "custom.d",
    dynamic_ttl: "Динамический TTL",
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
    toastErr("Ошибка: ", e);
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
        resyncToggle(key, box, onApplied);
      } else {
        toast(wanted === "0" ? "Выключено" : "Включено");
      }
      // Чекбокс мог вернуться в прежнее положение (провал или resync) —
      // строка с временем обязана поехать за ним.
      if (key === "auto_update") auHourSync(box);
      if (key === "category_youtube") syncGvPreflight(box.checked);
      if (key === "yt_autopilot" && !jobUnresolved(outcome)) {
        const ytBox = $app.querySelector('[data-key="category_youtube"] input');
        const ytOn = ytBox ? ytBox.checked : true;
        syncAutopilotBadge(ytOn, box.checked, (outcome !== JOB_FAIL && box.checked) ? true : undefined);
        syncAutopilotModeControls(box.checked);
      }
      if (restarts && !jobUnresolved(outcome)) {
        setTimeout(() => {
          refreshStatus();
          if (onApplied) onApplied();
        }, 500);
      }
    },
  });
}
