import { PANEL_HDR } from "./api.js";
import { $app, API } from "./dom.js";

// MD5 — своей реализацией, потому что в браузере его нет.
//
// Схема входа Keenetic требует ровно MD5(логин:realm:пароль): Web Crypto
// умеет SHA-*, но MD5 из него намеренно исключён как устаревший. Заменить
// алгоритм нельзя — его выбирает роутер, а не мы.
//
// Считать ОБЯЗАТЕЛЬНО здесь, а не на сервере: панель работает по HTTP, и
// отправка пароля на роутер открытым текстом перечеркнула бы весь смысл
// схемы — она существует ровно для того, чтобы пароль не попадал в сеть.
// Реализация классическая (RFC 1321), работает над UTF-8 байтами.
function md5hex(str) {
  const bytes = new TextEncoder().encode(str);
  const S = [7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
             5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
             4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
             6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21];
  const K = new Uint32Array(64);
  for (let i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296);
  const len = bytes.length;
  const withPad = new Uint8Array((((len + 8) >> 6) + 1) << 6);
  withPad.set(bytes);
  withPad[len] = 0x80;
  const bitLen = len * 8;
  const dv = new DataView(withPad.buffer);
  dv.setUint32(withPad.length - 8, bitLen >>> 0, true);
  dv.setUint32(withPad.length - 4, Math.floor(bitLen / 4294967296), true);

  let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  const rotl = (x, c) => (x << c) | (x >>> (32 - c));
  for (let off = 0; off < withPad.length; off += 64) {
    let A = a0, B = b0, C = c0, D = d0;
    for (let i = 0; i < 64; i++) {
      let F, g;
      if (i < 16)      { F = (B & C) | (~B & D);            g = i; }
      else if (i < 32) { F = (D & B) | (~D & C);            g = (5 * i + 1) % 16; }
      else if (i < 48) { F = B ^ C ^ D;                     g = (3 * i + 5) % 16; }
      else             { F = C ^ (B | ~D);                  g = (7 * i) % 16; }
      F = (F + A + K[i] + dv.getUint32(off + g * 4, true)) >>> 0;
      A = D; D = C; C = B;
      B = (B + rotl(F, S[i])) >>> 0;
    }
    a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0;
    c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0;
  }
  const out = new Uint8Array(16);
  new DataView(out.buffer).setUint32(0, a0, true);
  new DataView(out.buffer).setUint32(4, b0, true);
  new DataView(out.buffer).setUint32(8, c0, true);
  new DataView(out.buffer).setUint32(12, d0, true);
  return Array.from(out, (x) => x.toString(16).padStart(2, "0")).join("");
}

// SHA-256 — ТОЖЕ СВОЕЙ РЕАЛИЗАЦИЕЙ, И ЭТО НЕ ПЕРЕСТРАХОВКА.
//
// Здесь стоял crypto.subtle.digest, и на HTTPS через KeenDNS всё работало.
// А по локалке — нет: crypto.subtle доступен ТОЛЬКО в защищённом контексте,
// и на http://192.168.1.1:8088 он попросту undefined. Проверено в браузере
// на самом роутере: isSecureContext=false, crypto.subtle=undefined. То есть
// вход ломался ровно на том пути, который у панели основной, а работал на
// том, который есть не у всех.
//
// Считать всё равно надо на странице: пароль не должен покидать браузер,
// панель работает по HTTP. Поэтому реализация своя (FIPS 180-4), а
// crypto.subtle используется, только если он есть, — он быстрее и проверен.
function sha256hexJS(str) {
  const K = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  let h0=0x6a09e667,h1=0xbb67ae85,h2=0x3c6ef372,h3=0xa54ff53a,
      h4=0x510e527f,h5=0x9b05688c,h6=0x1f83d9ab,h7=0x5be0cd19;
  const bytes = new TextEncoder().encode(str);
  const len = bytes.length;
  const padded = new Uint8Array((((len + 8) >> 6) + 1) << 6);
  padded.set(bytes);
  padded[len] = 0x80;
  const dv = new DataView(padded.buffer);
  // Длина в битах — 64-битное поле, старшие 32 бита пишем честно: строки в
  // 512 МБ у нас не бывает, но нулём его оставлять — молчаливая мина.
  dv.setUint32(padded.length - 8, Math.floor(len / 536870912), false);
  dv.setUint32(padded.length - 4, (len << 3) >>> 0, false);
  const w = new Uint32Array(64);
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4, false);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >>> 3);
      const s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >>> 10);
      w[i] = (w[i-16] + s0 + w[i-7] + s1) >>> 0;
    }
    let a=h0,b=h1,c=h2,d=h3,e=h4,f=h5,g=h6,h=h7;
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + K[i] + w[i]) >>> 0;
      const S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
      const mj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + mj) >>> 0;
      h=g; g=f; f=e; e=(d + t1) >>> 0; d=c; c=b; b=a; a=(t1 + t2) >>> 0;
    }
    h0=(h0+a)>>>0; h1=(h1+b)>>>0; h2=(h2+c)>>>0; h3=(h3+d)>>>0;
    h4=(h4+e)>>>0; h5=(h5+f)>>>0; h6=(h6+g)>>>0; h7=(h7+h)>>>0;
  }
  return [h0,h1,h2,h3,h4,h5,h6,h7].map(x => x.toString(16).padStart(8, "0")).join("");
}

