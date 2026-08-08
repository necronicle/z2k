#!/bin/sh
# tests/test_webpanel_actions_fixes.sh
#
# Обработчики панели (webpanel/cgi/actions.sh) пишут в живые файлы роутера из
# CGI, который lighttpd запускает ПАРАЛЛЕЛЬНО и может убить в любой момент.
# Здесь проверяется то, что от них требуется именно поэтому:
#
#   * проверка стратегии не открывает боевой файл на запись ВООБЩЕ — ни на
#     удачном кандидате, ни на битом (иначе убитый на полпути CGI оставляет
#     непроверенную строку в бою, а следующий тумблер запекает её в NFQWS2_OPT
#     и nfqws2 не стартует);
#   * пустая строка (и строка из одних комментариев) отвергается: генератор
#     такую молча заменяет штатной Strategy.txt, и человек остаётся с ротацией
#     под надписью «работает своя стратегия»;
#   * значение флага переживает `. config` — конфиг ИСПОЛНЯЕТСЯ, а имена
#     политик люди пишут по-русски и с пробелами;
#   * успешное выключение возвращает 0, иначе панель откатывает галочку с
#     «не получилось» поверх записанного флага;
#   * подмена файла не обнуляет цель и переносит на новый inode её режим и
#     ВЛАДЕЛЬЦА (state.tsv принадлежит nobody — под этим пользователем в него
#     пишет lua внутри nfqws2);
#   * удаляется и ЕДИНСТВЕННАЯ запись списка, а импорт в ПУСТОЙ список
#     что-то добавляет;
#   * дописывание в файл без завершающего перевода строки не склеивает записи;
#   * имя политики не принимает то, что портится по дороге, а лимит длины
#     считается в символах;
#   * живой лог задачи режется по границе символа;
#   * проверка обновлений ограничена по времени и не ходит в сеть после
#     недавней неудачи.
#
# Песочница в TMPDIR: без root, без сети, без обращений к настоящему /opt.
# POSIX sh.
#
# ACTIONS=<путь> — прогнать набор против другой копии обработчиков. Так
# проверяется, что каждое утверждение ПАДАЕТ на до-фиксовом коде: копия с
# возвращённым старым поведением кладётся в /tmp и гоняется этим набором.

HERE=$(cd "$(dirname "$0")/.." && pwd)
ACTIONS="${ACTIONS:-$HERE/webpanel/cgi/actions.sh}"
UTILS="$HERE/lib/utils.sh"
[ -f "$ACTIONS" ] || { printf '[FAIL] missing %s\n' "$ACTIONS"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wpafix.XXXXXX") || exit 1
# Мусор в НАСТОЯЩЕМ /tmp: пути job_log и теней зашиты в обработчиках, подменить
# их нечем, поэтому имена уникальны и снимаются здесь же.
ORPH="/tmp/z2k-strat-shadow.wpafixold$$"
ORPH_NEW="/tmp/z2k-strat-shadow.wpafixnew$$"
JID="wpafix$$"
trap 'rm -rf "$TMP" "$ORPH" "$ORPH_NEW" "/tmp/z2k-job-$JID.log"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { printf '[SKIP] %s (%s)\n' "$1" "$2"; }

# `sed -i EXPR FILE` shim. Продакшн-код использует busybox/GNU-форму, которая
# верна для роутера; BSD sed на маке ждёт после -i СУФФИКС и молча съел бы
# выражение как имя бэкапа, оставив файл нетронутым — то есть тест бы «прошёл»
# на неизменённом конфиге. Шим делает проверку верной роутеру, а не хосту.
BIN="$TMP/bin"; mkdir -p "$BIN"
REALSED=$(command -v sed)
cat > "$BIN/sed" <<SHIM
#!/bin/sh
if [ "\$1" = "-i" ]; then
    _expr=\$2; _file=\$3
    "$REALSED" "\$_expr" "\$_file" > "\$_file.shim" && mv "\$_file.shim" "\$_file"
    exit \$?
fi
exec "$REALSED" "\$@"
SHIM
chmod +x "$BIN/sed"
# curl-заглушка: набор обязан быть офлайновым. Без неё ветка деградации в
# проверке обновлений реально пошла бы в сеть.
cat > "$BIN/curl" <<CURLSTUB
#!/bin/sh
printf 'curl %s\n' "\$*" >> "$TMP/curl.calls"
exit 7
CURLSTUB
chmod +x "$BIN/curl"
PATH="$BIN:$PATH"; export PATH

# ---------------------------------------------------------------------------
# Фальшивый корень установки: движок-заглушка и генератор-заглушка, чтобы гонять
# настоящие обработчики без роутера.
# ---------------------------------------------------------------------------
ZD="$TMP/opt/zapret2"
mkdir -p "$ZD/lists/custom-strategies" "$ZD/nfq2" "$ZD/lib" "$ZD/extra_strats" "$ZD/ipset"
mkdir -p "$ZD/lists/warp"
: > "$ZD/lists/warp/.legacy-aggregate-purged"
printf 'ENABLED=1\n' > "$ZD/config"

# Движок: отвергает всё, где встретилось NOPE (настоящий так же отвергает
# неизвестный --lua-desync, проверено на железе: rc 1). Аргументы записывает,
# чтобы можно было посмотреть, ЧТО именно проверялось.
cat > "$ZD/nfq2/nfqws2" <<ENGINE
#!/bin/sh
printf '%s\n' "\$*" > "$ZD/dryrun.args"
case "\$*" in *NOPE*) echo "unrecognized option"; exit 1 ;; esac
exit 0
ENGINE
chmod +x "$ZD/nfq2/nfqws2"

# utils.sh-заглушка повторяет ключевое свойство настоящей: присваивает пути
# БЕЗУСЛОВНО. Если обработчик не вернёт свои значения после подключения, вся
# генерация уедет на /opt/zapret2 — и это здесь видно по результату.
cat > "$ZD/lib/utils.sh" <<'STUBU'
ZAPRET2_DIR="/opt/zapret2"
CONFIG_DIR="/opt/etc/zapret2"
LISTS_DIR="${ZAPRET2_DIR}/lists"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
export ZAPRET2_DIR CONFIG_DIR LISTS_DIR INIT_SCRIPT
STUBU

