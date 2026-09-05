import { JOB_FAIL, jobOutcome, jobUnresolved, openJobModal, unresolvedMsg } from "../job.js";
import { apiGet, apiPost, toastErr } from "../core/api.js";
import { copyToClipboard } from "../core/clipboard.js";
import { $app, escapeHtml } from "../core/dom.js";
import { toast } from "../core/toast.js";
import { strategiesShell } from "./strategies.js";

// ПОДБОР ПО ДОМЕНУ — наш аналог blockcheck.
//
// Почему отдельная вкладка, а не блок на «Автоподборе». Соседние вкладки
// отвечают на «что выбрано» и «что задать вручную» — обе про уже готовые
// строки. Здесь другая работа: строку ЕЩЁ НЕТ, её надо получить замером.
// Это третий вопрос, и у него своя дверь.
//
// Почему не на «Диагностике», где уже есть ввод домена. Та проба отвечает
// «блокируют ли», эта — «чем пробить». Ответ здесь — строка стратегии, и
// искать её человек пойдёт туда, где живут стратегии. Из результата пробы на
// «Диагностике» стоит дать сюда ссылку, но поле ввода дублировать нельзя:
// два одинаковых поля в разных разделах — ровно та путаница, из-за которой
// «Стратегии» и «Rotator» когда-то свели в одну страницу.
//
// ЧЕГО ЗДЕСЬ НАМЕРЕННО НЕТ. Вердиктов инструмента и трассы зондов. Человеку,
// у которого не грузится сайт, слово «poisonable» не говорит ничего и только
// провоцирует спор о терминах. Показываем то, ради чего пришли: строку,
// которая пробивает. Сырой ответ замера лежит в свёрнутом блоке — он для
// поддержки, а не для чтения.

// РЕЖИМЫ ЗАМЕРА. Выбирает человек, а не мы за него.
//
// Раньше мерились оба протокола сразу, а подбор под старые устройства
// включался по списку доменов. И то и другое — гадание: у одного дома
// телевизор, у другого нет, одному важен браузер, другому приставка. Сколько
// человек готов ждать, мы тем более не знаем — поэтому цена каждого режима
// написана рядом с ним, до нажатия, а не выясняется по неподвижному
// индикатору.
const MODES = [
  { id: "tcp13", name: "Современные устройства", hint: "браузеры и телефоны · до 2 минут" },
  { id: "tcp12", name: "Старые устройства", hint: "телевизоры и приставки · до 2 минут" },
  { id: "mixed", name: "И те, и другие", hint: "одна строка на всех · 3–5 минут" },
  { id: "quic", name: "QUIC", hint: "HTTP/3 в браузере · около минуты" },
  { id: "voice", name: "Голос Дискорда", hint: "нужен идущий разговор · без домена" },
];

function selectedMode() {
  const el = document.querySelector('input[name="pick-mode"]:checked');
  return el ? el.value : "tcp13";
}

export function renderStrategyPick() {
  $app.innerHTML = strategiesShell("pick", `
    <div class="card">
      <h3>Подбор стратегии для домена</h3>
      <p class="desc">
        Замеряем, чем именно режут этот домен, и показываем строку параметров,
        которая его пробивает. Замер ничего не меняет и никуда не записывает —
        что делать со строкой, решаете вы.
      </p>
      <div class="pick-modes" role="radiogroup" aria-label="Что замерять">
        ${MODES.map((m, i) => `
          <label class="pick-mode">
            <input type="radio" name="pick-mode" value="${m.id}"${i === 0 ? " checked" : ""}>
            <span class="pick-mode-name">${escapeHtml(m.name)}</span>
            <span class="pick-mode-hint">${escapeHtml(m.hint)}</span>
          </label>`).join("")}
      </div>
      <div class="probe-row">
        <input type="text" id="pick-domain" placeholder="например, rutracker.org"
               autocomplete="off" autocapitalize="none" spellcheck="false">
        <button class="btn btn-primary" id="pick-run">Подобрать</button>
      </div>
      <div id="pick-result"></div>
    </div>
  `);
  wirePick();
  loadLast();
}

function wirePick() {
  const input = document.getElementById("pick-domain");
  const btn = document.getElementById("pick-run");
  if (!input || !btn) return;
  // Поле домена гасим на голосе: там его не существует, и активное поле
  // заставляло бы человека выдумывать, что туда вписать.
  const syncInput = () => {
    const voice = selectedMode() === "voice";
    input.disabled = voice;
    input.placeholder = voice ? "домен не нужен — адрес берём из разговора" : "например, rutracker.org";
  };
  document.querySelectorAll('input[name="pick-mode"]').forEach((r) => {
    r.addEventListener("change", syncInput);
  });
  syncInput();
  btn.addEventListener("click", () => run(input, btn));
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") run(input, btn); });
}

