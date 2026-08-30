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
        Замеряем, чем именно режут этот домен, и показываем строку параметров,
        которая его пробивает. Замер ничего не меняет и никуда не записывает —
        что делать со строкой, решаете вы. Занимает около минуты.
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
  const copy = document.getElementById("pick-copy");
  if (copy) {
    copy.addEventListener("click", () => {
      copyToClipboard(copy.dataset.line || "");
      toast("Строка скопирована");
    });
  }
}

function renderResult(r) {
  const target = String(r.target || "").replace(/:443$/, "");
  const raw = `<details class="probe-raw">
      <summary>Подробности замера</summary>
      <pre class="log">${escapeHtml(JSON.stringify(r, null, 2))}</pre>
    </details>`;

  if (r.strategy) {
    return `
      <div class="pick-report">
        <div class="pick-head">Домен <b>${escapeHtml(target)}</b> пробивает такая строка:</div>
        <pre class="pick-line" id="pick-line">${escapeHtml(r.strategy)}</pre>
        <div class="pick-actions">
          <button class="btn" id="pick-copy" data-line="${escapeHtml(r.strategy)}">Скопировать</button>
        </div>
        <p class="desc">
          Чтобы её применить, вставьте строку на вкладке «Свои стратегии».
          Учтите: своя строка заменяет набор плеч для всего пула целиком,
          а не только для этого домена.
        </p>
        ${raw}
      </div>`;
  }

  // «Обходить нечего» — не отказ, а хорошая новость, и подать её надо как
  // ответ на вопрос, с которым пришли, а не как пустой результат.
  if (r.verdict === "clear") {
    return `
      <div class="pick-report">
        <div class="pick-head">Домен <b>${escapeHtml(target)}</b> открывается и без обхода — подбирать нечего.</div>
        <p class="desc">
          Если сайт всё равно не грузится, дело не в блокировке этого имени.
          Проверьте домен на «Диагностике» — она покажет, на какой стадии обрывается.
        </p>
        ${raw}
      </div>`;
  }

  return `
    <div class="pick-report">
      <div class="pick-head">Для домена <b>${escapeHtml(target)}</b> подход не найден.</div>
      <p class="desc">
        Замер не нашёл строки, которая его пробивает. Пришлите домен в поддержку —
        разберём вручную.
      </p>
      ${raw}
    </div>`;
}