# Генератор-заглушка: собирает опции из пользовательской строки пула (или из
# «штатной», если её нет) И дочитывает флаг из config — так видно, что проверка
# идёт по настоящему дереву, а не по пустышке.
cat > "$ZD/lib/config_official.sh" <<'STUBC'
create_official_config() {
    _dest="$1"
    _en=$(grep '^ENABLED=' "${ZAPRET2_DIR}/config" 2>/dev/null | head -1)
    [ -n "$_en" ] || _en="NOFLAG"
    _cs="${ZAPRET2_DIR}/lists/custom-strategies/rkn_tcp.txt"
    _line="SHIPPED"
    if [ -s "$_cs" ]; then
        _got=$(awk '{ sub(/\r$/,""); sub(/^[[:space:]]*#.*$/,"") } NF { printf "%s ", $0 }' "$_cs" | sed 's/[[:space:]]*$//')
        [ -n "$_got" ] && _line="$_got"
    fi
    { printf '%s\n' "$_en"
      printf 'NFQWS2_OPT="\n--filter-tcp=443 %s flag:%s\n"\n' "$_line" "$_en"
    } > "$_dest"
}
STUBC

# init-скрипт: пишет, что его звали, и завершается успешно.
cat > "$TMP/init" <<INIT
#!/bin/sh
printf '%s\n' "\$1" >> "$TMP/init.calls"
exit 0
INIT
chmod +x "$TMP/init"

WL="$ZD/lists/whitelist.txt"
ED="$ZD/lists/extra-domains.txt"
EX="$ZD/ipset/zapret-hosts-user-exclude.txt"
LIVE="$ZD/lists/custom-strategies/rkn_tcp.txt"
WLD="$ZD/lists/warp"

# act <код> — выполнить код с загруженным actions.sh в песочнице.
# ACT_ENV — дополнительные присваивания, которые нужны одной проверке
# (свой config, свой кэш манифеста); выполняются ПОСЛЕ значений по умолчанию и
# ДО подключения обработчиков.
ACT_ENV=""
act() {
    ( ZAPRET2_DIR="$ZD"
      CONFIG_FILE="$ZD/config"
      LISTS_DIR="$ZD/lists"
      CUSTOM_STRAT_DIR="$ZD/lists/custom-strategies"
      WHITELIST_FILE="$WL"
      EXTRA_DOMAINS_FILE="$ED"
      EXCLUDE_FILE="$EX"
      WARP_LISTS_DIR="$WLD"
      INIT_SCRIPT="$TMP/init"
      WARP_SCRIPT="$TMP/nonexistent-warp.sh"
      export ZAPRET2_DIR CONFIG_FILE LISTS_DIR CUSTOM_STRAT_DIR WHITELIST_FILE \
             EXTRA_DOMAINS_FILE EXCLUDE_FILE WARP_LISTS_DIR INIT_SCRIPT WARP_SCRIPT
      eval "${ACT_ENV:-:}"
      # shellcheck disable=SC1090
      . "$ACTIONS"
      eval "$1" )
}

# actproc <код> — то же самое, но ОТДЕЛЬНЫМ процессом. lighttpd форкает CGI на
# каждый запрос, и уникальность временных файлов держится на $$; подоболочки
# одного процесса делят $$, поэтому конкуренцию ими проверять бессмысленно.
actproc() {
    env ZAPRET2_DIR="$ZD" CONFIG_FILE="$ZD/config" LISTS_DIR="$ZD/lists" \
        CUSTOM_STRAT_DIR="$ZD/lists/custom-strategies" WHITELIST_FILE="$WL" \
        EXTRA_DOMAINS_FILE="$ED" EXCLUDE_FILE="$EX" WARP_LISTS_DIR="$WLD" \
        INIT_SCRIPT="$TMP/init" WARP_SCRIPT="$TMP/nonexistent-warp.sh" PATH="$PATH" \
        sh -c ". \"$ACTIONS\"; $1"
}

# Права в переносимом виде: ls одинаково пишет их и на BSD, и на GNU, и на busybox.
fmode() { ls -l "$1" 2>/dev/null | cut -c2-10; }
fowner() { ls -ldn "$1" 2>/dev/null | awk '{print $3":"$4}'; }
finode() { ls -di "$1" 2>/dev/null | awk '{print $1}'; }
# mtime числом. Порядок важен: BSD stat не знает -c, GNU stat -f это ФС, а не
# файл, `date -r ФАЙЛ` работает на busybox и на GNU, но не на BSD.
fmtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null \
        || date -r "$1" +%s 2>/dev/null || echo 0
}

# ===========================================================================
printf '\n--- 1. проверка стратегии не трогает живой файл ---\n'
# ===========================================================================
printf -- '--lua-desync=fake\n' > "$LIVE"
# mtime в прошлое: содержимое можно вернуть как было, а вот метку времени и
# inode запись подделать нечем. Именно поэтому проверка не на «содержимое
# совпало» — «записали и восстановили» её проходит.
touch -t 200001020304.05 "$LIVE"
_live_ino=$(finode "$LIVE"); _live_mt=$(fmtime "$LIVE")
_shadow_before=$(ls -d /tmp/z2k-strat-shadow.* 2>/dev/null | wc -l | tr -d ' ')

act 'printf "NOPE\n" | strategy_validate rkn_tcp' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 1 ] && ok "битый кандидат не проходит проверку" \
               || no "битый кандидат не проходит проверку" "rc=1" "rc=$_rc"
if [ "$(finode "$LIVE")" = "$_live_ino" ] && [ "$(fmtime "$LIVE")" = "$_live_mt" ]; then
    ok "после ОТКАЗА живой файл не открывали на запись (inode и mtime прежние)"
