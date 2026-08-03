#!/bin/sh
# tests/test_custom_strategies.sh
#
# Two user requests: a switch for the auto-hostlist mode, and the ability to run
# one's own strategy instead of the rotator.
#
# The dangerous half is the second one. nfqws2 parses every profile as ONE option
# string and refuses to start if any part of it is wrong — so a typo in a line
# written for the RKN pool does not degrade that pool, it stops the bypass
# entirely. Hence the rules asserted here:
#
#   * a candidate is validated against the WHOLE generated option string, not the
#     fragment alone;
#   * validation must leave NO trace — a failed check on a router that is
#     currently fine must leave it fine;
#   * a rejected line is not saved and is NOT silently replaced by the shipped
#     one, which would leave the user certain their strategy is live;
#   * the custom line is re-read on EVERY regeneration, or the first toggle in
#     the panel would quietly restore the shipped strategy.
#
# And the storage rule: user lines live beside whitelist/extra-domains, never in
# shipped Strategy.txt — edits to those are wiped by update by design.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
CFG="$HERE/lib/config_official.sh"
ACTIONS="$HERE/webpanel/cgi/actions.sh"
API="$HERE/webpanel/cgi/api.sh"
MENU="$HERE/lib/menu.sh"
APPJS="$HERE/webpanel/www/app.js"
INST="$HERE/lib/install.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cstrat.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

for f in "$CFG" "$ACTIONS" "$API" "$MENU" "$APPJS" "$INST"; do
    [ -f "$f" ] || { printf '[FAIL] missing %s\n' "$f"; exit 1; }
done

# ---------------------------------------------------------------------------
# A fake install root with a stub engine and a stub generator, so the real
# handlers can be driven without a router.
# ---------------------------------------------------------------------------
ZD="$TMP/opt/zapret2"
mkdir -p "$ZD/lists/custom-strategies" "$ZD/nfq2" "$ZD/lib"
printf 'ENABLED=1\n' > "$ZD/config"
# Engine stub: rejects anything containing NOPE, like the real one rejects an
# unknown --lua-desync (verified on hardware: rc 1).
printf '#!/bin/sh\ncase "$*" in *NOPE*) echo "unrecognized option"; exit 1 ;; esac\nexit 0\n' > "$ZD/nfq2/nfqws2"
chmod +x "$ZD/nfq2/nfqws2"
cat > "$ZD/lib/config_official.sh" <<'STUB'
create_official_config() {
  d=$(cat "${ZAPRET2_DIR}/lists/custom-strategies/rkn_tcp.txt" 2>/dev/null | tr '\n' ' ')
  printf 'NFQWS2_OPT="\n--filter-tcp=443 %s\n"\n' "$d" > "$1"
}
STUB

cgi() {
    _m="$1"; _p="$2"; _q="$3"; _b="$4"
    if [ -n "$_b" ]; then
        printf '%s' "$_b" | env -i PATH="$PATH" ZAPRET2_DIR="$ZD" CONFIG_FILE="$ZD/config" \
            LISTS_DIR="$ZD/lists" REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" CONTENT_LENGTH="${#_b}" sh "$API" 2>&1 | tail -1
    else
        env -i PATH="$PATH" ZAPRET2_DIR="$ZD" CONFIG_FILE="$ZD/config" \
            LISTS_DIR="$ZD/lists" REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" CONTENT_LENGTH=0 sh "$API" 2>&1 | tail -1
    fi
}
LIVE="$ZD/lists/custom-strategies/rkn_tcp.txt"

# --- validation ---------------------------------------------------------------
out=$(cgi POST /strategy/pool/validate 'pool=rkn_tcp' '--lua-desync=fake:dir=out')
case "$out" in *'"valid":true'*) ok "корректная строка проходит проверку" ;;
               *) no "корректная строка проходит проверку" '"valid":true' "$out" ;; esac

out=$(cgi POST /strategy/pool/validate 'pool=rkn_tcp' 'NOPE')
case "$out" in *'"valid":false'*) ok "битая строка не проходит" ;;
               *) no "битая строка не проходит" '"valid":false' "$out" ;; esac
