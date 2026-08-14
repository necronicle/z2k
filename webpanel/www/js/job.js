import { apiGet, isRefusal } from "./core/api.js";
import { _icons, escapeHtml } from "./core/dom.js";
import { toast } from "./core/toast.js";

// Registry of currently-running jobs. Each entry survives modal close
// (user clicks "Скрыть") and powers the bottom-right badge — click on
// the badge re-opens the modal with the same jobId so user can check
// progress again.
export const _activeJobs = new Map();

// Чем кончилась фоновая задача. Провал и «мы не знаем, чем кончилось» —
// разные вещи: во втором случае в конфиге ничего не откатывалось, и
// говорить «вернул как было» нельзя, это прямая ложь.
const JOB_OK = "ok";

export const JOB_FAIL = "fail";

const JOB_GONE = "gone";

const JOB_OFFLINE = "offline";

// JOB_REFUSED больше нет. Он означал «панель на связи и ответила отказом»,
// но на практике им становился 404 от lighttpd во время переустановки —
// то есть штатный переезд дерева подавался человеку как отказ.
export function jobOutcome(d) {
  if (!d) return JOB_GONE;
  if (d.outcome) return d.outcome;
  // status==="unknown" трактуем терминально САМИ, не полагаясь на done в
  // ответе: роутер мог не обновиться, и старый бекенд на неизвестный id
  // отдаёт HTTP 200 с done:false — поллер тогда крутится вечно.
  if (d.status === "unknown") return JOB_GONE;
  return d.exit === 0 ? JOB_OK : JOB_FAIL;
}

// Итог не получен: откатывать UI нельзя, надо перечитать состояние.
export function jobUnresolved(o) { return o === JOB_GONE || o === JOB_OFFLINE; }

// Про неопределённый исход человеку НЕ СООБЩАЕТСЯ ничего.
//
// Здесь стояли «Связь с панелью пропала» и «Панель ответила ошибкой» — оба
// с хвостом «чем кончилось, пока неизвестно». Во время переустановки они
// выпадали каждому: панель на три минуты уезжает вместе с деревом, и это
// норма, а не происшествие. Текст пустой — toast() такой молча гасит, а UI
// просто перечитывает состояние (см. jobUnresolved).
export function unresolvedMsg(_o) { return ""; }

// Ждём, пока панель снова начнёт отвечать. Рестарт nfqws2 перетряхивает
// iptables на том же канале, через который открыта панель, — обрыв на
// десятки секунд здесь штатный, поэтому ждём долго и молча.
export async function awaitPanelBack(timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { return await apiGet("/status"); }
    catch (e) {
      // Панель ответила отказом — она на связи, ждать её «возвращения»
      // бессмысленно: так можно простоять все две минуты на ровном месте.
      // Но 404 и 5xx-«поднимаюсь» отказом НЕ считаются: при переустановке
      // корень и CGI переезжают вместе с /opt/zapret2, и живой lighttpd без
      // файлов отвечает именно 404. Ждать тут как раз и надо.
      if (isRefusal(e)) return null;
      if (Date.now() >= deadline) return null;
      await new Promise(r => { setTimeout(r, 2000); });
    }
  }
}

// Background pollers — независимы от модалки. Запускаются при первом
// openJobModal, продолжают работать даже если юзер закрыл модалку. На
// done централизованно дёргают onDone, чистят registry и разлочивают UI.
// Модалка — это просто «вью» подписанное на тик через attachers.
const _jobPollers = new Map();

function _renderJobBadges() {
  let container = document.getElementById("job-badges");
  if (!container) {
    container = document.createElement("div");
    container.id = "job-badges";
    container.className = "job-badges";
    document.body.appendChild(container);
  }
  container.innerHTML = "";
  for (const [jobId, info] of _activeJobs) {
    const b = document.createElement("button");
    b.className = "job-badge";
    b.title = "Кликни чтобы открыть лог снова";
    b.innerHTML = `<span class="job-badge-dot"></span>${escapeHtml(info.title)}`;
    b.addEventListener("click", () => openJobModal(info.title, jobId, info.opts));
    container.appendChild(b);
  }
  _updateGlobalUILock();
}

