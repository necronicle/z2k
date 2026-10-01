#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^tg_connect_queue_failures\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$ROOT/files/z2k-diag.sh" > "$TMP/fn"
[ -s "$TMP/fn" ] || { echo 'FAIL: no CONNECT queue diagnostic'; exit 1; }
. "$TMP/fn"
[ "$(tg_connect_queue_failures "$TMP/missing")" = 0 ]
printf '%s\n' '2026/10/01 16:51:58 [tunnel] stream 8066 CONNECT throttled (timeout)' > "$TMP/log"
[ "$(tg_connect_queue_failures "$TMP/log")" = 1 ]
i=0
while [ "$i" -lt 200 ]; do echo '[tunnel] CONNECT_OK' >> "$TMP/log"; i=$((i+1)); done
[ "$(tg_connect_queue_failures "$TMP/log")" = 0 ]
echo '[tunnel] stream 42 CONNECT throttled (timeout)' >> "$TMP/log"
[ "$(tg_connect_queue_failures "$TMP/log")" = 1 ]
echo 'PASS: reports recent queue failures, ignores old failures and missing logs'
