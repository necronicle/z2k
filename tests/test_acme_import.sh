#!/bin/sh
# tests/test_acme_import.sh — импорт сертификата caddy в кеш autocert
# исполняется на самоподписанном сертификате: ключ и цепочка читаются
# openssl из одного файла, права 0600.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/vps/bin/acme-import-from-caddy.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }
[ -f "$S" ] || { bad "скрипт есть" "нет файла"; printf '\nPASSED: 0\nFAILED: 1\n'; exit 1; }
command -v openssl >/dev/null || { echo "нет openssl"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2kacme.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
H=213.176.74.63.nip.io
mkdir -p "$TMP/caddy/$H" "$TMP/cache"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj "/CN=$H" \
    -keyout "$TMP/caddy/$H/$H.key" -out "$TMP/caddy/$H/$H.crt" >/dev/null 2>&1 || { bad "openssl req" "не сгенерировал"; exit 1; }
me="$(id -un):$(id -gn)"
if out=$(sh "$S" "$H" "$TMP/caddy/$H" "$TMP/cache" "$me" 2>&1); then
    ok "скрипт отработал: $out"
else
    bad "скрипт отработал" "$out"
fi
f="$TMP/cache/$H"
[ -f "$f" ] && ok "файл кеша создан" || bad "файл кеша создан" "нет $f"
perm=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)
[ "$perm" = 600 ] && ok "права 0600" || bad "права 0600" "$perm"
openssl pkey -in "$f" -noout 2>/dev/null && ok "ключ читается из кеша" || bad "ключ читается" "openssl pkey"
openssl x509 -in "$f" -noout -subject 2>/dev/null | grep -q "$H" && ok "сертификат читается из кеша" || bad "сертификат читается" "openssl x509"
[ ! -f "$TMP/cache/.$H.tmp" ] && ok "временный файл убран" || bad "временный файл убран" "остался"
if sh "$S" "$H" "$TMP/nope" "$TMP/cache" "$me" >/dev/null 2>&1; then
    bad "без исходных файлов — отказ" "вернул 0"
else
    ok "без исходных файлов — отказ"
fi
printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
