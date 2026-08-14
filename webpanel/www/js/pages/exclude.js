import { PANEL_HDR, apiGet, apiPost, errHtml, toastErr } from "../core/api.js";
import { $app, API, _icons, escapeHtml, skeletonLines } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
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
    list.innerHTML = `<li style="color:var(--bad)">${errHtml(e)}</li>`;
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
    toastErr("Ошибка: ", e);
  }
}

async function wlDelete(domain) {
  try {
    await apiPost("/whitelist/delete", { domain });
    toast("Удалено");
    loadWhitelist();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}
