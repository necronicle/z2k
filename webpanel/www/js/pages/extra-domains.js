import { renderDomainList } from "../core/domain-list-editor.js";
import { apiGet, apiPost, errHtml, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, skeletonLines } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { toast } from "../core/toast.js";

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

export async function renderAutohostlistDomains() {
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
    const domains = Array.isArray(d && d.domains) ? d.domains : [];
    if (!domains.length) {
      list.innerHTML = `<li style="color:var(--text-muted)">(пока ничего не найдено)</li>`;
      return;
    }
    list.innerHTML = domains.map(dom => `
      <li><span>${escapeHtml(dom)}</span><button class="btn-icon" title="Удалить" aria-label="Удалить ${escapeHtml(dom)}" data-del="${escapeHtml(dom)}">${_icons.close}</button></li>
    `).join("");
    list.querySelectorAll("button[data-del]").forEach(btn => {
      btn.addEventListener("click", () => ahDelete(btn.dataset.del));
    });
  } catch (e) {
    if (_stale("autohostDomains", seq)) return;
    list.innerHTML = `<li style="color:var(--bad)">${errHtml(e)}</li>`;
  }
}

async function ahDelete(domain) {
  try {
    await apiPost("/autohostlist-domains/delete", { domain });
    toast("Удалено");
    loadAutohostlistDomains();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}

export async function renderExtraDomains() {
  await renderDomainList({
    endpoint: "/extra-domains",
    shell: html => extraShell("own", html),
    title: "Обрабатывать эти сайты",
    description: 'Добавьте сайты, которым нужен обход блокировок в дополнение к основным спискам. <code>example.com</code> включает все поддомены. Домены, уже покрытые другими списками, повторно добавлять не нужно.',
    deleteHint: "Эти сайты будут удалены из дополнительного списка. Обработка по другим спискам сохранится.",
  });
}
