#!/bin/sh
# tests/test_preflight_wiring.sh — цепочка проверки DPI отдельным соединением
# целиком: от доставки файла до правила NAT, которым механизм дышит.
#
# ПОЧЕМУ ЦЕПОЧКОЙ. У шага четыре независимых звена в разных файлах: lua-файл,
# его загрузка в движок и правило NAT в S99, инстанс в профиле googlevideo в
# генераторе. Любое одно ломает механизм молча: служба зелёная, конфиг валиден,
# а видео стоит.
#
# Каждое звено проверяется ИСПОЛНЕНИЕМ кода, а не поиском строки.
# POSIX sh (busybox ash).

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

LUA_FILE="$ROOT/files/lua/z2k-preflight.lua"
TMP="${TMPDIR:-/tmp}/z2k-preflight-wiring.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- 1. Файл есть и это рабочий Lua ------------------------------------------
[ -f "$LUA_FILE" ] && ok "lua-файл механизма на месте" || bad "нет $LUA_FILE"

LUA=$(command -v lua5.3 || command -v lua5.4 || command -v lua || true)
if [ -n "$LUA" ]; then
    if "$LUA" -e "assert(loadfile('$LUA_FILE'))" 2>"$TMP/lua.err"; then
        ok "lua-файл компилируется"
    else
        bad "lua-файл не компилируется: $(cat "$TMP/lua.err")"
    fi
    # Функция, на которую ссылается профиль, обязана появиться в _G: именно по
    # имени её ищет движок, и опечатка здесь = error() на каждом пакете.
    if "$LUA" -e "
        DLOG=function() end
        dofile('$LUA_FILE')
        assert(type(z2k_preflight)=='function', 'z2k_preflight не объявлена глобально')
        assert(type(z2k_pf_flows)=='table', 'нет таблицы состояний')
    " 2>"$TMP/lua2.err"; then
        ok "движок найдёт z2k_preflight по имени"
    else
        bad "функция профиля не объявлена: $(cat "$TMP/lua2.err")"
    fi
else
    printf '[SKIP] нет lua — компиляция файла не проверена\n'
fi

# --- 2. Движок получает файл на старте ---------------------------------------
# Блок LUAOPT из S99 исполняется как есть, с подставным ZAPRET_BASE: сначала с
# файлом на диске, потом без него. Второй случай — не придирка: патч заменяет
# файлы, но не создаёт их, и на роутере, где файла нет, --lua-init на него
# означал бы, что движок не стартует вообще.
S99="$ROOT/files/S99zapret2.new"
PREFLIGHT_BLOCK=$(sed -n '/^LUA_Z2K_PREFLIGHT=/,/^\[ -f "\$LUA_Z2K_PREFLIGHT" \]/p' "$S99")
if [ -n "$PREFLIGHT_BLOCK" ]; then
    mkdir -p "$TMP/base/lua"
    : > "$TMP/base/lua/z2k-preflight.lua"
    WITH=$(ZAPRET_BASE="$TMP/base" LUAOPT="" sh -c "$PREFLIGHT_BLOCK"'; printf "%s" "$LUAOPT"')
    rm -f "$TMP/base/lua/z2k-preflight.lua"
    WITHOUT=$(ZAPRET_BASE="$TMP/base" LUAOPT="" sh -c "$PREFLIGHT_BLOCK"'; printf "%s" "$LUAOPT"')
    has "--lua-init=@$TMP/base/lua/z2k-preflight.lua" "$WITH" \
        && ok "S99 грузит файл, когда он есть" \
        || bad "S99 не добавил --lua-init: '$WITH'"
    [ -z "$WITHOUT" ] && ok "без файла S99 ничего не добавляет" \
        || bad "S99 ссылается на отсутствующий файл: '$WITHOUT'"
else
    bad "в S99 нет блока загрузки z2k-preflight.lua"
fi

