import { apiGet, apiGetText, apiPost, apiPostText, errHtml, errMsg, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, skeletonBlocks } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { _updateGlobalUILock } from "../job.js";
import { strategiesShell } from "./strategies.js";

export function renderCredits() {
  $app.innerHTML = `
    <h1 class="page-title">Благодарности</h1>
    <p class="credits-intro">
      Проект живёт благодаря людям, которые вкладывают в него время и ресурсы.
    </p>

    <div class="credits-grid">
      <div class="card credits-card tester-card">
        <div class="credits-badge tester-badge">${_icons.star} Главный тестировщик</div>
        <div class="credits-name">AusterusJ</div>
        <p class="desc">
          Бесконечные часы живых тестов на роутерах, отлов регрессий ещё
          до релиза и терпение, с которым он проверяет каждую
          экспериментальную стратегию. Без него z2k был бы сильно менее
          стабильным.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">SupWgeneral</div>
        <p class="desc">
          Материальная поддержка, благодаря которой у z2k есть выделенный
          VPS под Telegram-туннель и возможность развиваться дальше.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Alexey</div>
        <p class="desc">
          За каждым стабильным релизом стоит не только код — стоят и
          спонсоры вроде Alexey, которые держат проект на плаву между
          апдейтами.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Jet_sk_ya</div>
        <p class="desc">
          Без таких людей z2k оставался бы pet-проектом одного-двух
          разработчиков. Спасибо, что вкладываешь в инструмент, которым
          пользуются сотни.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Suharik39</div>
        <p class="desc">
          Без таких сторонников z2k быстро остался бы без независимого
          источника финансирования. Спасибо за вклад в свободу
          пользователей.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">ZyaK&lt;-</div>
        <p class="desc">
          За весомый вклад в развитие проекта и веру в свободный интернет.
          Спасибо, что держишь Z2K на плаву!
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Алексей Стрельцов</div>
        <p class="desc">
          Поддержка, которая приходит тихо и по делу: благодаря таким, как
          Алексей, туннель остаётся бесплатным для всех, а проект —
          независимым от рекламы и площадок. Спасибо за веру в свободный
          интернет.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Diman86RUS</div>
        <p class="desc">
          Новый спонсор проекта. Благодаря таким людям, как Diman86RUS, z2k
          продолжает развиваться, а Telegram-туннель остаётся бесплатным для
          всех. Спасибо, что вкладываешься в свободный интернет!
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Alex</div>
        <p class="desc">
          Счета за VPS приходят каждый месяц — независимо от того, помнит
          о них кто-нибудь или нет. В этот раз их закрыл ты, и Telegram-туннель
          продолжил работать для всех, кто о существовании этих счетов даже
          не догадывается. Спасибо.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">GRM</div>
        <p class="desc">
          Спасибо, что не прошёл мимо. Сам обход работает на роутере, а всё
          вокруг него — Telegram-туннель, зеркала для обновлений, служебные
          сервисы — живёт на сервере, и за него приходят счета. Проект
          складывается из вложенного в него времени и из таких вот взносов:
          ты закрыл ту часть, которую временем не закроешь.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Dez</div>
        <p class="desc">
          Спасибо, Dez. Поддержать проект никто не обязан, и каждый раз, когда
          это всё же происходит, работать дальше становится легче.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">hoaxx</div>
        <p class="desc">
          Спасибо, hoaxx. Такая поддержка делает проект устойчивее, а работу
          над ним — спокойнее.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Mansurchick</div>
        <p class="desc">
          Спасибо, Mansurchick. Часть обхода живёт не на роутере: чтобы найти
          рабочий адрес заблокированного сайта, нужен взгляд из-за границы —
          и сервер, который этим занят, держится в том числе на таких взносах.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Dkarloff - SEO отец</div>
        <p class="desc">
          Спасибо за поддержку проекта. Такие взносы держат на плаву всё, что
          вокруг обхода — туннель, зеркала обновлений и служебные сервисы, —
          и позволяют развивать z2k дальше.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">KIBERPANK</div>
        <p class="desc">
          Спасибо, KIBERPANK. У проекта нет ни рекламы, ни платных версий —
          он держится ровно на таких людях, и благодаря им остаётся
          бесплатным для всех остальных.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">olmer2002</div>
        <p class="desc">
          Спасибо, olmer2002. Обход блокировок — не готовая вещь, а работа,
          которая не кончается: то, что открывалось вчера, завтра приходится
          открывать заново. Поддержка вроде этой покупает не отдельную
          функцию, а саму возможность продолжать — для всех, кто этим
          пользуется.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">TiaMax</div>
        <p class="desc">
          Спасибо, TiaMax. Проект живёт не разовым усилием, а тем, что кто-то
          готов поддержать его в тот момент, когда всё уже вроде бы работает
          и незаметно. Именно на такой поддержке держится то, чем каждый день
          пользуются молча.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Denis</div>
        <p class="desc">
          Спасибо, Denis. Обход блокировок — это гонка, в которой финиша нет:
          каждую неделю что-то ломают, и каждую неделю это надо чинить. Такая
          поддержка — это не «спасибо за вчера», а возможность быть готовыми
          к завтра.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">Mega Man</div>
        <p class="desc">
          Спасибо, Mega Man. Проект не продаёт подписок и не показывает
          рекламу — он существует ровно настолько, насколько его готовы
          поддерживать те, кому он нужен. Каждая такая поддержка — ещё немного
          времени, которое можно потратить на то, чтобы всё просто работало.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">TheGreatYogo</div>
        <p class="desc">
          Спасибо, TheGreatYogo. Он сам айтишник, и это меняет смысл поддержки.
          Ему не надо объяснять, почему «вчера работало, сегодня нет» — это два
          разных бага, и сколько уходит не на код, а на то, чтобы понять, что
          именно поменяли на той стороне. Поддержка от человека, который мог бы
          разобрать это по строчкам и написать своё, — самая точная рецензия,
          какую тут можно получить.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">logistik77</div>
        <p class="desc">
          Спасибо, logistik77. У поддержки тут есть вполне вещественная сторона:
          сервер, через который сверяются адреса, роутеры, на которых всё ломают
          раньше, чем это доедет до людей, домены и сборки под каждую железку.
          Без этого остался бы набор скриптов, работающих у одного человека
          дома, — а не то, что можно поставить и забыть.
        </p>
      </div>

      <div class="card credits-card sponsor-card">
        <div class="credits-badge sponsor-badge">${_icons.heart} Спонсор проекта</div>
        <div class="credits-name">b11d11</div>
        <p class="desc">
          Спасибо, b11d11. Обход живёт не на энтузиазме, а на счетах: аренда
          узла, домены, железки, на которых всё это проверяется до того, как
          попадёт к людям. Поддержка закрывает ровно эту часть — ту, которую
          из окна панели не видно, но без которой окна бы не было.
        </p>
      </div>
    </div>
  `;
}

