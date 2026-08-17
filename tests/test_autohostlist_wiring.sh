#!/bin/sh
# tests/test_autohostlist_wiring.sh — тумблер «Автохостлист» доходит до движка.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. Тумблер существовал с r-45 и всё это время не делал
# ничего: он писал MODE_FILTER=autohostlist в конфиг, а аргументы демона в обоих
# положениях оставались БАЙТ В БАЙТ одинаковыми. Апстрим подставляет
# --hostlist-auto заменой плейсхолдера <HOSTLIST> (common/list.sh), а мы
# генерируем профили с явными путями и плейсхолдеров не используем — функция
# подстановки вызывалась вхолостую. Человеку при этом обещано в меню, в панели
# и в README, что «движок сам находит заблокированные домены».
#
# ЧТО ЗДЕСЬ ОХРАНЯЕТСЯ:
#
#   1. Флаг реально доезжает: при Z2K_AUTOHOSTLIST=1 в NFQWS2_OPT появляется
#      --hostlist-auto=, при 0 — не появляется вовсе.
#   2. Детектор — ПОСЛЕДНИЙ профиль. Это не стиль: профиль с автолистом
#      выигрывает подбор при любом известном имени хоста, а подбор
#      останавливается на первом совпадении. Поставленный выше, он заберёт
#      youtube.com и googlevideo.com у yt_tcp/gv_tcp — те стоят с тем же
#      фильтром портов и живут только за счёт непересекающихся хостлистов.
#   3. Профили YT/GV/QUIC при включении тумблера не меняются ни на байт.
#      Это прямая проверка пункта 2 с другой стороны.
#   4. Найденное подключено обратно: тот же файл объявлен обычным --hostlist
#      у rkn_tcp и у профиля 80-го порта — иначе движок бы находил домены и
#      ничего с ними не делал.
#   5. Пороги: заданные в config доезжают до аргументов, незаданные не
#      добавляются вовсе (дефолт держит движок).
#   6. Слив автолиста забирает находки ПЕРЕИМЕНОВАНИЕМ и не теряет их, а
#      whitelist вычитается ДО показа человеку.
#   7. Файл создаётся с правами для WS_USER: демон роняет привилегии в nobody,
#      а файл создаёт root — без chown движок молча не может дописать домен.
#
# POSIX sh. Настоящий генератор и настоящие функции init-скрипта исполняются на
# временном дереве; сервис не запускается.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CFG="$ROOT/lib/config_official.sh"
INIT="$ROOT/files/S99zapret2.new"
for f in "$CFG" "$INIT"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$CFG" >/dev/null 2>&1

# --- мок-дерево и прогон настоящего генератора -------------------------------
gen() {   # $1 — содержимое config; печатает NFQWS2_OPT
    local root="$TMP/root"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" \
             "$root/lists" "$root/ipset"
    echo "youtube.com"      > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com"  > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"      > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"    > "$root/extra_strats/TCP/RKN/List.txt"
    echo "bank.example.com" > "$root/lists/whitelist.txt"
    printf '%s\n' '--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:strategy=1' \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    printf '%s\n' "$1" > "$root/config"
    ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null )
}

OFF=$(gen 'Z2K_AUTOHOSTLIST=0')
ON=$(gen 'Z2K_AUTOHOSTLIST=1')

# --- 1. Флаг доезжает --------------------------------------------------------
_n_off=$(printf '%s' "$OFF" | grep -c -- '--hostlist-auto=')
_n_on=$(printf '%s' "$ON"  | grep -c -- '--hostlist-auto=')
[ "$_n_off" = "0" ] && ok "выключен — --hostlist-auto не эмитится" \
    || no "выключен — нет --hostlist-auto" "0" "$_n_off"
[ "$_n_on" = "1" ] && ok "включён — ровно один --hostlist-auto" \
    || no "включён — один --hostlist-auto" "1" "$_n_on"

# --- 2. Детектор — последний профиль ----------------------------------------
#
# Профили в выводе идут по строке на профиль. Автолист обязан быть в ПОСЛЕДНЕЙ.
_last=$(printf '%s\n' "$ON" | grep -v '^"$' | grep -v '^NFQWS2_OPT=' | sed '/^$/d' | tail -1)
case "$_last" in
    *--hostlist-auto=*) ok "детектор — последний профиль" ;;
    *) no "детектор последний" "--hostlist-auto в последней строке" "$(printf '%s' "$_last" | cut -c1-80)" ;;
esac

# --- 3. Профили YouTube/GV/QUIC не изменились --------------------------------
for _marker in 'TCP/YT/List.txt' 'TCP/YT_GV/List.txt' 'UDP/YT/List.txt'; do
    _a=$(printf '%s\n' "$OFF" | grep -F "$_marker" | head -1)
    _b=$(printf '%s\n' "$ON"  | grep -F "$_marker" | head -1)
    if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then
        ok "профиль с $_marker не тронут включением тумблера"
    else
        no "профиль с $_marker не тронут" "побайтно тот же" "разошлись"
    fi
done

# --- 4. Найденное подключено обратно ----------------------------------------
_auto_path=$(printf '%s' "$ON" | tr ' ' '\n' | sed -n 's/^--hostlist-auto=//p' | head -1)
if [ -n "$_auto_path" ]; then
    ok "путь автолиста определён: ${_auto_path##*/}"
else
    no "путь автолиста" "непустой" "пусто"
fi
_rkn_line=$(printf '%s\n' "$ON" | grep -F 'key=rkn_tcp' | grep -v -- '--filter-tcp=80' | head -1)
case "$_rkn_line" in
    *"--hostlist=$_auto_path"*) ok "автолист подключён к rkn_tcp обычным хостлистом" ;;
    *) no "автолист в rkn_tcp" "--hostlist=$_auto_path" "нет — найденное никто не обходит" ;;
