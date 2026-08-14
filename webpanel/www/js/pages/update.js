import { apiGet, apiPost, toastErr } from "../core/api.js";
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