else
    no "после отказа живой файл не писался" "ino=$_live_ino mt=$_live_mt" \
       "ino=$(finode "$LIVE") mt=$(fmtime "$LIVE")"
fi

act 'printf -- "--lua-desync=split2\n" | strategy_validate rkn_tcp' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && ok "корректный кандидат проходит проверку" \
               || no "корректный кандидат проходит проверку" "rc=0" "rc=$_rc"
if [ "$(finode "$LIVE")" = "$_live_ino" ] && [ "$(fmtime "$LIVE")" = "$_live_mt" ]; then
    ok "после УСПЕХА живой файл тоже не писался (применяет только save)"
else
    no "после успеха живой файл не писался" "ino=$_live_ino mt=$_live_mt" \
       "ino=$(finode "$LIVE") mt=$(fmtime "$LIVE")"
fi
[ "$(cat "$LIVE")" = "--lua-desync=fake" ] \
    && ok "и содержимое живого файла прежнее" \
    || no "содержимое живого файла прежнее" "--lua-desync=fake" "$(cat "$LIVE")"

# Проверялся именно кандидат, а не то, что лежит в бою.
case "$(cat "$ZD/dryrun.args" 2>/dev/null)" in
    *split2*) ok "движку отдан кандидат, а не текущая строка" ;;
    *) no "движку отдан кандидат" "split2" "$(cat "$ZD/dryrun.args" 2>/dev/null)" ;;
esac
# И собран он был по НАСТОЯЩЕМУ дереву: флаг из config доехал до опций.
case "$(cat "$ZD/dryrun.args" 2>/dev/null)" in
    *flag:ENABLED=1*) ok "тень отдаёт генератору настоящие config/lists, а не пустой каталог" ;;
    *) no "тень отдаёт настоящий config" "flag:ENABLED=1" "$(cat "$ZD/dryrun.args" 2>/dev/null)" ;;
esac

# Пула без своей строки проверка тоже не создаёт.
rm -f "$ZD/lists/custom-strategies/yt_tcp.txt"
act 'printf -- "--lua-desync=fake\n" | strategy_validate yt_tcp' >/dev/null 2>&1
[ -f "$ZD/lists/custom-strategies/yt_tcp.txt" ] \
    && no "проверка не создаёт файл пула" "файла нет" "создан" \
    || ok "проверка пула без своей строки не создаёт файл"

_shadow_after=$(ls -d /tmp/z2k-strat-shadow.* 2>/dev/null | wc -l | tr -d ' ')
[ "$_shadow_before" = "$_shadow_after" ] \
    && ok "теневой каталог снесён после проверки" \
    || no "теневой каталог снесён" "$_shadow_before" "$_shadow_after"

# ===========================================================================
printf '\n--- 2. пустая стратегия и строка из одних комментариев отвергаются ---\n'
# ===========================================================================
act 'printf "" | strategy_pool_save rkn_tcp' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 1 ] && ok "пустое тело не сохраняется" || no "пустое тело не сохраняется" "rc=1" "rc=$_rc"

act 'printf "# просто заметка\n\n   \n" | strategy_pool_save rkn_tcp' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 1 ] && ok "тело из одних комментариев не сохраняется" \
               || no "тело из одних комментариев не сохраняется" "rc=1" "rc=$_rc"
[ "$(cat "$LIVE")" = "--lua-desync=fake" ] \
    && ok "отказ по пустоте не портит уже сохранённую строку" \
    || no "отказ по пустоте не портит сохранённую строку" "--lua-desync=fake" "$(cat "$LIVE")"

_msg=$(act 'printf "" | strategy_pool_save rkn_tcp' 2>&1)
case "$_msg" in
    *awk*|*NF*) no "сообщение об отказе написано человеку" "без awk" "$_msg" ;;
    *[Пп]уста*) ok "сообщение об отказе написано человеку" ;;
    *) no "сообщение об отказе написано человеку" "про пустую стратегию" "$_msg" ;;
esac

# А нормальное тело по-прежнему сохраняется (иначе «починили» бы сохранение вовсе).
act 'printf -- "--lua-desync=split2\n" | strategy_pool_save rkn_tcp' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && ok "корректное тело сохраняется" || no "корректное тело сохраняется" "rc=0" "rc=$_rc"
grep -q 'split2' "$LIVE" 2>/dev/null \
    && ok "сохранено именно то, что прислали" \
    || no "сохранено именно то, что прислали" "split2" "$(cat "$LIVE" 2>/dev/null)"

# Генератор-заглушка перезаписала config — вернём флаг для дальнейших проверок.
printf 'ENABLED=1\n' > "$ZD/config"
printf -- '--lua-desync=fake\n' > "$LIVE"

# ===========================================================================
printf '\n--- 3. значение флага переживает `. config` ---\n'
# ===========================================================================
CFG="$TMP/flagcfg"
printf 'ENABLED=1\n' > "$CFG"

act "set_flag POLICY_NAME 'Через ВПН' '$CFG'" >/dev/null 2>&1 \
    && ok "set_flag дописывает отсутствующий ключ" || no "set_flag дописывает ключ" "rc=0" "rc=$?"
_got=$(sh -c ". '$CFG' 2>/dev/null; printf '%s' \"\$POLICY_NAME\"")
[ "$_got" = "Через ВПН" ] \
    && ok "имя с пробелом и кириллицей доходит через исполнение конфига целиком" \
    || no "имя доходит целиком" "Через ВПН" "$_got"
[ "$(act "read_flag POLICY_NAME '$CFG'")" = "Через ВПН" ] \
    && ok "read_flag снимает кавычки, которые поставил set_flag" \
    || no "read_flag снимает кавычки" "Через ВПН" "$(act "read_flag POLICY_NAME '$CFG'")"
if [ -f "$UTILS" ]; then
    _scr=$( ( . "$UTILS" >/dev/null 2>&1; safe_config_read POLICY_NAME "$CFG" ) )
    [ "$_scr" = "Через ВПН" ] \
        && ok "safe_config_read из lib/utils.sh читает то же значение" \
        || no "safe_config_read читает то же значение" "Через ВПН" "$_scr"
