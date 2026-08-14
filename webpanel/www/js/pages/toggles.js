import { apiGet, apiPost, errHtml, errMsg, toastErr } from "../core/api.js";
import { $app } from "../core/dom.js";
import { _newLoad, _stale, refreshStatus, rstIsOn } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { JOB_FAIL, _updateGlobalUILock, confirmModal, jobOutcome, jobUnresolved, openJobModal, setLockAware, unresolvedMsg } from "../job.js";
import { AUTOHOSTLIST_WARNING, TOGGLES_RESTART_SERVICE, resyncToggle } from "./policy.js";

const TOGGLE_DEFS = [
  { key: "rst_filter", name: "RST-фильтр (пассивный DPI)",
    desc: "Блокирует поддельные TCP RST от ТСПУ через nfqws — 3 эвристики (pre-response RST, multi-RST burst, TTL mismatch). Не требует kernel-модулей. Может задеть редкие edge cases у Cloudflare — отключите если заметили проблемы с reconnect'ом." },
  { key: "silent_fallback", name: "Silent fallback РКН",
    desc: "Детект «тихих чёрных дыр» РКН. Осторожно — возможны ложные срабатывания." },
  // game_warp переехал в собственный раздел «WARP» (renderWarp) вместе с
  // управлением списками адресов — здесь его больше нет.
  { key: "customd", name: "Скрипты custom.d",
    desc: "Дополнительные daemons из init.d/custom.d (50-stun4all, 50-discord-media)." },
  { key: "dynamic_ttl", name: "Динамический TTL",
    desc: "Инжекция фиксированного TTL в исходящий трафик — обход обнаружения tethering у мобильных операторов (МТС/Билайн с телефонной симкой). Если у роутера уже настроен NDM TTL-fix — отключи, чтобы избежать конфликта." },
  { key: "stats", name: "Сбор статистики (анонимно)",
    desc: "Раз в сутки шлёт на сервер проекта обезличенный срез: какая стратегия активна в каждом пуле и как долго держится — чтобы двигать лучшие стратегии в начало. НЕ уходит: сайты/домены, IP, провайдер, регион, любой ID устройства. Только: имя пула, номер стратегии, время удержания. Выключите, если не хотите участвовать." },
  { key: "ppe", name: "Аппаратный offload: per-flow исключение",
    desc: "На Keenetic (MediaTek) аппаратный ускоритель уводит поток в железо после первого пакета, и роутер не видит повторные ClientHello — стратегия залипает для блокировок без RST (mailsuite и т.п.). Эта опция держит окно рукопожатия на CPU только для нужных портов (родной firmware-механизм -j PPE), поэтому подбор стратегии снова работает, а общий трафик остаётся ускоренным. Работает только на совместимых Keenetic. Выключите, чтобы вернуть прежнее поведение." },
  { key: "autohostlist", name: "Автохостлист",
    desc: "Обычно обходятся только домены из списков. С этой опцией движок сам замечает, что домен не открывается, и добавляет его — найденное попадает в основной список и подхватывается штатно. Плюс: сайты вне списков начинают работать без ручных добавлений. Минус: движок судит по поведению соединения и иногда ошибается, в список может попасть домен, который просто лежал сам по себе. Это смена принципа отбора трафика целиком, поэтому по умолчанию выключено." },
  { key: "auto_update", name: "Автообновление",
    desc: "Ночью в 02:00 роутер сам проверяет обновления и устанавливает их. Выключите, если хотите обновляться только вручную — кнопка «Обновить» продолжит работать, и панель по-прежнему покажет, что доступна новая версия." },
];

const TOGGLE_API_NAME = {
  rst_filter: "rst-filter",
  silent_fallback: "silent-fallback",
  customd: "customd",
  dynamic_ttl: "dynamic-ttl",
  stats: "stats",
  ppe: "ppe",
  auto_update: "auto-update",
  autohostlist: "autohostlist",
};

