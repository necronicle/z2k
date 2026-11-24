// Unit and DOM tests for Variant A YouTube Autopilot card in webpanel/www/js/pages/toggles.js.
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const assert = require("node:assert/strict");

// Minimal DOM implementation supporting real innerHTML parsing of toggles.js markup,
// selectors, closest(), hidden/disabled/checked/value/open/dataset/classList/events.
function makeDom() {
  const VOID = new Set(["input", "br", "hr", "img", "meta", "link"]);
  class ClassList {
    constructor(el) { this.el = el; this._set = new Set(); }
    _syncFromAttr(s) {
      this._set = new Set(String(s || "").trim().split(/\s+/).filter(Boolean));
    }
    _pushToAttr() { this.el._attrs.class = Array.from(this._set).join(" "); }
    add(...c) { c.forEach(x => x && this._set.add(x)); this._pushToAttr(); }
    remove(...c) { c.forEach(x => this._set.delete(x)); this._pushToAttr(); }
    toggle(c, f) {
      if (f === undefined) f = !this._set.has(c);
      if (f) this._set.add(c); else this._set.delete(c);
      this._pushToAttr();
      return f;
    }
    contains(c) { return this._set.has(c); }
  }
  class El {
    constructor(tag) {
      this.tagName = String(tag || "div").toUpperCase();
      this._attrs = {};
      this.dataset = {};
      this.classList = new ClassList(this);
      this.children = [];
      this.parentNode = null;
      this.listeners = {};
      this._text = "";
      this._checked = false;
      this._value = "";
      this._disabled = false;
      this._hidden = false;
      this._open = false;
      this._isConnected = true;
    }
    get isConnected() { return this._isConnected; }
    get id() { return this._attrs.id || ""; }
    set id(v) { this._attrs.id = String(v); }
    get className() { return this._attrs.class || ""; }
    set className(v) { this.classList._syncFromAttr(v); this.classList._pushToAttr(); }
    get hidden() { return this._hidden; }
    set hidden(v) { this._hidden = !!v; }
    get disabled() { return this._disabled; }
    set disabled(v) { this._disabled = !!v; }
    get checked() { return this._checked; }
    set checked(v) { this._checked = !!v; }
    get open() { return this._open; }
    set open(v) {
      const prev = this._open;
      this._open = !!v;
      if (prev !== this._open) this.dispatchEvent({ type: "toggle", target: this });
    }
    get value() {
      if (this.tagName === "SELECT" && !this._value && this.children.length) {
        const opt = this.children.find(c => c.tagName === "OPTION");
        return opt ? opt._value : "";
      }
      return this._value;
    }
    set value(v) { this._value = String(v); }
    get title() { return this._attrs.title || ""; }
    set title(v) { this._attrs.title = String(v); }
    setAttribute(k, v) {
      const val = v === undefined ? "" : String(v);
      this._attrs[k] = val;
      if (k === "class") this.classList._syncFromAttr(val);
      else if (k === "hidden") this._hidden = true;
      else if (k === "disabled") this._disabled = true;
      else if (k === "open") this._open = true;
      else if (k === "value") this._value = val;
      else if (k.startsWith("data-")) {
        const camel = k.slice(5).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
        this.dataset[camel] = val;
      }
    }
    removeAttribute(k) {
      delete this._attrs[k];
      if (k === "hidden") this._hidden = false;
      else if (k === "disabled") this._disabled = false;
      else if (k === "open") this._open = false;
    }
    appendChild(ch) {
      ch.parentNode = this;
      this.children.push(ch);
      if (this.tagName === "SELECT" && ch.tagName === "OPTION" && !this._value) {
        this._value = ch._value;
      }
      return ch;
    }
    remove() {
      this._isConnected = false;
      if (this.parentNode) {
        this.parentNode.children = this.parentNode.children.filter(x => x !== this);
        this.parentNode = null;
      }
    }
    get textContent() {
      if (this.children.length === 0) return this._text;
      return this._text + this.children.map(c => c.textContent).join(" ");
    }
    set textContent(v) {
      this.children = [];
      this._text = String(v == null ? "" : v);
    }
    get innerHTML() { return this._rawHtml || ""; }
    set innerHTML(html) {
      this._rawHtml = String(html || "");
      this.children = [];
      this._text = "";
      parseHtmlInto(this, this._rawHtml);
    }
    addEventListener(type, fn) {
      (this.listeners[type] ||= []).push(fn);
    }
    dispatchEvent(ev) {
      const e = ev || { type: "change", target: this };
      e.target ||= this;
      for (const fn of (this.listeners[e.type] || [])) fn(e);
    }
    contains(other) {
      let cur = other;
      while (cur) { if (cur === this) return true; cur = cur.parentNode; }
      return false;
    }
    closest(sel) {
      let cur = this;
      while (cur) {
        if (matchesSelector(cur, sel)) return cur;
        cur = cur.parentNode;
      }
      return null;
    }
    querySelectorAll(sel) {
      const parts = sel.split(",").map(s => s.trim()).filter(Boolean);
      const out = [];
      const walk = (n) => {
        for (const ch of n.children) {
          if (parts.some(p => matchesSelector(ch, p))) out.push(ch);
          walk(ch);
        }
      };
      walk(this);
      return out;
    }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  }

  function matchesAtom(el, atom) {
    if (!el || el.tagName === "#DOC") return false;
    let rest = atom.trim();
    if (rest.startsWith(":scope >")) rest = rest.slice(8).trim();
    const tagMatch = rest.match(/^[a-zA-Z0-9_-]+/);
    if (tagMatch) {
      if (el.tagName !== tagMatch[0].toUpperCase()) return false;
      rest = rest.slice(tagMatch[0].length);
    }
    while (rest.length) {
      if (rest[0] === "#") {
        const m = rest.match(/^#([a-zA-Z0-9_-]+)/);
        if (!m || el.id !== m[1]) return false;
        rest = rest.slice(m[0].length);
      } else if (rest[0] === ".") {
        const m = rest.match(/^\.([a-zA-Z0-9_-]+)/);
        if (!m || !el.classList.contains(m[1])) return false;
        rest = rest.slice(m[0].length);
      } else if (rest[0] === "[") {
        const m = rest.match(/^\[([a-zA-Z0-9_-]+)(?:="([^"]*)")?\]/);
        if (!m) return false;
        if (m[2] !== undefined) {
          const av = m[1] === "type" ? el._attrs.type : el._attrs[m[1]];
          if (av !== m[2]) return false;
        } else if (!(m[1] in el._attrs)) {
          return false;
        }
        rest = rest.slice(m[0].length);
      } else {
        return false;
      }
    }
    return true;
  }

  function matchesSelector(el, sel) {
    const tokens = sel.trim().replace(/\s*>\s*/g, " > ").split(/\s+/);
    let idx = tokens.length - 1;
    let cur = el;
    if (!matchesAtom(cur, tokens[idx])) return false;
    idx--;
    while (idx >= 0) {
      if (tokens[idx] === ">") {
        idx--;
        cur = cur.parentNode;
        if (!cur || !matchesAtom(cur, tokens[idx])) return false;
        idx--;
      } else {
        let p = cur.parentNode;
        while (p && !matchesAtom(p, tokens[idx])) p = p.parentNode;
        if (!p) return false;
        cur = p;
        idx--;
      }
    }
    return true;
  }

  function parseHtmlInto(root, html) {
    const stack = [root];
    const re = /<!--[\s\S]*?-->|<\/([a-zA-Z0-9-]+)>|<([a-zA-Z0-9-]+)([^>]*)>|([^<]+)/g;
    let m;
    while ((m = re.exec(html))) {
      if (m[1]) {
        const closing = m[1].toUpperCase();
        while (stack.length > 1 && stack[stack.length - 1].tagName !== closing) stack.pop();
        if (stack.length > 1) stack.pop();
      } else if (m[2]) {
        const tag = m[2].toLowerCase();
        const el = new El(tag);
        const attrStr = m[3] || "";
        const attrRe = /([a-zA-Z0-9_-]+)(?:=(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g;
        let am;
        while ((am = attrRe.exec(attrStr))) {
          if (!am[1]) continue;
          const v = am[2] !== undefined ? am[2] : (am[3] !== undefined ? am[3] : (am[4] !== undefined ? am[4] : ""));
          el.setAttribute(am[1], v);
        }
        stack[stack.length - 1].appendChild(el);
        if (!VOID.has(tag) && !attrStr.trim().endsWith("/")) stack.push(el);
      } else if (m[4]) {
        const txt = m[4].replace(/\s+/g, " ").trim();
        if (txt) stack[stack.length - 1]._text += (stack[stack.length - 1]._text ? " " : "") + txt;
      }
    }
  }

  const rootDoc = new El("#DOC");
  const appEl = new El("div");
  appEl.id = "app";
  const bodyEl = new El("body");
  bodyEl.appendChild(appEl);
  rootDoc.appendChild(bodyEl);

  return {
    appEl,
    document: {
      body: bodyEl,
      createElement: (t) => new El(t),
      getElementById: (id) => rootDoc.querySelector("#" + id),
      querySelector: (sel) => rootDoc.querySelector(sel),
      querySelectorAll: (sel) => rootDoc.querySelectorAll(sel),
    },
  };
}

function stripEsm(code) {
  return code
    .replace(/^import .* from "[^"]*";\r?\n/gm, "")
    .replace(/^export /gm, "");
}

function loadTogglesContext(handlers) {
  const { appEl, document } = makeDom();
  const root = path.join(__dirname, "..");
  const jobSrc = stripEsm(fs.readFileSync(path.join(root, "webpanel/www/js/job.js"), "utf8"));
  const polSrc = stripEsm(fs.readFileSync(path.join(root, "webpanel/www/js/pages/policy.js"), "utf8"));
  const togSrc = stripEsm(fs.readFileSync(path.join(root, "webpanel/www/js/pages/toggles.js"), "utf8"));

  const toasts = [];
  const postCalls = [];
  const ctx = {
    document,
    $app: appEl,
    _icons: { hourglass: "" },
    escapeHtml: (x) => String(x),
    errHtml: (e) => String(e && e.message ? e.message : e),
    errMsg: (e) => String(e && e.message ? e.message : e),
    isRefusal: () => false,
    _newLoad: () => 1,
    _stale: () => false,
    refreshStatus: () => {},
    toast: (msg, kind) => toasts.push({ msg, kind: kind || "ok" }),
    toastErr: (pfx, e) => toasts.push({ msg: pfx + String(e && e.message ? e.message : e), kind: "err" }),
    confirmModal: async () => true,
    apiGet: async (url) => handlers.get(url),
    apiPost: async (url, body) => {
      postCalls.push({ url, body });
      return handlers.post(url, body);
    },
    openJobModal: handlers.openJobModal,
    setTimeout,
    clearTimeout,
    Date,
    Set,
    Map,
    Number,
    String,
    Array,
    Boolean,
  };
  vm.createContext(ctx);
  // Prevent job.js pollers from touching network in unit test unless openJobModal is overridden.
  vm.runInContext(jobSrc + "\n" + polSrc + "\n" + togSrc +
    "\nthis.renderToggles=renderToggles;this.TOGGLE_DEFS=TOGGLE_DEFS;", ctx);
  if (handlers.openJobModal) ctx.openJobModal = handlers.openJobModal;
  return { ctx, appEl, document, toasts, postCalls };
}

async function runTests() {
  // 1. Variant A structure + live telemetry + XSS safety
  let currentStatus = {
    installed: true,
    running: true,
    service: "active",
    toggles: {
      category_youtube: "1",
      category_rkn: "1",
      category_discord_voice: "1",
      yt_autopilot: "auto",
      gv_preflight: "auto",
      yt_quic_off: "auto",
      quic_off: "auto",
      customd: "0",
      dynamic_ttl: "1",
      auto_update: "1",
      au_hour: "02",
      autohostlist: "0",
    },
    autopilot: {
      policy_present: true,
      gvsub_present: true,
      updated: 1790001234,
      stale: false,
      usable_v4: 2,
      usable_v6: 1,
      baseline_rtt_ms: 28,
      ggc_rtt_ms: 5,
      global_quic_blocked: true,
      preflight_sni: "<img src=x onerror=1>",
      resyn_delay_ms: 110,
      preflight_giveup_ms: 900,
      ggc_stall_guard_ms: 1400,
      safety_fuse_ok: true,
      observed_count: 7,
      ips_total: 8,
      prefixes_total: 3,
      isp_good: 4,
      isp_dead: 1,
      google_good: 2,
      google_bypassable: 1,
      google_unbypassable: 0,
      google_dead: 0,
      quic_ok_count: 3,
      play_count: 1,
    },
    tunnel: { running: false },
  };

  let nextJobOutcome = { exit: 0 };
  const h = loadTogglesContext({
    get: async (url) => {
      if (url === "/status") return currentStatus;
      if (url === "/auth/session-ttl") return { seconds: 86400 };
      if (url === "/policy/status") return { name: "nfqws", exclude: "0", exists: 1 };
      return { ok: true };
    },
    post: async () => ({ ok: true, job: "job-1" }),
    openJobModal: (_title, _id, opts) => {
      opts.onDone(nextJobOutcome);
    },
  });

  await h.ctx.renderToggles();

  // Prominent toggles removed from main toggle cards; only inside #ap-debug as tri-state selects
  for (const key of ["gv_preflight", "yt_quic_off", "quic_off"]) {
    const sel = h.document.getElementById("ap-sel-" + key);
    assert.ok(sel, "missing debug select for " + key);
    assert.equal(sel.value, "auto");
    assert.ok(sel.closest("#ap-debug"), key + " select must live inside #ap-debug");
    const row = sel.closest(".toggle-row");
    assert.equal(row.querySelector("input"), null, key + " must not be a prominent checkbox");
  }
  const apDebug = h.document.getElementById("ap-debug");
  assert.equal(apDebug.open, false, "debug spoiler must be collapsed by default");

  assert.equal(h.document.getElementById("ap-master-switch").checked, true);
  assert.equal(h.document.getElementById("ap-state-badge").textContent, "Автопилот активен");
  assert.ok(h.document.getElementById("ap-caches-val").textContent.includes("2 IPv4 · 1 IPv6"));
  assert.ok(h.document.getElementById("ap-caches-sub").textContent.includes("ISP GGC: 4 раб. / 1 отсеяно"));
  assert.ok(h.document.getElementById("ap-quic-val").textContent.includes("Сеть режет QUIC"));
  assert.ok(h.document.getElementById("ap-rtt-val").textContent.includes("База 28 мс · GGC 5 мс"));
  assert.ok(h.document.getElementById("ap-rtt-sub").textContent.includes("DoH/DoT: 7"));
  assert.ok(h.document.getElementById("ap-fuse-val").textContent.includes("Активен"));
  assert.ok(!h.appEl.innerHTML.includes("<img src=x onerror=1>"), "SNI must be written as textContent, never innerHTML");
  console.log("[PASS] Variant A telemetry, badge, collapsed debug spoiler, XSS-safe SNI");

  // 2. Tri-state select change succeeds and saves new value
  const pfSel = h.document.getElementById("ap-sel-gv_preflight");
  pfSel.value = "off";
  pfSel.dispatchEvent({ type: "change" });
  await new Promise(r => setTimeout(r, 10));
  const lastPost = h.postCalls.pop();
  assert.ok(lastPost);
  assert.equal(lastPost.url, "/toggle/gv-preflight");
  assert.equal(lastPost.body.value, "off");
  assert.equal(pfSel.dataset.saved, "off");

  // 3. Tri-state select rollback on JOB_FAIL
  nextJobOutcome = { exit: 1 };
  pfSel.value = "1";
  pfSel.dispatchEvent({ type: "change" });
  await new Promise(r => setTimeout(r, 10));
  assert.equal(pfSel.value, "off", "failed job must revert select back to saved value");
  assert.equal(pfSel.dataset.saved, "off");

  // 4. Master autopilot switch rollback on network erro
  const apBox = h.document.getElementById("ap-master-switch");
  const failingH = loadTogglesContext({
    get: async (url) => {
      if (url === "/status") return currentStatus;
      if (url === "/auth/session-ttl") return { seconds: 86400 };
      if (url === "/policy/status") return { name: "", exclude: "0", exists: 0 };
      return { ok: true };
    },
    post: async () => { throw new Error("network down"); },
    openJobModal: () => {},
  });
  await failingH.ctx.renderToggles();
  const apBox2 = failingH.document.getElementById("ap-master-switch");
  apBox2.checked = false;
  apBox2.dispatchEvent({ type: "change" });
  await new Promise(r => setTimeout(r, 10));
  assert.equal(apBox2.checked, true, "failed POST must revert master switch");
  assert.equal(apBox.checked, true);
  console.log("[PASS] Tri-state select save & JOB_FAIL / network error rollbacks");

  // 5. Search opens debug spoiler for QUIC/preflight and restores closed on clea
  const search = h.document.getElementById("toggles-search");
  search.value = "quic";
  search.dispatchEvent({ type: "input" });
  assert.equal(apDebug.open, true, "search hit inside debug spoiler opens it");
  assert.equal(pfSel.closest(".toggle-row").hidden, true, "non-matching row hidden during search");
  assert.equal(h.document.getElementById("ap-sel-yt_quic_off").closest(".toggle-row").hidden, false);
  search.value = "";
  search.dispatchEvent({ type: "input" });
  assert.equal(apDebug.open, false, "clearing search collapses debug spoiler again");
  console.log("[PASS] Search auto-expands debug spoiler and restores closed state");

  // 6. category_youtube=0 disables youtube-scoped selects and sets unavailable badge; yt_autopilot=0 -> Ручной режим
  const manualStatus = JSON.parse(JSON.stringify(currentStatus));
  manualStatus.toggles.yt_autopilot = "0";
  manualStatus.toggles.gv_preflight = "1";
  manualStatus.toggles.yt_quic_off = "off";
  manualStatus.toggles.quic_off = "off";
  manualStatus.autopilot = { policy_present: false, gvsub_present: false, gvsub_enabled: true };
  const hManual = loadTogglesContext({
    get: async (u) => u === "/status" ? manualStatus : (u === "/auth/session-ttl" ? { seconds: 86400 } : {}),
    post: async () => ({ ok: true, job: "j2" }),
    openJobModal: (_t, _j, opts) => opts.onDone({ exit: 0 }),
  });
  await hManual.ctx.renderToggles();
  assert.equal(hManual.document.getElementById("ap-state-badge").textContent, "Ручной режим");
  assert.equal(hManual.document.getElementById("ap-master-switch").checked, false);
  assert.equal(hManual.document.getElementById("ap-caches-val").textContent, "Нет замеров");
  assert.equal(hManual.document.getElementById("ap-fuse-val").textContent, "Ожидание (fail-open)");
  assert.equal(hManual.document.getElementById("ap-manual-note").hidden, false);
  for (const key of ["gv_preflight", "yt_quic_off", "quic_off"]) {
    const sel = hManual.document.getElementById("ap-sel-" + key);
    assert.equal(sel.querySelector('option[value="auto"]').disabled, true, key + " auto option must be disabled in manual mode");
  }

  // 7. gvsub_enabled=false while autopilot active shows honest warning badge
  const noGvsubStatus = JSON.parse(JSON.stringify(currentStatus));
  noGvsubStatus.autopilot = { policy_present: false, gvsub_present: false, gvsub_enabled: false };
  const hNoGvsub = loadTogglesContext({
    get: async (u) => u === "/status" ? noGvsubStatus : (u === "/auth/session-ttl" ? { seconds: 86400 } : {}),
    post: async () => ({ ok: true, job: "j2b" }),
    openJobModal: (_t, _j, opts) => opts.onDone({ exit: 0 }),
  });
  await hNoGvsub.ctx.renderToggles();
  assert.equal(hNoGvsub.document.getElementById("ap-state-badge").textContent, "Без замеров: gvsub выключен");
  assert.ok(hNoGvsub.document.getElementById("ap-caches-sub").textContent.includes("Z2K_GV_SERVER_REPLY2=0"));

  // 8. Immediate badge sync when toggling yt_autopilot or category_youtube, and unresolved outcome recovery
  const hImmediate = loadTogglesContext({
    get: async (u) => u === "/status" ? currentStatus : (u === "/auth/session-ttl" ? { seconds: 86400 } : {}),
    post: async () => ({ ok: true, job: "j3" }),
    openJobModal: (_t, _j, opts) => opts.onDone({ exit: 0 }),
  });
  await hImmediate.ctx.renderToggles();
  const immMaster = hImmediate.document.getElementById("ap-master-switch");
  immMaster.checked = false;
  immMaster.dispatchEvent({ type: "change" });
  await new Promise(r => setTimeout(r, 10));
  // Immediately after onDone (before 500ms timeout) badge and manual-mode controls sync
  assert.equal(hImmediate.document.getElementById("ap-state-badge").textContent, "Ручной режим");
  assert.equal(hImmediate.document.getElementById("ap-manual-note").hidden, false);

  const ytBoxImm = hImmediate.document.querySelector('[data-key="category_youtube"] input');
  ytBoxImm.checked = false;
  ytBoxImm.dispatchEvent({ type: "change" });
  await new Promise(r => setTimeout(r, 10));
  assert.equal(hImmediate.document.getElementById("ap-state-badge").textContent, "Недоступно: обход YouTube выключен");

  // Unresolved outcome in overrideSelectChange recovers status & unlocks select
  let afterUnres = false;
  const hUnres = loadTogglesContext({
    get: async (u) => {
      if (u === "/status") {
        const st = JSON.parse(JSON.stringify(currentStatus));
        if (afterUnres) {
          st.toggles.quic_off = "1";
          st.autopilot.usable_v4 = 9;
        }
        return st;
      }
      if (u === "/auth/session-ttl") return { seconds: 86400 };
      return { ok: true };
    },
    post: async () => { afterUnres = true; return { ok: true, job: "j-unres" }; },
    openJobModal: (_t, _j, opts) => opts.onDone({ outcome: "gone", status: "unknown" }),
  });
  await hUnres.ctx.renderToggles();
  const qSel = hUnres.document.getElementById("ap-sel-quic_off");
  qSel.value = "off";
  qSel.dispatchEvent({ type: "change" });
  await new Promise(r => setTimeout(r, 20));
  assert.equal(qSel.disabled, false, "override select must unlock after jobUnresolved awaitPanelBack");
  assert.equal(qSel.value, "1", "override select must apply recovered /status");
  assert.equal(qSel.dataset.saved, "1");
  assert.ok(hUnres.document.getElementById("ap-caches-val").textContent.includes("9 IPv4"));

  const ytOffStatus = JSON.parse(JSON.stringify(currentStatus));
  ytOffStatus.toggles.category_youtube = "0";
  const hYtOff = loadTogglesContext({
    get: async (u) => u === "/status" ? ytOffStatus : (u === "/auth/session-ttl" ? { seconds: 86400 } : {}),
    post: async () => ({ ok: true, job: "j4" }),
    openJobModal: (_t, _j, opts) => opts.onDone({ exit: 0 }),
  });
  await hYtOff.ctx.renderToggles();
  assert.equal(hYtOff.document.getElementById("ap-state-badge").textContent, "Недоступно: обход YouTube выключен");
  assert.equal(hYtOff.document.getElementById("ap-yt-off-note").hidden, false);
  assert.equal(hYtOff.document.getElementById("ap-sel-gv_preflight").disabled, true);
  assert.equal(hYtOff.document.getElementById("ap-sel-yt_quic_off").disabled, true);
  assert.equal(hYtOff.document.getElementById("ap-sel-quic_off").disabled, false);
  console.log("[PASS] Manual mode, empty policy, and category_youtube=0 lock handling");
}

runTests().catch((err) => {
  console.error("[FAIL] test_autopilot_panel:", err);
  process.exit(1);
});
