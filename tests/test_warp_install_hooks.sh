#!/bin/sh
# tests/test_warp_install_hooks.sh — контракт install.sh/uninstall/scheduler
# после переезда WARP на z2k-warpd. Grep-контракты: каждая строка — решение,
# которое уже один раз было нарушено или дорого стоило бы нарушить.
#   - движок НЕ ставится при установке z2k: только по кнопке «Установить»;
#   - установленный движок обновляется (sha256 из UPDATES.json — внутри
#     z2k-warp.sh install), неустановленный — не качается;
#   - uninstall зовёт `z2k-warp.sh remove` и убирает init/хук, device.json
#     остаётся;
#   - usque нигде не упоминается как живой код (только зачистка);
#   - rollback знает z2k-warpd, а не z2k-usque;
#   - шедулер продолжает звать selfheal.
# POSIX sh.
TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
I="$SCRIPT_DIR/lib/install.sh"
count() { grep -c -- "$1" "$2" 2>/dev/null; return 0; }   # grep -c сам печатает 0

assert_eq "install: no engine pre-install at setup" "0" "$(grep -c 'WARP: устанавливаю движок' "$I")"
assert_eq "install: refreshes engine only if installed" "1" "$(grep -c 'if \[ -x /opt/sbin/z2k-warpd \]; then' "$I")"
assert_eq "install: engine refresh goes through z2k-warp.sh install" "yes" "$(grep -A4 'if \[ -x /opt/sbin/z2k-warpd \]; then' "$I" | grep -q 'z2k-warp.sh" install' && echo yes || echo no)"
assert_eq "install: deploys S51z2k-warp" "1" "$(count 'files/init.d/S51z2k-warp' "$I")"
assert_eq "install: deploys 93-z2k-warp.sh" "1" "$(count 'files/ndm/93-z2k-warp.sh' "$I")"
assert_eq "install: stale .new cleanup knows z2k-warpd" "1" "$(count 'z2k-warpd.new' "$I")"
assert_eq "install: stale .new cleanup forgot z2k-usque" "0" "$(count 'z2k-usque.new' "$I")"
assert_eq "rollback: ROLLBACK_SBIN_BINS has z2k-warpd" "1" "$(grep -c '^ROLLBACK_SBIN_BINS=.*z2k-warpd' "$I")"
assert_eq "rollback: ROLLBACK_SBIN_BINS has no z2k-usque" "0" "$(grep -c '^ROLLBACK_SBIN_BINS=.*z2k-usque' "$I")"
assert_eq "uninstall: calls z2k-warp.sh remove" "1" "$(count 'z2k-warp.sh" remove' "$I")"
assert_eq "uninstall: removes init and hook" "1" "$(grep -c 'rm -f /opt/etc/init.d/S51z2k-warp /opt/etc/ndm/netfilter.d/93-z2k-warp.sh' "$I")"
assert_eq "uninstall: never touches S51usque" "0" "$(count 'S51usque' "$I")"
assert_eq "uninstall: no killall z2k-usque" "0" "$(count 'killall z2k-usque' "$I")"
assert_eq "install: migrate runs on every install (usque cleanup)" "1" "$(count 'z2k-warp.sh" migrate' "$I")"
assert_eq "service map: z2k-warpd → S51z2k-warp" "1" "$(grep -c 'z2k-warpd)[[:space:]]*echo "/opt/etc/init.d/S51z2k-warp"' "$I")"

S="$SCRIPT_DIR/files/z2k-scheduler.sh"
assert_eq "scheduler: still calls selfheal" "1" "$(count 'z2k-warp.sh" selfheal' "$S")"
assert_eq "scheduler: WARP block no longer promises usque restarts" "0" "$(sed -n '/WARP: selfheal/,/z2k-warp.sh" selfheal/p' "$S" | grep -c usque)"

C="$SCRIPT_DIR/z2k_cleanup.sh"
assert_eq "cleanup: knows z2ktun" "yes" "$(grep -q 'z2ktun' "$C" && echo yes || echo no)"
assert_eq "cleanup: no usque" "0" "$(count 'usque' "$C")"

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
