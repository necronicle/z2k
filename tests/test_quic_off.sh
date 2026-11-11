#!/bin/sh
# tests/test_quic_off.sh — тумблеры «YouTube без QUIC» (Z2K_YT_QUIC_OFF) и
# «Весь QUIC через TCP» (Z2K_QUIC_OFF).
#
# Механизм — профиль с drop на QUIC Initial ПЕРЕД профилем обхода QUIC: движок
# берёт первый подходящий профиль, и стоящий после него drop не сработал бы
# никогда. Проверяется исполнением генератора, панели и пересборки конфига.
# POSIX sh (busybox ash).

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

TMP="${TMPDIR:-/tmp}/z2k-quic-off.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

. "$ROOT/lib/utils.sh" 2>/dev/null
. "$ROOT/lib/config_official.sh" 2>/dev/null

mkroot() {
    local root="$TMP/$1"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" "$root/lists"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    echo "ENABLED=1" > "$root/config"
    printf '%s' "$root"
}

gen() { # $1 - тег, остальное - строки конфига
    local tag="$1"; shift
    local root; root=$(mkroot "$tag")
    for l in "$@"; do echo "$l" >> "$root/config"; done
    ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null ) \
        | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk"
}

# Номер строки-профиля: первый с drop и первый профиль обхода QUIC.
line_of() { printf '%s\n' "$2" | grep -n -F -- "$1" | head -1 | cut -d: -f1; }

# --- 1. Выключено по умолчанию ------------------------------------------------
OUT=$(gen absent)
has "--lua-desync=drop" "$OUT" \
    && bad "без ключей QUIC режется (умолчание должно быть выключено)" \
    || ok "без ключей QUIC не режется"
OUT=$(gen zeros "Z2K_QUIC_OFF=0" "Z2K_YT_QUIC_OFF=0")
has "--lua-desync=drop" "$OUT" && bad "=0 всё равно режет QUIC" || ok "=0 не режет QUIC"

# --- 2. Только YouTube ---------------------------------------------------------
OUT=$(gen yt "Z2K_YT_QUIC_OFF=1")
DROP=$(printf '%s\n' "$OUT" | grep -F -- '--lua-desync=drop' | head -1)
if [ -n "$DROP" ]; then
    ok "YouTube без QUIC: профиль с drop есть"
    has "--filter-udp=443" "$DROP" && has "--filter-l7=quic" "$DROP" \
        && has "--payload=quic_initial" "$DROP" \
        && ok "режется только QUIC Initial на 443" || bad "фильтр профиля не тот: $DROP"
    has "/UDP/YT/List.txt" "$DROP" && ok "ограничен списком YouTube" \
        || bad "профиль YouTube без списка — резал бы весь QUIC: $DROP"
    has "--hostlist-exclude=" "$DROP" && has "whitelist.txt" "$DROP" \
        && ok "исключения не трогаются" || bad "нет исключений: $DROP"
    D=$(line_of '--lua-desync=drop' "$OUT"); Q=$(line_of 'key=quic' "$OUT")
    [ -n "$Q" ] && [ "$D" -lt "$Q" ] && ok "drop стоит перед профилем обхода QUIC" \
        || bad "drop не перед профилем QUIC (drop=$D quic=$Q)"
else
    bad "YouTube без QUIC: профиля с drop нет"
fi

# Без категории YouTube профиль YouTube не нужен: z2k YouTube не трогает.
OUT=$(gen ytcatoff "Z2K_YT_QUIC_OFF=1" "Z2K_CATEGORY_YOUTUBE=0")
has "--lua-desync=drop" "$OUT" \
    && bad "YouTube выключен, а QUIC YouTube режется" || ok "без категории YouTube профиль не ставится"

# --- 3. Весь QUIC -------------------------------------------------------------
OUT=$(gen all "Z2K_QUIC_OFF=1")
DROP=$(printf '%s\n' "$OUT" | grep -F -- '--lua-desync=drop' | head -1)
if [ -n "$DROP" ]; then
    ok "весь QUIC: профиль с drop есть"
    has "--hostlist=" "$DROP" && bad "весь QUIC ограничен списком: $DROP" \
        || ok "без списка — режется любой QUIC"
    has "whitelist.txt" "$DROP" && ok "весь QUIC: исключения не трогаются" \
        || bad "весь QUIC: нет исключений: $DROP"
    D=$(line_of '--lua-desync=drop' "$OUT"); Q=$(line_of 'key=quic' "$OUT")
    [ -n "$Q" ] && [ "$D" -lt "$Q" ] && ok "весь QUIC: drop перед профилем обхода QUIC" \
        || bad "весь QUIC: drop не перед профилем QUIC (drop=$D quic=$Q)"
