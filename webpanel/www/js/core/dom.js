"use strict";

export const API = "/cgi-bin/api";

export const $app = document.getElementById("app");

export const $toastStack = document.getElementById("toast-stack");

export const $nav = document.getElementById("nav");

export function humanAgo(tsSec) {
  const age = Math.max(0, Math.floor(Date.now() / 1000) - tsSec);
  if (age < 60) return age + " с назад";
  if (age < 3600) return Math.floor(age / 60) + " мин назад";
  if (age < 86400) return Math.floor(age / 3600) + " ч назад";
  return Math.floor(age / 86400) + " дн назад";
}

export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

// Inline SVG icons — single source of truth.
// Skill compliance (Common Rules > Icons & Visual Elements):
//   - Consistent Icon Sizing: all stroke icons = 16×16 (one size token).
//     Filled glyphs (star, heart) also 16×16 для visual parity.
//   - Stroke Consistency: stroke-width=2 везде (skill: "1.5px or 2px").
//   - Style: outline/stroke for UI icons, fill only for award badges
//     (star/heart on Credits) — clear semantic separation.
//   - SVG vector, не emoji (no-emoji-icons rule).
// class="icon" + .icon-sm modifier для 12px inline-в-pill контекстов.
export const _icons = {
  close:        '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>',
  // Lucide pencil / download (MIT) — WARP list row actions.
  edit:         '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg>',
  download:     '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>',
  chevronDown:  '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 9 12 15 18 9"/></svg>',
  arrowUp:      '<svg class="icon icon-sm" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 15 12 9 18 15"/></svg>',
  arrowDown:    '<svg class="icon icon-sm" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 9 12 15 18 9"/></svg>',
  star:         '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26"/></svg>',
  heart:        '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
  statusGood:   '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>',
  statusWarn:   '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>',
  statusBad:    '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>',
  hourglass:    '<svg class="icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 22h14M5 2h14M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22M17 2v4.172a2 2 0 0 1-.586 1.414L12 12 7.586 7.586A2 2 0 0 1 7 6.172V2"/></svg>',
  // Lucide lock-keyhole / lock-keyhole-open (MIT, no attribution). Closed = frozen,
  // open = auto-rotating. Drawn at 17px to read a touch larger than the row text.
  lockClosed:   '<svg class="icon" viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="10" width="18" height="12" rx="2"/><path d="M7 10V7a5 5 0 0 1 10 0v3"/><circle cx="12" cy="16" r="1"/></svg>',
  lockOpen:     '<svg class="icon" viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="10" width="18" height="12" rx="2"/><path d="M7 10V7a5 5 0 0 1 9.33-2.5"/><circle cx="12" cy="16" r="1"/></svg>',
};

// Status icon picker for the dashboard cells. "" kind = no icon (neutral).
export function statusIcon(kind) {
  if (kind === "good") return _icons.statusGood;
  if (kind === "warn") return _icons.statusWarn;
  if (kind === "bad")  return _icons.statusBad;
  return "";
}

// Skeleton placeholders for >300ms fetches (Skill rule: loading-states).
// skeletonLines(n) — variable-width pulsing bars; skeletonBlocks(n) — taller
// cards for grid/table loads. Both reserve space so the page doesn't jump
// when real content arrives (Core Web Vitals: CLS).
export function skeletonLines(n = 4) {
  const widths = ["68%", "92%", "54%", "80%", "44%", "76%"];
  let out = "";
  for (let i = 0; i < n; i++) {
    out += `<div class="skel-line" style="width:${widths[i % widths.length]}"></div>`;
  }
  return out;
}

export function skeletonBlocks(n = 4) {
  let out = "";
  for (let i = 0; i < n; i++) out += `<div class="skel-block"></div>`;
  return out;
}
