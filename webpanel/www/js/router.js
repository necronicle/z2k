import { closeNavMore } from "./chrome.js";
import { $app, $nav } from "./core/dom.js";
import { renderCredits, renderStrategies } from "./pages/credits.js";
import { renderDashboard } from "./pages/dashboard.js";
import { renderDiag } from "./pages/diag.js";
import { renderExcludeAddresses, renderExcludeDomains } from "./pages/exclude.js";
import { renderAutohostlistDomains, renderExtraDomains } from "./pages/extra-domains.js";
import { renderState } from "./pages/strategies.js";
import { renderToggles } from "./pages/toggles.js";
import { renderWarp } from "./pages/warp.js";

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

export function navigate() {
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
