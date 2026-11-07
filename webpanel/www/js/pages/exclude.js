import { apiGet, apiPost, errHtml, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, skeletonLines } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { renderDomainList } from "../core/domain-list-editor.js";
import { toast } from "../core/toast.js";

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

export async function renderExcludeAddresses() {
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
    list.innerHTML = `<li style="color:var(--bad)">${errHtml(e)}</li>`;
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
    toastErr("Ошибка: ", e);
  }
}

async function exDelete(entry) {
  try {
    await apiPost("/exclude/delete", { entry });
    toast("Удалено");
    loadExclude();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}

export async function renderExcludeDomains() {
  await renderDomainList({
    endpoint: "/whitelist",
    shell: html => excludeShell("domains", html),
    title: "Не трогать эти сайты",
    description: 'z2k пропускает эти сайты без обработки. <code>example.com</code> включает все его поддомены, <code>!api.example.com</code> оставляет поддомен в обработке. Для IP-адресов используйте вкладку <a href="#/exclude">«Адреса»</a>.',
    deleteHint: "Эти сайты перестанут исключаться из обработки z2k.",
  });
}