const STRATEGY_POOL_NAMES = {
  rkn_tcp: "Заблокированные сайты (TCP)",
  yt_tcp:  "YouTube (TCP)",
  gv_tcp:  "YouTube видео (TCP)",
  yt_quic: "YouTube (QUIC/UDP)",
  discord_udp: "Дискорд, голос (UDP)",
};

export async function renderStrategies() {
  $app.innerHTML = strategiesShell("config", `
    <div class="card">
      <p class="desc">
        Обычно z2k подбирает стратегию сам: пробует варианты по очереди и
        закрепляет ту, что заработала. Здесь можно взять любой пул под себя и
        задать свою строку параметров — тогда для него подбор выключается и
        работает ровно то, что вы написали. Остальные пулы продолжат
        подбираться автоматически.
      </p>
      <p class="desc">
        <b>Свои строки переживают обновления и переустановку.</b> Перед
        сохранением строка проверяется движком: непрошедшая проверку не
        применяется, потому что одна ошибка в ней останавливает обход целиком,
        а не только этот пул.
      </p>
      <p class="desc">
        Нужно не на весь пул, а разово поправить один домен — это на вкладке
        <a href="#/state">«Автоподбор»</a>.
      </p>
    </div>
    <div id="strategy-pools">${skeletonBlocks(4)}</div>
  `);
  loadStrategyPools();
  _updateGlobalUILock();
}

