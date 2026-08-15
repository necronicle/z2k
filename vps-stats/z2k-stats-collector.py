#!/usr/bin/env python3
# z2k-stats-collector.py — anonymized strategy-statistics collector (server side).
#
# Receives anonymized rotation snapshots from z2k routers and appends them to a
# flat append-only log. Deliberately minimal and privacy-preserving:
#   * stdlib only (no third-party deps);
#   * binds to localhost — public exposure is via a dedicated caddy :PORT block
#     (reverse_proxy) so the relay's nginx:443 / caddy:8443 stay untouched;
#   * NEVER records the client source IP, X-Forwarded-For, User-Agent, or any
#     request header beyond the auth token — the only thing stored is the
#     validated anonymized body plus a coarse server receive-DATE (no time);
#   * the payload itself carries NO host/domain, NO provider, NO region, NO IP,
#     and NO device identifier of any kind (see the DELIBERATELY-NO-id note
#     below) — only {pool, strategy, dwell, count} rows.
#
# Wire contract (POST /stats, header X-Z2K-Token: <shared secret>):
#   {
#     "schema": 1,
#     "rows": [ {"pool": "yt_quic", "strategy": 1, "dwell": 8123, "count": 3}, ... ]
#   }
# Response: 204 on accept, 4xx on malformed/unauthorized, 503 once the log has
# hit its ceiling. Failures are designed to be silent no-ops on the client, so
# the collector never affects bypass.
#
# THE TOKEN IS NOT A DEFENCE. It is a documented public constant shipped in every
# router image, so "only our fleet can write here" was never true. Everything
# that protects this endpoint is therefore a bound, not a gate: MAX_BODY and
# MAX_ROWS per request, MAX_CONN concurrent connections, MAX_RAW_BYTES on the log,
# and per-upload collapsing so one request cannot masquerade as many samples.
# The disk and the RAM under this service are shared with the Telegram tunnels
# and the WhatsApp relay; a stats endpoint must not be able to take those down.
#
# DELIBERATELY NO device identifier: per the privacy audit, attaching any stable
# per-device id (serial, install-id, even a random nonce) would make uploads
# longitudinally joinable and re-introduce identity even with host stripped.
# Uploads are ~1/day/device, so a population sample needs no de-dup key — the
# aggregator treats each upload as one anonymous device-day sample.

import json
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND_HOST = os.environ.get("Z2K_STATS_BIND", "127.0.0.1")
BIND_PORT = int(os.environ.get("Z2K_STATS_PORT", "9099"))
TOKEN = os.environ.get("Z2K_STATS_TOKEN", "")
RAW_PATH = os.environ.get("Z2K_STATS_RAW", "/var/lib/z2k-stats/raw.jsonl")

MAX_BODY = 65536          # 64 KiB hard cap on request body
MAX_ROWS = 400            # generous: ~8 pools × dozens of strategies
POOL_MAX_LEN = 40
ALLOWED_POOL = set("abcdefghijklmnopqrstuvwxyz0123456789_")

# Ceiling on the append-only log. The token is a documented PUBLIC constant, so
# "who may write here" is not a defence — anyone can. Retention (z2k-stats-trim)
# keeps the file near ~90 MiB in normal operation; this cap is what stops a flood
# from turning a stats endpoint into a full disk on the box that also carries the
# Telegram tunnels and the WhatsApp relay. Past the cap we refuse new uploads
# (503) instead of writing: losing statistics is recoverable, losing the relay is
# not.
MAX_RAW_BYTES = int(os.environ.get("Z2K_STATS_MAX_RAW", str(256 * 1024 * 1024)))

# Ceiling on simultaneously served connections. ThreadingHTTPServer spawns one OS
# thread per accepted connection and stdlib imposes no limit whatsoever, so
# without this a few thousand opened-and-abandoned sockets exhaust memory and
# descriptors on a 2 GiB VPS. Over the cap we close the socket immediately: a
# dropped upload is a silent no-op on the client by design.
MAX_CONN = int(os.environ.get("Z2K_STATS_MAX_CONN", "64"))