// Пока есть хотя бы один active job — блокируем ВСЕ toggle switches и
// service-кнопки. Любое новое действие порождало бы конкурентный
// restart сервиса с непредсказуемым итогом.
//
// Visual treatment (ui-ux рекомендация 2026-05-24): browser default
// disabled state слишком subtle — юзер видел просто чуть-серый
// элемент и думал что нажал «не туда». Применяем per-card locked
// treatment: каждая карточка с интерактивными элементами получает
// opacity-reduce + большую пилюлю «⏳ Операция выполняется…» в углу.
// Это immediately visible без hover. Tooltip остаётся для precision.
// Пока лок держит элемент, его настоящее состояние лежит в lockBackup, а
// .disabled принудительно true. Прямая запись в .disabled в это время
// теряется: снятие лока вернёт значение, снятое ДО перечитывания статуса.
// Поэтому загрузчики состояния пишут через эту обёртку.
export function setLockAware(el, disabled) {
  if (!el) return;
  if (el.dataset.lockBackup !== undefined) el.dataset.lockBackup = disabled ? "1" : "0";
  else el.disabled = disabled;
}

export function _updateGlobalUILock() {
  const busy = _activeJobs.size > 0;
  const lockMsg = "Дождитесь завершения текущей операции";
  // Сравнение именно с undefined: lockBackup === "0" — валидный бэкап
  // («был включён»), но строка "0" ложна, и на !dataset.lockBackup вторая
  // задача перезаписывала бэкап уже залоченным значением "1". После неё
  // элемент оставался выключенным навсегда — до перезагрузки страницы.
  document.querySelectorAll(".switch input[type=\"checkbox\"]").forEach(cb => {
    if (busy) {
      if (cb.dataset.lockBackup === undefined) {
        cb.dataset.lockBackup = cb.disabled ? "1" : "0";
        cb.disabled = true;
        cb.closest(".switch")?.setAttribute("title", lockMsg);
      }
    } else {
      if (cb.dataset.lockBackup !== undefined) {
        cb.disabled = cb.dataset.lockBackup === "1";
        delete cb.dataset.lockBackup;
        cb.closest(".switch")?.removeAttribute("title");
      }
    }
  });
  // #uninstall-btn ОБЯЗАН быть в этом списке. Без него кнопка удаления
  // оставалась живой во время чужой фоновой задачи: можно было запустить
  // снос дерева параллельно идущей переустановке — общего замка у них нет,
  // и `rm -rf` гонялся бы с записью файлов установщиком. Тем же путём второй
  // клик по самой кнопке в первые секунды порождал второе удаление.
  document.querySelectorAll("[data-svc], #tg-enable, #tg-disable, #uninstall-btn").forEach(btn => {
    if (busy) {
      if (btn.dataset.lockBackup === undefined) {
        btn.dataset.lockBackup = btn.disabled ? "1" : "0";
        btn.disabled = true;
        btn.setAttribute("title", lockMsg);
      }
    } else {
      if (btn.dataset.lockBackup !== undefined) {
        btn.disabled = btn.dataset.lockBackup === "1";
        delete btn.dataset.lockBackup;
        btn.removeAttribute("title");
      }
    }
  });
  // Dimmed cards — signal что заблокировано на каждой карточке с
  // контролами. Без overlay'а — content виден полностью.
  document.querySelectorAll(".card").forEach(card => {
    // Тот же список, что и у лока выше — иначе карточка удаления гасила бы
    // кнопку, но сама оставалась яркой, и выключенная кнопка выглядела бы
    // поломкой, а не занятостью.
    const hasLockableControl = card.querySelector(".switch input[type=\"checkbox\"], [data-svc], #tg-enable, #tg-disable, #uninstall-btn");
    if (!hasLockableControl) return;
    if (busy) card.classList.add("card-locked");
    else card.classList.remove("card-locked");
  });

  // Single page-level pill в строке h1.page-title — не дублируется на
  // каждую карточку, не оверлайит content. Job-badge в углу показывает
  // конкретное имя операции; этот pill — общий statement что страница
  // в busy состоянии.
  const pageTitle = document.querySelector(".page-title");
  if (pageTitle) {
    let pill = pageTitle.querySelector(":scope > .page-locked-pill");
    if (busy && !pill) {
      pill = document.createElement("span");
      pill.className = "page-locked-pill";
      pill.setAttribute("aria-hidden", "true");
      pill.innerHTML = _icons.hourglass + "<span>Операция выполняется…</span>";
      pageTitle.appendChild(pill);
    } else if (!busy && pill) {
      pill.remove();
    }
  }
}

