import { apiGet, apiPost, errHtml, errMsg, toastErr } from "../core/api.js";
import { _icons, escapeHtml, humanAgo } from "../core/dom.js";
import { refreshStatus } from "../core/loadorder.js";
import { openJobModal } from "../job.js";

export async function refreshUpdateBanner(opts = {}) {
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
  // Подпись «когда оно само» — ответ на вопрос, который люди задают прямо
  // здесь, глядя на баннер (issue #60). Только текст: крутят время там же,
  // где и сам тумблер автообновления, а баннер целиком перерисовывается на
  // каждом опросе — настройке внутри него не на чем держаться.
  const auEnabled = !d || d.au_enabled !== "0";
  const auHour = /^([01][0-9]|2[0-3])$/.test(String((d && d.au_hour) || "")) ? d.au_hour : "02";
  const auNote = auEnabled
    ? ` · <a class="upd-au-link" href="#/toggles">автообновление в ${auHour}:00</a>`
    : ` · <a class="upd-au-link" href="#/toggles">автообновление выключено</a>`;
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
        <span class="update-banner-meta">установлена ${escapeHtml(installed)} · отстаёт на ${behind} · проверено ${ago}${auNote}</span>
      </div>
      <div class="update-banner-actions">
        <button class="btn btn-primary" id="upd-apply">Обновить</button>
        ${pending.length > 0 ? `<button class="btn btn-disclosure" id="upd-changelog-btn" aria-expanded="false"><span>Что нового</span>${_icons.chevronDown}</button>` : ""}
        <button class="btn" id="upd-history-link" type="button">История версий</button>
        <button class="btn" id="upd-recheck">Проверить ещё раз</button>
      </div>
      ${pending.length > 0 ? `
        <div class="update-banner-body" id="upd-changelog" hidden>
          <div class="upd-changelog">
            ${pending.map(e => renderChangelogEntry(e, false)).join("")}
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
    const why = err ? escapeHtml(errMsg(err)) : "список версий не скачался";
    const known = installed !== "?" ? `установлена ${escapeHtml(installed)} · ` : "";
    banner.hidden = false;
    banner.className = "update-banner";
    banner.innerHTML = `
      <div class="update-banner-text">
        <strong>Не удалось проверить обновления</strong>
        <span class="update-banner-meta">${known}${why} · последняя удачная проверка ${ago}</span>
      </div>
      <div class="update-banner-actions">
        <button class="btn" id="upd-history-link" type="button">История версий</button>
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
        <button class="btn" id="upd-history-link" type="button">История версий</button>
        <button class="btn" id="upd-recheck">Проверить ещё раз</button>
      </div>
    `;
  } else {
    banner.hidden = false;
    banner.className = "update-banner update-banner-ok";
    banner.innerHTML = `
      <div class="update-banner-text">
        <span>Установлена последняя версия (${escapeHtml(installed)})</span>
        <span class="update-banner-meta">проверено ${ago}${auNote}</span>
      </div>
      <div class="update-banner-actions">
        <button class="btn" id="upd-history-link" type="button">История версий</button>
        <button class="btn" id="upd-recheck">Проверить</button>
      </div>
    `;
  }

  const histLink = document.getElementById("upd-history-link");
  if (histLink) histLink.addEventListener("click", () => openHistoryModal({ installed, behind }));

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
    toastErr("Ошибка запуска: ", e);
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

function getMonthKey(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  try {
    const s = d.toLocaleDateString("ru-RU", { month: "long", year: "numeric" });
    const clean = s.replace(/\s*г\.?$/, "");
    return clean.charAt(0).toUpperCase() + clean.slice(1);
  } catch (_) {
    return iso.slice(0, 7);
  }
}

function renderChangelogEntry(e, isUninstalled) {
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
  const uninstalledBadge = isUninstalled
    ? `<span class="upd-uninstalled" title="Версия ещё не установлена">не установлено</span>`
    : "";
  return `
    <div class="upd-entry">
      <div class="upd-entry-head">
        <span class="upd-tag">${escapeHtml(v)}</span>
        <span class="upd-type ${typeCls}">${escapeHtml(type)}</span>
        ${resetBadge}
        ${uninstalledBadge}
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

// Полный архив открывается только отдельной кнопкой «История версий».
async function openHistoryModal(ctx = {}) {
  const installed = (ctx && ctx.installed) || "";
  const behind = Number((ctx && ctx.behind) || 0);
  const prevFocus = document.activeElement;
  const backdrop = document.createElement("div");
  backdrop.className = "modal-backdrop";
  backdrop.innerHTML = `
    <div class="modal" role="dialog" aria-modal="true" aria-labelledby="hist-modal-title">
      <div class="modal-header">
        <h3 id="hist-modal-title"></h3>
        <button class="modal-close" id="hist-modal-close" type="button" aria-label="Закрыть">${_icons.close}</button>
      </div>
      <div class="upd-history-list" id="hist-modal-list" tabindex="0">
        <div class="upd-history-loading">Загрузка…</div>
      </div>
      <div class="modal-footer">
        <button class="btn" id="hist-close-btn" type="button">Закрыть</button>
      </div>
    </div>
  `;

  document.body.appendChild(backdrop);

  const listEl = backdrop.querySelector("#hist-modal-list");
  const closeX = backdrop.querySelector("#hist-modal-close");
  const closeBtn = backdrop.querySelector("#hist-close-btn");
  const titleEl = backdrop.querySelector("#hist-modal-title");

  let closed = false;
  function closeModal() {
    if (closed) return;
    closed = true;
    document.removeEventListener("keydown", onKey);
    backdrop.remove();
    if (prevFocus && typeof prevFocus.focus === "function") {
      prevFocus.focus();
    }
  }

  function onKey(e) {
    if (e.key === "Escape") {
      e.preventDefault();
      closeModal();
    }
  }

  document.addEventListener("keydown", onKey);
  backdrop.addEventListener("click", e => {
    if (e.target === backdrop) closeModal();
  });
  if (closeX) closeX.addEventListener("click", closeModal);
  if (closeBtn) closeBtn.addEventListener("click", closeModal);
  if (closeBtn) closeBtn.focus();

  let inFlight = null;
  let offset = 0;
  const limit = 20;
  let total = 0;
  let lastMonthKey = "";
  let foundInstalled = false;

  function bindRetry() {
    const recheckBtn = listEl.querySelector("#hist-recheck-btn");
    if (recheckBtn) {
      recheckBtn.addEventListener("click", async () => {
        recheckBtn.disabled = true;
        recheckBtn.textContent = "Проверяем…";
        try {
          await refreshUpdateBanner({ force: true });
        } catch (_) {}
        offset = 0;
        lastMonthKey = "";
        foundInstalled = false;
        listEl.innerHTML = '<div class="upd-history-loading">Загрузка…</div>';
        await loadMore();
      });
    }
  }

  function showEmptyState() {
    listEl.innerHTML = `
      <div class="upd-history-empty">
        <p>Список версий ещё не скачан — роутер не смог сходить на GitHub. Нажмите «Проверить».</p>
        <button class="btn" id="hist-recheck-btn" type="button">Проверить</button>
      </div>
    `;
    bindRetry();
  }

  function showErrorState(err) {
    listEl.innerHTML = `
      <div class="upd-history-empty">
        <p>Не удалось загрузить историю версий: ${errHtml(err)}</p>
        <button class="btn" id="hist-recheck-btn" type="button">Проверить</button>
      </div>
    `;
    bindRetry();
  }

  async function loadMore() {
    if (inFlight) return inFlight;
    inFlight = (async () => {
      try {
        const res = await apiGet(`/update/history?offset=${offset}&limit=${limit}`);
        if (!res || !res.ok) throw new Error("bad response");
        total = Number(res.total) || 0;
        const items = Array.isArray(res.history) ? res.history : [];

        if (offset === 0) {
          listEl.innerHTML = "";
        }

        if (total === 0 || (!items.length && offset === 0)) {
          showEmptyState();
          return;
        }

        let chunkHtml = "";
        for (const item of items) {
          const monthKey = getMonthKey(item.ts);
          if (monthKey && monthKey !== lastMonthKey) {
            lastMonthKey = monthKey;
            chunkHtml += `<div class="upd-month-header">${escapeHtml(monthKey)}</div>`;
          }

          const isUninstalled = !foundInstalled && behind > 0 && item.v !== installed;
          if (item.v === installed) {
            foundInstalled = true;
          }

          chunkHtml += renderChangelogEntry(item, isUninstalled);
        }

        if (offset === 0) {
          listEl.innerHTML = chunkHtml;
        } else {
          listEl.insertAdjacentHTML("beforeend", chunkHtml);
        }
        offset += items.length;
      } catch (e) {
        if (offset === 0) {
          showErrorState(e);
        } else {
          toastErr("Не удалось загрузить историю версий: ", e);
        }
      } finally {
        inFlight = null;
      }
    })();
    return inFlight;
  }

  listEl.addEventListener("scroll", () => {
    if (inFlight || offset >= total) return;
    if (listEl.scrollTop + listEl.clientHeight >= listEl.scrollHeight - 80) {
      loadMore();
    }
  });

  if (titleEl) titleEl.textContent = "История версий";
  await loadMore();
}
