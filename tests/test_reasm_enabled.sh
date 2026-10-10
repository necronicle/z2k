#!/bin/sh
# tests/test_reasm_enabled.sh — пересборка TLS ClientHello ВКЛЮЧЕНА, а дедлок
# на серверах с малым окном снят там, где он рождался: в правиле очереди.
#
# ИСТОРИЯ. С 21.08 по 11.09.2026 init добавлял демону
# `--reasm-disable=tls_client_hello` (tests/test_reasm_disable_tls_only.sh,
# снят): большой ClientHello к img.reg.ru вис в браузере, curl работал
# (bol-van/zapret2#229). Замер 11.09 на роутере владельца показал причину:
# сервер с окном 1448 (анти-DDoS) держит клиент на первом сегменте, а движок
# держит сегмент до сборки. Защита движка от этого («reasm cancelled because
# server window size is smaller») молчала, потому что SYN-ACK IPv4 не попадал в
# очередь: правило `--connbytes 1:N --connbytes-dir reply` на ядре Keenetic не
# матчит первый ответный пакет (счётчик ещё 0). Счётчики на SYN-ACK за 6
# соединений: без connbytes 7, 0:50 — 7, 1:50 — 0. Форк r2 даёт 0:N; с ним и
# без флага img.reg.ru 1800/1500 байт отвечает за 0.09 с (5/5), раньше —
# таймаут 6 с (5/5).
#
# ЦЕНА ФЛАГА, ради которой он снят: клон-фейки (tls_client_hello_clone) и любой
# разбор по reasm видели только первый сегмент, а 18 из 30 ClientHello на линии
# владельца многосегментные (Chrome/Firefox с постквантовым ключом).
#
# ЧТО ПИНИТСЯ:
#   1. init не передаёт демону --reasm-disable ни в каком виде и гейта нет;
#   2. движок закреплён не ниже форка r2 — только в нём common/ipt.sh даёт 0:N,
#      а без этого включённая пересборка вернёт дедлок на reg.ru;
#   3. диагностика считает флаг у демона отклонением, а его отсутствие — нормой.
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
INIT="$ROOT/files/S99zapret2.new"
INSTALL="$ROOT/lib/install.sh"
DIAG="$ROOT/files/z2k-diag.sh"

# --- 1. init: флага и гейта нет ----------------------------------------------
# Комментарии не считаем: история флага в init описана словами, и это нормально.
_code=$(grep -v '^[[:space:]]*#' "$INIT")
case "$_code" in
    *reasm-disable*) no "init не передаёт --reasm-disable" "нет в коде" "$(printf '%s\n' "$_code" | grep -n 'reasm-disable' | head -2)" ;;
    *) ok "init не передаёт --reasm-disable" ;;
esac
case "$_code" in
    *z2k_apply_reasm_gate*|*Z2K_REASM_GATE*) no "гейта reasm в init нет" "нет" "остался" ;;
    *) ok "гейта reasm в init нет" ;;
esac

# --- 2. движок закреплён не ниже r2 ------------------------------------------
# Минимум — v1.0.5.1-z2k-r2. База апстрима сравнивается по числам через точку,
# ревизия форка — только при равной базе: v1.0.5.2-z2k-r0 новее v1.0.5.1-z2k-r3,
# ребейз на новый апстрим обнуляет rN (так было с 10.10.2026, пин 1.0.5.2-r0).
# Только строка пина: в комментариях install.sh живут исторические версии (v1.0-z2k-r0).
_pin=$(grep 'local fallback_url=' "$INSTALL" | grep -oE 'v[0-9]+(\.[0-9]+)*-z2k-r[0-9]+' | sort -u)
_n=$(printf '%s\n' "$_pin" | wc -l | tr -d ' ')
[ "$_n" = "1" ] && ok "пин движка в install.sh один: $_pin" || no "пин движка один" "1" "$_pin"
if printf '%s\n' "$_pin" | awk '
    { b = $0; sub(/^v/, "", b); sub(/-z2k.*/, "", b); r = $0; sub(/.*-r/, "", r) }
    END {
        nb = split(b, B, "."); nm = split("1.0.5.1", M, ".")
        n = (nb > nm) ? nb : nm
        for (i = 1; i <= n; i++) { if ((B[i]+0) > (M[i]+0)) exit 0; if ((B[i]+0) < (M[i]+0)) exit 1 }
        exit !((r+0) >= 2)
    }'; then
    ok "движок не ниже форка v1.0.5.1-r2 (connbytes 0:N): $_pin"
else
    no "движок не ниже форка v1.0.5.1-r2" ">= v1.0.5.1-z2k-r2" "$_pin"
fi

# --- 3. диагностика: флаг = отклонение, его отсутствие = норма ----------------
_svc=$(awk '/^print_service\(\) \{/,/^\}/' "$DIAG")
case "$_svc" in
    *'"$_rs" = "off"'*'включена (ок)'*) ok "diag: пересборка включена — «ок»" ;;
    *) no "diag: off → ок" "проверка off перед «ок»" "иначе" ;;
esac
case "$_svc" in
    *'очередь connbytes'*) ok "diag: печатает состояние правила connbytes" ;;
    *) no "diag: строка connbytes" "есть" "нет" ;;
esac
grep -q 'nfqws_first_packets_state()' "$DIAG" && ok "diag: функция чтения connbytes есть" || no "diag: nfqws_first_packets_state" "есть" "нет"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