async function loadStrategyPools() {
  const host = document.getElementById("strategy-pools");
  if (!host) return;
  const seq = _newLoad("strategyPools");
  let d;
  try {
    d = await apiGet("/strategy/pools");
  } catch (e) {
    if (_stale("strategyPools", seq)) return;
    host.innerHTML = `<p class="desc">Не удалось загрузить: ${errHtml(e)}</p>`;
    return;
  }
  if (_stale("strategyPools", seq)) return;
  const pools = (d && d.pools) || [];
  host.innerHTML = pools.map(p => {
    const custom = p.custom === 1 || p.custom === "1";
    const title = STRATEGY_POOL_NAMES[p.pool] || p.pool;
    return `
      <div class="card" data-pool="${escapeHtml(p.pool)}">
        <div class="toggle-row">
          <div class="t-text">
            <div class="t-name">${escapeHtml(title)}</div>
            <div class="t-desc">${custom
              ? "Своя стратегия — автоподбор для этого пула выключен"
              : "Автоподбор: стратегия выбирается и меняется автоматически"}</div>
          </div>
          <button type="button" class="btn ${custom ? "" : "btn-primary"}" data-act="mode">
            ${custom ? "Вернуть авто" : "Своя стратегия"}
          </button>
        </div>
        <div class="strategy-editor" hidden>
          <textarea class="strategy-text" rows="6" spellcheck="false"
            placeholder="--lua-desync=fake:dir=out:repeats=2 …"></textarea>
          <div class="btn-row" style="margin-top:10px">
            <button type="button" class="btn" data-act="check">Проверить</button>
            <button type="button" class="btn btn-primary" data-act="save">Сохранить и применить</button>
          </div>
          <p class="desc strategy-msg" hidden></p>
        </div>
      </div>`;
  }).join("");

  host.querySelectorAll("[data-pool]").forEach(card => {
    const pool = card.getAttribute("data-pool");
    const ed   = card.querySelector(".strategy-editor");
    const ta   = card.querySelector(".strategy-text");
    const msg  = card.querySelector(".strategy-msg");
    const say = (text, good) => {
      msg.hidden = false;
      msg.textContent = text;
      msg.style.color = good ? "var(--good)" : "var(--bad)";
    };

    const isCustom = card.querySelector('[data-act="mode"]').textContent.trim() === "Вернуть авто";
    if (isCustom) { ed.hidden = false; loadStrategyText(pool, ta, say); }

    card.querySelector('[data-act="mode"]').addEventListener("click", async () => {
      if (isCustom) {
        if (!confirm(`Вернуть «${STRATEGY_POOL_NAMES[pool] || pool}» на автоподбор?\n\nВаша строка будет удалена.`)) return;
        try { await apiPost("/strategy/pool/reset", { pool }); }
        catch (e) { toastErr("Ошибка: ", e); return; }
        toast("Пул вернулся на автоподбор");
        loadStrategyPools();
      } else {
        ed.hidden = !ed.hidden;
        if (!ed.hidden && !ta.value) loadStrategyText(pool, ta, say);
      }
    });

    card.querySelector('[data-act="check"]').addEventListener("click", async () => {
      say("Проверяю…", true);
      try {
        const r = await apiPostText("/strategy/pool/validate?pool=" + encodeURIComponent(pool), ta.value);
        if (r && r.valid) {
          // Подбор по домену выдаёт ОДИН приём, а движку нужен полный набор
          // опций пула. Бекенд достраивает недостающее сам — и возвращает то,
          // что реально применится. Показываем это в том же поле: иначе
          // человек сохранит одно, а работать будет другое, и он об этом не
          // узнает.
          const done = r.line && r.line.trim() !== ta.value.trim();
          if (done) ta.value = r.line;
          say(done
            ? "Строка корректна. Дописал недостающие параметры пула — применится то, что в поле"
            : "Строка корректна — можно сохранять", true);
        }
        else say("Не принято движком: " + (r && r.error ? r.error : "неизвестная ошибка"), false);
      } catch (e) { say("Ошибка проверки: " + errMsg(e), false); }
    });

    card.querySelector('[data-act="save"]').addEventListener("click", async () => {
      // Пустое поле — это либо неудавшееся чтение, либо ничего не введено.
      // И то и другое ушло бы на бекенд пустым телом поверх рабочей строки.
      if (!ta.value.trim()) {
        say("Строка пустая — сохранять нечего. Чтобы отключить свою строку, вернитесь на автоподбор.", false);
        return;
      }
      say("Проверяю и применяю…", true);
      try {
        await apiPostText("/strategy/pool/save?pool=" + encodeURIComponent(pool), ta.value);
      } catch (e) {
        // The line was rejected — nothing was applied and the previous state
        // is untouched, which is exactly what the message must convey.
        say("Не сохранено: " + errMsg(e), false);
        return;
      }
      toast("Стратегия применена, сервис перезапущен — автоподбор для пула выключен");
      loadStrategyPools();
    });
  });
}

async function loadStrategyText(pool, ta, say) {
  try {
    ta.value = await apiGetText("/strategy/pool?pool=" + encodeURIComponent(pool));
  } catch (e) {
    // Молчаливая пустая textarea читается как «строка пропала»: юзер жмёт
    // «Сохранить и применить», и на бекенд уходит пустое тело поверх
    // работающей строки. Поэтому — сказать вслух и не подсовывать пустоту.
    ta.value = "";
    if (say) say("Не удалось прочитать текущую строку: " + errMsg(e) +
                 ". Не сохраняйте, пока она не загрузится — отправится пустая.", false);
  }
}
