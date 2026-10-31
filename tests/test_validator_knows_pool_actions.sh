#!/bin/sh
# tests/test_validator_knows_pool_actions.sh — валидатор знает каждое действие
# поставляемых пулов.
#
# Полевой случай 31.10.2026: в p-87.3 в пул РКН приехал multidisorder_legacy, а в
# списке валидатора его не было. Движок действие знает, конфиг рабочий, но
# обновление у всего флота писало «validate-config: предупреждения» — ложная
# тревога на каждом роутере. Список действий валидатора обязан покрывать всё,
# что стоит в манифестах и в генераторе.
HERE=$(cd "$(dirname "$0")/.." && pwd)
V="$HERE/files/z2k-config-validator.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

known=$(sed -n '/^KNOWN_LUA_DESYNC_ACTIONS="/,/"$/p' "$V" | sed 's/^KNOWN_LUA_DESYNC_ACTIONS="//; s/["\\]//g' | tr ' ' '\n' | grep -v '^$')
[ -n "$known" ] || { no "список действий валидатора прочитан" "непустой" "пусто"; exit 1; }
used=$(cat "$HERE/strats_new2.txt" "$HERE/quic_strats.ini" "$HERE/lib/config_official.sh" "$HERE/lib/utils.sh" \
    | grep -oE -- '--lua-desync=[a-z0-9_]+' | sed 's/^--lua-desync=//' | sort -u)
unknown=""
for a in $used; do
    printf '%s\n' "$known" | grep -qx "$a" || unknown="$unknown $a"
done
[ -z "$unknown" ] && ok "валидатор знает все действия пулов ($(printf '%s\n' "$used" | wc -l | tr -d ' '))" \
    || no "валидатор знает все действия пулов" "пусто" "неизвестны:$unknown"

printf '\nИТОГ: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
