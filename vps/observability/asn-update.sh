#!/bin/sh
# Недельное обновление таблицы префикс→ASN для событий релея.
# Источник — iptoasn.com (свободные данные, обновляются ежечасно).
# Пишем через временный файл и rename: релей перечитывает по mtime и не
# должен увидеть полуфайл.
set -eu
DST="${1:-/var/lib/z2k-relay/ip2asn-v4.tsv}"
URL="https://iptoasn.com/data/ip2asn-v4.tsv.gz"
tmp="$(mktemp "$(dirname "$DST")/.ip2asn.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --max-time 120 "$URL" | gunzip -c > "$tmp"
lines=$(wc -l < "$tmp")
[ "$lines" -gt 100000 ] || { echo "asn-update: подозрительно короткая таблица ($lines строк) — оставляю прежнюю" >&2; exit 1; }
chmod 0644 "$tmp"
mv -f "$tmp" "$DST"
echo "asn-update: $lines строк"
