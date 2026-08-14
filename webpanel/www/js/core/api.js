import { API, escapeHtml } from "./dom.js";
import { toast } from "./toast.js";

// Every API call carries X-Z2K-Panel. The backend (cgi/auth.sh) treats it as
// proof the request came from this page: a cross-origin form cannot set a
// header, and a cross-origin fetch that sets one is held back by a CORS
// preflight the panel never answers. Do not drop it from any call site.
export const PANEL_HDR = { "X-Z2K-Panel": "1" };

// «Панель не ответила» и «панель ответила отказом» — разные события, и
// путать их дорого: обрыв связи поллер задачи обязан терпеть минутами
// (рестарт трясёт тот же канал, через который открыта панель), а 403/400/500
// — это определённый ответ, ждать после него нечего. Признак второго —
// поле httpStatus у ошибки; текст сообщения при этом не меняется.
// Временные статусы, означающие «панель сейчас переезжает или поднимается».
// Держим ОДНИМ списком: isRefusal ниже и текст сообщения обязаны совпадать,
// иначе получится ровно то, что и получилось — опрос ждёт, а страница
// одновременно кричит про ошибку.
const TRANSIENT_HTTP = { 404: 1, 502: 1, 503: 1, 504: 1 };

// ЧТО ДЕЛАТЬ, КОГДА СЕССИЯ КОНЧИЛАСЬ, РЕШАЕТ НЕ ТРАНСПОРТ.
//
// Помощники fetch звали showLoginScreen напрямую, то есть слой запросов знал
// про устройство экрана входа. При разбиении по файлам это давало цикл:
// запросы → вход → запросы. Инверсия развязывает его и заодно ставит вещи на
// места — транспорту незачем знать, чем именно мы просим человека войти.
let onUnauthorized = () => {};

export function setUnauthorizedHandler(fn) { onUnauthorized = fn; }

function httpError(status, statusText, message) {
  // Текст для ЧЕЛОВЕКА, а не код протокола.
  //
  // Исходная беда была не в том, что панель показывает ошибки, а в том, что
  // она показывает их словами «404 Not Found» там, где на самом деле идёт
  // штатная переустановка: lighttpd жив, но корень и CGI лежат внутри
  // /opt/zapret2, которое на время переезжает. Классификацию я починил
  // (90823e8), но только в опросе задачи и awaitPanelBack — а сырой текст
  // ошибки печатает 41 место в этом файле, и все они продолжали пугать людей
  // кодом 404 весь день.
  //
  // Чинить 41 обработчик по одному незачем: сообщение рождается здесь, и
  // достаточно, чтобы оно рождалось человеческим. Настоящие отказы (403, 500)
  // текст сохраняют — их прятать нельзя.
  // ВРЕМЕННЫЙ СТАТУС — ЭТО НЕ СОБЫТИЕ ДЛЯ ЧЕЛОВЕКА, И ТЕКСТА У НЕГО НЕТ.
  //
  // Наш код 404 не возвращает нигде и никогда. Тот, что видели люди, —
  // ответ самого lighttpd: он остаётся жив, а корень и CGI лежат внутри
  // /opt/zapret2, которое на пятом шаге переустановки переезжает. То есть
  // панель показывала чужой ответ как свой и сообщала об ошибке там, где
  // ничего не сломалось.
  //
  // Раньше я чинил это классификацией: 404 объявлялся временным, текст
  // смягчался. Классификация была верной, а решение — нет: сообщение всё
  // равно всплывало, просто другими словами, и пугало ровно так же.
  // Поэтому сообщения здесь больше НЕТ ВООБЩЕ. Пустой текст молча гасится
  // и в тостах, и в логе задачи — человек видит идущую установку, а не
  // разговор про коды ответов.
  //
  // Настоящие отказы (403, 500) текст сохраняют: их прятать нельзя.
  let msg = "";
  if (!TRANSIENT_HTTP[status]) {
    msg = message || `${status} ${statusText}`;
  }
  const e = new Error(msg);
  e.httpStatus = status;
  e.transient = !!TRANSIENT_HTTP[status];
  return e;
}

// ПАРА К httpError СО СТОРОНЫ ПОКАЗА.
//
// httpError рождает пустой текст для временных статусов, и обещание «текста
// нет» выполняется ровно настолько, насколько с ним считается каждое место
// показа. А их 37, и считалось — одно.
//
// Что было: 11 мест печатали e.message прямо в разметку, давая красную
// плашку «Ошибка» с пустотой под ней. Ещё 26 склеивали «Ошибка: » + e.message
// ДО вызова toast, из-за чего его защита от пустого текста не срабатывала:
// строка «Ошибка: » непустая. То есть починка «убрано как класс» была верна
// у источника и неверна у потребителей — человек посреди переустановки
// по-прежнему получал испуг, только другой формы.
//
// Дашборд свою копию этой развилки уже завёл (9f3ea92) — здесь она общая,
// чтобы следующее место показа не пришлось чинить отдельно.
const TRANSIENT_WHY = "Панель сейчас не отвечает — обычно так выглядит идущее обновление.";

// Простой текст: для textContent и подписей.
export function errMsg(e) {
  return (e && e.message) ? String(e.message) : TRANSIENT_WHY;
}

// Уже экранированный текст: для вставки в разметку.
export function errHtml(e) {
  return escapeHtml(errMsg(e));
}