fi

# Перезапись существующего ключа (путь sed -i).
act "set_flag POLICY_NAME 'Дом / дача' '$CFG'" >/dev/null 2>&1
_got=$(sh -c ". '$CFG' 2>/dev/null; printf '%s' \"\$POLICY_NAME\"")
[ "$_got" = "Дом / дача" ] \
    && ok "перезапись ключа тоже пишет в кавычках (слэш не ломает sed)" \
    || no "перезапись ключа пишет в кавычках" "Дом / дача" "$_got"
[ "$(grep -c '^POLICY_NAME=' "$CFG")" = 1 ] \
    && ok "перезапись не плодит дубликаты строк" \
    || no "перезапись не плодит дубликаты" "1" "$(grep -c '^POLICY_NAME=' "$CFG")"

# Конфиг ИСПОЛНЯЕТСЯ, поэтому подстановки и обратные кавычки не должны сработать
# даже если чарсет-гейт когда-нибудь пропустит их до set_flag.
act "set_flag POLICY_NAME 'a\$(id)b' '$CFG'" >/dev/null 2>&1
_got=$(sh -c ". '$CFG' 2>/dev/null; printf '%s' \"\$POLICY_NAME\"")
[ "$_got" = 'a$(id)b' ] \
    && ok "подстановка команд в значении не выполняется при исполнении конфига" \
    || no "подстановка команд не выполняется" 'a$(id)b' "$_got"

# И конфиг остаётся исполняемым (иначе сервис просто не стартует).
sh -c ". '$CFG'" >/dev/null 2>&1 \
    && ok "конфиг после записи флагов исполняется без ошибок" \
    || no "конфиг исполняется" "rc=0" "ошибка"

# ===========================================================================
printf '\n--- 4. код возврата toggle_customd при остановленном сервисе ---\n'
# ===========================================================================
printf 'ENABLED=1\nDISABLE_CUSTOM=0\n' > "$ZD/config"
: > "$TMP/init.calls"
act 'toggle_customd 0' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] \
    && ok "успешное выключение custom.d возвращает 0 (панель не откатит галочку)" \
    || no "выключение custom.d возвращает 0" "rc=0" "rc=$_rc"
grep -q '^DISABLE_CUSTOM=' "$ZD/config" && _v=$(act "read_flag DISABLE_CUSTOM '$ZD/config'") || _v=""
[ "$_v" = "1" ] && ok "флаг DISABLE_CUSTOM записан" || no "флаг DISABLE_CUSTOM записан" "1" "$_v"
[ -s "$TMP/init.calls" ] \
    && no "остановленный сервис не дёргается зря" "init не звали" "$(tr '\n' ' ' < "$TMP/init.calls")" \
    || ok "на остановленном сервисе init-скрипт не вызывается"

act 'toggle_customd 1' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && ok "обратное включение тоже возвращает 0" \
               || no "обратное включение возвращает 0" "rc=0" "rc=$_rc"
[ "$(act "read_flag DISABLE_CUSTOM '$ZD/config'")" = "0" ] \
    && ok "флаг вернулся в 0" || no "флаг вернулся в 0" "0" "$(act "read_flag DISABLE_CUSTOM '$ZD/config'")"

# ===========================================================================
printf '\n--- 5. подмена файла: режим, владелец, конкуренция ---\n'
# ===========================================================================
# Режим ЦЕЛИ, а не 644 наугад: mv уносит inode вместе с правами, и файл,
# который админ закрыл (или который сервис создал под собой), после первой же
# правки из панели становился общедоступным.
printf 'a.example.com\nb.example.com\n' > "$WL"; chmod 640 "$WL"
act 'whitelist_delete a.example.com' >/dev/null 2>&1
[ "$(fmode "$WL")" = "rw-r-----" ] \
    && ok "режим цели (640) пережил подмену, а не заменился на 644" \
    || no "режим цели пережил подмену" "rw-r-----" "$(fmode "$WL")"

# Владелец. Сменить его без root нельзя, поэтому проверяем ФАКТ переноса:
# chown обязан быть вызван с uid:gid ЦЕЛИ и подменяющим файлом. На роутере
# state.tsv принадлежит nobody:nobody, панель работает от root, и без этого
# вызова nfqws2 (--user=nobody) теряет право писать в собственный стейт.
mkdir -p "$TMP/bin2"
CHOWNLOG="$TMP/chown.args"
cat > "$TMP/bin2/chown" <<CH
#!/bin/sh
printf '%s\n' "\$*" >> "$CHOWNLOG"
exit 0
CH
chmod +x "$TMP/bin2/chown"
: > "$CHOWNLOG"
_want_owner=$(fowner "$WL")
( PATH="$TMP/bin2:$PATH"; export PATH; act 'whitelist_delete b.example.com' ) >/dev/null 2>&1
if grep -q "^$_want_owner .*z2k-new" "$CHOWNLOG" 2>/dev/null; then
    ok "владелец цели ($_want_owner) перенесён на подменяющий файл"
else
    no "владелец цели перенесён" "$_want_owner <temp>" "$(tr '\n' ' ' < "$CHOWNLOG")"
fi

mk_wl() {
    : > "$WL"
    _i=1
    while [ "$_i" -le 400 ]; do printf 'host%03d.example.com\n' "$_i" >> "$WL"; _i=$((_i+1)); done
    printf 'sentinel.example.com\n' >> "$WL"
    chmod 644 "$WL"
}