// Background poller для одного jobId. Живёт независимо от модалки —
// поэтому даже если юзер кликнул «Скрыть», job дойдёт до done, UI
// разлочится, opts.onDone сработает. Модалка просто подписывается через
// attachers и снимает подписку на close.
function _startJobPoller(jobId, opts) {
  const existing = _jobPollers.get(jobId);
  if (existing) return existing;
  const state = {
    jobId,
    opts: opts || {},
    stopped: false,
    lastLog: "Запуск…",
    lastData: null,
    consecutiveErrors: 0,
    lastOutageWarn: 0,
    httpErrors: 0,
    attachers: new Set(),      // (log, done, data) callbacks
  };
  _jobPollers.set(jobId, state);

  // Потолок опроса — предохранитель от вечного цикла, а не срок, после
  // которого «всё пропало». С tolerateOutage это 300 × 2 с ≈ десять минут:
  // с запасом перекрывает трёхминутную переустановку.
  const MAX_ERRORS = state.opts.tolerateOutage ? 300 : 5;
  // Три попытки — запас на разовый промах CGI, который на роутере под
  // памятью может не форкнуться. Больше держать определённый отказ незачем.
  const MAX_HTTP_ERRORS = 3;
  const POLL_OK_MS = 1000;
  const POLL_ERR_MS = state.opts.tolerateOutage ? 2000 : 1000;

  const notify = (log, done, data) => {
    state.lastLog = log;
    if (data) state.lastData = data;
    for (const cb of state.attachers) {
      try { cb(log, done, data); } catch (_) {}
    }
  };

  const finish = (d) => {
    state.stopped = true;
    _jobPollers.delete(jobId);
    _activeJobs.delete(jobId);
    _renderJobBadges();  // также дёрнет _updateGlobalUILock — кнопки разлочатся
    if (typeof state.opts.onDone === "function") {
      try { state.opts.onDone(d); } catch (_) {}
    }
  };

  async function tick() {
    if (state.stopped) return;
    try {
      const d = await apiGet("/job?id=" + encodeURIComponent(jobId));
      const recovered = state.consecutiveErrors > 0;
      state.consecutiveErrors = 0;
      state.lastOutageWarn = 0;
      // Задачи нет: файлы подчистил job_reap или роутер перезагрузился
      // посреди операции. Ответ при этом успешный (HTTP 200), счётчик
      // сетевых ошибок его не поймает — терминальность решается здесь.
      if (jobOutcome(d) === JOB_GONE) {
        const log = (d.log || state.lastLog || "") +
          "\n[задача не найдена — роутер перезагрузился или запись о ней уже удалена]";
        const fin = { done: true, exit: null, status: "unknown", outcome: JOB_GONE, log };
        notify(log, true, fin);
        toast("Фоновая задача не найдена — проверьте состояние сервиса", "bad");
        finish(fin);
        return;
      }
      // «Снова на связи» не пишем: мы не говорили, что связь пропадала.
      const baseLog = d.log || "(нет вывода)";
      // Возврат связи отмечаем В ЛОГЕ — так было до p-73.2.
      const log = recovered ? baseLog + "\n[панель снова на связи]" : baseLog;
      notify(log, !!d.done, d);
      if (d.done) { finish(d); return; }
    } catch (e) {
      // НЕДОСТУПНАЯ ПАНЕЛЬ — ЭТО НЕ ИСХОД ЗАДАЧИ.
      //
      // Задача выполняется на роутере и от браузера не зависит: он всего
      // лишь смотрит на неё. Пока смотреть не получается, честный ответ —
      // «пока не знаю», а не «задача кончилась неизвестно чем».
      //
      // Раньше здесь стояло обратное: три неудачных опроса подряд объявляли
      // задачу законченной и дописывали в лог «панель ответила ошибкой».
      // Во время переустановки это срабатывало ВСЕГДА — дерево переезжает,
      // lighttpd остаётся жив и отвечает 404 — то есть человек ровно
      // посреди штатной установки получал сообщение о поломке, которой нет.
      // Ветки больше нет: временная недоступность просто пережидается.
      //
      // Настоящий отказ никуда не делся: 403 и 5xx приносят свой текст и
      // всплывают там, где их обрабатывают. Здесь они не превращают идущую
      // задачу в проваленную.
      state.consecutiveErrors++;
      // Определённый отказ (403, 5xx кроме «поднимаюсь») — это ОТВЕТ, а не
      // переезд: ждать его «возвращения» бессмысленно, и держать из-за него
      // весь UI залоченным десять минут нельзя. Такой опрос прекращаем
      // быстро — но так же молча: что произошло на самом деле, человеку
      // покажет перечитанное с роутера состояние, а не наша догадка.
      if (isRefusal(e)) state.httpErrors++; else state.httpErrors = 0;
      // ЗАДАЧА, КОТОРАЯ УБИВАЕТ САМУ ПАНЕЛЬ.
      //
      // Для удаления пропажа сервера — не «переезд, переждём», а ожидаемый
      // финал: lighttpd гасится вместе со всем деревом и не поднимется.
      // Ждать его «возвращения» здесь означало бы врать десять минут подряд,
      // а потом всё равно закончить молчанием.
      //
      // Порог небольшой, но не единичный: одиночный промах CGI на роутере
      // под памятью бывает и без всякого удаления, и объявлять по нему
      // «z2k удалён» нельзя. Десять подряд по две секунды — это двадцать
      // секунд тишины, столько штатная пауза не длится.
      if (state.opts.expectGone && state.consecutiveErrors >= 10) {
        const clean = String(state.lastLog || "").replace(/\n\[панель.*\]$/g, "");
        // ИТОГ НЕ ОБЪЯВЛЯЕТСЯ УСПЕШНЫМ, И ЭТО ВАЖНО.
        //
        // Молчание сервера говорит ровно одно: панели больше нет. Про то,
        // чем кончилось удаление, оно не говорит ничего — а панель гасится
        // ВТОРЫМ действием, задолго до чистки правил, сноса дерева и
        // конфига. Всё, что упадёт после (носитель ушёл в read-only,
        // коробку перезагрузили), случится уже за нашей спиной.
        //
        // Здесь стояло exit: 0 и «z2k удалён». Это была догадка, поданная
        // как факт: человек читал «удалён», закрывал вкладку, а дерево и
        // правила оставались на месте, и проверить было уже нечем —
        // журнал задачи лежит в /tmp и доступен только по SSH.
        //
        // Поэтому статус unknown: опрос прекращается, UI разблокируется,
        // но успех не заявлен. В логе — что известно и что делать дальше.
        const log = clean +
          "\n[панель выключилась — так и должно быть, она удаляется вместе с z2k]" +
          "\n[дальше удаление идёт без неё, и результат отсюда уже не виден]" +
          "\n[если z2k остался, откройте меню в терминале — пункт 5]";
        const fin = { done: true, exit: null, status: "unknown", log };
        notify(log, true, fin);
        finish(fin);
        return;
      }
      if (state.httpErrors >= MAX_HTTP_ERRORS || state.consecutiveErrors >= MAX_ERRORS) {
        // В лог не дописываем ничего: jobUnresolved заставит UI перечитать
        // состояние, и человек увидит факт вместо жалобы.
        finish({ done: true, exit: null, outcome: JOB_OFFLINE, log: state.lastLog });
        return;
      }
    }
      // ПРИЗНАК ЖИЗНИ, ПОКА ПАНЕЛЬ НЕ ОТВЕЧАЕТ.
      //
      // Лог во время переезда дерева замирает на последней строке, и
      // молчание неотличимо от зависшей установки — именно на это и
      // пожаловались: «ни логов, ни того, что панель скоро вернётся».
      // До p-73.2 счётчик ожидания здесь был; его снесли ЗАОДНО с ложными
      // вердиктами («панель ответила ошибкой… чем кончилась задача,
      // неизвестно»). Вердикты убраны правильно, счётчик — нет: он ничего
      // не утверждает о судьбе задачи, он показывает, что мы ещё ждём.
      // Предыдущую строку затираем, чтобы лог не рос столбиком.
      if (state.consecutiveErrors === 2
          || (state.consecutiveErrors - state.lastOutageWarn) >= 15) {
        const secs = Math.round(state.consecutiveErrors * POLL_ERR_MS / 1000);
        const clean = String(state.lastLog || "").replace(/\n\[панель.*\]$/g, "");
        // При удалении панель не «пока не отвечает», а выключается насовсем —
        // и обещать её возвращение нельзя.
        notify(clean + (state.opts.expectGone
          ? "\n[панель выключается вместе с z2k… " + secs + "с]"
          : "\n[панель пока не отвечает, ждём… " + secs + "с]"), false, null);
        state.lastOutageWarn = state.consecutiveErrors;
      }
    setTimeout(tick, state.consecutiveErrors > 0 ? POLL_ERR_MS : POLL_OK_MS);
  }
  tick();
  return state;
}