case "$out" in *unrecognized*) ok "в ответе видна причина от движка" ;;
               *) no "в ответе видна причина от движка" "текст ошибки" "$out" ;; esac

# The check itself must not become a way to change the router's state.
[ ! -f "$LIVE" ] && ok "проверка не оставляет следов (файл не создан)" \
                 || no "проверка не оставляет следов" "файла нет" "файл создан"

# --- saving --------------------------------------------------------------------
out=$(cgi POST /strategy/pool/save 'pool=rkn_tcp' 'NOPE')
case "$out" in *'"ok":false'*) ok "битая строка не сохраняется" ;;
               *) no "битая строка не сохраняется" '"ok":false' "$out" ;; esac
[ ! -f "$LIVE" ] && ok "после отказа файл не появился" \
                 || no "после отказа файл не появился" "файла нет" "есть"

out=$(cgi POST /strategy/pool/save 'pool=rkn_tcp' '--lua-desync=fake:dir=out')
case "$out" in *'"ok":true'*) ok "корректная строка сохраняется" ;;
               *) no "корректная строка сохраняется" '"ok":true' "$out" ;; esac
grep -q 'lua-desync=fake' "$LIVE" 2>/dev/null \
    && ok "сохранено именно то, что прислали" \
    || no "сохранено именно то, что прислали" "строка в файле" "нет"

# A rejected line must not damage a good one already in place.
cgi POST /strategy/pool/save 'pool=rkn_tcp' 'NOPE' >/dev/null 2>&1
grep -q 'lua-desync=fake' "$LIVE" 2>/dev/null \
    && ok "отказ не портит уже сохранённую строку" \
    || no "отказ не портит уже сохранённую строку" "прежняя строка на месте" "затёрта"

out=$(cgi GET /strategy/pools '')
case "$out" in *'"pool":"rkn_tcp","custom":1'*) ok "пул помечен как ручной" ;;
               *) no "пул помечен как ручной" 'custom:1' "$out" ;; esac
case "$out" in *'"pool":"yt_tcp","custom":0'*) ok "остальные пулы остались на автоподборе" ;;
               *) no "остальные пулы на автоподборе" 'yt_tcp custom:0' "$out" ;; esac

# --- reset ---------------------------------------------------------------------
cgi POST /strategy/pool/reset '' 'pool=rkn_tcp' >/dev/null 2>&1
[ ! -f "$LIVE" ] && ok "возврат на авто удаляет файл" \
                 || no "возврат на авто удаляет файл" "файла нет" "остался"

# --- hostile pool names --------------------------------------------------------
# The pool name becomes a filename.
for bad in ../etc/passwd 'rkn_tcp;rm' '' nosuchpool; do
    out=$(cgi POST /strategy/pool/save "pool=$bad" '--lua-desync=fake')
    case "$out" in *'"ok":false'*|*error*) : ;;
        *) no "враждебное имя пула отклонено: '$bad'" "отказ" "$out" ;; esac
done
ok "враждебные имена пулов отклонены"

# --- the generator prefers the user's line, every time -------------------------
# Re-read on each regeneration is the property: baking it once would mean the
# next toggle in the panel silently restores the shipped strategy.
GEN="$TMP/gen"; mkdir -p "$GEN/extra_strats/TCP/RKN" "$GEN/lists/custom-strategies"
printf 'SHIPPED --lua-desync=fake\n' > "$GEN/extra_strats/TCP/RKN/Strategy.txt"
resolve() {
    sh -c "ZAPRET2_DIR='$GEN'; extra_strats_dir='$GEN/extra_strats'
        $(awk '/^    z2k_custom_strategy\(\) \{/,/^    \}$/' "$CFG")
        rkn_tcp=\$(cat \"\$extra_strats_dir/TCP/RKN/Strategy.txt\")
        _cs=\$(z2k_custom_strategy rkn_tcp) && [ -n \"\$_cs\" ] && rkn_tcp=\"\$_cs\"
        printf '%s' \"\$rkn_tcp\""
}
case "$(resolve)" in SHIPPED*) ok "без своей строки берётся shipped" ;;
                     *) no "без своей строки берётся shipped" "SHIPPED…" "$(resolve)" ;; esac
