# z2k VPS relay — build & deploy

The relay (`/usr/local/bin/z2k-vps-relay`) runs on the Aeza VPS behind the
nginx `:443` SNI stream router → caddy (TLS + `/ws`) → relay `127.0.0.1:8080`.
It is **deployed by hand on the VPS** and is deliberately decoupled from the
router auto-update fleet (only the *client* binaries in `mtproxy-client/builds/`
ship via `UPDATES.json`). This dir exists so that decoupled deploy is
reproducible and documented, not tribal knowledge.

## Files

- `build.sh` — reproducible static `linux/amd64` build → `vps-relay/z2k-vps-relay`.
- `z2k-relay.service` — reference unit (secrets are placeholders; the live unit
  on the VPS holds the real values). Source-of-truth for the invocation flags.
- `20-gomemlimit.conf` — systemd drop-in that sets `GOMEMLIMIT=1500MiB`
  (non-invasive; does not touch the main unit or its secrets).

## Deploy (off-peak — restarting drops all live tunnels; they reconnect)

```sh
# 1. build (from repo root)
sh vps-relay/deploy/build.sh

# 2. copy the binary up
scp vps-relay/z2k-vps-relay root@<vps>:/usr/local/bin/z2k-vps-relay.new

# 3. on the VPS: apply the GOMEMLIMIT drop-in (one-time)
mkdir -p /etc/systemd/system/z2k-relay.service.d
scp vps-relay/deploy/20-gomemlimit.conf \
    root@<vps>:/etc/systemd/system/z2k-relay.service.d/20-gomemlimit.conf

# 4. on the VPS: swap binary + restart (atomic-ish; off-peak)
mv /usr/local/bin/z2k-vps-relay.new /usr/local/bin/z2k-vps-relay
chmod +x /usr/local/bin/z2k-vps-relay
systemctl daemon-reload
systemctl restart z2k-relay
```

## Verify after deploy

```sh
# RSS should fall from ~0.9 GB toward ~0.15-0.3 GB at ~1600 tunnels
grep VmRSS /proc/$(pgrep -f z2k-vps-relay)/status
free -m                       # swap usage should drop
# dialing to Telegram must stay healthy across the restart
journalctl -u z2k-relay -n 20 | grep 'dial summary'   # fail=0 throttle=0 p95~45ms
```

## Rollback

Keep the previous `/usr/local/bin/z2k-vps-relay` (e.g. `.bak`); restore it and
`systemctl restart z2k-relay`. The `20-gomemlimit.conf` drop-in is independent
and safe to leave in place.