# --- 3. Правило NAT для повторного SYN ---------------------------------------
# Функция, владеющая нашей цепочкой nat, исполняется с подставным iptables.
# Правило обязано идти за СОБРАННЫМ конфигом: флаг, изменённый без пересборки,
# не должен снимать правило при живом шаге.
NAT_FN=$(awk '/^z2k_udp_masquerade_fix_start\(\)/{p=1} p{print} p&&/^}/{exit}' "$S99")
if [ -n "$NAT_FN" ]; then
    nat_rules() {
        NFQWS2_OPT="$1" Z2K_GV_SERVER_REPLY2="$2" sh -c '
            z2k_fw_is_iptables() { return 0; }
            exists() { return 0; }
            get_wan_ifaces4() { printf "ppp0"; }
            iptablesw() { printf "%s\n" "$*"; }
            Z2K_IPT_NAT_CHAIN=zapret2_nat
            DESYNC_MARK=0x40000000
            '"$NAT_FN"'
            z2k_udp_masquerade_fix_start
        '
    }
    STEP_OPT="--filter-tcp=443 --lua-desync=z2k_preflight:pieces=6 --new"
    ON=$(nat_rules "$STEP_OPT" 1)
    OFF=$(nat_rules "--filter-tcp=443 --new" 1)
    STALE=$(nat_rules "$STEP_OPT" 0)
    has "-p tcp --dport 443 -j MASQUERADE" "$ON" \
        && ok "шаг в конфиге: правило NAT ставится" \
        || bad "нет правила NAT для TCP :443: $ON"
    has "-m mark --mark 0x40000000/0x40000000 -p tcp" "$ON" \
        && ok "правило NAT берёт только помеченные движком пакеты" \
        || bad "правило NAT не ограничено меткой движка: $ON"
    has "-p udp -j MASQUERADE" "$OFF" \
        && ok "без шага правило UDP остаётся" \
        || bad "снято чужое правило UDP: $OFF"
    has "-p tcp --dport 443 -j MASQUERADE" "$OFF" \
        && bad "шага нет, а правило NAT стоит: $OFF" \
        || ok "без шага правила NAT нет"
    has "-p tcp --dport 443 -j MASQUERADE" "$STALE" \
        && ok "флаг без пересборки не снимает правило при живом шаге" \
        || bad "шаг в конфиге остался без правила NAT: $STALE"
else
    bad "в S99 не нашлась функция цепочки nat"
fi

# --- 3б. Тумблер панели --------------------------------------------------------
# Настоящие функции панели с подставной службой: флаг, пересборка, перезапуск.
TG="$TMP/tg"; mkdir -p "$TG"; CALLS="$TG/calls"; : > "$CALLS"
ACT="$ROOT/webpanel/cgi/actions.sh"
TGFN=$(awk '/^toggle_gv_preflight\(\)/{p=1} p{print} p&&/^}/{exit}' "$ACT")
if [ -n "$TGFN" ]; then
    run_toggle() {
        CALLS="$CALLS" GENRC="$2" sh -c '
            CONFIG_FILE=/dev/null
            set_flag() { echo "flag:$1=$2" >> "$CALLS"; }
            regenerate_config() { echo regen >> "$CALLS"; return "$GENRC"; }
            restart_service_if_running() { echo restart >> "$CALLS"; }
            '"$TGFN"'
            toggle_gv_preflight "$0"
        ' "$1"
    }
    run_toggle 0 0 && _rc=0 || _rc=1
    [ "$_rc" = 0 ] && [ "$(tr '\n' ' ' < "$CALLS")" = "flag:Z2K_GV_SERVER_REPLY2=0 regen restart " ] \
        && ok "тумблер: флаг, пересборка, перезапуск по порядку" \
        || bad "тумблер: rc=$_rc, вызовы: $(tr '\n' ' ' < "$CALLS")"
    : > "$CALLS"
    run_toggle 0 1 && _rc=0 || _rc=1
    if [ "$_rc" = 1 ] && ! grep -q restart "$CALLS"; then
        ok "тумблер: сбой пересборки не перезапускает службу"
    else
        bad "тумблер: сбой пересборки, rc=$_rc, вызовы: $(tr '\n' ' ' < "$CALLS")"
    fi
    : > "$CALLS"
    run_toggle maybe 0 && _rc=0 || _rc=1
    [ "$_rc" = 1 ] && [ ! -s "$CALLS" ] \
        && ok "тумблер: мусорное значение отвергнуто" \
        || bad "тумблер принял мусор: rc=$_rc"
else
    bad "в панели нет toggle_gv_preflight"
fi
grep -q '"POST /toggle/gv-preflight"' "$ROOT/webpanel/cgi/api.sh" \
    && grep -q '_toggle_fn=toggle_gv_preflight' "$ROOT/webpanel/cgi/api.sh" \
    && ok "маршрут панели ведёт в тумблер" \
    || bad "в api.sh нет маршрута тумблера"

