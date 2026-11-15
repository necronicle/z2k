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
R=$(regen absent ""); has "Z2K_YT_QUIC_OFF=0" "$R" && has "Z2K_QUIC_OFF=0" "$R" && ok "отсутствующие ключи фиксируются по прежнему умолчанию 0" || bad "умолчания не зафиксированы: [$R]"
R=$(regen junk "Z2K_QUIC_OFF=maybe"); has "Z2K_QUIC_OFF=maybe" "$R" && ok "существующий ключ не меняется при обновлении" || bad "существующий ключ изменён: [$R]"

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

# --- 6. Сброс UDP:443 по IP видеосерверов (gvsub) и youtube-nocookie.com -------
grep -qxF 'youtube-nocookie.com' "$ROOT/files/lists/extra_strats/UDP/YT/List.txt" \
    && ok "youtube-nocookie.com входит в офлайн-список UDP/YT/List.txt" \
    || bad "youtube-nocookie.com отсутствует в UDP/YT/List.txt"

GV_IPS_TEST="$TMP/gv-ips-yt.txt"
OUT_IPSET=$(
    root=$(mkroot "yt-ipset")
    printf 'Z2K_YT_QUIC_OFF=1\nZ2K_GV_SERVER_REPLY2=1\n' >> "$root/config"
    ZAPRET2_DIR="$root" Z2K_GVSUB_IPS="$GV_IPS_TEST" generate_nfqws2_opt_from_strategies 2>/dev/null \
        | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk"
)
if [ -f "$GV_IPS_TEST" ] && grep -qxF '0.0.0.0/32' "$GV_IPS_TEST" && grep -qxF '::/128' "$GV_IPS_TEST"; then
    ok "генератор подготовил sentinels в Z2K_GVSUB_IPS для UDP drop"
else
    bad "sentinels не подготовлены в $GV_IPS_TEST"
fi
IPSET_DROP=$(printf '%s\n' "$OUT_IPSET" | grep -F -- "--ipset=$GV_IPS_TEST" | head -1)
if [ -n "$IPSET_DROP" ]; then
    has "--filter-udp=443" "$IPSET_DROP" && has "--lua-desync=drop" "$IPSET_DROP" \
        && ok "при Z2K_YT_QUIC_OFF=1 добавлен страхующий drop по --ipset на UDP:443" \
        || bad "неверные параметры страхующего профиля: $IPSET_DROP"
    has "--hostlist" "$IPSET_DROP" \
        && bad "в профиле --ipset есть hostlist (отвергал бы потоки без SNI): $IPSET_DROP" \
        || ok "профиль --ipset работает без hostlist/hostlist-exclude"
    has "--filter-l7=quic" "$IPSET_DROP" \
        && bad "профиль --ipset ограничен quic_initial (пропускал бы фрагменты/0-RTT): $IPSET_DROP" \
        || ok "профиль --ipset режет любые UDP:443 пакеты к узлам видео"
    HL_L=$(line_of '/UDP/YT/List.txt --filter-udp=443 --filter-l7=quic' "$OUT_IPSET")
    IP_L=$(line_of "--ipset=$GV_IPS_TEST" "$OUT_IPSET")
    QU_L=$(line_of 'key=quic' "$OUT_IPSET")
    [ -n "$HL_L" ] && [ -n "$IP_L" ] && [ -n "$QU_L" ] && [ "$HL_L" -lt "$IP_L" ] && [ "$IP_L" -lt "$QU_L" ] \
        && ok "профиль --ipset стоит сразу после hostlist-drop и перед обходом QUIC" \
        || bad "неверный порядок профилей: hostlist=$HL_L ipset=$IP_L quic=$QU_L"
else
    bad "нет профиля --ipset для Z2K_YT_QUIC_OFF=1"
fi

OUT_NOGV=$(
    root=$(mkroot "yt-nogv")
    printf 'Z2K_YT_QUIC_OFF=1\nZ2K_GV_SERVER_REPLY2=0\n' >> "$root/config"
    ZAPRET2_DIR="$root" Z2K_GVSUB_IPS="$TMP/nogv-ips.txt" generate_nfqws2_opt_from_strategies 2>/dev/null \
        | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk"
)
has "--ipset=" "$OUT_NOGV" \
    && bad "при Z2K_GV_SERVER_REPLY2=0 добавлен --ipset в UDP drop" \
    || ok "при Z2K_GV_SERVER_REPLY2=0 страхующий --ipset не ставится"

GV_CATOFF_IPS="$TMP/catoff-gv-ips.txt"
(
    root=$(mkroot "yt-catoff-ipset")
    printf 'Z2K_YT_QUIC_OFF=1\nZ2K_GV_SERVER_REPLY2=1\nZ2K_CATEGORY_YOUTUBE=0\n' >> "$root/config"
    ZAPRET2_DIR="$root" Z2K_GVSUB_IPS="$GV_CATOFF_IPS" generate_nfqws2_opt_from_strategies >/dev/null 2>&1
)
[ ! -e "$GV_CATOFF_IPS" ] \
    && ok "при Z2K_CATEGORY_YOUTUBE=0 генератор не создаёт файл Z2K_GVSUB_IPS" \
    || bad "при Z2K_CATEGORY_YOUTUBE=0 создан лишний файл $GV_CATOFF_IPS"

printf '\nИТОГ: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

