#!/bin/sh
# tests/test_warp_games_seed.sh
#
# Since p-67.8 the per-game lists are the ONLY way WARP gets any addresses, and
# they were fetched exclusively by the nightly refresh. So a router that had just
# updated showed an empty WARP page for up to a day — the feature apparently
# doing nothing, on the very screen we had just made central.
#
# The fetch therefore also happens as part of an update and of a fresh install.
# Two properties matter and pull in opposite directions:
#
#   * it must happen when there is nothing to show, including after a reinstall,
#     which deliberately does NOT preserve games/ (upstream data, re-fetched);
#   * it must NOT happen on every update — once lists exist the nightly refresh
#     owns them, and hitting the mirror after each patch is pointless traffic.
#
# Hence the gate is "the directory is empty", not a one-shot marker: a marker
# would satisfy the second property and break the first, stranding a reinstalled
# router with no lists and no way to get them until the next night.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
AU="$HERE/lib/auto_update.sh"
INST="$HERE/lib/install.sh"
UL="$HERE/files/z2k-update-lists.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wseed.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

for f in "$AU" "$INST" "$UL"; do
    [ -f "$f" ] || { printf '[FAIL] missing %s\n' "$f"; exit 1; }
done

# --- the targeted entry point ------------------------------------------------
# Running the whole nightly cycle after an update is not an option: it fetches
# the geosite and RKN lists and would add minutes to every update.
ZD="$TMP/opt/zapret2"
mkdir -p "$ZD/lists/warp/games"
out=$(ZAPRET2_DIR="$ZD" LOG_FILE="$TMP/u.log" sh "$UL" nonsense 2>&1)
case "$out" in
    *"usage: z2k-update-lists.sh"*) ok "неизвестный аргумент даёт usage" ;;
    *) no "неизвестный аргумент даёт usage" "usage" "$out" ;;
esac
ZAPRET2_DIR="$ZD" LOG_FILE="$TMP/u.log" sh "$UL" nonsense >/dev/null 2>&1
[ "$?" != 0 ] && ok "и ненулевой код возврата" || no "ненулевой код возврата" "!=0" "0"

# warp-games must run ONLY the game-list refresh. Asserted structurally because
# running it for real would go to the network.
disp=$(awk '/^if \[ -z "\$\{Z2K_UL_SOURCE_ONLY/,/^fi$/' "$UL")
case "$disp" in
    *"warp-games)"*) ok "аргумент warp-games объявлен" ;;
    *) no "аргумент warp-games объявлен" "ветка case" "нет" ;;
esac
case "$disp" in
    *"update_warp_game_list"*) ok "warp-games зовёт только обновление игровых списков" ;;
    *) no "warp-games зовёт только обновление игровых списков" "update_warp_game_list" "нет" ;;
esac
# Bare invocation must stay the nightly cycle — cron calls it with no argument.
case "$disp" in
    *"''|all)"*) ok "без аргумента поведение прежнее (ночной цикл)" ;;
    *) no "без аргумента поведение прежнее" "ветка ''|all" "нет" ;;
esac

# --- the gate, behaviourally -------------------------------------------------
# Extract the block from au_run_apply and drive it with a stub updater, so what
# is tested is the real condition rather than a paraphrase of it.
# From the _au_zd assignment, NOT from the log line inside the if body: taking
# only the body extracts the fetch WITHOUT its condition, and then the "lists
# already present" case runs it too and the test proves nothing.
GATE=$(awk '/^    _au_zd=/,/^    fi$/' "$AU" | grep -vE '^[[:space:]]*#')
case "$GATE" in
    *'lists/warp/games/'*) ok "в извлечённый блок попало САМО условие, а не только тело" ;;
    *) no "в извлечённый блок попало условие" "проверка каталога" "только тело" ;;
esac
[ -n "$GATE" ] && ok "блок гейта найден в au_run_apply" \
               || { no "блок гейта найден" "код" "пусто"; printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"; exit 1; }

printf '#!/bin/sh\necho called >> "%s/calls"\n' "$TMP" > "$ZD/z2k-update-lists.sh"
chmod +x "$ZD/z2k-update-lists.sh"
calls() { grep -c called "$TMP/calls" 2>/dev/null || echo 0; }
run_gate() {
    rm -f "$TMP/calls"
    sh -c "ZAPRET2_DIR='$ZD'; export ZAPRET2_DIR; au_log() { :; }
           $GATE
           wait" 2>/dev/null
    sleep 1
}

run_gate
[ "$(calls)" = 1 ] && ok "пустой games/ -> списки тянутся" \
                   || no "пустой games/ -> списки тянутся" "1" "$(calls)"

printf '1.2.3.4\n' > "$ZD/lists/warp/games/Steam.txt"
run_gate
[ "$(calls)" = 0 ] && ok "списки на месте -> в сеть не идём (не на каждое обновление)" \
                   || no "списки на месте -> в сеть не идём" "0" "$(calls)"

# The reinstall case the marker approach would have broken.
rm -f "$ZD/lists/warp/games/"*.txt
run_gate
[ "$(calls)" = 1 ] && ok "после реинстала (games/ вычищен) списки тянутся снова" \
                   || no "после реинстала списки тянутся снова" "1" "$(calls)"

# Missing updater must not blow up the tail of a successful update.
mv "$ZD/z2k-update-lists.sh" "$TMP/moved.sh"
run_gate
[ "$(calls)" = 0 ] && ok "нет апдейтера списков -> тихо пропускаем" \
                   || no "нет апдейтера списков -> тихо пропускаем" "0" "$(calls)"
mv "$TMP/moved.sh" "$ZD/z2k-update-lists.sh"

# --- it must not be able to fail the update ----------------------------------
case "$GATE" in
    *'>/dev/null 2>&1 || true ) &'*) ok "фетч фоновый и не-фатальный" ;;
    *) no "фетч фоновый и не-фатальный" "( ... || true ) &" "иначе" ;;
esac
# It has to sit AFTER the health check, or a slow mirror would be racing a
# rollback decision.
hc=$(grep -n 'au_health_check' "$AU" | tail -1 | cut -d: -f1)
gt=$(grep -n 'no WARP game lists yet' "$AU" | head -1 | cut -d: -f1)
[ -n "$hc" ] && [ -n "$gt" ] && [ "$gt" -gt "$hc" ] \
    && ok "фетч идёт после health-check (строка $gt > $hc)" \
    || no "фетч идёт после health-check" "после" "$gt/$hc"

# --- fresh install ------------------------------------------------------------
# A clean install never touches the auto-updater, so it needs its own trigger.
inst=$(grep -A6 'Загрузка игровых списков WARP' "$INST")
case "$inst" in
    *'warp-games'*) ok "чистая установка тоже тянет списки" ;;
    *) no "чистая установка тоже тянет списки" "warp-games" "нет" ;;
esac
grep -q 'ls "${ZAPRET2_DIR}/lists/warp/games/"\*.txt' "$INST" \
    && ok "и с тем же гейтом на пустоту" \
    || no "и с тем же гейтом на пустоту" "проверка каталога" "нет"

# --- the panel must not promise a day of waiting any more --------------------
APPJS="$HERE/webpanel/www/app.js"
grep -q 'раз в сутки' "$APPJS" \
    && no "текст про ожидание суток убран" "нет такого текста" "остался" \
    || ok "текст про ожидание суток убран"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
