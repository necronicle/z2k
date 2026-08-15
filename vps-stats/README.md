# z2k anonymized strategy statistics

Collect, in aggregate across opted-in routers, **which rotation strategy each
pool currently sits on and how long it has held** — so we can see which
strategies actually carry traffic and reorder rotation profiles (promote the
winners, demote / drop the never-played). Snapshot-only, anonymized, opt-out.

## Privacy model (what this deliberately does NOT collect)

The router uploads ONLY a list of `{pool, strategy, dwell}` rows. Concretely:

| field    | example   | why it's safe |
|----------|-----------|---------------|
| pool     | `yt_quic` | a strategy-bucket label, never embeds a host |
| strategy | `1`       | the integer rotation slot |
| dwell    | `8123`    | seconds the slot has been stable (`now - last_change_ts`) |

Never leaves the device, by construction:
- **the host/domain column** of `state.tsv` (the actual sites visited) — dropped
  at read time in `z2k-stats-upload.sh`. It is NOT hashed either: a hash over the
  small RU-blocked domain set is trivially reversible, so hashing ≠ anonymizing.
- **IP / provider / region** — never read on the client; the server discards the
  source IP on receipt (the collector logs nothing and stores no headers).
- **any device identifier** — no serial, no MAC, no install-id, not even a random
  nonce. A stable id would make uploads longitudinally joinable and re-introduce
  identity even with host stripped. Uploads are ~1/day, so the server treats each
  upload as one anonymous *device-day sample*; no de-dup key is needed.
- **raw timestamps** — only the relative `dwell` is sent, never absolute `ts`.

Default ON (`Z2K_STATS=1`, project policy: all features default on). Opt out via
the TUI menu `[C]`, the webpanel "Режимы → Сбор статистики" toggle, or
`Z2K_STATS=0` in `/opt/zapret2/config` (preserved across auto-update).

### The transport is NOT private, and that is the part that matters here

Everything above is about the *contents* of the upload. The *transport* is plain
HTTP to a bare IP: `http://213.176.74.63:8088/stats`, no TLS
(`files/z2k-stats-upload.sh`). Say plainly what that means, because for a
circumvention tool it outweighs the field-level anonymization:

- anyone who can watch the connection — in Russia that means the operator's DPI —
  sees a regular POST from your address to a fixed server, in the clear, carrying
  pool and strategy names. That is a usable signal for classifying the device as
  running z2k, and it is *more* revealing than any field inside the body;
- the body is anonymized against **us**, the people who run the server. It is not
  anonymized against an observer on the path, who already knows your address
  because they are carrying the packets.

So the honest summary is: the payload tells us nothing about you; the fact that
you sent it tells your ISP something about you. If that trade is not acceptable,
turn the collection off — the opt-out above is real and takes effect immediately.

Moving this to HTTPS is an outstanding public commitment (issue #28, point 3);
until it ships, this section is the disclosure, not a caveat buried in code.

## Metric: stable dwell (and its honest limitation)

`state.tsv` records WHERE rotation landed, not directly WHETHER it worked. The
proxy we trust is **stable dwell**: a strategy that many samples land on AND hold
for a long time is carrying traffic; one that churns is not.

**Known limitation (do not hide it):** a *stuck-but-broken* strategy (rotator
never rotates away despite breakage) also shows long dwell. Snapshot-only data
cannot separate "working" from "stuck-broken". The accuracy upgrade is the
**event-counter** path (per-strategy ok/fail/latency) — a complete telemetry
subsystem already exists, archived, in
`archive/custom-detectors-rotation/z2k-autocircular.lua`
(`telemetry[pool][host][strategy] = {ok, fail, lat, ts, cooldown_until}`). Wiring
it (host-stripped) would give a true success signal. Deferred by decision
(snapshot-first); see task #15.

## Pieces

Client (router, shipped by install):
- `files/z2k-stats-upload.sh` — builds the anonymized projection, POSTs it.
- fired daily at 03:00 by `files/z2k-scheduler.sh`, gated on `Z2K_STATS`.

Server (this dir → VPS):
- `z2k-stats-collector.py` — localhost HTTP service; validates + strips unknown
  fields + appends to `/var/lib/z2k-stats/raw.jsonl`; never stores the source IP.
- `z2k-stats-aggregate.py` — daily, turns `raw.jsonl` into `summary.{json,txt}`:
  per-(pool,strategy) sample count, dwell p50/p75, a stable-adoption score, and
  (given `--catalog`) the NEVER-PLAYED gap.
- `z2k-stats-trim.sh` — weekly retention: lines older than 60 days move to a
  per-month gzip archive. The collector only ever appends, so without this the
  log has no ceiling on a box that also carries the Telegram tunnels and the
  WhatsApp relay. The collector additionally refuses to append past
  `Z2K_STATS_MAX_RAW` (256 MiB) so a flood cannot fill the disk between runs.
- `z2k-stats-collector.service` / `z2k-stats-aggregate.{service,timer}` /
  `z2k-stats-trim.{service,timer}` — systemd.
- `caddy-z2k-stats.snippet` — additive `:8088` reverse-proxy block (does NOT touch
  the relay's nginx:443 SNI router or caddy:8443 block).
- `deploy-vps.sh` — idempotent installer (user, binaries, env+token, units, caddy
  append+validate-or-revert, firewall).

## Deploy (server)

```sh
# copy this dir to the VPS, then:
scp -r vps-stats root@213.176.74.63:/root/      # (or cat-over-ssh)
ssh root@213.176.74.63 'bash /root/vps-stats/deploy-vps.sh'
# prints the TOKEN; self-test command is printed at the end.
```

The client ships a public anti-abuse token constant (`z2kstats-pub-1`) — a spam
speed-bump, not a secret (the payload is anonymized; the repo is public). To
enforce a private token later: set `Z2K_STATS_TOKEN` in `/etc/z2k-stats.env` on
the VPS and push the matching `Z2K_STATS_TOKEN=` into `/opt/zapret2/config` on
clients — no code release needed.

## Catalog (for never-played detection)

`z2k-stats-aggregate.py --catalog catalog.json` flags strategies that exist in a
profile but no sample ever landed on. Build `catalog.json` as
`{ "<pool>": [1,2,3,...], ... }` from the current profiles (the strategy= slots in
`quic_strats.ini` / `strats_new2.txt`). Without it, aggregation still works; you
just don't get the gap report.

## Reading the result

`/var/lib/z2k-stats/summary.txt` — per pool, strategies sorted by score
(samples × median-dwell-minutes). High score = widely + stably used → keep near
the front. Score 0 / tiny dwell = churned → demote. NEVER PLAYED = candidate to
drop. Consult before the next manual reorder; nothing is applied automatically.