printf -- '--lua-desync=split2\n' > "$GEN/lists/custom-strategies/rkn_tcp.txt"
case "$(resolve)" in *split2*) ok "своя строка побеждает shipped" ;;
                     *) no "своя строка побеждает shipped" "split2" "$(resolve)" ;; esac
# Same call again — the value must come from the file, not from a cache.
case "$(resolve)" in *split2*) ok "и на повторной перегенерации тоже (не запеклось один раз)" ;;
                     *) no "на повторной перегенерации тоже" "split2" "$(resolve)" ;; esac
# Multi-line with comments: people edit this in a textarea.
printf '# мой комментарий\n--lua-desync=fake\n--lua-desync=drop\n' > "$GEN/lists/custom-strategies/rkn_tcp.txt"
case "$(resolve)" in *"fake --lua-desync=drop"*) ok "многострочная запись с комментариями склеивается" ;;
                     *) no "многострочная запись склеивается" "одна строка без #" "$(resolve)" ;; esac
# Empty / comments-only must fall back rather than leave the pool with nothing.
printf '\n# только комментарий\n' > "$GEN/lists/custom-strategies/rkn_tcp.txt"
case "$(resolve)" in SHIPPED*) ok "файл без содержимого откатывается к shipped" ;;
                     *) no "файл без содержимого откатывается к shipped" "SHIPPED…" "$(resolve)" ;; esac

# The helper above proves z2k_custom_strategy WORKS; it does not prove it is
# WIRED IN, because the harness applies the override itself. Assert the wiring
# for every pool separately — deleting one line in the generator is otherwise
# invisible here, and that pool silently goes back to the shipped strategy.
_wired=0
for _pool in rkn_tcp yt_tcp gv_tcp yt_quic; do
    grep -q "z2k_custom_strategy $_pool" "$CFG" && _wired=$((_wired + 1))
done
[ "$_wired" = 4 ] && ok "подстановка подключена для всех четырёх пулов" \
                  || no "подстановка подключена для всех пулов" "4" "$_wired"

# --- shipped Strategy.txt stays shipped ----------------------------------------
# Editing those is wiped by update by design, so nothing here may write to them.
grep -qE '(>|cp -f|sed -i).*extra_strats/.*Strategy\.txt' "$ACTIONS" \
    && no "панель не пишет в shipped Strategy.txt" "не пишет" "пишет" \
    || ok "панель не пишет в shipped Strategy.txt"

# --- survives a reinstall -------------------------------------------------------
grep -q 'custom-strategies' "$INST" \
    && ok "install.sh знает про каталог своих стратегий" \
    || no "install.sh знает про каталог" "custom-strategies" "нет"
_b=$(grep -c 'cp -f "\$ZAPRET2_DIR/lists/custom-strategies/"\*\.txt' "$INST")
_r=$(grep -c 'cp -f "\$backup_tmp/custom-strategies/"\*\.txt' "$INST")
[ "$_b" = 1 ] && [ "$_r" = 1 ] \
    && ok "и сохраняет их, и восстанавливает" \
    || no "сохраняет и восстанавливает" "1 и 1" "$_b и $_r"

# --- auto-hostlist toggle --------------------------------------------------------
grep -q 'MODE_FILTER=\${z2k_mode_filter}' "$CFG" \
    && ok "MODE_FILTER больше не прибит гвоздями" \
    || no "MODE_FILTER не прибит" "подстановка" "литерал"
grep -q 'z2k_mode_filter=autohostlist' "$CFG" \
    && ok "флаг переключает режим на autohostlist" \
    || no "флаг переключает режим" "autohostlist" "нет"
grep -q 'safe_config_read "Z2K_AUTOHOSTLIST" "$config_file" "0"' "$CFG" \
    && ok "по умолчанию выключено (просили возможность, а не смену поведения)" \
    || no "по умолчанию выключено" 'default "0"' "иначе"
