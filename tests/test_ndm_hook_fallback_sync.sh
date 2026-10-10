#!/bin/sh
# tests/test_ndm_hook_fallback_sync.sh — запасной heredoc хука в lib/install.sh
# обязан быть байт в байт равен files/000-zapret2.sh.
#
# install.sh копирует штатный файл, а heredoc достаёт только когда файла нет.
# Эта копия уже отставала однажды: штатный хук перешёл с restart_fw на
# add-only start_fw, запасной продолжал делать teardown на каждый реген NDM,
# и именно он уезжал части флота. Две реализации одного хука — дрейф по
# определению; тест запрещает его.
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ndmsync.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

awk '
    /<<'\''HOOK'\''$/ { grab=1; next }
    grab && /^HOOK$/  { grab=0; exit }
    grab              { print }
' "$HERE/lib/install.sh" > "$TMP/heredoc"

[ -s "$TMP/heredoc" ] || { printf '[FAIL] heredoc HOOK не найден в lib/install.sh\n'; exit 1; }

if cmp -s "$TMP/heredoc" "$HERE/files/000-zapret2.sh"; then
    printf '[PASS] запасной heredoc хука равен files/000-zapret2.sh\n\n1 passed, 0 failed\n'
    exit 0
fi
printf '[FAIL] запасной heredoc хука расходится с files/000-zapret2.sh:\n'
diff -u "$HERE/files/000-zapret2.sh" "$TMP/heredoc" | head -40
printf '\n0 passed, 1 failed\n'
exit 1