async function run(input, btn) {
  // Люди вставляют ссылку целиком. Схему и путь срезаем молча — ровно так же
  // это сделано у пробы домена на «Диагностике».
  const mode = selectedMode();
  // У голоса домена нет: сервер выдаётся на сессию, и адрес берётся из
  // идущего разговора. Поле ввода тут просто ни при чём.
  const domain = mode === "voice"
    ? ""
    : input.value.trim().replace(/^https?:\/\//i, "").replace(/\/.*$/, "");
  if (mode !== "voice") {
    if (!domain) { input.focus(); return; }
    input.value = domain;
  }
  btn.disabled = true;
  const label = btn.textContent;
  btn.textContent = "Подбираю…";

  let resp;
  try {
    resp = await apiPost("/strategy/pick", { domain, mode });
  } catch (e) {
    btn.disabled = false;
    btn.textContent = label;
    toastErr("Не удалось запустить замер: ", e);
    return;
  }

  const title = mode === "voice" ? "Замеряю голос Дискорда" : `Подбираю стратегию для ${domain}`;
  openJobModal(title, resp.job, {
    onDone: (d) => {
      btn.disabled = false;
      btn.textContent = label;
      const outcome = jobOutcome(d);
      if (jobUnresolved(outcome)) {
        const m = unresolvedMsg(outcome);
        if (m) toast(m, "bad");
        return;
      }
      if (outcome === JOB_FAIL) {
        toast("Замер не прошёл — причина в журнале выше", "bad");
        return;
      }
      loadLast();
    },
  });
}

async function loadLast() {
  const box = document.getElementById("pick-result");
  if (!box) return;
  let d;
  try {
    d = await apiGet("/strategy/pick");
  } catch (e) {
    box.innerHTML = "";
    return;
  }
  const r = d && d.result;
  if (!r) { box.innerHTML = ""; return; }
  box.innerHTML = renderResult(r);
  // Кнопок теперь столько же, сколько найденных строк, — по одной на протокол.
  // Поэтому класс, а не идентификатор: с идентификатором копирование работало
  // бы только у первой.
  box.querySelectorAll(".pick-copy").forEach((btn) => {
    btn.addEventListener("click", () => {
      copyToClipboard(btn.dataset.line || "");
      toast("Строка скопирована");
    });
  });
}

// Замер приходит по двум протоколам сразу. Показываем оба, но НЕ двумя
// одинаковыми карточками: вопрос, с которым сюда приходят, один — «что мне
// вставить», — и ответом на него остаётся строка. Протокол при ней подпись, а
// не отдельный раздел.
//
// Старый плоский ответ (только TCP) тоже поддерживаем: панель и CGI едут одним
// релизом, но у человека в браузере может лежать закэшированная страница.
function renderResult(r) {
  // Форму определяем по НАЛИЧИЮ ключей, а не по их истинности: у составного
  // ответа любая половина может быть null (протокол не дал результата), и по
  // истинности такой ответ спутался бы со старым плоским.
  const pair = r && ("tcp" in r || "quic" in r || "voice" in r);
  const parts = pair
    ? { tcp: r.tcp, quic: r.quic, voice: r.voice }
    : { tcp: r, quic: null, voice: null };
  // Голос обязан считаться наравне с остальными: раньше он в этот перебор не
  // входил, и чисто голосовой замер рисовал пустоту — человек нажимал
  // «Подобрать», задача честно отрабатывала, а на странице не появлялось
  // ничего.
  const any = parts.tcp || parts.quic || parts.voice;
  if (!any) return "";

  const target = String(any.target || "").replace(/:443$/, "");
  const raw = `<details class="probe-raw">
      <summary>Подробности замера</summary>
      <pre class="log">${escapeHtml(JSON.stringify(r, null, 2))}</pre>
    </details>`;

  // Подпись берём из режима, а не из протокола: «по TCP» одинаково выглядело
  // бы у замера под браузеры и под телевизоры, хотя это разные ответы.
  const tcpLabel = {
    tcp12: "TCP, старые устройства",
    mixed: "TCP, современные и старые",
  }[r && r.mode] || "TCP";
  const blocks = [
    protoBlock(tcpLabel, parts.tcp),
    protoBlock("QUIC", parts.quic),
    protoBlock("Голос Дискорда", parts.voice),
  ].filter(Boolean);

  const found = blocks.some((b) => b.hasLine);
  // У голоса домена нет, и подставлять туда адрес разговора нельзя: человек
  // читает это как «домен, который я вводил».
  const voiceOnly = !parts.tcp && !parts.quic && parts.voice;
  let head;
  if (voiceOnly) {
    head = found ? "Голос Дискорда пробивает такая строка:" : "Голос Дискорда — что показал замер:";
  } else {
    head = found
      ? `Домен <b>${escapeHtml(target)}</b> пробивают такие строки:`
      : `Домен <b>${escapeHtml(target)}</b> — что показал замер:`;
  }

  const hint = found
    ? `<p class="desc">
         Чтобы применить строку, вставьте её на вкладке «Свои стратегии».
         Учтите: своя строка заменяет набор плеч для всего пула целиком,
         а не только для этого домена. У TCP и QUIC пулы разные.
       </p>`
    : "";

  return `
    <div class="pick-report">
      <div class="pick-head">${head}</div>
      ${blocks.map((b) => b.html).join("")}
      ${hint}
      ${raw}
    </div>`;
}

// protoBlock — один протокол: подпись и то, что по нему вышло.
function protoBlock(name, res) {
  if (!res) return null;
  if (res.strategy) {
    // Предупреждение про старые устройства показываем ВСЕГДА, когда замер его
    // дал. Вердикты и трассу человеку не показываем принципиально, но это не
    // термин, а последствие: строка починит браузер и не починит телевизор.
    // Промолчать — значит отправить человека искать поломку в телевизоре.
    let warn = "";
    if (res.covers_tls12 === false) {
      warn = `<p class="desc pick-warn">Эта строка не поможет старым устройствам —
              телевизорам, приставкам и прочему, что ходит по устаревшему TLS.
              Браузер на компьютере и телефоне она чинит.</p>`;
    }
    return {
      hasLine: true,
      html: `
        <div class="pick-proto">по ${escapeHtml(name)}</div>
        <pre class="pick-line">${escapeHtml(res.strategy)}</pre>
        <div class="pick-actions">
          <button class="btn pick-copy" data-line="${escapeHtml(res.strategy)}">Скопировать</button>
        </div>
        ${warn}`,
    };
  }
  return {
    hasLine: false,
    html: `
      <div class="pick-proto">по ${escapeHtml(name)}</div>
      <p class="desc pick-outcome">${escapeHtml(outcomeText(name, res))}</p>`,
  };
}

// outcomeText — вердикт замера человеческими словами.
//
// Названий вердиктов человеку не показываем принципиально: слово «poisonable»
// или «no_quic» ничего ему не говорит и только провоцирует спор о терминах.
// Показываем то, что из вердикта следует для него.
function outcomeText(name, res) {
  switch (res.verdict) {
    case "clear":
      return `открывается и без обхода — подбирать нечего.`;
    case "no_quic":
      return `сайт не работает по HTTP/3 — обходить нечего, браузер и так пойдёт по TCP.`;
    case "local_address":
      return `имя подменяется на уровне DNS: роутер или AdGuard отдают внутренний адрес. `
        + `Пока это так, замерить по QUIC нечего.`;
    case "address":
      return `режут сам адрес, а не имя. Стратегией это не лечится — нужен туннель.`;
    case "response":
      // Отдельный класс: запрос доходит, режут ОТВЕТ сервера. Виден только на
      // TLS 1.2, где сертификат идёт открытым текстом. Написать тут «подход не
      // найден» значило бы отправить человека искать поломку у себя.
      return `запрос до сервера доходит, а режут его ответ — так бывает на старом TLS, `
        + `где имя видно в сертификате. Готового приёма под это у нас пока нет, `
        + `пришлите домен в поддержку.`;
    case "flaky":
      return `замер не воспроизводится: часть зондов прошла, часть нет. Вывод делать рано.`;
    case "unreachable":
      return `до адреса нет пути.`;
    case "no_call":
      return `разговор не идёт. Начните звонок в Дискорде и повторите замер: `
        + `у голоса нет имени, которое можно вписать, адрес берётся из идущего разговора.`;
    case "no_udp":
      return `на этом канале не ходит UDP вообще — обходить голос отдельно бессмысленно.`;
    case "blocked":
      return `голосовой сервер молчит, хотя UDP на канале ходит: режут именно этот поток.`;
    default:
      // Есть находки, но исполнить их движок пока не умеет — это отдельный,
      // честный исход, и прятать его за «подход не найден» нельзя.
      if (res.findings && res.findings.length) {
        return `домен пробивается, но приёмом, который движок пока не умеет исполнить. `
          + `Подробности — в разборе замера ниже, пришлите домен в поддержку.`;
      }
      return `режут, но строки, которая его пробивает, замер не нашёл. `
        + `Пришлите домен в поддержку — разберём вручную.`;
  }
}
