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

export function renderStrategyPick() {
  $app.innerHTML = strategiesShell("pick", `
    <div class="card">
      <h3>Подбор стратегии для домена</h3>
      <p class="desc">
        Замеряем, чем именно режут этот домен по TCP и по QUIC, и показываем
        строку параметров, которая его пробивает. Замер ничего не меняет и
        никуда не записывает — что делать со строкой, решаете вы.
        Занимает около минуты.
      </p>
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
  btn.addEventListener("click", () => run(input, btn));
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") run(input, btn); });
}

async function run(input, btn) {
  // Люди вставляют ссылку целиком. Схему и путь срезаем молча — ровно так же
  // это сделано у пробы домена на «Диагностике».
  const domain = input.value.trim().replace(/^https?:\/\//i, "").replace(/\/.*$/, "");
  if (!domain) { input.focus(); return; }
  input.value = domain;
  btn.disabled = true;
  const label = btn.textContent;
  btn.textContent = "Подбираю…";

  let resp;
  try {
    resp = await apiPost("/strategy/pick", { domain });
  } catch (e) {
    btn.disabled = false;
    btn.textContent = label;
    toastErr("Не удалось запустить замер: ", e);
    return;
  }

  openJobModal(`Подбираю стратегию для ${domain}`, resp.job, {
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
  const pair = r && ("tcp" in r || "quic" in r);
  const parts = pair ? { tcp: r.tcp, quic: r.quic } : { tcp: r, quic: null };
  const any = parts.tcp || parts.quic;
  if (!any) return "";

  const target = String(any.target || "").replace(/:443$/, "");
  const raw = `<details class="probe-raw">
      <summary>Подробности замера</summary>
      <pre class="log">${escapeHtml(JSON.stringify(r, null, 2))}</pre>
    </details>`;

  const blocks = [
    protoBlock("TCP", parts.tcp),
    protoBlock("QUIC", parts.quic),
  ].filter(Boolean);

  const found = blocks.some((b) => b.hasLine);
  const head = found
    ? `Домен <b>${escapeHtml(target)}</b> пробивают такие строки:`
    : `Домен <b>${escapeHtml(target)}</b> — что показал замер:`;

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