else
    bad "весь QUIC: профиля с drop нет"
fi
OUT=$(gen both "Z2K_QUIC_OFF=1" "Z2K_YT_QUIC_OFF=1")
N=$(printf '%s\n' "$OUT" | grep -c -F -- '--lua-desync=drop')
[ "$N" = 1 ] && ok "оба включены — один профиль на весь QUIC" || bad "оба включены — профилей drop: $N"

# --- 4. Пересборка конфига сохраняет выбор человека ---------------------------
regen() { # $1 - тег, $2 - строка конфига; печатает строки ключей после пересборки
    local root; root=$(mkroot "regen-$1")
    [ -n "$2" ] && echo "$2" >> "$root/config"
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    grep -E '^Z2K_(YT_)?QUIC_OFF=' "$root/config" | tr '\n' ' '
}
R=$(regen on-yt "Z2K_YT_QUIC_OFF=1"); has "Z2K_YT_QUIC_OFF=1" "$R" && ok "Z2K_YT_QUIC_OFF=1 переживает пересборку" || bad "Z2K_YT_QUIC_OFF=1 потерян: [$R]"
R=$(regen off-yt "Z2K_YT_QUIC_OFF=0"); has "Z2K_YT_QUIC_OFF=0" "$R" && ok "Z2K_YT_QUIC_OFF=0 переживает пересборку" || bad "Z2K_YT_QUIC_OFF=0 потерян: [$R]"
R=$(regen on-all "Z2K_QUIC_OFF=1"); has "Z2K_QUIC_OFF=1" "$R" && ok "Z2K_QUIC_OFF=1 переживает пересборку" || bad "Z2K_QUIC_OFF=1 потерян: [$R]"
R=$(regen absent ""); [ -z "$R" ] && ok "без ключей пересборка их не пишет (умолчание версии)" || bad "пересборка записала ключи: [$R]"
R=$(regen junk "Z2K_QUIC_OFF=maybe"); [ -z "$R" ] && ok "мусорное значение не сохраняется" || bad "мусор сохранён: [$R]"

# --- 5. Панель: тумблеры ставят флаг, пересобирают и перезапускают -------------
ACT="$ROOT/webpanel/cgi/actions.sh"
for fn in toggle_yt_quic_off:Z2K_YT_QUIC_OFF toggle_quic_off:Z2K_QUIC_OFF; do
    f=${fn%%:*}; key=${fn#*:}
    BODY=$(awk "/^$f\\(\\)/{p=1} p{print} p&&/^}/{exit}" "$ACT")
    if [ -z "$BODY" ]; then bad "в панели нет $f"; continue; fi
    CALLS="$TMP/calls-$f"; : > "$CALLS"
    sh -c "
        set_flag() { echo \"flag:\$1=\$2\" >> '$CALLS'; }
        regenerate_config() { echo regen >> '$CALLS'; }
        restart_service_if_running() { echo restart >> '$CALLS'; }
        CONFIG_FILE=/dev/null
        $BODY
        $f 1; echo rc=\$? >> '$CALLS'
        $f maybe; echo rc=\$? >> '$CALLS'
    "
    [ "$(tr '\n' ' ' < "$CALLS")" = "flag:$key=1 regen restart rc=0 rc=1 " ] \
        && ok "$f: флаг, пересборка, перезапуск; мусор отвергнут" \
        || bad "$f: вызовы не те: $(tr '\n' ' ' < "$CALLS")"
done
API="$ROOT/webpanel/cgi/api.sh"
for r in yt-quic-off:toggle_yt_quic_off quic-off:toggle_quic_off; do
    grep -q "\"POST /toggle/${r%%:*}\"" "$API" && grep -q "_toggle_fn=${r#*:}" "$API" \
        && ok "маршрут /toggle/${r%%:*} ведёт в ${r#*:}" || bad "нет маршрута /toggle/${r%%:*}"
done

printf '\nИТОГ: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