export async function renderToggles() {
  $app.innerHTML = `
    <h1 class="page-title">Режимы</h1>
    <div class="card">
      <div id="toggles-error" hidden></div>
      ${TOGGLE_DEFS.map(t => `
        <div class="toggle-row" data-key="${t.key}">
          <div class="t-text">
            <div class="t-name">${t.name}</div>
            <div class="t-desc">${t.desc}</div>
          </div>
          <label class="switch">
            <input type="checkbox" disabled>
            <span class="slider"></span>
          </label>
        </div>
      `).join("")}
    </div>
    <div class="card">
      <h3>Telegram туннель <span class="tg-state-badge" id="tg-state-badge" hidden></span></h3>
      <p class="desc">Прозрачный mux-прокси к Telegram DC через выделенный VPS-relay.</p>
      <div class="btn-row">
        <button class="btn btn-primary" id="tg-enable">Включить</button>
        <button class="btn btn-danger" id="tg-disable">Отключить</button>
      </div>
    </div>
    <div class="card" id="policy-card">
      <h3>Политика доступа Keenetic</h3>
      <label class="field">
        <span class="field-label">Имя политики</span>
        <input id="policy-name" type="text" placeholder="nfqws"
               inputmode="text" autocomplete="off" autocapitalize="off"
               spellcheck="false" autocorrect="off" maxlength="32">
      </label>
      <div class="policy-status" id="policy-status">
        <span class="policy-status-dot"></span>
        <span class="policy-status-text">Проверка…</span>
      </div>
      <div class="field-label" style="margin-top:14px">Применяется к устройствам</div>
      <div class="segmented" id="policy-mode" role="radiogroup" aria-label="Применяется к устройствам">
        <button type="button" class="seg-btn" data-exclude="0" role="radio" aria-checked="true">Только в политике</button>
        <button type="button" class="seg-btn" data-exclude="1" role="radio" aria-checked="false">Все, кроме политики</button>
      </div>
      <div class="btn-row" style="margin-top:14px;justify-content:space-between;align-items:center">
        <details class="policy-help disclosure">
          <summary>Как создать политику</summary>
          <div class="disclosure-body">
            <div class="how-to">
              <ol class="steps">
                <li>
                  <span class="step-num">1</span>
                  <div class="step-body">
                    <div class="step-title">Откройте раздел приоритетов</div>
                    <div class="step-desc">В админке Keenetic: <b>Интернет → Приоритеты подключений</b>.</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">2</span>
                  <div class="step-body">
                    <div class="step-title">Создайте политику</div>
                    <div class="step-desc">Вкладка <b>«Конфигурация политик»</b> → кнопка <b>«+ Добавить политику»</b>.</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">3</span>
                  <div class="step-body">
                    <div class="step-title">Задайте имя</div>
                    <div class="step-desc">Имя должно <b>точно совпадать</b> с тем, что введено выше — по умолчанию <code>nfqws</code>. Регистр учитывается.</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">4</span>
                  <div class="step-body">
                    <div class="step-title">Выберите подключение</div>
                    <div class="step-desc">В колонке «Подключение» оставьте галки на тех интерфейсах, которыми пользуются эти устройства (обычно ваше текущее подключение к интернету).</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">5</span>
                  <div class="step-body">
                    <div class="step-title">Привяжите устройства</div>
                    <div class="step-desc">Вкладка <b>«Привязка устройств к профилям»</b> → включите <b>«Показать все объекты»</b> → перетащите нужные устройства на созданную политику.</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">6</span>
                  <div class="step-body">
                    <div class="step-title">Примените у нас</div>
                    <div class="step-desc">Вернитесь сюда и нажмите <b>«Сохранить и применить»</b>. Статус выше должен загореться зелёным.</div>
                  </div>
                </li>
              </ol>
              <div class="how-to-note">
                <b>Нет раздела «Приоритеты подключений»?</b><br>
                Установите компонент: <b>Управление → Общие настройки → Изменить набор компонентов</b>, найдите «Приоритеты подключений (PBR)» и установите. После перезагрузки роутера раздел появится в меню «Интернет».
              </div>
            </div>
          </div>
        </details>
        <button class="btn btn-primary" id="policy-save-btn">Сохранить и применить</button>
      </div>
    </div>
  `;

  // Load current state and wire up switches. Шаблон рендерит все свитчи
  // disabled, включаются они только здесь — поэтому упавший /status обязан
  // сказать об этом и дать повтор: иначе страница выглядит нормальной, но
  // не кликается ни один тумблер, и понять это можно только методом тыка.
  const errBox = $app.querySelector("#toggles-error");
  // Джоб завершается через 10-20 секунд, юзер за это время успевает уйти на
  // другую страницу. renderToggles() без проверки молча подменял бы $app
  // содержимым «Режимов», оставив адрес и подсветку меню от чужой страницы.
  // Она же отвечает на вопрос «мы ещё здесь?» для ответов, пришедших после
  // ухода: _stale ловит только более свежую загрузку, но не смену маршрута.
  const onTogglesPage = () => !!document.getElementById("tg-state-badge");

  async function loadTogglesState() {
    const seq = _newLoad("toggles");
    let s;
    try {
      s = await apiGet("/status");
    } catch (e) {
      if (_stale("toggles", seq) || !onTogglesPage()) return;
      if (!errBox) return;
      // Сообщение обещает, что переключатели заблокированы — значит и кнопки
      // туннеля тоже: под ними реальные запуск и останов, а панель сейчас не
      // знает даже, что включено. Свитчи глушим тем же проходом — после
      // удачной загрузки они уже разлочены, и повторный провал оставил бы их
      // живыми под текстом «заблокированы».
      TOGGLE_DEFS.forEach(t => {
        const row = $app.querySelector(`[data-key="${t.key}"]`);
        if (row) setLockAware(row.querySelector("input"), true);
      });
      setLockAware($app.querySelector("#tg-enable"), true);
      setLockAware($app.querySelector("#tg-disable"), true);
      errBox.hidden = false;
      errBox.innerHTML = `
        <p class="desc" style="color:var(--bad)">Не удалось прочитать состояние: ${errHtml(e)}.
           Переключатели заблокированы — панель не знает, что сейчас включено.</p>
        <div class="btn-row" style="margin-bottom:10px">
          <button class="btn btn-primary" id="toggles-retry">Повторить</button>
        </div>`;
      const retry = $app.querySelector("#toggles-retry");
      if (retry) retry.addEventListener("click", () => {
        retry.disabled = true;
        retry.textContent = "Читаю…";
        loadTogglesState();
      });
      return;
    }
    if (_stale("toggles", seq)) return;
    // /status мог вернуться уже после ухода со страницы: $app очищен, ни
    // одного из этих элементов больше нет, и обращение к badge.hidden роняло
    // весь остаток renderToggles — вместе с привязкой кнопок туннеля,
    // секцией политики и глобальным локом.
    const badge = $app.querySelector("#tg-state-badge");
    if (!badge) return;
    if (errBox) { errBox.hidden = true; errBox.innerHTML = ""; }
    TOGGLE_DEFS.forEach(t => {
      const row = $app.querySelector(`[data-key="${t.key}"]`);
      if (!row) return;
      const box = row.querySelector("input");
      box.checked = t.key === "rst_filter" ? rstIsOn(s.toggles[t.key]) : s.toggles[t.key] === "1";
      setLockAware(box, false);
      // Повторная загрузка не должна вешать второй обработчик: два POST'а
      // на один клик — два конкурентных рестарта сервиса.
      if (!box.dataset.wired) {
        box.dataset.wired = "1";
        box.addEventListener("change", () => toggleClick(t.key, box));
      }
    });
    // TG-tunnel state pill + button enable/disable matching reality.
    const tgRunning = s.tunnel && s.tunnel.running === true;
    badge.hidden = false;
    badge.textContent = tgRunning ? "Включён" : "Остановлен";
    badge.className = "tg-state-badge " + (tgRunning ? "tg-state-on" : "tg-state-off");
    const enableBtn = $app.querySelector("#tg-enable");
    const disableBtn = $app.querySelector("#tg-disable");
    setLockAware(enableBtn, tgRunning);
    setLockAware(disableBtn, !tgRunning);
    if (enableBtn) enableBtn.title = tgRunning ? "Туннель уже запущен" : "";
    if (disableBtn) disableBtn.title = tgRunning ? "" : "Туннель уже остановлен";
  }
  await loadTogglesState();
  // Пока читался /status, юзер мог уйти — вешать обработчики уже некуда, а
  // querySelector вернёт null и уронит остаток функции.
  if (!onTogglesPage()) return;

  async function tgAction(action, title) {
    const btns = [$app.querySelector("#tg-enable"), $app.querySelector("#tg-disable")];
    const wasDisabled = btns.map(b => b && b.disabled);
    const restoreBtns = () => btns.forEach((b, i) => { if (b) b.disabled = wasDisabled[i]; });
    // Глобальный лок включится только с приходом id задачи; до тех пор обе
    // кнопки кликабельны, и второй клик поднимал второй tunnel_enable.
    btns.forEach(b => { if (b) b.disabled = true; });
    let resp;
    try {
      resp = await apiPost("/tunnel/" + action);
    } catch (e) {
      restoreBtns();
      toastErr("Ошибка: ", e);
      return;
    }
    const expectRunning = (action === "enable");
    // Wait until tunnel state actually matches what we asked for — init
    // script может тратить 1-2 сек на cleanup iptables / conntrack
    // после stop, и /status в это время ещё видит daemon alive. Без
    // polling renderToggles из onDone подхватывает stale=true state,
    // и badge показывает «ВКЛЮЧЁН» через секунду после клика
    // «Отключить» — юзер думает что не сработало.
    async function pollTgState() {
      const deadline = Date.now() + 10000;
      while (Date.now() < deadline) {
        try {
          const s = await apiGet("/status");
          if (s.tunnel && s.tunnel.running === expectRunning) return true;
        } catch (e) {
          // network blip — продолжим
        }
        await new Promise(r => { setTimeout(r, 500); });
      }
      return false;
    }

    // Backend returns either {ok:true,job:<id>} (async, new) or
    // {ok:true} (sync, old). Если есть job — открываем модалку с
    // live-логом; иначе toast + re-render toggles страницы.
    if (resp && resp.job) {
      // Исходное состояние возвращаем ДО openJobModal: лок запоминает
      // текущее disabled как «правильное» и вернул бы кнопку выключенной.
      restoreBtns();
      openJobModal(title, resp.job, {
        onDone: async () => {
          await pollTgState();
          if (onTogglesPage()) renderToggles();
        },
      });
    } else {
      toast(title + " — готово");
      await pollTgState();
      if (onTogglesPage()) renderToggles();
      else restoreBtns();
    }
  }
  $app.querySelector("#tg-enable").addEventListener("click", () => tgAction("enable", "Запуск Telegram туннеля"));
  $app.querySelector("#tg-disable").addEventListener("click", () => tgAction("disable", "Остановка Telegram туннеля"));

  // ----- Policy access section -----
  const nameInput = $app.querySelector("#policy-name");
  const statusEl  = $app.querySelector("#policy-status");
  const segGroup  = $app.querySelector("#policy-mode");
  const saveBtn   = $app.querySelector("#policy-save-btn");
  // ПРАВИЛО ЗДЕСЬ ОБЯЗАНО СОВПАДАТЬ С СЕРВЕРНЫМ, И РАНЬШЕ НЕ СОВПАДАЛО.
  //
  // Стояло /^[A-Za-z0-9_-]{0,32}$/ — то есть латиница и всё. На сервере это
  // давно исправлено: политики Keenetic люди называют по-русски и с пробелами
  // («Незарегистрированные клиенты», «Через ВПН»), и обработчик их принимает.
  // А форма отбивала такое имя ДО отправки, поэтому серверная правка выглядела
  // сделанной, но пользователю по-прежнему было нельзя.
  //
  // Запрещаем ровно то же, что и сервер, и ровно по тем же причинам:
  //   " $ ` \ ;  — ломают `. config`, куда имя попадает через set_flag;
  //   '            — set_flag экранирует апостроф как '\'', а обратно это не
  //                  разворачивается: имя портится навсегда при первой же
  //                  перегенерации конфига;
  //   |            — policy_status отдаёт «name=%s|exclude=%s», и на чтении
  //                  назад имя срезалось бы по разделителю;
  //   перевод строки — по той же причине, что и всё выше.
  const NAME_BAD_RE = /["$`\\;'|\n\r]/;
  // Длина в СИМВОЛАХ, а не в кодовых единицах: '…'.length считает UTF-16, и
  // на суррогатных парах цифра разошлась бы с серверной, где считаются
  // символы UTF-8.
  const nameLen = (v) => Array.from(v).length;
  const nameOk  = (v) => v.length > 0 && !NAME_BAD_RE.test(v) && nameLen(v) <= 32;
  const NAME_HINT = "Имя политики: до 32 символов, нельзя \" $ ` \\ ; \u0027 |";

  function setPolicyStatus(state, text) {
    // state: good | warn | muted | error
    statusEl.dataset.state = state;
    statusEl.querySelector(".policy-status-text").textContent = text;
  }
  function setPolicyMode(exclude) {
    segGroup.querySelectorAll(".seg-btn").forEach(b => {
      const on = b.dataset.exclude === String(exclude);
      b.classList.toggle("seg-on", on);
      b.setAttribute("aria-checked", String(on));
    });
  }
  async function loadPolicyStatus() {
    const seq = _newLoad("policy");
    try {
      const d = await apiGet("/policy/status");
      if (_stale("policy", seq)) return;
      nameInput.value = d.name || "";
      setPolicyMode(d.exclude === "1" ? 1 : 0);
      if (!d.name) {
        setPolicyStatus("muted", "Поле пусто — фильтр выключен");
      } else if (d.exists === 1 || d.exists === true) {
        setPolicyStatus("good", `Политика «${d.name}» найдена в Keenetic`);
      } else {
        setPolicyStatus("warn", `Политика «${d.name}» не найдена — фильтр игнорируется, обрабатывается весь трафик`);
      }
    } catch (e) {
      if (_stale("policy", seq)) return;
      setPolicyStatus("error", "Ошибка: " + errMsg(e));
    }
  }
  loadPolicyStatus();

  // Validate + (опционально) повторный status check на blur
  nameInput.addEventListener("blur", () => {
    const v = nameInput.value.trim();
    if (!nameOk(v)) {
      setPolicyStatus("error", NAME_HINT);
      return;
    }
    // Запрос свежего status'а с currently-saved конфигом — input не сохранит
    // ничего пока юзер не нажмёт «Сохранить». Если хочется live-проверки
    // existence без save — на будущее можно добавить отдельный endpoint
    // /policy/check?name=. Сейчас: оставляем статус до Save.
  });

  segGroup.addEventListener("click", (e) => {
    const btn = e.target.closest(".seg-btn");
    if (!btn) return;
    setPolicyMode(parseInt(btn.dataset.exclude, 10));
  });

  saveBtn.addEventListener("click", async () => {
    if (saveBtn.disabled) return;
    const v = nameInput.value.trim();
    if (!nameOk(v)) {
      toast(NAME_HINT, "bad");
      nameInput.focus();
      return;
    }
    const exclude = segGroup.querySelector(".seg-btn.seg-on")?.dataset.exclude || "0";
    // Кнопка не входит в глобальный лок, а под ней рестарт сервиса: без
    // этого второй клик в окне ожидания ответа запускал вторую задачу.
    saveBtn.disabled = true;
    let resp;
    try {
      resp = await apiPost("/policy/save", { name: v, exclude });
    } catch (e) {
      saveBtn.disabled = false;
      toastErr("Ошибка: ", e);
      return;
    }
    if (resp && resp.job) {
      openJobModal("Применение политики доступа", resp.job, {
        onDone: () => { saveBtn.disabled = false; setTimeout(loadPolicyStatus, 500); }
      });
    } else {
      saveBtn.disabled = false;
      toast("Применено");
      loadPolicyStatus();
    }
  });

  // Если уже бежит job (юзер пришёл с другой вкладки) — сразу заблочить
  // только что отрендеренные switches/buttons. Без этого глобал-лок
  // применился бы к старым DOM-элементам которых на этой странице нет.
  _updateGlobalUILock();
}

async function toggleClick(key, box) {
  const sw = box.closest(".switch");
  const wanted = box.checked ? "1" : "0";
  if (key === "autohostlist" && wanted === "1") {
    // Тумблер блокируем на время вопроса. Подложка модалки перехватывает
    // мышь, но не клавиатуру: без этого Tab уводил фокус из модалки обратно
    // на чекбокс, пробел давал второй change, и запрос уходил на бэкенд мимо
    // подтверждения — в итоге в конфиге было включено, а галочка снята.
    box.disabled = true;
    const go = await confirmModal("Включить автохостлист?", AUTOHOSTLIST_WARNING,
                                  "Включать", "Не включать");
    // Пока висел вопрос, страницу могла перерисовать чужая фоновая задача
    // (например завершившийся туннель зовёт renderToggles): тогда наш box
    // уже отцеплен от документа, и запись в него ничего не покажет. Ответ
    // при этом остаётся в силе — состояние подтянет следующий /status.
    if (typeof document.body.contains === "function" && !document.body.contains(box)) return;
    box.disabled = false;
    if (!go) {
      // Событие change уже переставило чекбокс — возвращаем его сами.
      box.checked = false;
      return;
    }
  }
  sw.classList.add("loading");
  box.disabled = true; // блок UI до завершения, не даём кликать ещё
  const restarts = TOGGLES_RESTART_SERVICE[key] === 1;
  const verb = wanted === "1" ? "Включаю" : "Отключаю";
  const niceName = {
    rst_filter: "RST-фильтр",
    silent_fallback: "Silent fallback",
    customd: "custom.d",
    dynamic_ttl: "Динамический TTL",
    stats: "Сбор статистики",
    ppe: "PPE de-offload",
    auto_update: "Автообновление",
    autohostlist: "Автохостлист",
  }[key] || key;

  let resp;
  try {
    resp = await apiPost("/toggle/" + TOGGLE_API_NAME[key], { value: wanted });
  } catch (e) {
    box.checked = !box.checked; // revert
    box.disabled = false;
    sw.classList.remove("loading");
    toastErr("Ошибка: ", e);
    return;
  }
  // Backend async — открываем модалку с live-логом. Состояние switch'а
  // (loading + disabled) держится до onDone — если юзер закрыл модалку
  // раньше, badge в углу позволит снова открыть, а UI блокировка не
  // даст думать что переключение уже применилось.
  openJobModal(verb + " " + niceName, resp.job, {
    // Рестарт nfqws2 перетряхивает iptables на канале, по которому открыта
    // сама панель: обрыв на десятки секунд здесь норма, и обрывать опрос
    // через пять секунд значит объявить провалом штатный ход операции.
    tolerateOutage: restarts,
    onDone: (d) => {
      sw.classList.remove("loading");
      box.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) {
        // Toggle failed — revert checkbox чтобы UI отражал реальное
        // состояние (старое значение сохранилось в config).
        box.checked = !box.checked;
        toast("Не получилось — вернул как было", "bad");
      } else if (jobUnresolved(outcome)) {
        // Итог неизвестен: в конфиге ничего не откатывалось, поэтому не
        // трогаем чекбокс и не обещаем, что вернули как было.
        const m = unresolvedMsg(outcome);
        if (m) toast(m, "bad");
        resyncToggle(key, box);
      } else {
        toast(wanted === "1" ? "Включено" : "Выключено");
      }
      if (restarts && !jobUnresolved(outcome)) setTimeout(refreshStatus, 500);
    },
  });
}
