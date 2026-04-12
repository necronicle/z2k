// z2k-tunnel: Cloudflare Worker relay for multiplexed TCP-over-WebSocket tunnel.
// Accepts mux protocol frames from tunnel client and relays to Telegram DC IPs.
//
// Deploy: npx wrangler deploy
// Env var: TUNNEL_SECRET (shared secret for HMAC auth)

import { connect } from "cloudflare:sockets";

// Mux message types
const MUX_CONNECT      = 0x01;
const MUX_DATA         = 0x02;
const MUX_CLOSE        = 0x03;
const MUX_CONNECT_OK   = 0x04;
const MUX_CONNECT_FAIL = 0x05;

// Address types
const ADDR_IPV4 = 1;
const ADDR_IPV6 = 4;

/**
 * Encode a mux frame: [2 bytes stream_id BE][1 byte msg_type][payload]
 */
function encodeMuxFrame(streamId, msgType, payload) {
  const header = new Uint8Array(3);
  header[0] = (streamId >> 8) & 0xff;
  header[1] = streamId & 0xff;
  header[2] = msgType;
  if (!payload || payload.byteLength === 0) {
    return header.buffer;
  }
  const frame = new Uint8Array(3 + payload.byteLength);
  frame.set(header);
  frame.set(new Uint8Array(payload), 3);
  return frame.buffer;
}

/**
 * Decode a mux frame from an ArrayBuffer.
 */
function decodeMuxFrame(buffer) {
  const view = new DataView(buffer);
  if (buffer.byteLength < 3) {
    throw new Error(`mux frame too short: ${buffer.byteLength}`);
  }
  return {
    streamId: view.getUint16(0, false), // big-endian
    msgType: view.getUint8(2),
    payload: buffer.slice(3),
  };
}

/**
 * Parse CONNECT payload: [addr_type][addr][port BE]
 */
function parseConnectPayload(buffer) {
  const view = new DataView(buffer);
  const addrType = view.getUint8(0);

  if (addrType === ADDR_IPV4) {
    if (buffer.byteLength < 7) throw new Error("IPv4 CONNECT too short");
    const a = view.getUint8(1);
    const b = view.getUint8(2);
    const c = view.getUint8(3);
    const d = view.getUint8(4);
    const port = view.getUint16(5, false);
    return { address: `${a}.${b}.${c}.${d}`, port };
  }

  if (addrType === ADDR_IPV6) {
    if (buffer.byteLength < 19) throw new Error("IPv6 CONNECT too short");
    const parts = [];
    for (let i = 0; i < 8; i++) {
      parts.push(view.getUint16(1 + i * 2, false).toString(16));
    }
    const port = view.getUint16(17, false);
    return { address: parts.join(":"), port };
  }

  throw new Error(`unknown addr type: ${addrType}`);
}

/**
 * Compute HMAC-SHA256 of secret keyed by itself.
 */
