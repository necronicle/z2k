#!/bin/sh
# tests/test_warp_games.sh — WARP per-game lists: the refresh in
# z2k-update-lists.sh::update_warp_game_list, and the loader/toggle contract in
# z2k-warp.sh (warp_active_lists).
#
# Replaces the old test_warp_merge.sh, which exercised a 3-way merge that no
# longer exists. That merge was there because one aggregate list doubled as
# upstream data AND the user's editable list. Splitting the two removed the need
# for it: games/ is upstream-owned and overwritten wholesale by the nightly
# refresh, the user's own lists sit beside it and are never touched by it.
#
# "Upstream-owned" НЕ значит «выбрасывается при переустановке». Раньше значило,
# и это стоило минут на каждой установке: четыре десятка списков качались
# заново, хотя не менялись. Теперь install.sh переносит games/ через пересборку
# дерева вместе с кешем .<имя>.raw, а перенос проходит гейт полноты — обрубок
# или битый кеш отвергаются ЦЕЛИКОМ, и тогда списки честно тянутся заново
# (tests/test_warp_games_survive_reinstall.sh, tests/test_warp_games_seed.sh).
# Владение осталось у обновлялки: установка ничего в games/ не пишет.
#
# What actually has to hold now:
#   * Other_Games is never fetched — a catch-all bucket nobody asked for.
#   * A game named in the index but not yet published upstream 404s, and that
#     must skip one list, not abort the refresh (upstream has three such today).
#   * The address filter runs on upstream data too: the aggregate shipped
#     10.0.0.0/8, 127.0.0.0/8 and 192.168.0.0/16, i.e. private space and the
#     user's own LAN, straight into the routing set.
#   * Nothing is loaded unless switched on, and a fresh install switches on
#     nothing.
#
# POSIX sh (busybox ash) compatible.

TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}
setof() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sort | tr '\n' ',' ; }

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

Z2K_UL_SOURCE_ONLY=1
export Z2K_UL_SOURCE_ONLY
# shellcheck disable=SC1091
. "$SCRIPT_DIR/files/z2k-update-lists.sh"

ZAPRET2_DIR="$SB/opt/zapret2"
LOG_FILE="$SB/update-lists.log"
WDIR="$ZAPRET2_DIR/lists/warp"
GDIR="$WDIR/games"
mkdir -p "$GDIR"