async function sha256hex(str) {
  if (window.crypto && window.crypto.subtle && window.isSecureContext) {
    try {
      const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(str));
      return Array.from(new Uint8Array(buf), (x) => x.toString(16).padStart(2, "0")).join("");
    } catch (e) { /* падаем на свою реализацию ниже */ }
  }
  return sha256hexJS(str);
}

export function showLoginScreen(msg) {
  if (document.getElementById("login-go")) {
    if (msg) {
      const e = document.getElementById("login-error");
      if (e) { e.textContent = msg; e.hidden = false; }
    }
    return;
  }
  document.body.setAttribute("data-page", "login");
  $app.innerHTML = `
    <div class="login-box">
      <h1 class="page-title">Вход в панель</h1>
      <p class="desc">
        Логин и пароль — те же, что у веб-интерфейса роутера. Отдельного
        пароля у панели нет: она спрашивает сам роутер.
      </p>
      <label class="login-label" for="login-user">Логин</label>
      <input type="text" id="login-user" autocomplete="username"
             autocapitalize="none" spellcheck="false" value="admin">
      <label class="login-label" for="login-pass">Пароль</label>
      <input type="password" id="login-pass" autocomplete="current-password">
      <div class="login-error" id="login-error" hidden></div>
      <div class="btn-row">
        <button class="btn btn-primary" id="login-go">Войти</button>
      </div>
      <p class="desc login-hint">
        Забыли пароль или панель не пускает — вход можно снять в меню роутера:
        пункт «Веб-панель», переключатель входа по паролю. Он работает,
        даже когда сюда войти не получается.
      </p>
    </div>
  `;
  const user = document.getElementById("login-user");
  const pass = document.getElementById("login-pass");
  const err  = document.getElementById("login-error");
  const go   = document.getElementById("login-go");

  const submit = async () => {
    err.hidden = true;
    go.disabled = true;
    const label = go.textContent;
    go.textContent = "Проверяю…";
    try {
      // ШАГ 1: берём у роутера realm и одноразовый вызов.
      const c = await fetch(API + "/auth/challenge", {
        method: "POST",
        credentials: "same-origin",
        headers: { ...PANEL_HDR, "Content-Type": "application/x-www-form-urlencoded" },
        body: "",
      });
      const cd = await c.json().catch(() => null);
      if (!c.ok || !cd || !cd.ok) {
        err.textContent = (cd && cd.error) || "не удалось начать вход";
        err.hidden = false;
        go.disabled = false; go.textContent = label;
        return;
      }
      // ШАГ 2: ответ считаем ЗДЕСЬ. Пароль дальше этой строки не уходит —
      // ни в сеть, ни на роутер: панель работает по HTTP, и отправлять его
      // означало бы отдать пароль администратора любому, кто слушает сеть.
      const ha1  = md5hex(user.value.trim() + ":" + cd.realm + ":" + pass.value);
      const resp = await sha256hex(cd.challenge + ha1);
      pass.value = "";
      const r = await fetch(API + "/auth/login", {
        method: "POST",
        credentials: "same-origin",
        headers: { ...PANEL_HDR, "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          login: user.value.trim(), ticket: cd.ticket, response: resp,
        }).toString(),
      });
      const d = await r.json().catch(() => null);
      if (r.ok && d && d.ok) {
        // Перезагружаем страницу целиком: половина экранов уже пыталась
        // загрузиться и получила отказ, и дорисовывать их по одному —
        // верный способ забыть один.
        location.reload();
        return;
      }
      err.textContent = (d && d.error) || "не удалось войти";
      err.hidden = false;
    } catch (e) {
      err.textContent = "панель не отвечает";
      err.hidden = false;
    }
    go.disabled = false;
    go.textContent = label;
    pass.focus();
    pass.select();
  };

  go.addEventListener("click", submit);
  for (const el of [user, pass]) {
    el.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); submit(); } });
  }
  pass.focus();
  if (msg) { err.textContent = msg; err.hidden = false; }
}
