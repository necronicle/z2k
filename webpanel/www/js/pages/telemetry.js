import { apiGet, apiPost, toastErr } from "../core/api.js";
import { escapeHtml } from "../core/dom.js";
import { STATS_ENDPOINT, toast } from "../core/toast.js";

//
// Телеметрия включена по умолчанию — это решение владельца. Но «включено по
// умолчанию» и «ушло раньше, чем человек успел узнать» — разные вещи.
// Аплоадер молчит, пока Z2K_STATS_ACK=0 (не дольше трёх суток), а эта
// карточка снимает гейт, показав, ЧТО именно уходит и куда.
//
// Согласия не спрашиваем — спрашивать было бы враньём, раз выключить можно
// и после. Показываем состав и даём выключить в один шаг прямо отсюда.
export async function renderStatsNotice() {
  const host = document.getElementById("stats-notice");
  if (!host) return;
  let t;
  try {
    t = await apiGet("/toggles");
  } catch (_) {
    return; // не смогли — не мешаем дашборду
  }
  if (!t || t.stats_ack !== "0") return;

  host.hidden = false;
  host.className = "card";
  host.innerHTML = `
    <h3>z2k отправляет обезличенную статистику</h3>
    <p class="desc">
      Раз в сутки уходит срез ротации: <strong>имя пула</strong>
      (yt_quic, rkn_tcp…), <strong>номер стратегии</strong> и
      <strong>как долго она держится</strong> — округлённо.
      Доменов, посещённых адресов и идентификатора роутера в посылке нет.
    </p>
    <p class="desc">
      Адрес: <code>${escapeHtml(STATS_ENDPOINT)}</code>. Сейчас без TLS —
      содержимое видно вашему провайдеру. Подробности в README.
    </p>
    <div class="row">
      <button class="btn" id="stats-ack-ok">Понятно</button>
      <button class="btn" id="stats-ack-off">Выключить сбор</button>
    </div>
  `;
  const done = () => { host.hidden = true; host.innerHTML = ""; };
  document.getElementById("stats-ack-ok").addEventListener("click", async () => {
    try { await apiPost("/stats/ack"); toast("Понятно, больше не показываем"); }
    catch (e) { toastErr("Ошибка: ", e); }
    done();
  });
  document.getElementById("stats-ack-off").addEventListener("click", async () => {
    try {
      await apiPost("/toggle/stats", { value: "0" });
      await apiPost("/stats/ack");
      toast("Сбор статистики выключен");
    } catch (e) { toastErr("Ошибка: ", e); }
    done();
  });
}
