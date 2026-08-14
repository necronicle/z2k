import { toast } from "./toast.js";

// navigator.clipboard exists ONLY in a secure context (HTTPS or
// localhost). The webpanel is served over plain HTTP on a LAN IP
// (http://192.168.x.x:<port>), which is NOT a secure context, so
// navigator.clipboard is undefined in EVERY modern browser — not a
// "old browser" issue. Fall back to the legacy execCommand("copy")
// path, which works on non-secure origins, via a temporary textarea.
export function copyToClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text)
      .then(() => toast("Скопировано"))
      .catch(() => legacyCopy(text));
  } else {
    legacyCopy(text);
  }
}

function legacyCopy(text) {
  let ok = false;
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    // Keep it off-screen but selectable; readonly avoids the mobile
    // keyboard popping up. position:fixed avoids a scroll jump.
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "0";
    ta.style.left = "0";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    ta.setSelectionRange(0, text.length); // iOS needs the explicit range
    ok = document.execCommand("copy");
    document.body.removeChild(ta);
  } catch (e) {
    ok = false;
  }
  toast(ok ? "Скопировано" : "Не удалось скопировать", ok ? "ok" : "bad");
}
