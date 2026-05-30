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
# Response: 204 on accept, 4xx on malformed/unauthorized. Failures are designed
# to be silent no-ops on the client, so the collector never affects bypass.
#
# DELIBERATELY NO device identifier: per the privacy audit, attaching any stable
# per-device id (serial, install-id, even a random nonce) would make uploads
# longitudinally joinable and re-introduce identity even with host stripped.
# Uploads are ~1/day/device, so a population sample needs no de-dup key — the
# aggregator treats each upload as one anonymous device-day sample.

import json
import os
import sys
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
    # Bound every blocking socket op so a slow/stalled client (slowloris) cannot
    # pin a worker thread indefinitely. BaseHTTPRequestHandler applies this to
    # the request socket in setup(). Caddy in front also enforces its own
    # timeouts; this is defence in depth for the localhost listener.
    timeout = 15

    # Silence default logging entirely — we must not log client IPs.
    def log_message(self, *args):
        pass

    def _reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

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


def main():
    if not TOKEN:
        sys.stderr.write("warning: Z2K_STATS_TOKEN empty — endpoint open (validation/size-cap still enforced)\n")
    httpd = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    sys.stderr.write(f"z2k-stats-collector listening on {BIND_HOST}:{BIND_PORT}\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
