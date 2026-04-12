// z2k-tunnel: Cloudflare Worker relay for multiplexed TCP-over-WebSocket tunnel.
// Accepts mux protocol frames from tunnel client and relays to Telegram DC IPs.
//
// Deploy: npx wrangler deploy
// Env var: TUNNEL_SECRET (shared secret for HMAC auth)

import { connect } from "cloudflare:sockets";

// Mux message types
const MUX_AUTH         = 0x00;
const MUX_CONNECT      = 0x01;
const MUX_DATA         = 0x02;
const MUX_CLOSE        = 0x03;
const MUX_CONNECT_OK   = 0x04;
const MUX_CONNECT_FAIL = 0x05;

// Address types
const ADDR_IPV4 = 1;
const ADDR_IPV6 = 4;

// Telegram DC IP allowlist (from AS62041, AS59930)
const TELEGRAM_CIDRS = [
  "149.154.160.0/20",
  "91.108.4.0/22",
  "91.108.8.0/22",
  "91.108.12.0/22",
  "91.108.16.0/22",
  "91.108.20.0/22",
  "91.108.56.0/22",
  "91.105.192.0/23",
  "95.161.64.0/20",
  "185.76.151.0/24",
].map(cidr => {
  const [addr, bits] = cidr.split("/");
  const parts = addr.split(".").map(Number);
  const ip = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  const mask = ~0 << (32 - parseInt(bits));
  return { network: ip & mask, mask };
});

const TELEGRAM_V6_PREFIXES = [
  "2001:b28:f23d:",
  "2001:b28:f23f:",
  "2001:67c:4e8:",
];

function isTelegramIP(address) {
  const v4parts = address.split(".");
  if (v4parts.length === 4) {
    const nums = v4parts.map(Number);
    if (nums.some(n => isNaN(n) || n < 0 || n > 255)) return false;
    const ip = (nums[0] << 24) | (nums[1] << 16) | (nums[2] << 8) | nums[3];
    return TELEGRAM_CIDRS.some(c => (ip & c.mask) === c.network);
  }
  const lower = address.toLowerCase();
  return TELEGRAM_V6_PREFIXES.some(p => lower.startsWith(p));
}

function encodeMuxFrame(streamId, msgType, payload) {
  const plen = payload ? payload.byteLength : 0;
  const buf = new Uint8Array(3 + plen);
  buf[0] = (streamId >> 8) & 0xff;
  buf[1] = streamId & 0xff;
  buf[2] = msgType;
  if (plen > 0) {
    buf.set(new Uint8Array(payload), 3);
  }
  return buf.buffer;
}

function decodeMuxFrame(buffer) {
  if (buffer.byteLength < 3) {
    throw new Error(`mux frame too short: ${buffer.byteLength}`);
  }
  const view = new DataView(buffer);
  return {
    streamId: view.getUint16(0, false),
    msgType: view.getUint8(2),
    payload: buffer.slice(3),
  };
}

function parseConnectPayload(buffer) {
  const view = new DataView(buffer);
  const addrType = view.getUint8(0);
  if (addrType === ADDR_IPV4) {
    if (buffer.byteLength < 7) throw new Error("IPv4 CONNECT too short");
    const a = view.getUint8(1), b = view.getUint8(2), c = view.getUint8(3), d = view.getUint8(4);
    return { address: `${a}.${b}.${c}.${d}`, port: view.getUint16(5, false) };
  }
  if (addrType === ADDR_IPV6) {
    if (buffer.byteLength < 19) throw new Error("IPv6 CONNECT too short");
    const parts = [];
    for (let i = 0; i < 8; i++) parts.push(view.getUint16(1 + i * 2, false).toString(16));
    return { address: parts.join(":"), port: view.getUint16(17, false) };
  }
  throw new Error(`unknown addr type: ${addrType}`);
}