# Гонка двух CGI. Потерянное обновление (оба прочитали исходный файл, второй mv
# перекрыл первый) этим кодом не лечится и здесь не утверждается — блокировок
# в обработчиках нет. Утверждается то, что уникальный temp действительно даёт:
# сосед не читает наполовину записанный чужой файл, поэтому список не
# обнуляется и в нём не появляется обрубков строк.
mk_wl
_broken=""
_round=1
while [ "$_round" -le 8 ]; do
    actproc "whitelist_delete host$(printf '%03d' "$_round").example.com" >/dev/null 2>&1 &
    actproc "whitelist_delete host$(printf '%03d' "$((_round+200))").example.com" >/dev/null 2>&1 &
    wait
    [ -s "$WL" ] || { _broken="файл пуст"; break; }
    grep -qxF 'sentinel.example.com' "$WL" || { _broken="пропала уцелевшая запись"; break; }
    if grep -vqE '^(host[0-9][0-9][0-9]|sentinel)\.example\.com$' "$WL"; then
        _broken="битая строка: $(grep -vE '^(host[0-9][0-9][0-9]|sentinel)\.example\.com$' "$WL" | head -1)"
        break
    fi
    _round=$((_round+1))
done
[ -z "$_broken" ] \
    && ok "8 раундов параллельных удалений: файл ни разу не обнулился и не побился" \
    || no "параллельные удаления не портят файл" "файл цел" "раунд $_round: $_broken"

# Гонку выше воспроизвести стабильно нельзя (окно — доли миллисекунды), поэтому
# гарантом остаётся структурная проверка: ни одного общего на процесс temp'а.
# Нумеруем ДО фильтра комментариев, иначе номера строк в отчёте от другого файла.
_fixed=$(grep -nE '\.z2k-(new|raw)"' "$ACTIONS" | grep -v '^[0-9]*:[[:space:]]*#')
if [ -n "$_fixed" ]; then
    no "временные файлы уникальны на процесс" "везде суффикс .\$\$" \
       "$(printf '%s' "$_fixed" | head -3 | tr '\n' ' ')"
else
    ok "временные файлы списков уникальны на процесс (суффикс .\$\$)"
fi

# ===========================================================================
printf '\n--- 6. удаление ЕДИНСТВЕННОЙ записи ---\n'
# ===========================================================================
printf 'only.example.com\n' > "$WL"; chmod 644 "$WL"
act 'whitelist_delete only.example.com' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && ok "whitelist: удаление единственной записи возвращает успех" \
               || no "whitelist: удаление единственной записи" "rc=0" "rc=$_rc"
grep -qxF 'only.example.com' "$WL" 2>/dev/null \
    && no "whitelist: запись действительно удалена" "нет записи" "осталась" \
    || ok "whitelist: запись действительно удалена"

printf 'only.example.com\n' > "$ED"; chmod 644 "$ED"
act 'extra_domains_delete only.example.com' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && ok "extra-domains: удаление единственной записи возвращает успех" \
               || no "extra-domains: удаление единственной записи" "rc=0" "rc=$_rc"
grep -qxF 'only.example.com' "$ED" 2>/dev/null \
    && no "extra-domains: запись действительно удалена" "нет записи" "осталась" \
    || ok "extra-domains: запись действительно удалена"

printf '203.0.113.7\n' > "$EX"; chmod 644 "$EX"
act 'exclude_delete 203.0.113.7' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && ok "исключения: удаление единственной записи возвращает успех" \
               || no "исключения: удаление единственной записи" "rc=0" "rc=$_rc"
grep -qxF '203.0.113.7' "$EX" 2>/dev/null \
    && no "исключения: запись действительно удалена" "нет записи" "осталась" \
    || ok "исключения: запись действительно удалена"

# ===========================================================================
printf '\n--- 7. импорт в ПУСТОЙ whitelist ---\n'
# ===========================================================================
# Путь первого импорта у каждого нового пользователя: whitelist.txt существует
# и пуст. awk-разделение файлов по NR==FNR на пустом первом файле считало
# существующими ВСЕ строки импорта, и панель отвечала added=0 на любой файл.
: > "$WL"; chmod 644 "$WL"
_out=$(act 'printf "one.example.com\ntwo.example.com\n" | whitelist_import' 2>/dev/null)
case "$_out" in
    *added=2*) ok "импорт в пустой список: added=2" ;;
    *) no "импорт в пустой список добавляет записи" "added=2" "$_out" ;;
esac
if grep -qxF 'one.example.com' "$WL" && grep -qxF 'two.example.com' "$WL"; then
    ok "импорт в пустой список: обе записи в файле"
else
    no "импорт в пустой список пишет записи" "обе строки" "$(tr '\n' '|' < "$WL")"
fi

_out=$(act 'printf "one.example.com\nthree.example.com\n" | whitelist_import' 2>/dev/null)
case "$_out" in
    *"added=1 skipped_dup=1"*) ok "импорт в непустой список: дедуп по-прежнему работает" ;;
    *) no "импорт в непустой список дедуплицирует" "added=1 skipped_dup=1" "$_out" ;;
esac

# ===========================================================================
printf '\n--- 8. имя политики доступа ---\n'
# ===========================================================================
POLCFG="$TMP/policy.conf"
ACT_ENV="CONFIG_FILE='$POLCFG'; ZAPRET2_DIR='$TMP/nolib'"

printf 'ENABLED=1\n' > "$POLCFG"
PNAME="O'Brien"; export PNAME
act 'policy_save "$PNAME" 0' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 1 ] && ok "апостроф в имени политики отвергнут" \
               || no "апостроф отвергнут" "rc=1" "rc=$_rc"
# Почему отвергнут: set_flag пишет его как '\'' , а safe_config_read (не наш
# файл) обратно не разворачивает — и следующая же перегенерация, которую
# policy_save сам и запускает, закрепляет испорченное имя в конфиге.
grep -q "POLICY_NAME" "$POLCFG" \
    && no "отвергнутое имя не записано в конфиг" "нет строки" "$(grep POLICY_NAME "$POLCFG")" \
    || ok "отвергнутое имя не записано в конфиг"

PNAME="Дом|дача"; export PNAME
act 'policy_save "$PNAME" 0' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 1 ] && ok "вертикальная черта в имени отвергнута (разделитель полей /policy/status)" \
               || no "вертикальная черта отвергнута" "rc=1" "rc=$_rc"

