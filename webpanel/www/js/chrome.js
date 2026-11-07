import { _icons } from "./core/dom.js";
import { STATE_SORT_LABELS, saveStateSort, stateSort } from "./state-model.js";

// localStorage key z2k-sidebar = "expanded" | "collapsed".
// Sidebar только на desktop (≥768px / >500h height); на mobile drawer
// показывает все items — collapse button скрыт.
const SIDEBAR_KEY = "z2k-sidebar";

export function initSidebar() {
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
export function closeNavMore() {}

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

export function initTheme() {
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

// На мобиле topbar = [z2k] _ [☰]. Клик — open right-slide drawer.
// Содержит все nav links + theme-toggle. Closes на: click outside,
// click backdrop, click nav link, Escape.
export function initDrawer() {
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
      onSortPicked();
    });
  });
}

// КОГО ЗВАТЬ ПОСЛЕ ВЫБОРА, РЕШАЕТ НЕ ЛИСТ СОРТИРОВКИ.
//
// Он звал resortState напрямую — то есть общая деталь оболочки знала про
// конкретную страницу. При разбиении это давало цикл оболочка → страница →
// оболочка. Теперь страница передаёт, что сделать после выбора.
let onSortPicked = () => {};

export function openSortSheet(afterPick) {
  if (typeof afterPick === "function") onSortPicked = afterPick;
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
