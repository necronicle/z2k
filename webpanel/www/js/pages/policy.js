import { refreshStatus } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { _activeJobs, awaitPanelBack } from "../job.js";

// Toggles that restart nfqws2 under the hood (see actions.sh:toggle_*).
// After toggling we should wait for the service to come back to "active"
// before clearing the indicator so the user sees the restart actually
// completed and didn't silently die. rst-filter (raw iptables) is the
// only one that doesn't bounce the daemon.
// Must mirror what the backend actually does: a toggle whose handler calls
// restart_service_if_running has to be listed here, or the user gets a silent
// blip in the bypass with no indication it happened. Asserted in the suite.
export const TOGGLES_RESTART_SERVICE = { customd: 1, dynamic_ttl: 1, ppe: 1, autohostlist: 1 };

// Автохостлист меняет принцип отбора трафика целиком, и промах движка
// выглядит для юзера как «сайт сломался после обновления». Формулировка
// согласована — правке не подлежит.
export const AUTOHOSTLIST_WARNING =
  "Включая автохостлист вы рискуете что будут попадать левые адреса и что-то перестанет работать. " +
  "Жалобы на прекративший работу сайт после включения автохостлиста не принимаются.";

// Дождаться панели и взять фактическое значение из конфига, а не гадать.
export async function resyncToggle(key, box) {
  const s = await awaitPanelBack();
  if (!s || !s.toggles) return;
  // За время ожидания юзер мог запустить новую задачу — её результат
  // свежее нашего чтения, не затираем.
  if (_activeJobs.size) return;
  const on = s.toggles[key] === "1";
  box.checked = on;
  toast("Связь есть — фактически " + (on ? "включено" : "выключено"));
  refreshStatus();
}
