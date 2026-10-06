import { $toastStack } from "./dom.js";

// Skill rule toast-dismiss: 3-5s. New toasts push old ones up; if more
// than MAX_TOASTS are visible the oldest is evicted immediately. Each
// toast has its own dismiss timer so a fast burst doesn't double-fire.
const MAX_TOASTS = 3;

const TOAST_TTL_MS = 3500;

export function toast(msg, kind = "ok") {
  if (!$toastStack) return;
  // Пустой текст — это осознанное молчание, а не недосмотр вызывающего.
  // Так гасятся временные ответы во время переустановки: дерево переезжает,
  // каждый фоновый загрузчик об него спотыкается, и без этого человек
  // получает очередь красных плашек про то, что ничего не сломалось.
  // Единственная точка, где такой текст рождается пустым, — httpError.
  if (!msg || !String(msg).trim()) return;
  const el = document.createElement("div");
  el.className = "toast-item toast-" + kind;
  el.setAttribute("role", "status");
  el.textContent = msg;
  $toastStack.appendChild(el);
  // FIFO eviction: keep at most MAX_TOASTS visible.
  while ($toastStack.children.length > MAX_TOASTS) {
    $toastStack.firstElementChild.remove();
  }
  // Fade-in next frame so transition fires.
  requestAnimationFrame(() => el.classList.add("is-visible"));
  setTimeout(() => {
    el.classList.remove("is-visible");
    el.classList.add("is-leaving");
    setTimeout(() => el.remove(), 250);
  }, TOAST_TTL_MS);
}