grep -q 'menu_autohostlist' "$MENU" \
    && ok "тумблер есть в консольном меню" \
    || no "тумблер есть в консольном меню" "menu_autohostlist" "нет"
grep -q 'toggle_autohostlist' "$ACTIONS" \
    && ok "и в панели" \
    || no "и в панели" "toggle_autohostlist" "нет"
# Switching the mode only means something after the config is rebuilt.
awk '/^toggle_autohostlist\(\)/,/^}/' "$ACTIONS" | grep -q 'regenerate_config' \
    && ok "переключение перегенерирует конфиг" \
    || no "переключение перегенерирует конфиг" "regenerate_config" "нет"
_rs=$(sed -n 's/.*TOGGLES_RESTART_SERVICE = {\(.*\)};.*/\1/p' "$APPJS")
case "$_rs" in *autohostlist*) ok "и перезапускает сервис" ;;
               *) no "перезапускает сервис" "autohostlist в списке" "$_rs" ;; esac

# --- the panel must not lie about restarts -------------------------------------
# Found the hard way: toggle_autohostlist regenerated the config but never
# restarted, while the UI showed a restart. The config then said one thing and
# the running daemon did another — the user's «переключил, а не применилось».
# The mirror case existed too: rst_filter restarted silently, so the bypass
# blipped with nothing on screen to explain it.
#
# So the invariant, for every toggle: the handler calling restart_service_if_running
# and the UI listing it must agree. Checked for all of them, not just the two
# that were wrong, because the next one will be a different one.
_ui_list=$(sed -n 's/.*TOGGLES_RESTART_SERVICE = {\(.*\)};.*/\1/p' "$APPJS")
_mismatch=""
for _fn in $(grep -oE '^toggle_[a-z_]+\(\)' "$ACTIONS" | sed 's/()//'); do
    _key=${_fn#toggle_}
    _body=$(awk "/^${_fn}\(\)/,/^}/" "$ACTIONS")
    _code=нет; printf '%s' "$_body" | grep -q 'restart_service_if_running' && _code=да
    _ui=нет; case "$_ui_list" in *"$_key"*) _ui=да ;; esac
    [ "$_code" = "$_ui" ] || _mismatch="$_mismatch $_key(код:$_code/UI:$_ui)"
done
[ -z "$_mismatch" ] && ok "код и интерфейс согласны по рестарту для всех тумблеров" \
                    || no "код и интерфейс согласны по рестарту" "нет расхождений" "$_mismatch"

# The same invariant, but NOT keyed on the `toggle_` prefix — which is exactly how
# it was escaped. strategy_pool_save/reset regenerated the config and never
# restarted, so the panel reported «Стратегия применена» while nfqws2 kept running
# the previous one: it receives NFQWS2_OPT as argv at start and never re-reads it.
# Rule: anything that regenerates the LIVE config must restart the service.
# Exempt are only the primitive itself and the two validation helpers, which write
# to a throwaway path precisely so a candidate cannot touch a working router.
_exempt=" regenerate_config regenerate_config_to strategy_validate "
_noresta=""
for _fn in $(grep -oE '^[a-z_]+\(\)' "$ACTIONS" | sed 's/()//'); do
    case "$_exempt" in *" $_fn "*) continue ;; esac
    _body=$(awk "/^${_fn}\(\)/,/^}/" "$ACTIONS")
    printf '%s' "$_body" | grep -q 'regenerate_config' || continue
    printf '%s' "$_body" | grep -q 'restart_service_if_running' \
        || _noresta="$_noresta $_fn"
done
[ -z "$_noresta" ] && ok "любой обработчик, пересобирающий живой конфиг, перезапускает сервис" \
                   || no "любой обработчик, пересобирающий живой конфиг, перезапускает сервис" \
                         "нет таких" "$_noresta"

# And specifically: switching the filtering mode without a restart writes a
# config the daemon is not running.
awk '/^toggle_autohostlist\(\)/,/^}/' "$ACTIONS" | grep -q 'restart_service_if_running' \
    && ok "переключение автохостлиста перезапускает сервис" \
    || no "переключение автохостлиста перезапускает сервис" "restart" "нет"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
