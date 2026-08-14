import { apiPost, toastErr } from "../core/api.js";
import { $app, skeletonBlocks } from "../core/dom.js";
import { refreshStatus } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { JOB_FAIL, _updateGlobalUILock, awaitPanelBack, confirmTypedModal, jobOutcome, jobUnresolved, openJobModal, unresolvedMsg } from "../job.js";
import { renderStatsNotice } from "./telemetry.js";
import { refreshUpdateBanner } from "./update.js";

export async function renderDashboard() {
  $app.innerHTML = `
    <div id="update-banner" hidden></div>
    <div id="stats-notice" hidden></div>
    <h1 class="page-title">Дашборд</h1>
    <div class="card" id="status-card">
      <h3>Состояние</h3>
      <div class="status-grid" id="status-grid">${skeletonBlocks(7)}</div>
    </div>
    <div class="card">
      <h3>Управление сервисом</h3>
      <p class="desc">Запуск, остановка и перезапуск nfqws2.</p>
      <div class="btn-row">
        <button class="btn btn-primary" data-svc="start" data-target="active">Запустить</button>
        <button class="btn" data-svc="restart" data-target="active">Перезапустить</button>
        <button class="btn btn-danger" data-svc="stop" data-target="stopped">Остановить</button>
      </div>
    </div>
    <!-- ОТДЕЛЬНАЯ КАРТОЧКА, А НЕ ЧЕТВЁРТАЯ КНОПКА В РЯДУ ВЫШЕ.
         «Остановить» обратимо и делается каждый день; удаление необратимо и
         делается один раз. В одном ряду они получили бы одинаковый вес и
         отличались бы только подписью — так и промахиваются. -->
    <div class="card card-danger" id="uninstall-card">
      <h3>Удаление z2k</h3>
      <p class="desc">
        Снимает z2k с роутера полностью: сервис, правила обхода, настройки,
        подобранные стратегии и саму эту панель. Отмены нет — вернуть можно
        только установкой заново, с нуля.
      </p>
      <div class="btn-row">
        <button class="btn btn-danger" id="uninstall-btn">Удалить z2k</button>
      </div>
    </div>
  `;

  // querySelectorAll().forEach, а не querySelector().addEventListener — тем же
  // приёмом, что и обработчик [data-svc] выше. Пустая выборка просто ничего не
  // делает, а обращение к .addEventListener у null роняет весь рендер
  // страницы: дашборд собирается одной строкой innerHTML, и любой сторонний
  // рендер этой же разметки (тестовый харнесс, будущая подстраница) уронил бы
  // не кнопку, а экран целиком.
  $app.querySelectorAll("#uninstall-btn").forEach(btn => btn.addEventListener("click", async () => {
    const ok = await confirmTypedModal(
      "Удалить z2k с роутера",
      [
        "Будут удалены: служба обхода и её автозапуск, все правила iptables, " +
          "настройки, списки доменов и подобранные для них стратегии.",
        "Вместе с ними исчезнет и эта панель — страница перестанет отвечать " +
          "примерно на середине, и это нормальный конец, а не сбой.",
        "Интернет продолжит работать, но уже без обхода блокировок.",
      ],
      "УДАЛИТЬ",
      "Удалить z2k"
    );
    if (!ok) return;
    let resp;
    try {
      resp = await apiPost("/uninstall", { confirm: "УДАЛИТЬ" });
    } catch (e) {
      toastErr("Не удалось запустить удаление: ", e);
      return;
    }
    openJobModal("Удаление z2k", resp.job, {
      tolerateOutage: true,
      // Панель входит в удаляемое и обратно не поднимется. Без этого флага
      // опрос честно ждал бы её возвращения десять минут и всё это время
      // писал «ждём…» — про сервер, которого больше нет.
      expectGone: true,
    });
  }));

  $app.querySelectorAll("[data-svc]").forEach(btn => {
    btn.addEventListener("click", async () => {
      if (btn.disabled) return;
      const action = btn.dataset.svc;
      const titleByAction = { start: "Запуск сервиса", stop: "Остановка сервиса", restart: "Перезапуск сервиса" };
      const title = titleByAction[action] || ("Действие: " + action);
      // Глобальный лок включается только когда придёт id задачи, а до тех
      // пор кнопка кликабельна: второй клик по «Перезапустить» запускал
      // второй конкурентный S99zapret2 restart.
      btn.disabled = true;
      let resp;
      try {
        resp = await apiPost("/service/" + action);
      } catch (e) {
        btn.disabled = false;
        toastErr("Ошибка запуска: ", e);
        return;
      }
      // Кнопку возвращаем в исходное состояние ДО openJobModal: лок
      // запоминает текущее disabled как «правильное» и после задачи вернул
      // бы её навсегда выключенной.
      btn.disabled = false;
      // Backend теперь async — возвращает {ok, job:<id>}. Открываем
      // модалку с live-логом точно как при auto-update apply. После
      // завершения refreshStatus подтянет grid вверху.
      openJobModal(title, resp.job, {
        // Старт/стоп/рестарт бьют по тому же iptables, через который открыта
        // панель — короткий обрыв здесь штатный, а не отказ команды.
        tolerateOutage: true,
        onDone: (d) => {
          const outcome = jobOutcome(d);
          if (outcome === JOB_FAIL) {
            toast("Команда завершилась с кодом " + d.exit, "bad");
          } else {
            const m = unresolvedMsg(outcome);
            if (m) toast(m, "bad");
          }
          if (jobUnresolved(outcome)) awaitPanelBack().then(() => refreshStatus());
          else setTimeout(refreshStatus, 500);
        },
      });
    });
  });

  refreshStatus();
  refreshUpdateBanner();
  renderStatsNotice();
  _updateGlobalUILock();
}