export function openJobModal(title, jobId, opts = {}) {
  // Если уже есть открытая модалка для этого job — не плодить вторую.
  if (document.querySelector(`.modal-backdrop[data-job-id="${jobId}"]`)) {
    return;
  }
  // Зарегистрировать job так чтобы badge отображался даже если юзер
  // закроет модалку. Background poller начнёт жить независимо.
  if (!_activeJobs.has(jobId)) {
    _activeJobs.set(jobId, { title, opts });
    _renderJobBadges();
  }
  const poller = _startJobPoller(jobId, opts);

  const warning = opts.warning ? `<div class="modal-warning">${escapeHtml(opts.warning)}</div>` : "";
  const backdrop = document.createElement("div");
  backdrop.className = "modal-backdrop";
  backdrop.dataset.jobId = jobId;
  backdrop.innerHTML = `
    <div class="modal">
      <h3>${escapeHtml(title)}</h3>
      ${warning}
      <pre class="log" id="job-log">${escapeHtml(poller.lastLog || "Запуск…")}</pre>
      <div class="modal-footer">
        <button class="btn" id="job-close">Скрыть</button>
      </div>
    </div>
  `;
  document.body.appendChild(backdrop);
  const logEl = backdrop.querySelector("#job-log");
  const closeBtn = backdrop.querySelector("#job-close");
  logEl.scrollTop = logEl.scrollHeight;

  // Модалка — подписчик на background poller. На done меняет текст
  // кнопки на «Готово»/«Закрыть». Если юзер закроет до done — мы
  // снимаем подписку, poller продолжит крутиться и сам разлочит UI.
  const onTick = (log, done, d) => {
    logEl.textContent = log;
    logEl.scrollTop = logEl.scrollHeight;
    if (done) {
      const isLockHeld = (log || "").includes("lock held by pid=");
      if (d && d.exit === 0) {
        closeBtn.textContent = "Готово";
      } else if (isLockHeld) {
        closeBtn.textContent = "ОК — обновление уже идёт";
      } else {
        closeBtn.textContent = "Закрыть";
      }
    }
  };
  poller.attachers.add(onTick);

  // Если poller уже завершился до того как мы повторно открыли модалку
  // через badge — мгновенно отрисуем финальное состояние.
  if (poller.stopped && poller.lastData) {
    onTick(poller.lastLog, true, poller.lastData);
  }

  closeBtn.addEventListener("click", () => {
    poller.attachers.delete(onTick);
    backdrop.remove();
  });
}

