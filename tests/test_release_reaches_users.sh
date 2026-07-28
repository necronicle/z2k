#!/bin/sh
# tests/test_release_reaches_users.sh
#
# Two ways a release can be perfectly correct and still do nothing on a router.
# p-67.9 hit both at once, and every other test in this suite passed while it
# did, because each of them asked "is the code right?" and neither asked "can
# this code ever run?".
#
# 1. AN UPDATE IS APPLIED BY THE UPDATER ALREADY ON THE ROUTER — the PREVIOUS
#    release. So a hook added to lib/auto_update.sh cannot fire during the very
#    update that ships it. p-67.9 added "fetch the WARP game lists if there are
#    none" there; p-67.8's updater ran that update, knew nothing about it, and
#    the lists stayed empty. The hook was correct, tested, and unreachable.
#
#    The rule: a first-run side effect must ALSO be reachable from a component
#    the patch restarts. files/z2k-scheduler.sh is such a component
#    (au_apply_patch's restart_set maps it to S99z2k-scheduler).
#
# 2. THE BROWSER DECIDES WHETHER IT LOADS THE NEW PANEL. index.html requests its
#    assets as `app.js?v=<tag>`; the browser caches by URL, so that suffix is the
#    only thing that reliably makes it fetch a new one. It was a hand-written
#    literal stuck at `p39` for twenty-eight releases — the panel shipped, the
#    URL did not change, and a caching browser kept running the old script.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
AU="$HERE/lib/auto_update.sh"
SCHED="$HERE/files/z2k-scheduler.sh"
IDX="$HERE/webpanel/www/index.html"
MAN="$HERE/UPDATES.json"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

for f in "$AU" "$SCHED" "$IDX" "$MAN"; do
    [ -f "$f" ] || { printf '[FAIL] missing %s\n' "$f"; exit 1; }
done

# --- 1. the first-run hook must be reachable on the release that ships it ----
grep -q 'warp-games' "$SCHED" \
    && ok "сид игровых списков есть в планировщике (перезапускается патчем)" \
    || no "сид игровых списков есть в планировщике" "warp-games" "нет"

# The scheduler only restarts if the patch actually carries it, so the mapping
# that makes that true is itself load-bearing.
grep -q 'files/z2k-scheduler.sh)            restart_set="$restart_set S99z2k-scheduler"' "$AU" \
    && ok "патч с планировщиком перезапускает S99z2k-scheduler" \
    || no "патч с планировщиком перезапускает планировщик" "маппинг в restart_set" "нет"

# Belt and braces, not either/or: the updater keeps its copy for later updates.
grep -q 'no WARP game lists yet' "$AU" \
    && ok "хук в апдейтере тоже на месте (сработает со следующей обновы)" \
    || no "хук в апдейтере на месте" "гейт" "нет"

# Both gates must agree, or one of them fetches when the other would not.
sched_gate=$(grep -c 'lists/warp/games/"\*.txt' "$SCHED")
au_gate=$(grep -c 'lists/warp/games/"\*.txt' "$AU")
[ "$sched_gate" -ge 1 ] && [ "$au_gate" -ge 1 ] \
    && ok "оба места используют один и тот же гейт на пустоту" \
    || no "оба места используют один гейт" ">=1 и >=1" "$sched_gate/$au_gate"

# The seed must not block the scheduler loop — it runs before `while true`.
seed_ln=$(grep -n 'warp-games' "$SCHED" | head -1 | cut -d: -f1)
loop_ln=$(grep -n '^while true; do' "$SCHED" | head -1 | cut -d: -f1)
[ -n "$seed_ln" ] && [ -n "$loop_ln" ] && [ "$seed_ln" -lt "$loop_ln" ] \
    && ok "сид отрабатывает до входа в цикл (строка $seed_ln < $loop_ln)" \
    || no "сид отрабатывает до цикла" "раньше while" "$seed_ln/$loop_ln"
# run_task backgrounds it, so a dead mirror cannot stall the scheduler.
grep -q 'run_task warp-games-seed' "$SCHED" \
    && ok "сид запускается через run_task (фоном, вывод в лог)" \
    || no "сид запускается через run_task" "run_task" "иначе"

# --- 2. the browser must be made to load the new panel ----------------------
cur=$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MAN" | head -1)
[ -n "$cur" ] && ok "текущий релиз читается из манифеста ($cur)" \
              || no "текущий релиз читается из манифеста" "тег" "пусто"

vers=$(grep -oE '\?v=[A-Za-z0-9._-]+' "$IDX" | sed 's/^?v=//' | LC_ALL=C sort -u)
[ -n "$vers" ] && ok "кеш-бастер присутствует в index.html" \
               || no "кеш-бастер присутствует" "?v=" "нет"
# One value for every asset, and it must equal the release. Anything else means
# a browser can keep serving the previous panel after an update.
n_distinct=$(printf '%s\n' "$vers" | grep -c .)
[ "$n_distinct" = 1 ] && ok "у всех ресурсов один и тот же ?v=" \
                      || no "у всех ресурсов один ?v=" "1 значение" "$n_distinct"
[ "$vers" = "$cur" ] && ok "кеш-бастер совпадает с текущим релизом ($vers)" \
                     || no "кеш-бастер совпадает с релизом" "$cur" "$vers"

# And it is derived, not typed by hand — the literal is exactly what rotted.
grep -q 'кеш-бастер панели' "$HERE/scripts/gen_file_hashes.sh" \
    && ok "значение проставляется генератором, а не руками" \
    || no "значение проставляется генератором" "sed по index.html" "нет"

# Every asset that can change between releases must carry it, or that one file
# is the stale one.
for asset in app.js style.css; do
    grep -q "$asset?v=" "$IDX" \
        && ok "$asset грузится с версией" \
        || no "$asset грузится с версией" "$asset?v=" "без версии"
done

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