async function computeAuthHMAC(secret) {
  const enc = new TextEncoder();
  const keyData = enc.encode(secret);
  const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, keyData);
  return new Uint8Array(sig);
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a[i] ^ b[i];
  return r === 0;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/ws") {
      return new Response("z2k-tunnel relay", { status: 200 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    const secret = env.TUNNEL_SECRET;
    if (!secret || secret === "CHANGE_ME_TO_RANDOM_SECRET") {
      console.error("TUNNEL_SECRET not configured");
      return new Response("Server misconfigured", { status: 500 });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();

    const sessionId = Math.random().toString(36).slice(2, 8);
    const clientIP = request.headers.get("CF-Connecting-IP") || "unknown";
    const sessionStart = Date.now();
    console.log(`[${sessionId}] WS accepted from ${clientIP}`);

    // Per-stream state: { socket, writer, closed }
    const streams = new Map();
    let authenticated = false;
    let totalConnects = 0;
    let totalMessages = 0;

    // Direct send — no Promise chaining (avoids microtask overhead per frame).
    // server.send() is synchronous in CF Workers; on WS teardown it throws
    // and we swallow since the close handler will clean up streams.
    function sendFrame(streamId, msgType, payload) {
      try {
        server.send(encodeMuxFrame(streamId, msgType, payload));
      } catch (_) {}
    }

    const expectedHMAC = await computeAuthHMAC(secret);

    function closeStream(streamId) {
      const s = streams.get(streamId);
      if (!s || s.closed) return;
      s.closed = true;
      streams.delete(streamId);
      try { s.writer.close(); } catch (_) {}
      try { s.socket.close(); } catch (_) {}
    }

    async function handleConnect(streamId, payload) {
      let target;
      try {
        target = parseConnectPayload(payload);
      } catch (e) {
        sendFrame(streamId, MUX_CONNECT_FAIL, null);
        return;
      }

      if (!isTelegramIP(target.address)) {
        console.warn(`[${sessionId}] stream ${streamId} blocked non-Telegram target ${target.address}`);
        sendFrame(streamId, MUX_CONNECT_FAIL, null);
        return;
      }

      totalConnects++;
      const t0 = Date.now();

      let socket;
      try {
        socket = connect(
          { hostname: target.address, port: target.port },
          { allowHalfOpen: false }
        );
      } catch (e) {
        console.error(`[${sessionId}] stream ${streamId} connect() threw: ${e.message}`);
        sendFrame(streamId, MUX_CONNECT_FAIL, null);
        return;
      }

      // Wait for TCP handshake; confirms reachability before we tell the client OK.
      try {
        await socket.opened;
      } catch (e) {
        console.error(`[${sessionId}] stream ${streamId} opened rejected: ${e.message || e}`);
        sendFrame(streamId, MUX_CONNECT_FAIL, null);
        try { socket.close(); } catch (_) {}
        return;
      }

      const writer = socket.writable.getWriter();
      const state = { socket, writer, closed: false };
      streams.set(streamId, state);
      sendFrame(streamId, MUX_CONNECT_OK, null);

      // TCP → WS pump. Direct synchronous server.send() per chunk — minimum
      // CPU overhead to keep us under the Worker CPU-time limit.
      let bytesIn = 0;
      let reads = 0;
      let closeReason = "eof";
      try {
        const reader = socket.readable.getReader();
        while (!state.closed) {
          const { done, value } = await reader.read();
          if (done) break;
          if (value && value.byteLength > 0) {
            bytesIn += value.byteLength;
            reads++;
            try {
              server.send(encodeMuxFrame(streamId, MUX_DATA, value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)));
            } catch (_) {
              closeReason = "ws_send_err";
              break;
            }
          }
        }
      } catch (e) {
        closeReason = `read_err: ${e.message || e}`;
      }

      const dur = Date.now() - t0;
      // Only log long-lived or erroring streams to save CPU on log serialization.
      if (dur > 5000 || closeReason !== "eof") {
        console.log(`[${sessionId}] stream ${streamId} CLOSE reason=${closeReason} bytesIn=${bytesIn} reads=${reads} dur=${dur}ms`);
      }

      if (!state.closed) {
        state.closed = true;
        streams.delete(streamId);
        sendFrame(streamId, MUX_CLOSE, null);
        try { writer.close(); } catch (_) {}
        try { socket.close(); } catch (_) {}
      }
    }

    server.addEventListener("message", async (event) => {
      totalMessages++;
      let data;
      if (event.data instanceof ArrayBuffer) {
        data = event.data;
      } else if (event.data instanceof Blob) {
        data = await event.data.arrayBuffer();
      } else {
        return;
      }

      let frame;
      try {
        frame = decodeMuxFrame(data);
      } catch (e) {
        console.error(`[${sessionId}] bad mux frame #${totalMessages}: ${e.message}`);
        return;
      }

      if (!authenticated) {
        if (frame.streamId !== 0 || frame.msgType !== MUX_AUTH) {
          console.error(`[${sessionId}] first message not auth`);
          try { server.close(4001, "auth required"); } catch (_) {}
          return;
        }
        const got = new Uint8Array(frame.payload);
        if (got.length !== 32 || !timingSafeEqual(got, expectedHMAC)) {
          console.error(`[${sessionId}] auth failed`);
          try { server.close(4002, "auth failed"); } catch (_) {}
          return;
        }
        authenticated = true;
        console.log(`[${sessionId}] authenticated`);
        return;
      }

      switch (frame.msgType) {
        case MUX_CONNECT:
          // Fire-and-forget: handleConnect awaits internally.
          handleConnect(frame.streamId, frame.payload).catch(e => {
            console.error(`[${sessionId}] stream ${frame.streamId} handleConnect unhandled: ${e.message || e}`);
            closeStream(frame.streamId);
          });
          break;

        case MUX_DATA: {
          const s = streams.get(frame.streamId);
          if (!s || s.closed) {
            // Silent drop — client closed or stream unknown (in-flight race is ok).
            return;
          }
          // Fire-and-forget TCP write; on error, close the stream asynchronously.
          // Awaiting here would suspend/resume the message handler per packet,
          // which costs too much CPU under heavy telegram load.
          s.writer.write(new Uint8Array(frame.payload)).catch((e) => {
            if (s.closed) return;
            s.closed = true;
            streams.delete(frame.streamId);
            sendFrame(frame.streamId, MUX_CLOSE, null);
            try { s.writer.close(); } catch (_) {}
            try { s.socket.close(); } catch (_) {}
          });
          break;
        }

        case MUX_CLOSE:
          closeStream(frame.streamId);
          break;

        default:
          console.warn(`[${sessionId}] unknown msg type 0x${frame.msgType.toString(16)} stream=${frame.streamId}`);
      }
    });

    server.addEventListener("close", (event) => {
      const dur = Date.now() - sessionStart;
      console.log(`[${sessionId}] WS closed code=${event.code} reason="${event.reason}" dur=${dur}ms active=${streams.size} totalConnects=${totalConnects} totalMessages=${totalMessages}`);
      for (const [id] of streams) closeStream(id);
    });

    server.addEventListener("error", (e) => {
      console.error(`[${sessionId}] WS error: ${e.message || e} active=${streams.size}`);
      for (const [id] of streams) closeStream(id);
    });

    return new Response(null, { status: 101, webSocket: client });
  },
};