// Подтверждение со своими подписями кнопок. Нативный confirm() тут не
// годится: его кнопки всегда OK/Отмена, а вопрос вида «Включать /
// Не включать» ответом «ОК» не описывается.
// Разметка — те же классы, что у openJobModal: своих в style.css нет.
// Подтверждение НАБОРОМ СЛОВА — для единственного необратимого действия.
//
// Обычная модалка «Да/Отмена» здесь не годится: она отделяет от катастрофы
// одним кликом, а к кликам «Да» в диалогах у всех выработан рефлекс. Набор
// слова требует прочитать, что именно произойдёт, и физически это набрать.
// Приём стандартный для необратимых операций (так спрашивают об удалении
// репозитория на GitHub и проекта в Vercel), и здесь он уместен ровно по той
// же причине: восстановления нет, есть только установка заново.
//
// То же слово проверяет и сервер: панель работает без авторизации и доверяет
// всей локальной сети, поэтому единственный необратимый вызов в API не должен
// срабатывать от голого POST.
export function confirmTypedModal(title, lines, word, okLabel) {
  return new Promise(resolve => {
    const prevFocus = document.activeElement;
    const backdrop = document.createElement("div");
    backdrop.className = "modal-backdrop";
    backdrop.innerHTML = `
      <div class="modal" role="dialog" aria-modal="true"
           aria-labelledby="typed-title" aria-describedby="typed-text">
        <h3 id="typed-title">${escapeHtml(title)}</h3>
        <div class="modal-warning" id="typed-text">
          ${lines.map(l => `<p>${escapeHtml(l)}</p>`).join("")}
        </div>
        <label class="typed-confirm-label" for="typed-input">
          Наберите <b>${escapeHtml(word)}</b>, чтобы подтвердить
        </label>
        <input type="text" id="typed-input" class="typed-confirm-input"
               autocomplete="off" autocapitalize="characters" spellcheck="false">
        <div class="modal-footer">
          <button class="btn btn-danger" id="typed-ok" disabled>${escapeHtml(okLabel)}</button>
          <button class="btn btn-primary" id="typed-cancel">Отмена</button>
        </div>
      </div>
    `;
    document.body.appendChild(backdrop);
    const input = backdrop.querySelector("#typed-input");
    const okBtn = backdrop.querySelector("#typed-ok");
    const cancelBtn = backdrop.querySelector("#typed-cancel");

    let answered = false;
    function finish(answer) {
      if (answered) return;
      answered = true;
      document.removeEventListener("keydown", onKey);
      backdrop.remove();
      if (prevFocus && typeof prevFocus.focus === "function") prevFocus.focus();
      resolve(answer);
    }
    // Сверяем без учёта регистра и краевых пробелов: требование — прочитать и
    // осознанно набрать, а не попасть в раскладку и Caps Lock.
    const matches = () => input.value.trim().toLocaleUpperCase("ru") === word;
    const sync = () => { okBtn.disabled = !matches(); };
    // Начальное состояние выставляем КОДОМ, а не только атрибутом в разметке:
    // атрибут легко потерять при правке шаблона, и тогда кнопка удаления
    // окажется активной с первой миллисекунды — ровно то, от чего диалог и
    // защищает. Плюс браузер может восстановить значение поля при возврате
    // на страницу, и тогда состояние кнопки обязано ему соответствовать.
    sync();
    input.addEventListener("input", sync);
    function onKey(e) {
      if (e.key === "Escape") { finish(false); return; }
      if (e.key === "Enter" && document.activeElement === input) {
        // Enter в поле подтверждает, только если слово уже совпало — иначе
        // это просто попытка отправить полупустую форму.
        if (matches()) { e.preventDefault(); finish(true); }
        return;
      }
      if (e.key !== "Tab") return;
      const stops = [input, okBtn, cancelBtn];
      const first = e.shiftKey ? stops[stops.length - 1] : stops[0];
      const last = e.shiftKey ? stops[0] : stops[stops.length - 1];
      if (document.activeElement === last || !backdrop.contains(document.activeElement)) {
        e.preventDefault();
        first.focus();
      }
    }
    okBtn.addEventListener("click", () => { if (matches()) finish(true); });
    cancelBtn.addEventListener("click", () => finish(false));
    backdrop.addEventListener("click", (e) => { if (e.target === backdrop) finish(false); });
    document.addEventListener("keydown", onKey);
    // Фокус в поле: диалог не подталкивает к согласию — кнопка выключена,
    // пока слово не набрано, — но и не заставляет искать, куда печатать.
    input.focus();
  });
}