def _valid_pool(p):
    return (
        isinstance(p, str)
        and 0 < len(p) <= POOL_MAX_LEN
        and all(c in ALLOWED_POOL for c in p)
    )


def _valid_int(v, lo, hi):
    return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def sanitize(payload):
    """Return a clean, minimal dict or None. Drops every unexpected field so
    nothing unforeseen can ever be persisted."""
    if not isinstance(payload, dict):
        return None
    if payload.get("schema") != 1:
        return None
    rows = payload.get("rows")
    if not isinstance(rows, list) or len(rows) == 0 or len(rows) > MAX_ROWS:
        return None
    # ROWS ARE KEPT AS SENT — NOT COLLAPSED BY (pool, strategy).
    #
    # It is tempting to merge duplicate pairs here, and a first attempt at
    # hardening did exactly that. It was wrong, because duplicates are NORMAL.
    # The client emits one row per (pool, host) straight out of state.tsv and
    # never sends `count` at all, so a pool where five hosts sit on the same
    # strategy legitimately produces five rows with that same (pool, strategy)
    # and five DIFFERENT dwell values. Merging them kept one dwell and threw the
    # rest away, corrupting the very distribution the aggregator exists to
    # measure — a real cost paid by every healthy multi-host router, to blunt an
    # abuse case.
    #
    # The invariant that actually needed enforcing ("one upload is one sample")
    # is not a property of a row, it is a property of an upload — so it belongs
    # in the aggregator, which is where it now lives: it counts each
    # (pool, strategy) at most once per upload. That kills the inflation without
    # discarding a single legitimate measurement.
    clean_rows = []
    for r in rows:
        if not isinstance(r, dict):
            return None
        pool = r.get("pool")
        strat = r.get("strategy")
        dwell = r.get("dwell")
        count = r.get("count", 1)               # optional; one state row => count 1
        if not _valid_pool(pool):
            return None
        if not _valid_int(strat, 0, 100000):
            return None
        if not _valid_int(dwell, 0, 31_536_000):   # cap dwell at 1 year of seconds
            return None
        if not _valid_int(count, 1, 100000):
            return None
        clean_rows.append({"pool": pool, "strategy": strat, "dwell": dwell, "count": count})
    return {"schema": 1, "rows": clean_rows}