esac
_http_line=$(printf '%s\n' "$ON" | grep -F -- '--filter-tcp=80' | head -1)
case "$_http_line" in
    *"--hostlist=$_auto_path"*) ok "автолист подключён к профилю 80-го порта" ;;
    *) no "автолист в http-профиле" "--hostlist=$_auto_path" "нет" ;;
esac
# И обратное: при выключенном тумблере путь не всплывает нигде.
case "$OFF" in
    *zapret-hosts-auto.txt*) no "выключен — автолист нигде не упомянут" "нет упоминаний" "есть" ;;
    *) ok "выключен — автолист не упомянут вовсе" ;;
esac

# --- 5. Пороги ---------------------------------------------------------------
TUNED=$(gen 'Z2K_AUTOHOSTLIST=1
AUTOHOSTLIST_FAIL_THRESHOLD=7
AUTOHOSTLIST_RETRANS_RESET=0')
case "$TUNED" in
    *--hostlist-auto-fail-threshold=7*) ok "заданный порог доезжает до движка" ;;
    *) no "порог доезжает" "--hostlist-auto-fail-threshold=7" "нет" ;;
esac
case "$TUNED" in
    *--hostlist-auto-retrans-reset=0*) ok "retrans-reset=0 доезжает (значение 0 не теряется)" ;;
    *) no "retrans-reset=0" "--hostlist-auto-retrans-reset=0" "нет — ноль потерян как «пусто»" ;;
esac
case "$ON" in
    *--hostlist-auto-*=*) no "без настроек порогов нет" "только --hostlist-auto=" "лишние флаги порогов" ;;
    *) ok "без настроек пороги не эмитятся — дефолт держит движок" ;;
esac

# --- 6. Слив автолиста -------------------------------------------------------
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}
{
    extract_fn normalize_autohost_domains "$INIT"
    extract_fn sync_autohostlist_to_rkn "$INIT"
} > "$TMP/sync.sh"

SR="$TMP/sync-root"
mkdir -p "$SR/ipset" "$SR/lists" "$SR/extra_strats/TCP/RKN"
printf 'meduza.io\n'      > "$SR/ipset/zapret-hosts-auto.txt"
printf 'rutracker.org\n'  > "$SR/lists/autohostlist-domains.txt"
printf 'bank.example.com\n' > "$SR/lists/whitelist.txt"
printf 'already.example\n' > "$SR/extra_strats/TCP/RKN/List.txt"
# Домен, который человек уже занёс в whitelist, но движок успел найти раньше.
printf 'bank.example.com\n' >> "$SR/ipset/zapret-hosts-auto.txt"

(
    ZAPRET_BASE="$SR"; WS_USER=""
    # shellcheck source=/dev/null
    . "$TMP/sync.sh"
    sync_autohostlist_to_rkn
) > "$TMP/sync.log" 2>&1

_keep=$(sort "$SR/lists/autohostlist-domains.txt" 2>/dev/null | tr '\n' ' ')
_rkn=$(sort "$SR/extra_strats/TCP/RKN/List.txt" 2>/dev/null | tr '\n' ' ')
_auto=$(cat "$SR/ipset/zapret-hosts-auto.txt" 2>/dev/null)

[ "$_keep" = "meduza.io rutracker.org " ] \
    && ok "накопленное = находка ∪ прежнее, без whitelist" \
    || no "накопленное" "meduza.io rutracker.org" "$_keep"
case "$_rkn" in
    *meduza.io*rutracker.org*) ok "оба домена влиты в РКН-список" ;;
    *) no "влито в РКН-список" "meduza.io и rutracker.org" "$_rkn" ;;
esac
case "$_rkn" in
    *bank.example.com*) no "whitelist не попадает в РКН-список" "нет bank.example.com" "есть" ;;
    *) ok "домен из whitelist в РКН-список не попал" ;;
esac
[ -f "$SR/ipset/zapret-hosts-auto.txt" ] && [ -z "$_auto" ] \
    && ok "исходник забран и оставлен пустым (файл на месте — иначе демон не стартует)" \
    || no "исходник забран" "пустой существующий файл" "[$_auto] exists=$([ -f "$SR/ipset/zapret-hosts-auto.txt" ] && echo да || echo нет)"
# Забирать надо ПЕРЕИМЕНОВАНИЕМ: чтение с последующим обнулением теряет всё,
# что движок допишет между этими двумя моментами.
if grep -q 'mv -f "\$auto" "\$drain"' "$INIT"; then
    ok "находки забираются переименованием, а не «прочитать и обнулить»"
else
    no "drain через rename" "mv -f \$auto \$drain" "нет — гонка с движком"
fi

# --- 7. Права на файл для WS_USER -------------------------------------------
_ens=$(extract_fn ensure_autohostlist_files "$INIT")
case "$_ens" in
    *'chown "$WS_USER" "$auto"'*) ok "автолист отдаётся во владение WS_USER" ;;
    *) no "chown автолиста" "chown \$WS_USER" "нет — nobody не сможет дописать домен" ;;
esac
# Отладочный лог не должен обнуляться, когда отладку никто не включал.
if printf '%s' "$_ens" | grep -q 'AUTOHOSTLIST_DEBUGLOG" = "1" \] && \[ -f'; then
    no "лог не трётся при выключенной отладке" "условие через if" "старое A && B || C"
else
    ok "отладочный лог не обнуляется при выключенной отладке"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
