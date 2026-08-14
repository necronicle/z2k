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
export const STATE_SORT_LABELS = { key: "Профиль", host: "Домен", strategy: "Стратегия", age: "Возраст" };

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

export function saveStateSort() {
  try { localStorage.setItem(STATE_SORT_KEY, JSON.stringify(stateSort)); } catch (_) {}
}

export let stateSort = loadStateSort();

// Размеры пулов, прочитанные с /pools. Живут здесь, а меняет их страница
// стратегий — единственное место во всём файле, где значение присваивалось
// через границу раздела (замер связности нашёл ровно одно). В модулях
// импортированное имя менять нельзя, поэтому запись идёт через сеттер: так
// владение остаётся у модели, а не размазывается по странице.
export let statePools = {};

export function setStatePools(v) { statePools = v || {}; }