# 32 символа кириллицы = 64 байта. ${#name} на ash считает байты, и такое имя
# отбивалось как «слишком длинное», хотя форма разрешает ровно 32 символа.
PNAME="ааааааааааааааааааааааааааааааaа"; export PNAME
act 'policy_save "$PNAME" 0' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && ok "имя из 32 кириллических символов принято" \
               || no "имя из 32 символов принято" "rc=0" "rc=$_rc"
_got=$(sh -c ". '$POLCFG' 2>/dev/null; printf '%s' \"\$POLICY_NAME\"")
[ "$_got" = "$PNAME" ] \
    && ok "принятое имя доехало до конфига целиком" \
    || no "принятое имя доехало целиком" "$PNAME" "$_got"

PNAME="ааааааааааааааааааааааааааааааааа"; export PNAME
act 'policy_save "$PNAME" 0' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 1 ] && ok "имя из 33 символов по-прежнему отвергается" \
               || no "имя из 33 символов отвергается" "rc=1" "rc=$_rc"
unset PNAME
ACT_ENV=""

# ===========================================================================
printf '\n--- 9. списки WARP ---\n'
# ===========================================================================
# Удаление идемпотентно (решение владельца): повторный клик по «удалить» не
# должен показывать ошибку, и tests/test_warp_lists.sh утверждает это же.
act 'warp_list_delete nosuchlist' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && ok "удаление несуществующего списка идемпотентно (rc 0)" \
               || no "удаление несуществующего списка" "rc=0" "rc=$_rc"

printf '8.8.8.8\n' > "$WLD/live.txt"
act 'warp_list_delete live' >/dev/null 2>&1 && _rc=0 || _rc=1
[ "$_rc" = 0 ] && [ ! -f "$WLD/live.txt" ] \
    && ok "существующий список удаляется" \
    || no "существующий список удаляется" "rc=0, файла нет" "rc=$_rc, файл $( [ -f "$WLD/live.txt" ] && echo есть || echo нет)"

# Дописывание в файл без завершающего перевода строки. Без этого 1.2.3.4 и
# 5.6.7.8 склеиваются в 1.2.3.45.6.7.8: панель рапортует saved=1, а загрузчик
# ipset и счётчик записей видят НОЛЬ адресов — пропадают оба.
printf '1.2.3.4' > "$WLD/app.txt"
act 'printf "5.6.7.8\n" | warp_list_save app append' >/dev/null 2>&1
if grep -qxF '1.2.3.4' "$WLD/app.txt" && grep -qxF '5.6.7.8' "$WLD/app.txt"; then
    ok "WARP append: адреса не склеились"
else
    no "WARP append: адреса не склеились" "две строки" "$(tr '\n' '|' < "$WLD/app.txt")"
fi
_cnt=$(awk '{sub(/\r$/,""); gsub(/^[ \t]+|[ \t]+$/,"")} /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$/{n++} END{print n+0}' "$WLD/app.txt")
[ "$_cnt" = 2 ] && ok "WARP append: счётчик записей видит оба адреса" \
                || no "WARP append: счётчик видит оба адреса" "2" "$_cnt"

# Замена целиком идёт подменой файла, а не «обнулить и залить». Проверяем по
# inode: смена inode = запись пришла через rename, то есть промежуточного
# состояния «файл уже пуст, новое ещё не дописано» не существовало. Обрыв
# питания или ENOSPC на этом месте раньше оставлял пустой список, который
# тут же уезжал в ipset.
printf '1.1.1.1\n2.2.2.2\n' > "$WLD/big.txt"
_ino_before=$(finode "$WLD/big.txt")
act 'printf "3.3.3.3\n" | warp_list_save big replace' >/dev/null 2>&1
[ "$(finode "$WLD/big.txt")" != "$_ino_before" ] \
    && ok "WARP replace: содержимое подменено целиком (новый inode), а не залито поверх" \
    || no "WARP replace идёт через rename" "inode != $_ino_before" "$(finode "$WLD/big.txt")"
[ "$(cat "$WLD/big.txt")" = "3.3.3.3" ] \
    && ok "WARP replace: в файле ровно новое содержимое" \
    || no "WARP replace: новое содержимое" "3.3.3.3" "$(tr '\n' '|' < "$WLD/big.txt")"

# Заявка имени: занято — это когда файл после отказа есть.
printf '9.9.9.9\n' > "$WLD/taken.txt"
_msg=$(act 'printf "1.1.1.1\n" | warp_list_save taken create' 2>&1 >/dev/null)
case "$_msg" in
    *exists*) ok "create на занятом имени: «уже существует»" ;;
    *) no "create на занятом имени" "list already exists" "$_msg" ;;
esac
[ "$(cat "$WLD/taken.txt")" = "9.9.9.9" ] \
    && ok "отказанный create не тронул чужой список" \
    || no "отказанный create не тронул чужой список" "9.9.9.9" "$(cat "$WLD/taken.txt")"

# ...а «не смогли создать» — это другое сообщение: человек иначе ищет чужой
# список вместо того, чтобы чинить раздел.
if [ "$(id -u)" = 0 ]; then
    skip "create на закрытом каталоге отличает отказ от занятого имени" "запущено от root"
else
    RO="$TMP/rodir"; mkdir -p "$RO"; : > "$RO/.legacy-aggregate-purged"; chmod 500 "$RO"
    ACT_ENV="WARP_LISTS_DIR='$RO'"
    _msg=$(act 'printf "1.1.1.1\n" | warp_list_save newone create' 2>&1 >/dev/null)
    ACT_ENV=""
    chmod 700 "$RO"
    case "$_msg" in
        *exists*) no "отказ создать не выдаётся за занятое имя" "не про exists" "$_msg" ;;
        '')       no "отказ создать объяснён" "сообщение" "(пусто)" ;;
        *)        ok "отказ создать отличается от «имя занято»: $_msg" ;;
    esac
