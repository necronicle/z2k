#!/bin/sh
# Исполняем функции init: отсутствующий, пустой и прежний список безопасны.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
fn() { awk -v f="$1" '$0 == f "()" || $0 == f "() {" {p=1} p{print} p&&/^}/{exit}' "$ROOT/files/S99zapret2.new"; }
{ fn z2k_gvsub_ip_sentinels; fn z2k_gvsub_ensure_ipfile; } > "$TMP/functions"
. "$TMP/functions"
Z2K_GVSUB_IPS="$TMP/ips"
printf '0.0.0.0/32\n::/128\n' > "$TMP/want"
z2k_gvsub_ensure_ipfile
cmp "$TMP/want" "$Z2K_GVSUB_IPS"
: > "$Z2K_GVSUB_IPS"
z2k_gvsub_ensure_ipfile
cmp "$TMP/want" "$Z2K_GVSUB_IPS"
printf '1.1.1.1\n2606:4700::1111\n' > "$Z2K_GVSUB_IPS"
printf '1.1.1.1\n2606:4700::1111\n' >> "$TMP/want"
z2k_gvsub_ensure_ipfile
cmp "$TMP/want" "$Z2K_GVSUB_IPS"
# Правильный список сохраняет inode и содержимое при повторном вызове.
ln "$Z2K_GVSUB_IPS" "$TMP/original"
z2k_gvsub_ensure_ipfile
# -ef не POSIX: сравниваем номера inode.
[ "$(ls -i "$Z2K_GVSUB_IPS" | awk '{print $1}')" = "$(ls -i "$TMP/original" | awk '{print $1}')" ]
cmp "$TMP/want" "$Z2K_GVSUB_IPS"
# Только одна заглушка — тоже требует починки; адрес сохраняется.
printf '0.0.0.0/32\n1.1.1.1\n' > "$Z2K_GVSUB_IPS"
z2k_gvsub_ensure_ipfile
grep -Fx '::/128' "$Z2K_GVSUB_IPS"
grep -Fx '1.1.1.1' "$Z2K_GVSUB_IPS"
Z2K_GVSUB_IPS="$TMP/missing/ips"
z2k_gvsub_ensure_ipfile
printf 'PASS: gvsub ipfile\n'
