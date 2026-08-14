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
    list.innerHTML = `<li style="color:var(--bad)">${errHtml(e)}</li>`;
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
    toastErr("Ошибка: ", e);
  }
}

async function edDelete(domain) {
  try {
    await apiPost("/extra-domains/delete", { domain });
    toast("Удалено");
    loadExtraDomains();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}