fi

# ===========================================================================
printf '\n--- 10. дописывание в файл без завершающего перевода строки ---\n'
# ===========================================================================
printf 'old.example.com' > "$WL"; chmod 644 "$WL"
act 'whitelist_add new.example.com' >/dev/null 2>&1
if grep -qxF 'old.example.com' "$WL" && grep -qxF 'new.example.com' "$WL"; then
    ok "whitelist: записи не склеились (обе находятся по точному совпадению)"
else
    no "whitelist: записи не склеились" "две отдельные строки" "$(tr '\n' '|' < "$WL")"
fi
[ "$(grep -c . "$WL")" = 2 ] \
    && ok "whitelist: в файле ровно две строки" \
    || no "whitelist: в файле две строки" "2" "$(grep -c . "$WL")"
# И удалить обе после этого можно.
act 'whitelist_delete old.example.com' >/dev/null 2>&1
grep -qxF 'old.example.com' "$WL" 2>/dev/null \
    && no "whitelist: приклеенная бы запись удаляется" "удалена" "осталась" \
    || ok "whitelist: запись, дописанная в файл без \\n, потом удаляется"

# Домен берём заведомо отсутствующий в других списках: new.example.com выше
# попал в исключения, а доп домены теперь не принимают то, что уже где-то есть.
printf 'old.example.com' > "$ED"; chmod 644 "$ED"
act 'extra_domains_add fresh.example.net' >/dev/null 2>&1
if grep -qxF 'old.example.com' "$ED" && grep -qxF 'fresh.example.net' "$ED"; then
    ok "extra-domains: записи не склеились"
else
    no "extra-domains: записи не склеились" "две отдельные строки" "$(tr '\n' '|' < "$ED")"
fi

# ===========================================================================
printf '\n--- 11. доп домены не принимают то, что уже в списках ---\n'
# ===========================================================================
# Запись домена, который и так покрыт другим списком, ничего не меняет: обход
# для него уже работает. Но человек уверен, что настроил, — поэтому отказываем
# и НАЗЫВАЕМ список, иначе искать домен по восьми файлам он не пойдёт.
_before=$(cat "$ED")
_msg=$(act 'extra_domains_add new.example.com' 2>&1 >/dev/null)
if [ "$(cat "$ED")" = "$_before" ]; then
    ok "домен из исключений в доп домены не попадает"
else
    no "домен из исключений в доп домены не попадает" "файл не менялся" "$(tr '\n' '|' < "$ED")"
fi
case "$_msg" in
    *исключени*) ok "в отказе назван список, где домен уже лежит" ;;
    *) no "в отказе назван список" "упоминание исключений" "${_msg:-пусто}" ;;
esac

# Родитель покрывает поддомен: хост-листы матчат его автоматически.
_before=$(cat "$ED")
act 'extra_domains_add www.new.example.com' >/dev/null 2>&1
if [ "$(cat "$ED")" = "$_before" ]; then
    ok "поддомен уже покрытого домена тоже отклоняется"
else
    no "поддомен уже покрытого домена тоже отклоняется" "файл не менялся" "$(tr '\n' '|' < "$ED")"
fi

# А вот обратное разрешено: example.com шире, чем new.example.com, и покрытием
# для него не является. Запретить его значило бы отнять рабочий сценарий.
act 'extra_domains_add example.com' >/dev/null 2>&1
if grep -qxF 'example.com' "$ED"; then
    ok "более широкий домен добавить можно"
else
    no "более широкий домен добавить можно" "example.com в файле" "$(tr '\n' '|' < "$ED")"
fi

printf '203.0.113.7' > "$EX"; chmod 644 "$EX"
act 'exclude_add 203.0.113.8' >/dev/null 2>&1
if grep -qxF '203.0.113.7' "$EX" && grep -qxF '203.0.113.8' "$EX"; then
    ok "исключения: записи не склеились"
else
    no "исключения: записи не склеились" "две отдельные строки" "$(tr '\n' '|' < "$EX")"
fi

# Обычный файл (с переводом строки в конце) не получает лишней пустой строки.
printf 'a.example.com\n' > "$WL"; chmod 644 "$WL"
act 'whitelist_add b.example.com' >/dev/null 2>&1
[ "$(wc -l < "$WL" | tr -d ' ')" = 2 ] \
    && ok "в нормальный файл не добавляется пустая строка" \
    || no "в нормальный файл не добавляется пустая строка" "2 строки" "$(wc -l < "$WL" | tr -d ' ')"

# ===========================================================================
printf '\n--- 11. живой лог задачи режется по границе символа ---\n'
# ===========================================================================
# Лог длиннее лимита и БЕЗ единого перевода строки — так выглядит прогресс
# через \r (curl, opkg). Срез по границе байта отдавал обрубок UTF-8, ответ с
# charset=utf-8 не разбирался JSON'ом во фронте, и модалка виснет.
# Размер нечётный, буквы двухбайтовые — граница среза заведомо попадает внутрь
# последовательности.
LOGF="/tmp/z2k-job-$JID.log"
: > "$LOGF"
_i=0
while [ "$_i" -lt 200 ]; do
    printf 'ыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыыы' >> "$LOGF"
    _i=$((_i+1))
done
printf 'x' >> "$LOGF"
_first=$(act "job_log $JID" | od -An -N1 -tu1 2>/dev/null | tr -d ' ')
case "$_first" in
    ''|*[!0-9]*) no "срез лога начинается с начала символа" "код байта" "$_first" ;;
    *) if [ "$_first" -ge 128 ] && [ "$_first" -le 191 ]; then
           no "срез лога начинается с начала символа" "не 128..191" "$_first"
       else
           ok "срез лога без переводов строки начинается с начала символа"
       fi ;;
esac
_len=$(act "job_log $JID" | wc -c | tr -d ' ')
[ "${_len:-0}" -gt 16000 ] && [ "${_len:-0}" -le 16384 ] \
    && ok "срез лога остался в пределах лимита и не опустел ($_len байт)" \
    || no "срез лога в пределах лимита" "16000 < N <= 16384" "$_len"