// Тост об ошибке. Пустой текст — осознанное молчание, ровно как задумано у
// toast: во время переустановки каждый фоновый загрузчик спотыкается о
// переезжающее дерево, и очередь красных плашек не нужна никому.
export function toastErr(prefix, e) {
  if (!e || !e.message) return;
  toast((prefix || "") + e.message, "bad");
}

function isHttpError(e) { return !!e && typeof e.httpStatus === "number"; }

// Отказ ли это на самом деле.
//
// Раньше отказом считался ЛЮБОЙ числовой статус, и это было ошибкой: при
// переустановке lighttpd не останавливается, а корень и CGI лежат внутри
// /opt/zapret2, которое на пятом шаге переезжает. Живой сервер без файлов
// отвечает 404 — и опрос, вместо того чтобы переждать переезд, объявлял
// «панель ответила ошибкой, чем кончилась задача, неизвестно» через ТРИ
// попытки, то есть через четыре секунды. При этом обрыв связи терпелся
// десять минут: мягкая ветка была ровно для этого случая, но он в неё не
// попадал.
//
// 404 — «этого сейчас нет», 502/503 — «сервер поднимается». Всё это
// временное и обязано пережидаться. Настоящий отказ — 403 (origin-гейт
// отверг) и 5xx кроме перечисленных.
export function isRefusal(e) {
  if (!isHttpError(e)) return false;
  return !TRANSIENT_HTTP[e.httpStatus];
}

export async function apiGet(path, opts = {}) {
  const r = await fetch(API + path, { credentials: "same-origin", headers: PANEL_HDR, signal: opts.signal });
  if (!r.ok) {
    // Тело ошибки РАЗБИРАЕМ, как это давно делает apiPost. Раньше здесь
    // стоял голый httpError(status, statusText), то есть ответ выбрасывался
    // целиком — а бекенд кладёт в него внятную русскую причину («панель не
    // отвечает на этот адрес», «обращение с другого сайта»). Человеку
    // доставалось «403 Forbidden» без единой подсказки, и это на 22 из 48
    // вызовов, то есть на загрузке всех страниц.
    const data = await r.json().catch(() => null);
    // needauth — не «ошибка», а «покажи форму входа». Признак машиночитаемый,
    // потому что по тексту сообщения такие вещи не различают.
    if (data && data.needauth) { onUnauthorized(); throw httpError(401, "", ""); }
    throw httpError(r.status, r.statusText, (data && data.error) || undefined);
  }
  return r.json();
}

export async function apiPost(path, params = {}) {
  const body = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) body.set(k, v);
  const r = await fetch(API + path, {
    method: "POST",
    credentials: "same-origin",
    headers: { ...PANEL_HDR, "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  const data = await r.json().catch(() => ({ ok: false, error: `${r.status}` }));
  if (!r.ok) {
    if (data && data.needauth) { onUnauthorized(); throw httpError(401, "", ""); }
    throw httpError(r.status, r.statusText, data.error || `${r.status}`);
  }
  if (!data.ok) throw new Error(data.error || `${r.status}`);
  return data;
}

// GET, отдающий сырой текст (не JSON) — /warp/list. Ошибки бекенд шлёт
// JSON'ом с не-200 статусом, поэтому на !ok пробуем вытащить .error.
export async function apiGetText(path) {
  const r = await fetch(API + path, { credentials: "same-origin", headers: PANEL_HDR });
  if (!r.ok) {
    let msg = `${r.status} ${r.statusText}`;
    let needauth = false;
    try {
      const d = await r.json();
      if (d && d.error) msg = d.error;
      needauth = !!(d && d.needauth);
    } catch (_) { /* тело не JSON — оставляем статус как есть */ }
    // Форма входа, как в остальных трёх помощниках.
    //
    // Ветка needauth появилась в 627f756 сразу в apiGet, apiPost и
    // apiPostText — одним диффом, а сюда не попала. Между тем через
    // apiGetText идут четыре живых вызова: правка списка WARP (дважды),
    // выгрузка диагностики и редактор своей стратегии. Сервер на протухшей
    // сессии отдаёт 401 {needauth:true} на ЛЮБОЙ маршрут, кроме /auth/*,
    // поэтому человек, открывший вкладку дольше двух часов назад, получал
    // тост с невнятной причиной и НИ ОДНОГО способа войти — форма не
    // показывалась вовсе, и оставалось только догадаться перезагрузить
    // страницу.
    if (needauth) { onUnauthorized(); throw httpError(401, "", ""); }
    throw httpError(r.status, r.statusText, msg);
  }
  return r.text();
}

// POST с сырым текстовым телом (как /whitelist/import) — /warp/list/save.
export async function apiPostText(path, text) {
  const r = await fetch(API + path, {
    method: "POST",
    credentials: "same-origin",
    headers: { ...PANEL_HDR, "Content-Type": "text/plain;charset=utf-8" },
    body: text,
  });
  const data = await r.json().catch(() => ({ ok: false, error: `${r.status}` }));
  if (!r.ok) {
    if (data && data.needauth) { onUnauthorized(); throw httpError(401, "", ""); }
    throw httpError(r.status, r.statusText, data.error || `${r.status}`);
  }
  if (!data.ok) throw new Error(data.error || `${r.status}`);
  return data;
}