# --- 4. Инстанс попадает ТОЛЬКО в профиль googlevideo ------------------------
# Генератор исполняется в песочнице. Профиль googlevideo обязан получить шаг
# ПЕРЕД своими --in-range/--out-range: окно перехвата a/a нужно шагу на время
# пробы, а ротатору и плечам — родные диапазоны пула, иначе ротация считает
# успехи и провалы по чужой полосе.
. "$ROOT/lib/utils.sh" 2>/dev/null
. "$ROOT/lib/config_official.sh" 2>/dev/null

gen() { # $1 - тег, $2 - строка конфига, $3 - наличие lua, $4 - полная регенерация
    local root="$TMP/gen-$1"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" \
             "$root/lists" "$root/lua"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    { echo "ENABLED=1"; [ -n "$2" ] && echo "$2"; } > "$root/config"
    [ "$3" = "1" ] && cp "$LUA_FILE" "$root/lua/z2k-preflight.lua"
    if [ "${4:-0}" = 1 ]; then
        ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 ) || return 1
        cat "$root/config"
    else
        ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null )
    fi
    rm -rf "$root"
}

OPT_ON=$(gen on "Z2K_GV_SERVER_REPLY2=1" 1)
GV_LINE=$(printf '%s\n' "$OPT_ON" \
    | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" | grep -F 'key=gv_tcp' | head -1)
YT_LINE=$(printf '%s\n' "$OPT_ON" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" \
    | grep -F 'key=yt_tcp' | head -1)
RKN_LINE=$(printf '%s\n' "$OPT_ON" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" \
    | grep -F 'key=rkn_tcp' | head -1)
QUIC_LINE=$(printf '%s\n' "$OPT_ON" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" \
    | grep -F 'key=quic' | head -1)

if [ -n "$GV_LINE" ]; then
    has "--lua-desync=z2k_preflight:pos=none:" "$GV_LINE" \
        && ok "проба googlevideo отправляет целый ClientHello (#1374)" \
        || bad "проба googlevideo режет ClientHello: $GV_LINE"
    has "--lua-desync=z2k_preflight:" "$GV_LINE" \
        && ok "шаг попал в профиль googlevideo" \
        || bad "шага нет в профиле googlevideo: $GV_LINE"
    # Позиция: шаг раньше ротатора, и диапазоны пула идут ПОСЛЕ шага.
    _before=${GV_LINE%%--lua-desync=z2k_preflight:*}
    _after=${GV_LINE#*--lua-desync=z2k_preflight:}
    has "--lua-desync=circular:" "$_after" \
        && ok "шаг стоит перед ротатором" \
        || bad "шаг оказался после ротатора: $GV_LINE"
    has "--in-range=-s" "$_after" \
        && ok "родные диапазоны пула идут после шага" \
        || bad "после шага нет диапазонов пула — ротатор получит окно шага: $GV_LINE"
    has "--in-range=-s" "$_before" \
        && bad "шаг поставлен после диапазонов пула и переопределил их: $GV_LINE" \
        || ok "шаг не перебивает диапазоны пула"
    has "--in-range=a --out-range=a --payload=all --lua-desync=z2k_preflight:" "$GV_LINE" \
        && ok "шаг получил своё окно перехвата" \
        || bad "у шага нет окна a/a: $GV_LINE"
else
    bad "в сгенерированном конфиге нет профиля googlevideo"
fi

# --- 4б. Профиль по адресам из ответов DNS ------------------------------------
# Первое соединение к новому адресу движок не знает по имени: профиль по
# --ipset (файл пишет служба подмены) ведёт его через пробу. Обязан стоять
# ПЕРЕД профилем по списку имён и нести тот же шаг (10.11.2026).
FLAT_ON=$(printf '%s\n' "$OPT_ON" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk")
IPSET_N=$(printf '%s\n' "$FLAT_ON" | grep -n -F -- '--ipset=/tmp/z2k-gv-ips.txt' | head -1 | cut -d: -f1)
HOST_N=$(printf '%s\n' "$FLAT_ON" | grep -n -F -- 'YT_GV/List.txt' | grep -v -F -- '--ipset=' | head -1 | cut -d: -f1)
IPSET_LINE=$(printf '%s\n' "$FLAT_ON" | grep -F -- '--ipset=/tmp/z2k-gv-ips.txt' | head -1)
if [ -n "$IPSET_N" ]; then
    has "--lua-desync=z2k_preflight:pos=none:" "$IPSET_LINE" \
        && ok "проба по адресам отправляет целый ClientHello (#1374)" \
        || bad "проба по адресам режет ClientHello: $IPSET_LINE"
    has "--hostlist" "$IPSET_LINE" \
        && bad "в профиле по адресам есть hostlist (включая exclude): $IPSET_LINE" \
        || ok "профиль по адресам без --hostlist и --hostlist-exclude"
    has "--lua-desync=z2k_preflight:" "$IPSET_LINE" && has "key=gv_tcp" "$IPSET_LINE" \
        && ok "профиль по адресам несёт шаг и ротатор googlevideo" \
        || bad "в профиле по адресам нет шага или ротатора: $IPSET_LINE"
    [ -n "$HOST_N" ] && [ "$IPSET_N" -lt "$HOST_N" ] \
        && ok "профиль по адресам стоит перед профилем по именам" \
        || bad "профиль по адресам после профиля по именам ($IPSET_N / $HOST_N)"
else
    bad "нет профиля googlevideo по адресам из ответов DNS"
fi
has "--ipset=/tmp/z2k-gv-ips.txt" "$(gen nosub "Z2K_GV_SUBST=0" 1)" \
    && bad "служба подмены выключена, а профиль по адресам остался" \
    || ok "Z2K_GV_SUBST=0 — профиля по адресам нет (файл некому наполнять)"
has "--ipset=/tmp/z2k-gv-ips.txt" "$(gen nostep "Z2K_GV_SERVER_REPLY2=0" 1)" \
    && bad "шаг выключен, а профиль по адресам остался" \
    || ok "без шага профиля по адресам нет"

for _p in "yt_tcp:$YT_LINE" "rkn_tcp:$RKN_LINE" "quic:$QUIC_LINE"; do
    _name=${_p%%:*}; _line=${_p#*:}
    [ -n "$_line" ] || continue
    has "z2k_preflight" "$_line" \
        && bad "шаг просочился в профиль $_name" \
        || ok "в профиле $_name шага нет"
done

# --- 5. Выключатель и отсутствующий файл ------------------------------------
# Умолчание этой версии — включено: без ключа шаг в конфиге есть.
OPT_ABSENT=$(gen absent "" 1)
has "z2k_preflight" "$OPT_ABSENT" \
    && ok "без ключа шаг есть: по умолчанию включено" \
    || bad "без ключа шага нет (умолчание должно быть включено)"
OPT_OFF=$(gen off "Z2K_GV_SERVER_REPLY2=0" 1)
has "z2k_preflight" "$OPT_OFF" \
    && bad "Z2K_GV_SERVER_REPLY2=0 не убрал шаг из конфига" \
    || ok "Z2K_GV_SERVER_REPLY2=0 убирает шаг из конфига"
# Разовое включение у всех (p-87.24): прежний ключ Z2K_GV_PREFLIGHT=0 шаг не убирает.
OPT_OLD0=$(gen old0 "Z2K_GV_PREFLIGHT=0" 1)
has "z2k_preflight" "$OPT_OLD0" \
    && ok "старый Z2K_GV_PREFLIGHT=0 не выключает: включено у всех" \
    || bad "старый Z2K_GV_PREFLIGHT=0 всё ещё выключает шаг"
# Исполняем полную регенерацию, включая сборку NFQWS2_OPT и запись флагов.
for _old in Z2K_GV_PREFLIGHT Z2K_GV_SERVER_REPLY; do
    REGEN=$(gen "regen-$_old" "$_old=0" 1 1) || bad "ошибка регенерации $_old"
    has "--lua-desync=z2k_preflight:" "$REGEN" \
        && ok "регенерация $_old=0: проба включена" \
        || bad "регенерация $_old=0: проба выключена"
    printf '%s\n' "$REGEN" | grep -Eq '^Z2K_GV_(PREFLIGHT|SERVER_REPLY)=' \
        && bad "регенерация перенесла устаревший ключ $_old" \
        || ok "регенерация удаляет устаревшие ключи"
    has "Z2K_GV_SERVER_REPLY2=0" "$REGEN" \
        && bad "регенерация перенесла старый ноль в новый ключ" \
        || ok "новый ключ не выключен старым нулём"
done
for _want in 0 1; do
    # Старые нули не должны перебивать новый осознанный выбор.
    REGEN=$(gen "regen-new$_want" "Z2K_GV_SERVER_REPLY2=$_want
Z2K_GV_SERVER_REPLY=0
Z2K_GV_PREFLIGHT=0" 1 1) || bad "ошибка регенерации нового ключа =$_want"
    printf '%s\n' "$REGEN" | grep -q "^Z2K_GV_SERVER_REPLY2=$_want$" \
        && ok "новый ключ =$_want сохраняется при регенерации" \
        || bad "регенерация потеряла новый ключ =$_want"
    if [ "$_want" = 0 ]; then
        has "--lua-desync=z2k_preflight:" "$REGEN" \
            && bad "новый ноль не убрал пробу из NFQWS2_OPT" \
            || ok "новый ноль убирает пробу из NFQWS2_OPT"
    else
        has "--lua-desync=z2k_preflight:" "$REGEN" \
            && ok "новая единица включает пробу в NFQWS2_OPT" \
            || bad "новая единица не включила пробу"
    fi
done

OPT_NOFILE=$(gen nofile "Z2K_GV_SERVER_REPLY2=1" 0)
has "z2k_preflight" "$OPT_NOFILE" \
    && bad "шаг объявлен, хотя lua-файла на диске нет — движок упадёт в error()" \
    || ok "без lua-файла шаг в конфиг не попадает"

# --- 6. Валидатор знает действие --------------------------------------------
# Иначе человек с рабочим конфигом получает предупреждение о «неизвестном
# действии» и идёт искать опечатку, которой нет.
VAL_OUT=$(
    mkdir -p "$TMP/val"
    printf 'NFQWS2_OPT="--filter-tcp=443 --lua-desync=z2k_preflight:pieces=6"\n' > "$TMP/val/config"
    sh "$ROOT/files/z2k-config-validator.sh" "$TMP/val/config" 2>&1
)
has "Неизвестное lua-desync действие: 'z2k_preflight'" "$VAL_OUT" \
    && bad "валидатор не знает z2k_preflight" \
    || ok "валидатор знает z2k_preflight"

# --- 7. Установщик кладёт файл ----------------------------------------------
# Полная установка обязана скачать файл: без него профиль ссылается на функцию,
# которой нет, и движок валится на каждом пакете googlevideo.
grep -q 'files/lua/z2k-preflight.lua' "$ROOT/z2k.sh" \
    && ok "установщик скачивает lua-файл" \
    || bad "z2k.sh не скачивает files/lua/z2k-preflight.lua"

# Релиз доставляет файл туда же, где его ищут движок и генератор, и объявляет
# перезапуск службы: без него новый файл лёг бы на диск, а в памяти остался
# прежний процесс без шага — ровно так однажды приехал и не включился r-81.
# Проверяем КАРТУ РЕЛИЗА, а не UPDATES.json: карту сумм пересобирает сам релиз
# (scripts/release.sh → gen_file_hashes.sh), и в рабочем дереве нового файла в
# ней законно ещё нет.
MAP=$(sh -c ". '$ROOT/lib/release_map.sh' 2>/dev/null
    z2k_install_paths files/lua/z2k-preflight.lua | tr '\n' '|'")
[ "$MAP" = "/opt/zapret2/lua/z2k-preflight.lua|" ] \
    && ok "релиз доставляет файл по тому же пути" \
    || bad "релиз доставляет не туда: '$MAP'"

STEPS=$(sh -c ". '$ROOT/lib/release_map.sh' 2>/dev/null
    z2k_steps_for files/lua/z2k-preflight.lua | tr '\n' ' '")
has "restart-service" "$STEPS" \
    && ok "обновление файла перезапускает службу" \
    || bad "обновление файла не объявляет перезапуск: '$STEPS'"

DELIV=$(sh -c ". '$ROOT/lib/release_map.sh' 2>/dev/null
    z2k_is_deliverable files/lua/z2k-preflight.lua && echo 1 || echo 0")
[ "$DELIV" = "1" ] \
    && ok "файл объявлен доставляемым" \
    || bad "файл не доставляется релизом вовсе"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