# Обычный многострочный лог: первая (обрезанная) строка выбрасывается целиком.
: > "$LOGF"
_i=0
while [ "$_i" -lt 400 ]; do
    printf 'строка %03d ыыыыыыыыыыыыыыыыыыыыыыыыыыыыыы\n' "$_i" >> "$LOGF"
    _i=$((_i+1))
done
_out=$(act "job_log $JID" | head -1)
case "$_out" in
    строка*) ok "многострочный лог: срез начинается с целой строки" ;;
    *) no "многострочный лог: срез начинается с целой строки" "строка NNN ..." "$_out" ;;
esac
rm -f "$LOGF"

# ===========================================================================
printf '\n--- 12. проверка обновлений: потолок времени и негативный кэш ---\n'
# ===========================================================================
# z2k_fetch — это до четырёх хопов по --max-time 180 каждый, а вызывается он из
# синхронного CGI на GET /update/status, который фронт дёргает при каждой
# инициализации дашборда.
AUR="$TMP/aur"; mkdir -p "$AUR/lib"
FETCHLOG="$TMP/fetch.calls"
cat > "$AUR/lib/utils.sh" <<STUBF
z2k_fetch() {
    printf 'call\n' >> "$FETCHLOG"
    sleep 25
    return 1
}
STUBF
AUCACHE="$TMP/au-manifest.json"
: > "$FETCHLOG"
ACT_ENV="ZAPRET2_DIR='$AUR'; AU_MANIFEST_CACHE='$AUCACHE'; AU_MANIFEST_FETCH_TIMEOUT=2"
_t0=$(date +%s)
act 'update_refresh_manifest 0' >/dev/null 2>&1
_t1=$(date +%s)
_el=$((_t1 - _t0))
[ "$_el" -le 10 ] \
    && ok "неудачная проверка обновлений уложилась в потолок (${_el}с)" \
    || no "проверка обновлений ограничена по времени" "<=10с" "${_el}с"

# Негативный кэш: следующая загрузка страницы не повторяет весь забег.
_t0=$(date +%s)
act 'update_refresh_manifest 0' >/dev/null 2>&1 && _rc=0 || _rc=1
_t1=$(date +%s)
[ "$((_t1 - _t0))" -le 1 ] \
    && ok "повторная загрузка страницы после неудачи не ходит в сеть" \
    || no "негативный кэш держит повтор" "<=1с" "$((_t1 - _t0))с"
[ "$(grep -c 'call' "$FETCHLOG")" = 1 ] \
    && ok "фетч за две загрузки страницы вызван ровно один раз" \
    || no "фетч вызван один раз" "1" "$(grep -c 'call' "$FETCHLOG")"
[ "$_rc" = 1 ] \
    && ok "и по-прежнему честно сообщает о неудаче (кэша нет)" \
    || no "неудача сообщается" "rc=1" "rc=$_rc"

# Кнопка «проверить» (force=1) негативный кэш минует — человек ждёт результата.
_t0=$(date +%s)
act 'update_refresh_manifest 1' >/dev/null 2>&1
_t1=$(date +%s)
[ "$(grep -c 'call' "$FETCHLOG")" = 2 ] \
    && ok "ручная проверка идёт в сеть, несмотря на негативный кэш" \
    || no "ручная проверка минует негативный кэш" "2" "$(grep -c 'call' "$FETCHLOG")"
[ "$((_t1 - _t0))" -le 10 ] \
    && ok "ручная проверка тоже ограничена по времени" \
    || no "ручная проверка ограничена по времени" "<=10с" "$((_t1 - _t0))с"

# Признак источника — единственное, за что api.sh может зацепиться: stderr
# обработчиков он уводит в /dev/null.
[ "$(act 'update_manifest_source')" = "mirrors" ] \
    && ok "источник манифеста доступен вызывающему: mirrors" \
    || no "источник манифеста доступен" "mirrors" "$(act 'update_manifest_source')"

if [ -f /tmp/z2k/lib/utils.sh ]; then
    skip "деградация на голый curl помечена" "на машине есть /tmp/z2k/lib/utils.sh"
else
    ACT_ENV="ZAPRET2_DIR='$TMP/nolib'; AU_MANIFEST_CACHE='$TMP/au2.json'; AU_MANIFEST_FETCH_TIMEOUT=2"
    act 'update_refresh_manifest 1' >/dev/null 2>&1
    [ "$(act 'update_manifest_source')" = "curl" ] \
        && ok "деградация на голый curl помечена для вызывающего" \
        || no "деградация помечена" "curl" "$(act 'update_manifest_source')"
    grep -q 'curl' "$TMP/curl.calls" 2>/dev/null \
        && ok "в этой ветке действительно звался curl" \
        || no "в ветке деградации звался curl" "вызов curl" "(нет)"
fi
ACT_ENV=""

# ===========================================================================
printf '\n--- 13. осиротевший скретч в /tmp подчищается ---\n'
# ===========================================================================
# CGI, убитый lighttpd'ом, уносит уборку с собой, а /tmp на роутере — это
# ОПЕРАТИВКА. Уборка «по своему $$» в начале обработчика спасает только при
# совпадении PID.
mkdir -p "$ORPH/lists"; touch -t 200001020304.05 "$ORPH"
mkdir -p "$ORPH_NEW/lists"
act 'printf -- "--lua-desync=split2\n" | strategy_validate rkn_tcp' >/dev/null 2>&1
[ -d "$ORPH" ] \
    && no "чужая осиротевшая тень снесена" "каталога нет" "остался $ORPH" \
    || ok "чужая осиротевшая тень старше часа снесена"
[ -d "$ORPH_NEW" ] \
    && ok "свежая чужая тень не тронута (рядом может идти живая проверка)" \
    || no "свежая чужая тень не тронута" "каталог на месте" "снесён"
rm -rf "$ORPH" "$ORPH_NEW"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
