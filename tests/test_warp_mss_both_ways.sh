#!/bin/sh
# tests/test_warp_mss_both_ways.sh — MSS зажимается в обе стороны, и число одно.
#
# ЗАЧЕМ. Жалоба из поля 2026-08-25: с включённым WARP «карты не грузятся, hh
# падает», а скачивание идёт. Замер на роутере владельца, живой трафик
# телефона через туннель:
#
#   SYN     клиент -> в туннель   : mss 1240   (140 из 140 — зажат)
#   SYN-ACK сервер -> из туннеля  : mss 1460   (140 из 140 — НЕ зажат)
#
# Клиенту разрешалось слать в туннель с MTU 1280 сегменты по 1460. Скачивание
# шло — 156 МБ за прогон, — а всё, что клиент ОТПРАВЛЯЕТ крупнее 1240 байт,
# обрывалось. После починки замер повторён: 176 из 176 видят mss 1240.
#
# ДВА МЕСТА ставят эти правила: движок (nat.go) и NDM-хук, который возвращает
# их после сброса правил прошивкой. Разъедутся — и после первого же регена
# netfilter половина починки исчезнет молча.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GO="$ROOT/z2k-warpd/internal/nat/nat.go"
HOOK="$ROOT/files/ndm/93-z2k-warp.sh"

assert_eq "движок зажимает НА пути в туннель"  "1" "$(grep -c '"-o", iface.*clamp-mss-to-pmtu' "$GO")"
assert_eq "движок зажимает И на пути из него"  "1" "$(grep -c '"-i", iface.*set-mss' "$GO")"
assert_eq "хук зажимает на пути в туннель"     "2" "$(grep -c -- '-o "$iface".*clamp-mss-to-pmtu' "$HOOK")"
assert_eq "хук зажимает и на пути из него"     "2" "$(grep -c -- '-i "$iface".*set-mss' "$HOOK")"

# Зеркалить первое правило нельзя: обратный SYN-ACK уходит через мост с MTU
# 1500, и clamp-mss-to-pmtu дал бы там 1460 — то есть ничего.
assert_eq "обратное правило не clamp-to-pmtu" "0" \
    "$(grep -c -- '-i "$iface".*clamp-mss-to-pmtu' "$HOOK")"

# Одно число в двух местах: движок считает от своего MTU, хук вписывает его
# буквой. Разойдутся — половина починки исчезнет после регена netfilter.
MTU=$(sed -n 's/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
      "$ROOT/z2k-warpd/internal/engine/engine.go" | head -1)
assert_eq "MTU туннеля читается"     "1280" "$MTU"
# MTU-40 встречается дважды — в Ensure и в Remove: снимать правило обязаны тем
# же числом, которым ставили, иначе оно останется висеть после выключения.
assert_eq "движок считает MSS от MTU" "2"   "$(grep -c 'MTU-40' "$ROOT/z2k-warpd/internal/engine/engine.go")"
assert_eq "хук вписывает то же число" "2"   "$(grep -c -- "--set-mss $((MTU - 40))" "$HOOK")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
