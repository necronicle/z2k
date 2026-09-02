#!/bin/sh
# Переносит текущий сертификат caddy в кеш autocert релея, чтобы переход
# на TLS в релее не начинался с окна без сертификата. Дальше autocert сам
# продлит его за 30 дней до истечения через TLS-ALPN.
# acme-import-from-caddy.sh HOST [CADDY_DIR] [CACHE_DIR] [OWNER]
set -eu
HOST="${1:?host}"
CADDY="${2:-/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$HOST}"
CACHE="${3:-/var/lib/z2k-relay/acme}"
OWNER="${4:-nobody:nogroup}"
[ -f "$CADDY/$HOST.key" ] && [ -f "$CADDY/$HOST.crt" ] || { echo "нет $CADDY/$HOST.{key,crt}" >&2; exit 1; }
mkdir -p "$CACHE"
tmp="$CACHE/.$HOST.tmp"
# autocert хранит ключ и цепочку одним PEM-файлом с именем хоста.
{ cat "$CADDY/$HOST.key"; echo; cat "$CADDY/$HOST.crt"; } > "$tmp"
openssl pkey -in "$tmp" -noout
openssl x509 -in "$tmp" -noout
chmod 0600 "$tmp"
chown "$OWNER" "$tmp" "$CACHE"
mv -f "$tmp" "$CACHE/$HOST"
echo "импортирован: $(openssl x509 -in "$CACHE/$HOST" -noout -enddate)"