export function confirmModal(title, text, okLabel, cancelLabel) {
  return new Promise(resolve => {
    const prevFocus = document.activeElement;
    const backdrop = document.createElement("div");
    backdrop.className = "modal-backdrop";
    // role/aria — по образцу sort-sheet ниже по файлу. Без них скринридер не
    // объявляет ни факт открытия диалога, ни сам текст предупреждения, ради
    // которого диалог и существует: озвучивалось только «кнопка».
    // Акцентной покрашена БЕЗОПАСНАЯ кнопка, а не «Включать»: визуальный
    // дефолт обязан совпадать с клавиатурным, иначе диалог подталкивает
    // ровно к тому действию, от которого предостерегает.
    backdrop.innerHTML = `
      <div class="modal" role="dialog" aria-modal="true"
           aria-labelledby="confirm-title" aria-describedby="confirm-text">
        <h3 id="confirm-title">${escapeHtml(title)}</h3>
        <div class="modal-warning" id="confirm-text">${escapeHtml(text)}</div>
        <div class="modal-footer">
          <button class="btn" id="confirm-ok">${escapeHtml(okLabel)}</button>
          <button class="btn btn-primary" id="confirm-cancel">${escapeHtml(cancelLabel)}</button>
        </div>
      </div>
    `;
    document.body.appendChild(backdrop);
    const okBtn = backdrop.querySelector("#confirm-ok");
    const cancelBtn = backdrop.querySelector("#confirm-cancel");

    let answered = false;
    function finish(answer) {
      // Escape и клик по кнопке могут прийти в одном кадре — промис резолвим
      // ровно один раз, второй ответ молча отбрасываем.
      if (answered) return;
      answered = true;
      document.removeEventListener("keydown", onKey);
      backdrop.remove();
      if (prevFocus && typeof prevFocus.focus === "function") prevFocus.focus();
      resolve(answer);
    }
    // Ловушка фокуса. Подложка position:fixed останавливает мышь, но Tab
    // из неё выходит на страницу — оттуда можно было повторно дёрнуть тот же
    // контрол и получить ВТОРУЮ модалку поверх первой, с теми же id.
    function onKey(e) {
      if (e.key === "Escape") { finish(false); return; }
      if (e.key !== "Tab") return;
      // Строго в порядке DOM: список задом наперёд ломает ровно то, ради чего
      // ловушка сделана — с изначально сфокусированной кнопки первый же Tab
      // не считался «последним» и уходил на страницу под диалогом.
      const stops = [okBtn, cancelBtn];
      const first = e.shiftKey ? stops[stops.length - 1] : stops[0];
      const last = e.shiftKey ? stops[0] : stops[stops.length - 1];
      if (document.activeElement === last || !backdrop.contains(document.activeElement)) {
        e.preventDefault();
        first.focus();
      }
    }

    okBtn.addEventListener("click", () => finish(true));
    cancelBtn.addEventListener("click", () => finish(false));
    // Клик мимо окна = отказ; клик внутри окна не закрывает ничего.
    backdrop.addEventListener("click", (e) => { if (e.target === backdrop) finish(false); });
    document.addEventListener("keydown", onKey);
    // Фокус на ОТКАЗЕ: это предупреждение, и случайный Enter обязан не
    // включить ничего.
    cancelBtn.focus();
  });
}
