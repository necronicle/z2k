#!/usr/bin/env bash
# deploy-vps.sh — set up the z2k anonymized stats collector on the relay VPS.
#
# SAFE BY DESIGN — touches nothing the Telegram relay depends on:
#   * does NOT modify nginx (the :443 SNI stream router for the relay);
#   * does NOT modify the existing caddy :8443 relay block — only APPENDS a
#     dedicated :8088 site;
#   * runs the collector as an unprivileged, sandboxed systemd service bound to
#     localhost; relay (z2k-relay.service) is never restarted or touched.
#
# Idempotent: re-running re-installs binaries and re-reads config without
# regenerating the token (unless --new-token is passed).
#
# Run as root on the VPS after copying this directory to /root/vps-stats.
set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="/usr/local/bin"
ENV_FILE="/etc/z2k-stats.env"
DATA_DIR="/var/lib/z2k-stats"
CADDYFILE="/etc/caddy/Caddyfile"
PORT_PUBLIC=8088

log() { printf '[deploy] %s\n' "$*"; }

# 1. unprivileged user
if ! id z2kstats >/dev/null 2>&1; then
	log "creating system user z2kstats"
	useradd --system --no-create-home --shell /usr/sbin/nologin z2kstats
fi

# 2. binaries
log "installing collector + aggregator + trim to $BIN_DIR"
install -m 0755 "$SRC_DIR/z2k-stats-collector.py" "$BIN_DIR/z2k-stats-collector.py"
install -m 0755 "$SRC_DIR/z2k-stats-aggregate.py" "$BIN_DIR/z2k-stats-aggregate.py"
install -m 0755 "$SRC_DIR/z2k-stats-trim.sh"      "$BIN_DIR/z2k-stats-trim.sh"

# 3. data dir
mkdir -p "$DATA_DIR"
chown z2kstats:z2kstats "$DATA_DIR"
chmod 0750 "$DATA_DIR"

# 4. env / token
#    Default token MUST match the client's shipped public anti-abuse constant
#    (z2k-stats-upload.sh: TOKEN="z2kstats-pub-1"), else clients get 401. Pass
#    --new-token to rotate to a private random value (then also push the matching
#    Z2K_STATS_TOKEN= into /opt/zapret2/config on clients).
PUBLIC_TOKEN="z2kstats-pub-1"
if [ ! -f "$ENV_FILE" ] || [ "${1:-}" = "--new-token" ]; then
	if [ "${1:-}" = "--new-token" ]; then
		TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	else
		TOKEN="$PUBLIC_TOKEN"
	fi
	log "writing $ENV_FILE (token set)"
	cat > "$ENV_FILE" <<EOF
Z2K_STATS_BIND=127.0.0.1
Z2K_STATS_PORT=9099
Z2K_STATS_RAW=$DATA_DIR/raw.jsonl
Z2K_STATS_TOKEN=$TOKEN
EOF
	chmod 0640 "$ENV_FILE"
	chown root:z2kstats "$ENV_FILE"
	log "TOKEN=$TOKEN   <-- put this into the router-side Z2K_STATS_TOKEN"
else
	log "$ENV_FILE exists; keeping current token (pass --new-token to rotate)"
	grep '^Z2K_STATS_TOKEN=' "$ENV_FILE" | sed 's/^/[deploy] current /'
fi

# 5. systemd units
#    The trim timer is not optional garnish: without it the collector appends
#    forever. It used to be installed by hand on the one live VPS and existed
#    nowhere in the repository, so any redeploy or rebuild produced a service
#    with no retention at all. See z2k-stats-trim.sh.
log "installing systemd units"
install -m 0644 "$SRC_DIR/z2k-stats-collector.service" /etc/systemd/system/z2k-stats-collector.service
install -m 0644 "$SRC_DIR/z2k-stats-aggregate.service"  /etc/systemd/system/z2k-stats-aggregate.service
install -m 0644 "$SRC_DIR/z2k-stats-aggregate.timer"    /etc/systemd/system/z2k-stats-aggregate.timer
install -m 0644 "$SRC_DIR/z2k-stats-trim.service"       /etc/systemd/system/z2k-stats-trim.service
install -m 0644 "$SRC_DIR/z2k-stats-trim.timer"         /etc/systemd/system/z2k-stats-trim.timer
systemctl daemon-reload
systemctl enable --now z2k-stats-collector.service
systemctl enable --now z2k-stats-aggregate.timer
systemctl enable --now z2k-stats-trim.timer

# Supersede the hand-installed cron entry this timer replaces, so the rewrite
# cannot run twice from two schedulers.
if [ -e /etc/cron.monthly/z2k-stats-trim ]; then
	log "removing superseded /etc/cron.monthly/z2k-stats-trim (now a systemd timer)"
	rm -f /etc/cron.monthly/z2k-stats-trim
fi

log "collector status:"; systemctl --no-pager --lines=0 status z2k-stats-collector.service | head -3 || true

# 6. caddy public entrypoint (append-only, idempotent)
if ! grep -q '^:8088 {' "$CADDYFILE" 2>/dev/null; then
	log "appending :$PORT_PUBLIC block to $CADDYFILE"
	printf '\n' >> "$CADDYFILE"
	cat "$SRC_DIR/caddy-z2k-stats.snippet" >> "$CADDYFILE"
	if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
		# `admin off` in the global Caddyfile disables the admin API that
		# `systemctl reload` drives, so reload fails — fall back to restart.
		# Restarting caddy does NOT affect nginx:443 (the SNI relay router); it
		# only bounces caddy's own :80/:8443 (relay :8443 is firewall-dropped
		# externally anyway).
		systemctl reload caddy 2>/dev/null || systemctl restart caddy
		log "caddy reloaded/restarted"
	else
		log "ERROR: caddy validate failed; reverting append"
		# remove the appended block
		sed -i '/^:8088 {/,/^}/d' "$CADDYFILE"
		exit 1
	fi
else
	log "caddy :$PORT_PUBLIC block already present"
fi

# 7. firewall — host INPUT policy is ACCEPT, but make 8088 explicit + persistent.
if command -v iptables >/dev/null 2>&1; then
	iptables -C INPUT -p tcp --dport "$PORT_PUBLIC" -j ACCEPT 2>/dev/null \
		|| iptables -I INPUT -p tcp --dport "$PORT_PUBLIC" -j ACCEPT
	log "iptables: tcp/$PORT_PUBLIC accepted (persist via your usual method, e.g. netfilter-persistent save)"
fi

log "done. self-test:"
log "  TOKEN=\$(grep TOKEN $ENV_FILE|cut -d= -f2); curl -s -o /dev/null -w '%{http_code}\\n' -XPOST http://127.0.0.1:$PORT_PUBLIC/stats -H \"X-Z2K-Token: \$TOKEN\" -d '{\"schema\":1,\"rows\":[{\"pool\":\"yt_quic\",\"strategy\":1,\"dwell\":99}]}'"