class Handler(BaseHTTPRequestHandler):
    server_version = "z2kstats/1"
    # Bound every blocking socket op so a stalled client cannot pin a worker
    # thread indefinitely. BaseHTTPRequestHandler applies this to the request
    # socket in setup().
    #
    # What this does NOT do, despite what an earlier version of this comment
    # claimed: it is not a slowloris defence on its own. The timeout resets on
    # every recv, so a client dribbling one byte every 14 seconds holds a thread
    # forever without ever tripping it. Nor does caddy cover it — v2 has no
    # default HTTP timeouts, and this deployment cannot add them (see the note in
    # caddy-z2k-stats.snippet), so the "caddy in front also enforces its own
    # timeouts" reassurance this comment used to carry was simply untrue.
    #
    # What actually bounds a slow client is MAX_CONN: a ceiling on live
    # connections makes the attack finite no matter how long each one lingers.
    timeout = 15

    # Silence default logging entirely — we must not log client IPs.
    def log_message(self, *args):
        pass

    def _reply(self, code):
        # WRITING THE ANSWER MUST NOT RAISE. If the peer is already gone — the
        # 408 path reaches here precisely because the socket died mid-read — then
        # send_response/end_headers hit a dead descriptor and BrokenPipeError
        # escapes the handler. socketserver then prints the calling address and a
        # full traceback to stderr, which under systemd is the persistent journal.
        # Two promises break at once: this file and the README both say the
        # collector logs nothing, and the address is exactly the thing we
        # committed never to record. Behind caddy that address is 127.0.0.1, so
        # no real user IP escapes today — but the claim is false either way, and
        # any topology change makes it a genuine leak.
        try:
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()
        except OSError:
            # Peer vanished. Nothing to report and nobody to report it to.
            self.close_connection = True

    def do_POST(self):
        if self.path.rstrip("/") != "/stats":
            return self._reply(404)
        # Token is an OPTIONAL anti-abuse gate: enforced only when configured.
        # The data is anonymized, so this is a spam speed-bump, not a secret.
        if TOKEN and self.headers.get("X-Z2K-Token", "") != TOKEN:
            return self._reply(401)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._reply(400)
        if length <= 0 or length > MAX_BODY:
            return self._reply(413)
        try:
            raw = self.rfile.read(length)
        except (OSError, TimeoutError):
            return self._reply(408)
        try:
            # RecursionError (RuntimeError subclass) can be raised by json.loads
            # on a deeply-nested body that is still under MAX_BODY — catch it so
            # a hostile payload yields a clean 4xx instead of an uncaught
            # traceback / dropped connection.
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, RecursionError):
            return self._reply(400)
        clean = sanitize(payload)
        if clean is None:
            return self._reply(422)
        # Stamp a COARSE server-side receive date (UTC, date only — no time of
        # day, to avoid any timing fingerprint). No IP, no headers.
        clean["rx_date"] = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        line = json.dumps(clean, separators=(",", ":"), sort_keys=True)
        try:
            os.makedirs(os.path.dirname(RAW_PATH), exist_ok=True)
            # Refuse rather than grow past the ceiling (see MAX_RAW_BYTES): the
            # disk under this file is shared with the relays people depend on.
            try:
                if os.stat(RAW_PATH).st_size >= MAX_RAW_BYTES:
                    return self._reply(503)
            except FileNotFoundError:
                pass
            with open(RAW_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            return self._reply(500)
        return self._reply(204)

    def do_GET(self):
        # Liveness only — reveals nothing.
        if self.path.rstrip("/") in ("/health", "/healthz"):
            return self._reply(204)
        return self._reply(404)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    # Deeper accept queue than the stdlib default of 5: the whole fleet uploads
    # in the same nightly window, and a refused SYN is a lost day of data.
    request_queue_size = 128

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._slots = threading.BoundedSemaphore(MAX_CONN)
        self._refused = 0

    def process_request(self, request, client_address):
        # Hard bound on live connections — see MAX_CONN. Refusing at accept time
        # costs one closed socket; not refusing costs one OS thread, and stdlib
        # will happily give out thousands.
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)
            # A ceiling nobody can see is indistinguishable from a ceiling set
            # too low: uploads would vanish during the nightly peak with no
            # trace anywhere. Count refusals and say so, sparsely — a bare
            # number, no address, first one and then every 100th, so a real
            # squeeze is visible in the journal without a flood becoming its own
            # denial of service via log writes.
            self._refused += 1
            if self._refused == 1 or self._refused % 100 == 0:
                sys.stderr.write("connection refused at MAX_CONN=%d (total refused: %d)\n"
                                 % (MAX_CONN, self._refused))
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()

    def handle_error(self, request, client_address):
        # NEVER the address, NEVER a traceback. The stdlib default prints both to
        # stderr, and under systemd that is the persistent journal — see the note
        # in _reply(). The exception class alone is enough to notice something
        # unexpected without recording who was talking to us or where our files
        # live on disk.
        exc = sys.exc_info()[1]
        sys.stderr.write("request failed: %s\n" % type(exc).__name__)


def main():
    if not TOKEN:
        sys.stderr.write("warning: Z2K_STATS_TOKEN empty — endpoint open (validation/size-cap still enforced)\n")
    httpd = Server((BIND_HOST, BIND_PORT), Handler)
    sys.stderr.write(f"z2k-stats-collector listening on {BIND_HOST}:{BIND_PORT}\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