# --- stubs -------------------------------------------------------------------
# z2k_fetch serves the index; update_list serves per-game files and returns the
# real function's codes (0 unchanged, 1 failed, 2 updated).
INDEX="$SB/sources.json"
z2k_fetch() { cp -f "$INDEX" "$2" 2>/dev/null; }
FETCHED="$SB/fetched.log"
: > "$FETCHED"
update_list() {
    _name="$1"; _url="$2"; _dest="$3"
    printf '%s\n' "$_url" >> "$FETCHED"
    _game=${_url##*/}; _game=${_game%.txt}
    if [ -f "$SB/up/$_game.txt" ]; then
        cp -f "$SB/up/$_game.txt" "$_dest"; return 2
    fi
    return 1        # 404 upstream — exactly what a not-yet-published game gives
}
mkdir -p "$SB/up"

write_index() {
    # Mirrors upstream's shape: game_map values are ARRAYS, never objects, which
    # is what lets the parser stop at the first closing brace.
    printf '{\n "output": {"games_dir": "games"},\n "game_map": {\n' > "$INDEX"
    _first=1
    for _g in "$@"; do
        [ "$_first" = 1 ] || printf ',\n' >> "$INDEX"
        _first=0
        printf '  "%s": ["hint"]' "$_g" >> "$INDEX"
    done
    printf '\n },\n "domain_game_hints": {}\n}\n' >> "$INDEX"
}

printf "\n--- refresh: which lists get fetched ---\n"
printf '5.6.7.8\n9.9.9.9\n'  > "$SB/up/Steam.txt"
printf '1.1.1.1\n'           > "$SB/up/Roblox.txt"
printf '2.2.2.2\n'           > "$SB/up/Other_Games.txt"
# NotPublishedYet goes FIRST on purpose: if a 404 aborted the loop instead of
# skipping one game, everything after it would be missing — which is invisible
# when the unavailable game is processed last.
write_index NotPublishedYet Steam Roblox Other_Games
update_warp_game_list >/dev/null 2>&1
assert_eq "Steam fetched"                "1" "$(grep -c '/games/Steam.txt$'  "$FETCHED")"
assert_eq "Roblox fetched"               "1" "$(grep -c '/games/Roblox.txt$' "$FETCHED")"
assert_eq "Other_Games NEVER fetched"    "0" "$(grep -c 'Other_Games'        "$FETCHED")"
assert_eq "Steam list written"           "5.6.7.8,9.9.9.9," "$(setof "$GDIR/Steam.txt")"
assert_eq "Roblox list written"          "1.1.1.1,"         "$(setof "$GDIR/Roblox.txt")"
assert_eq "Other_Games list absent"      "0" "$([ -f "$GDIR/Other_Games.txt" ] && echo 1 || echo 0)"
# A 404 on one game must not stop the others — this is the whole point of the
# per-game loop, and upstream lists three such games right now.
assert_eq "missing upstream game skipped, others survive" "1" \
          "$([ -f "$GDIR/Steam.txt" ] && [ ! -f "$GDIR/NotPublishedYet.txt" ] && echo 1 || echo 0)"

printf "\n--- refresh: the address filter applies to upstream data too ---\n"
printf '10.0.0.1\n127.0.0.1\n192.168.1.1\n172.16.0.5\n0.0.0.0/0\n3.0.0.0/8\n8.8.8.8\n2a00:1450::1\n' > "$SB/up/Steam.txt"
write_index Steam
update_warp_game_list >/dev/null 2>&1
# 3.0.0.0/8 остаётся: это Amazon, а не мусор. Отсеиваются только
# нероутируемые и служебные.
assert_eq "остаются только маршрутизируемые" "3.0.0.0/8,8.8.8.8," "$(setof "$GDIR/Steam.txt")"

printf "\n--- refresh: an all-junk list leaves no file ---\n"
# Better no list than an empty one the panel would offer as a switch.
printf '10.0.0.1\n192.168.0.0/16\n' > "$SB/up/Roblox.txt"
write_index Roblox
update_warp_game_list >/dev/null 2>&1
assert_eq "empty-after-filter list removed" "0" "$([ -f "$GDIR/Roblox.txt" ] && echo 1 || echo 0)"

printf "\n--- refresh: a broken index changes nothing ---\n"
printf '5.5.5.5\n' > "$SB/up/Steam.txt"
write_index Steam
update_warp_game_list >/dev/null 2>&1
BEFORE=$(setof "$GDIR/Steam.txt")
printf 'not json at all\n' > "$INDEX"
update_warp_game_list >/dev/null 2>&1 && r=0 || r=1
assert_eq "broken index reports failure"      "1" "$r"
assert_eq "broken index leaves lists intact"  "$BEFORE" "$(setof "$GDIR/Steam.txt")"

printf "\n--- refresh: user's own lists are never touched ---\n"
printf '203.0.113.7\n' > "$WDIR/mine.txt"
write_index Steam
update_warp_game_list >/dev/null 2>&1
assert_eq "user list survives a refresh" "203.0.113.7," "$(setof "$WDIR/mine.txt")"

# --- loader contract ---------------------------------------------------------
printf "\n--- loader: nothing is on unless switched on ---\n"
ENABLED="$WDIR/.enabled"
active() {
    sh -c "WARP_LISTS_DIR='$WDIR'; WARP_GAMES_DIR='$GDIR'; WARP_ENABLED_FILE='$ENABLED'
           $(awk '/^warp_active_lists\(\)/,/^}$/' "$SCRIPT_DIR/files/z2k-warp.sh")
           warp_active_lists | sed 's|.*/||' | LC_ALL=C sort | tr '\n' ','"
}
printf '5.5.5.5\n' > "$GDIR/Steam.txt"
printf '1.1.1.1\n' > "$GDIR/Roblox.txt"
rm -f "$ENABLED"
assert_eq "no .enabled -> only user lists"   "mine.txt," "$(active)"
: > "$ENABLED"
assert_eq "empty .enabled -> only user lists" "mine.txt," "$(active)"
printf 'Steam\n' > "$ENABLED"
assert_eq "one switched on"                  "Steam.txt,mine.txt," "$(active)"
printf 'Steam\nRoblox\n' > "$ENABLED"
assert_eq "two switched on"                  "Roblox.txt,Steam.txt,mine.txt," "$(active)"
printf 'Steam\nGoneUpstream\n' > "$ENABLED"
assert_eq "name without a file is ignored"   "Steam.txt,mine.txt," "$(active)"
# The name becomes a path, so it is validated like one.
# Each is caught by a DIFFERENT guard: leading dot, leading dash, and — only by
# the charset check — an embedded slash. The slash case has to RESOLVE to a real
# file to prove anything: a traversal through a directory that does not exist
# fails the -f test anyway, so it would pass even with the guard removed.
mkdir -p "$GDIR/sub"
printf '../../etc/passwd\n-rf\n.hidden\nsub/../../mine\n' > "$ENABLED"
assert_eq "hostile names rejected"           "mine.txt," "$(active)"

printf "\n--- the aggregate is gone for good ---\n"
assert_eq "no shipped aggregate in the repo" "0" \
          "$([ -f "$SCRIPT_DIR/files/lists/game-warp-ips.txt" ] && echo 1 || echo 0)"
assert_eq "installer no longer deploys it"   "0" \
          "$(grep -c 'iplist in .*game-warp-ips' "$SCRIPT_DIR/lib/install.sh")"
# The purge must run against the live dir, and install.sh must not carry the old
# list back in from its backup on the next reinstall.
# Two occurrences: the backup block and the restore block. One of them alone
# would mean the choice is saved but never put back, or vice versa.
# Both directions, asserted separately: backing the choice up without restoring
# it (or the reverse) silently resets everyone's selection on the next reinstall.
assert_eq "install.sh backs the choice up" "1" \
          "$(grep -c 'cp -f "\$ZAPRET2_DIR/lists/warp/\.enabled" "\$backup_tmp' "$SCRIPT_DIR/lib/install.sh")"
assert_eq "install.sh restores the choice" "1" \
          "$(grep -c 'cp -f "\$backup_tmp/warp-lists/\.enabled"' "$SCRIPT_DIR/lib/install.sh")"

printf "\n--- games/ survives the reinstall (the contract that changed) ---\n"
# Обе половины, как и у .enabled: бэкап без возврата означал бы, что перенос
# «есть», а списки всё равно качаются заново — то есть прежнее поведение под
# новым кодом. И наоборот. Само поведение переноса пинится отдельным набором.
assert_eq "install.sh backs games/ up"     "1" \
          "$(grep -c 'mkdir -p "\$backup_tmp/warp-games"' "$SCRIPT_DIR/lib/install.sh")"
assert_eq "install.sh restores games/"     "1" \
          "$(grep -c 'if \[ -d "\$backup_tmp/warp-games" \]' "$SCRIPT_DIR/lib/install.sh")"
# И кеш .raw переносится вместе со списками: без него ночной refresh скачал бы
# всё заново уже на следующую ночь, и экономия установки была бы отложенной,
# а не настоящей.
assert_eq "install.sh carries the .raw cache too" "1" \
          "$([ "$(grep -c '"\$backup_tmp/warp-games/"\.\*\.raw' "$SCRIPT_DIR/lib/install.sh")" -ge 1 ] && echo 1 || echo 0)"

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" = 0 ]