async function computeAuthHMAC(secret) {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(secret);
  const key = await crypto.subtle.importKey(
    "raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, keyData);
  return new Uint8Array(sig);
}

/**
 * Compare two Uint8Arrays in constant time.
 */
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result === 0;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Only handle /ws path
    if (url.pathname !== "/ws") {
      return new Response("z2k-tunnel relay", { status: 200 });
    }

    // Must be WebSocket upgrade
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

    // Track TCP streams: streamId → { socket, writer }
    const streams = new Map();
    const MAX_STREAMS = 100; // prevent memory exhaustion
    let authenticated = false;

    // Pre-compute expected auth HMAC
    const expectedHMAC = await computeAuthHMAC(secret);

    /**
     * Send a mux frame to the client WS.
     */
    function sendFrame(streamId, msgType, payload) {
      try {
        const frame = encodeMuxFrame(streamId, msgType, payload);
        server.send(frame);
      } catch (e) {
        console.error(`sendFrame error stream=${streamId}: ${e.message}`);
      }
    }

    /**
     * Handle a CONNECT request: open TCP to target and start reading.
     */
    async function handleConnect(streamId, payload) {
      let target;
      try {
        target = parseConnectPayload(payload);
      } catch (e) {
        console.error(`stream ${streamId} bad CONNECT: ${e.message}`);
        sendFrame(streamId, MUX_CONNECT_FAIL, null);
        return;
      }

      console.log(`stream ${streamId} CONNECT ${target.address}:${target.port}`);

      let socket;
      try {
        socket = connect({ hostname: target.address, port: target.port });
      } catch (e) {
        console.error(`stream ${streamId} connect failed: ${e.message}`);
        sendFrame(streamId, MUX_CONNECT_FAIL, null);
        return;
      }

      // Register stream and send CONNECT_OK immediately — don't wait
      // for TCP handshake. Client data is buffered by socket.writable
      // and flushed when connection establishes. This saves ~200ms per stream.
      const writer = socket.writable.getWriter();
      streams.set(streamId, { socket, writer });
      sendFrame(streamId, MUX_CONNECT_OK, null);

      // Monitor connection failure asynchronously
      socket.opened.catch((e) => {
        console.error(`stream ${streamId} connect failed: ${e.message}`);
        streams.delete(streamId);
        try { writer.close(); } catch (_) {}
        sendFrame(streamId, MUX_CLOSE, null);
      });

      // Read from TCP socket, send DATA frames back to client
      try {
        const reader = socket.readable.getReader();
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          if (value && value.byteLength > 0) {
            // value may be Uint8Array — ensure we pass ArrayBuffer
            const buf = value.buffer ? value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) : value;
            sendFrame(streamId, MUX_DATA, buf);
          }
        }
      } catch (e) {
        // Socket closed or errored
        if (streams.has(streamId)) {
          console.log(`stream ${streamId} TCP read ended: ${e.message}`);
        }
      }

      // TCP disconnected — send CLOSE
      streams.delete(streamId);
      sendFrame(streamId, MUX_CLOSE, null);
      try { writer.close(); } catch (_) {}
    }

    /**
     * Close a stream and its TCP socket.
     */
    function closeStream(streamId) {
      const entry = streams.get(streamId);
      if (entry) {
        streams.delete(streamId);
        try { entry.writer.close(); } catch (_) {}
        try { entry.socket.close(); } catch (_) {}
      }
    }

    server.addEventListener("message", async (event) => {
      let data;
      if (event.data instanceof ArrayBuffer) {
        data = event.data;
      } else if (event.data instanceof Blob) {
        data = await event.data.arrayBuffer();
      } else {
        // string message — ignore
        return;
      }

      let frame;
      try {
        frame = decodeMuxFrame(data);
      } catch (e) {
        console.error(`bad mux frame: ${e.message}`);
        return;
      }

      // First message must be auth
      if (!authenticated) {
        if (frame.streamId !== 0 || frame.msgType !== 0x00) {
          console.error("first message not auth frame");
          server.close(4001, "auth required");
          return;
        }
        const receivedHMAC = new Uint8Array(frame.payload);
        if (receivedHMAC.length !== 32 || !timingSafeEqual(receivedHMAC, expectedHMAC)) {
          console.error("auth failed: bad HMAC");
          server.close(4002, "auth failed");
          return;
        }
        authenticated = true;
        console.log("client authenticated");
        return;
      }

      // Dispatch by message type
      switch (frame.msgType) {
        case MUX_CONNECT:
          if (streams.size >= MAX_STREAMS) {
            console.warn(`stream ${frame.streamId} rejected: ${streams.size}/${MAX_STREAMS} streams active`);
            sendFrame(frame.streamId, MUX_CONNECT_FAIL, null);
          } else {
            // No await — handleConnect runs its own read loop async
            handleConnect(frame.streamId, frame.payload).catch(e => {
              console.error(`stream ${frame.streamId} unhandled error: ${e.message}`);
              closeStream(frame.streamId);
            });
          }
          break;

        case MUX_DATA: {
          const entry = streams.get(frame.streamId);
          if (entry) {
            try {
              await entry.writer.write(new Uint8Array(frame.payload));
            } catch (e) {
              console.error(`stream ${frame.streamId} TCP write error: ${e.message}`);
              closeStream(frame.streamId);
              sendFrame(frame.streamId, MUX_CLOSE, null);
            }
          }
          break;
        }

        case MUX_CLOSE:
          console.log(`stream ${frame.streamId} closed by client`);
          closeStream(frame.streamId);
          break;

        default:
          console.warn(`unknown msg type 0x${frame.msgType.toString(16)} stream=${frame.streamId}`);
      }
    });

    server.addEventListener("close", () => {
      console.log("WS closed, cleaning up all streams");
      for (const [id] of streams) {
        closeStream(id);
      }
    });

    server.addEventListener("error", (e) => {
      console.error(`WS error: ${e.message || e}`);
      for (const [id] of streams) {
        closeStream(id);
      }
    });

    return new Response(null, { status: 101, webSocket: client });
  },
};
