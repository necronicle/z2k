#!/bin/sh
# test_local_exclusions.sh
#
# Локальные адреса не должны попадать под десинк НИКОГДА: между роутером и
# 192.168.x / 10.x нет DPI, обходить там нечего — а сломать можно. Полевой
# отчёт 2026-08-06: приложение камер (EasyLive/Tiandy) не показывало видео при
# включённом обходе и работало при выключенном.
#
# Одной привязки правил к WAN недостаточно: в _fw_nfqws_post4 есть ветка без
# `-o $iface` (WAN не определился) — тогда правило висит на всех интерфейсах.
# Поэтому локалка засевается в сет nozapret, который проверяется в КАЖДОМ
# NFQUEUE-правиле через $IPSET_EXCLUDE и потому работает независимо от
# хостлистов и профилей (в т.ч. для Discord/STUN, у которого хостлиста нет).
#
# ПОЧЕМУ ТЕСТ ПЕРЕПИСАН. Прежняя версия утверждала только, что файл исключений
# создаётся, что имя у него апстримное и что бэкенд панели умеет в него писать
# и из него удалять. Ни одного утверждения про то, что запись НАЧИНАЕТ
# ДЕЙСТВОВАТЬ, в нём не было — и поэтому мимо него годами ехало сразу две
# поломки:
#
#   * файл не читал НИКТО. Апстримная цепочка (ipset/def.sh -> filedigger ->
#     nozapret) в z2k не выполняется, так что после перезагрузки роутера
#     адресные исключения просто исчезали;
#   * панель принимала в этот файл ДОМЕНЫ. Имя в ipset выразить нельзя, поэтому
#     доменная запись не действовала никогда и молча оседала в файле навсегда.
#
# Отсюда правило для всего, что ниже: утверждать поведение, а не наличие строк.
# Засев проверяется ВЫЗОВОМ настоящей z2k_seed_user_exclusions с подставным
# ipset (настоящий в тестах недоступен и root не нужен), контракт панели —
# ответом api.sh, а не грепом по его исходнику.
#
# POSIX sh (busybox ash), без root, без сети, без обращений к настоящему /opt.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$HERE/files/S99zapret2.new"
ACTIONS="$HERE/webpanel/cgi/actions.sh"
API="$HERE/webpanel/cgi/api.sh"
CFGGEN="$HERE/lib/config_official.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }

for f in "$INIT" "$ACTIONS" "$API" "$CFGGEN"; do
    [ -f "$f" ] || { printf '[FAIL] отсутствует %s\n' "$f"; exit 1; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2kexcl.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

SB="$TMP/opt/zapret2"                                   # он же ZAPRET_BASE
LISTS="$SB/lists"
EXCL="$SB/ipset/zapret-hosts-user-exclude.txt"
mkdir -p "$SB/ipset" "$LISTS" "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$SB/S99-stub"; chmod 755 "$SB/S99-stub"

# Подставной ipset. Настоящего в тестовой среде нет, а если есть — команды
# требуют root и существующих сетов, и результат зависел бы от хоста. Шим
# всегда успешен и пишет полученные аргументы в лог: по нему и судим, что
# именно и в какой сет ушло. Приём тот же, что в test_policy_member_guard.sh
# и test_module_loading.sh — каталог со стабами первым в PATH.
IPSET_LOG="$TMP/ipset.log"
: > "$IPSET_LOG"
cat > "$TMP/bin/ipset" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$IPSET_LOG"
exit 0
EOF
chmod 755 "$TMP/bin/ipset"
PATH="$TMP/bin:$PATH"; export PATH

# --- 1. Полный набор локальных диапазонов засевается ------------------------
for net in '10\.0\.0\.0/8' '172\.16\.0\.0/12' '192\.168\.0\.0/16' \
           '127\.0\.0\.0/8' '169\.254\.0\.0/16'; do
    plain=$(printf '%s' "$net" | sed 's/\\//g')
    if grep -q -- "$net" "$INIT"; then
        ok "локалка засевается: $plain"
    else
        bad "локалка засевается: $plain" "диапазон отсутствует в S99zapret2.new"
    fi
done
for net in '::1/128' 'fc00::/7' 'fe80::/10'; do
    if grep -qF -- "$net" "$INIT"; then
        ok "локалка IPv6 засевается: $net"
    else
        bad "локалка IPv6 засевается: $net" "диапазон отсутствует"
    fi
done

# CGNAT намеренно НЕ засевается (это не локалка, а адреса провайдерского NAT).
# Проверяем САМИ переменные засева, а не весь файл: в комментарии рядом стоит
# объяснение, почему CGNAT исключён, и наивный греп по файлу ловил бы его.
seed_vars=$(grep -E '^Z2K_LOCAL_EXCLUDE[46]=' "$INIT")
if printf '%s' "$seed_vars" | grep -qF -- "100.64.0.0/10"; then
    bad "CGNAT не засевается по умолчанию" "100.64.0.0/10 попал в засев — решение было не включать"
else
    ok "CGNAT (100.64.0.0/10) намеренно не засевается"
fi

# --- 2. Засев вызывается из start_fw и идёт в правильные сеты ---------------
start_fw_body=$(awk '/^start_fw\(\)/{i=1} i{print} i&&/^\}/{exit}' "$INIT")
if printf '%s' "$start_fw_body" | grep -q 'z2k_seed_local_exclusions'; then
    ok "засев локалки вызывается из start_fw"
else
    bad "засев локалки вызывается из start_fw" "функция не вызывается при старте файрвола"
fi
seed=$(awk '/^z2k_seed_local_exclusions\(\)/{i=1} i{print} i&&/^\}/{exit}' "$INIT")
if printf '%s' "$seed" | grep -q 'nozapret6' && printf '%s' "$seed" | grep -q 'family inet6'; then
    ok "IPv6-сет создаётся с family inet6"
else
    bad "IPv6-сет создаётся с family inet6" "nozapret6 создаётся неверно — add отвергнет адреса"
fi
if printf '%s' "$seed" | grep -q -- '-exist'; then
    ok "засев идемпотентен (-exist)"
else
    bad "засев идемпотентен (-exist)" "повторный старт будет сыпать ошибками"
fi

# --- 3. Пользовательский файл исключений создаётся --------------------------
if grep -q 'z2k_ensure_user_exclude_file' "$INIT"; then
    ok "пользовательский файл исключений создаётся при старте"
else
    bad "пользовательский файл исключений создаётся" "функция отсутствует"
fi
if grep -q 'zapret-hosts-user-exclude.txt' "$INIT"; then
    ok "используется апстримное имя файла (его читает ipset/def.sh)"
else
    bad "апстримное имя файла" "апстрим не подхватит список с другим именем"
fi

# --- 4. Пользовательский файл КТО-ТО ЧИТАЕТ ---------------------------------
# Именно здесь была дыра: файл создавался, панель в него писала, апстримная
# цепочка его не разбирала — и адресное исключение переставало действовать
# после первой же перезагрузки. Гоняем НАСТОЯЩУЮ функцию засева.
USEED=$(awk '/^z2k_seed_user_exclusions\(\)/{i=1} i{print} i&&/^\}/{exit}' "$INIT")
if [ -n "$USEED" ] && printf '%s' "$start_fw_body" | grep -q 'z2k_seed_user_exclusions'; then
    ok "пользовательский файл засевается при старте (функция есть и вызвана из start_fw)"
else
    bad "пользовательский файл засевается при старте" \
        "z2k_seed_user_exclusions отсутствует или не вызывается — файл не читает никто"
fi

# Драйвер: сама функция + минимальное окружение, которое ей даёт init-скрипт
# (exists из common/base.sh, ZAPRET_BASE, флаги семейств).
{
    printf '#!/bin/sh\n'
    printf 'exists() { command -v "$1" >/dev/null 2>&1; }\n'
    printf 'ZAPRET_BASE=%s\n' "$SB"
    printf 'DISABLE_IPV4="${D4:-0}"\nDISABLE_IPV6="${D6:-0}"\n'
    printf '%s\n' "$USEED"
    printf 'z2k_seed_user_exclusions\n'
} > "$TMP/seed_driver.sh"

run_seed() { : > "$IPSET_LOG"; D4=0 D6=0 sh "$TMP/seed_driver.sh" >/dev/null 2>&1; }
seeded()   { grep -qxF "add $1 $2 -exist" "$IPSET_LOG"; }
adds()     { c=$(grep -c '^add ' "$IPSET_LOG" 2>/dev/null); printf '%s' "${c:-0}"; }

# Бэкенд панели в песочнице. ipset тут тоже подставной, поэтому «живое»
# применение записи ничего не портит и ни от чего на хосте не зависит.
act() {
    ( ZAPRET2_DIR="$SB" LISTS_DIR="$LISTS" EXCLUDE_FILE="$EXCL" \
      WHITELIST_FILE="$LISTS/whitelist.txt" CONFIG_FILE="$SB/config" \
      INIT_SCRIPT="$SB/S99-stub"
      export ZAPRET2_DIR LISTS_DIR EXCLUDE_FILE WHITELIST_FILE CONFIG_FILE INIT_SCRIPT
      # shellcheck source=../webpanel/cgi/actions.sh
      . "$ACTIONS" 2>/dev/null || true
      eval "$1" )
}

# --- 5. Адрес из панели доезжает до сета ------------------------------------
: > "$EXCL"
if act 'exclude_add "203.0.113.10"' >/dev/null 2>&1 && grep -qxF '203.0.113.10' "$EXCL"; then
    run_seed
    if seeded nozapret 203.0.113.10; then
        ok "адрес из панели попадает в файл И засевается в nozapret при старте"
    else
        bad "адрес из панели засевается при старте" \
            "203.0.113.10 в файле есть, а в сет не попал — после ребута исключение мертво"
    fi
else
    bad "адрес из панели попадает в файл" "exclude_add не записал 203.0.113.10"
fi

# --- 6. Подсеть и IPv6 — каждый в свой сет ----------------------------------
: > "$EXCL"
act 'exclude_add "203.0.113.0/24"' >/dev/null 2>&1
run_seed
if seeded nozapret 203.0.113.0/24; then
    ok "подсеть засевается в nozapret"
else
    bad "подсеть засевается в nozapret" "203.0.113.0/24 не доехал до сета"
fi

: > "$EXCL"
act 'exclude_add "2001:db8::1"' >/dev/null 2>&1
run_seed
if seeded nozapret6 2001:db8::1 && ! seeded nozapret 2001:db8::1; then
    ok "IPv6 засевается в nozapret6 (и не в IPv4-сет)"
else
    bad "IPv6 засевается в nozapret6" \
        "адрес ушёл не в тот сет: $(tr '\n' ';' < "$IPSET_LOG")"
fi

# --- 7. Домен в адресный список не принимается ------------------------------
# В ipset имени нет, а апстримная цепочка «домен -> адреса» в z2k не работает.
# Принятая доменная запись — это молчаливый обман: панель показывает
# исключение, которого не существует.
: > "$EXCL"
if act 'exclude_add "tiandycloud.com"' >/dev/null 2>&1; then
    bad "домен в адресный список не принимается" "exclude_add принял домен"
elif grep -qxF 'tiandycloud.com' "$EXCL" 2>/dev/null; then
    bad "домен в адресный список не принимается" "домен всё равно записан в файл"
else
    ok "домен в адресный список не принимается"
fi

# Отказ должен доехать до человека текстом, а не кодом: «invalid or add failed»
# не говорит, что делать, а «добавьте во вкладке Домены» — говорит.
# HTTP_X_Z2K_PANEL — то же, что app.js шлёт на каждом fetch; без него
# origin-страж в cgi/auth.sh отвечает 403 и до роутинга дело не доходит.
api_cgi() { # api_cgi <METHOD> <PATH_INFO> [файл-тела] -> тело ответа
    _m="$1"; _p="$2"; _b="${3:-/dev/null}"
    _cl=0; [ "$_b" = /dev/null ] || _cl=$(wc -c < "$_b" | tr -d ' ')
    env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="" \
        HTTP_HOST=192.168.1.1 HTTP_X_Z2K_PANEL=1 CONTENT_LENGTH="$_cl" \
        ZAPRET2_DIR="$SB" CONFIG_FILE="$SB/config" LISTS_DIR="$LISTS" \
        EXCLUDE_FILE="$EXCL" WHITELIST_FILE="$LISTS/whitelist.txt" \
        STATE_FILE="$SB/state.tsv" INIT_SCRIPT="$SB/S99-stub" \
        sh "$API" < "$_b" 2>/dev/null | awk 'b{print} /^\r?$/{b=1}'
}

: > "$EXCL"
printf 'entry=tiandycloud.com' > "$TMP/body-domain"
resp=$(api_cgi POST /exclude/add "$TMP/body-domain")
case "$resp" in
    *'"ok":false'*'домен'*) ok "API: отказ на домене доносит причину до ответа" ;;
    *'"ok":true'*) bad "API: отказ на домене" "запрос удовлетворён — домен принят в адресный список" ;;
    *) bad "API: отказ на домене доносит причину" "в ответе нет объяснения: $resp" ;;
esac

# --- 8. Домены, осевшие в файле раньше --------------------------------------
# Вычищать их молча нельзя — человек вписывал их осознанно. Но и делать вид,
# что они работают, тоже нельзя: в сет они не попадают и не попадут.
# Домен ОБЯЗАН содержать цифру. С чисто буквенным (tiandycloud.com) буквенный
# фильтр сида можно было удалить целиком, и утверждение оставалось зелёным:
# строка без цифр не подходила и под следующую ветку, то есть отсеивалась по
# случайности, а не проверяемым кодом.
cat > "$EXCL" <<'EOF'
cam7.tiandycloud.com
203.0.113.77
EOF
run_seed
if [ "$(adds)" = "1" ] && seeded nozapret 203.0.113.77 && ! grep -q 'tiandycloud' "$IPSET_LOG"; then
    ok "легаси-домен из файла не засевается, адрес рядом с ним — засевается"
else
    bad "легаси-домен не засевается" \
        "в сет ушло не то: $(tr '\n' ';' < "$IPSET_LOG")"
fi

resp=$(api_cgi GET /exclude)
legacy=$(printf '%s' "$resp" | sed -n 's/.*"legacy_domains":\[\([^]]*\)\].*/\1/p')
entries=$(printf '%s' "$resp" | sed -n 's/.*"entries":\[\([^]]*\)\].*/\1/p')
case "$entries" in
    *203.0.113.77*) e_addr=1 ;;
    *) e_addr=0 ;;
esac
case "$entries" in
    *tiandycloud*) e_dom=1 ;;
    *) e_dom=0 ;;
esac
case "$legacy" in
    *tiandycloud*) l_dom=1 ;;
    *) l_dom=0 ;;
esac
if [ "$e_addr" = 1 ] && [ "$e_dom" = 0 ] && [ "$l_dom" = 1 ]; then
    ok "API: домен виден в legacy_domains и НЕ виден в entries"
else
    bad "API: разделение entries/legacy_domains" \
        "entries=[$entries] legacy_domains=[$legacy]"
fi

# --- 9. Комментарии и пустые строки ------------------------------------------
# Файл создаётся с шапкой-инструкцией на 15 строк комментариев, так что засев,
# который их не отбрасывает, свалил бы в ipset весь этот текст.
{
    printf '# Исключения из обхода\n'
    printf '\n'
    printf '   \n'
    printf '203.0.113.5 # камера в прихожей\n'
    printf '\t2001:db8::5\n'
    printf '   # ещё комментарий\n'
} > "$EXCL"
run_seed
if [ "$(adds)" = "2" ] && seeded nozapret 203.0.113.5 && seeded nozapret6 2001:db8::5; then
    ok "комментарии и пустые строки засев пропускает, записи рядом с ними — берёт"
else
    bad "комментарии и пустые строки пропускаются" \
        "ожидалось 2 записи, в сет ушло: $(tr '\n' ';' < "$IPSET_LOG")"
fi

# --- 10. Доменное исключение ведёт в whitelist.txt --------------------------
# Домены исключаются другим механизмом и давно работают: whitelist.txt уходит
# движку как --hostlist-exclude. Проверяем весь путь целиком — домен ложится
# туда, в адресном файле его при этом нет, и движок этот файл действительно
# получает. Средний пункт и есть то, что раньше было сломано.
: > "$EXCL"
: > "$LISTS/whitelist.txt"
act 'whitelist_add "tiandycloud.com"' >/dev/null 2>&1
act 'exclude_add "tiandycloud.com"'   >/dev/null 2>&1
w_ok=0; grep -qxF 'tiandycloud.com' "$LISTS/whitelist.txt" 2>/dev/null && w_ok=1
x_ok=0; grep -qxF 'tiandycloud.com' "$EXCL" 2>/dev/null || x_ok=1
g_ok=0; grep -qF -- '--hostlist-exclude=${lists_dir}/whitelist.txt' "$CFGGEN" && g_ok=1
if [ "$w_ok" = 1 ] && [ "$x_ok" = 1 ] && [ "$g_ok" = 1 ]; then
    ok "домен уходит в whitelist.txt (движку как --hostlist-exclude), а не в адресный файл"
else
    bad "домен уходит в whitelist.txt, а не в адресный файл" \
        "whitelist=$w_ok адресный-файл-чист=$x_ok движок-получает-whitelist=$g_ok"
fi

# --- 11. Бэкенд: дедупликация, валидация, удаление --------------------------
: > "$EXCL"
( ZAPRET2_DIR="$SB" LISTS_DIR="$LISTS" EXCLUDE_FILE="$EXCL"
  export ZAPRET2_DIR LISTS_DIR EXCLUDE_FILE
  # shellcheck source=../webpanel/cgi/actions.sh
  . "$ACTIONS" 2>/dev/null || true
  exclude_add "203.0.113.0/24"   || exit 11
  exclude_add "2001:db8::1"      || exit 12
  exclude_add "203.0.113.0/24"   || exit 13      # идемпотентность
  exclude_add "плохой домен"     2>/dev/null && exit 21
  exclude_add "-flag"            2>/dev/null && exit 22
  exclude_add 'a;rm -rf /'       2>/dev/null && exit 23
  exit 0 )
rc=$?
case "$rc" in
    0)  ok "бэкенд: добавление подсети/IPv6 и отказ на мусоре" ;;
    1[1-3]) bad "бэкенд: добавление" "легитимная запись отвергнута (код $rc)" ;;
    2[1-3]) bad "бэкенд: валидация" "принят опасный ввод (код $rc)" ;;
    *)  bad "бэкенд" "неожиданный код $rc" ;;
esac

[ -f "$EXCL" ] && n=$(grep -c . "$EXCL") || n=0
if [ "$n" = "2" ]; then
    ok "бэкенд: в файле ровно 2 записи (дубль не добавился)"
else
    bad "бэкенд: дедупликация" "в файле $n записей вместо 2"
fi

act 'exclude_delete "203.0.113.0/24"' >/dev/null 2>&1
if grep -q "203.0.113" "$EXCL" 2>/dev/null; then
    bad "бэкенд: удаление" "запись осталась в файле"
else
    ok "бэкенд: удаление работает"
fi

# Удалённая запись не должна воскресать при следующем старте, а оставшаяся —
# обязана доехать до сета: иначе «не воскресла» ничего не значит.
run_seed
if seeded nozapret6 2001:db8::1 && ! seeded nozapret 203.0.113.0/24; then
    ok "после удаления в сет уходит только оставшаяся запись"
else
    bad "после удаления в сет уходит только оставшаяся запись" \
        "в сет ушло: $(tr '\n' ';' < "$IPSET_LOG")"
fi

# --- 12. API-эндпоинты присутствуют ------------------------------------------
for ep in "GET /exclude" "POST /exclude/add" "POST /exclude/delete"; do
    if grep -qF -- "$ep" "$API"; then
        ok "API: $ep"
    else
        bad "API: $ep" "эндпоинт не зарегистрирован"
    fi
done

# --- 13. Файл переживает переустановку ---------------------------------------
# Он лежит ВНУТРИ дерева, которое reinstall уносит в .old и удаляет. Пока
# инсталлятор про него не знал, переустановка стирала адреса безвозвратно —
# причём незаметно: сет живёт в ядре и держит их до первой перезагрузки.
# Проверяем поведением: гоняем сами блоки бэкапа и восстановления из install.sh
# на песочном дереве, а не грепом по тексту.
INST_SH="$HERE/lib/install.sh"
SBOX="$TMP/reinstall"
mkdir -p "$SBOX/tree/ipset" "$SBOX/backup"
printf '203.0.113.7\n198.51.100.0/24\n' > "$SBOX/tree/ipset/zapret-hosts-user-exclude.txt"

# Блок бэкапа и блок восстановления вырезаем по якорям и исполняем как есть.
_bk=$(awk '/Адресные исключения \(вкладка/,/^        fi$/' "$INST_SH")
_rs=$(awk '/Восстановить адресные исключения/,/^        fi$/' "$INST_SH")
if [ -n "$_bk" ] && [ -n "$_rs" ]; then
    (
        ZAPRET2_DIR="$SBOX/tree"; backup_tmp="$SBOX/backup"
        die() { exit 1; }; print_success() { :; }
        eval "$_bk"
        rm -rf "$ZAPRET2_DIR"          # ровно то, что делает reinstall
        mkdir -p "$ZAPRET2_DIR"
        eval "$_rs"
    ) 2>/dev/null
    if [ "$(cat "$SBOX/tree/ipset/zapret-hosts-user-exclude.txt" 2>/dev/null)" = "$(printf '203.0.113.7\n198.51.100.0/24')" ]; then
        ok "адресные исключения переживают переустановку"
    else
        bad "адресные исключения переживают переустановку" \
            "после reinstall осталось: [$(cat "$SBOX/tree/ipset/zapret-hosts-user-exclude.txt" 2>/dev/null)]"
    fi
else
    bad "адресные исключения переживают переустановку" \
        "в install.sh не найден блок бэкапа или восстановления"
fi

# Путь обязан совпадать у всех троих: панель пишет, сид читает, инсталлятор
# сохраняет. Расхождение здесь и было корнем — инсталлятор про файл не знал.
_p='ipset/zapret-hosts-user-exclude.txt'
if grep -qF "$_p" "$ACTIONS" && grep -qF "$_p" "$HERE/files/S99zapret2.new" && grep -qF "$_p" "$INST_SH"; then
    ok "путь к файлу одинаков у панели, сида и инсталлятора"
else
    bad "путь к файлу одинаков у панели, сида и инсталлятора" \
        "actions=$(grep -cF "$_p" "$ACTIONS") seed=$(grep -cF "$_p" "$HERE/files/S99zapret2.new") install=$(grep -cF "$_p" "$INST_SH")"
fi

# --- Грамматика файла — одна, и она наша ------------------------------------
#
# Файл читают ровно двое: засев при старте файрвола и панель. Оба срезают
# комментарий после «#» и пробелы, оба пропускают строки, которые не адрес.
# Апстримная ночная пересборка (ipset/get_config.sh -> mdig -> ipset flush
# nozapret), которая читала тот же файл в СВОЕЙ грамматике — целиком, без
# срезания, с разрешением доменов — из планировщика убрана 02.09.2026
# (tests/test_no_upstream_ipset_job.sh). Отсюда утверждения ниже: то, что
# обещает подсказка рядом с файлом, обязано исполняться засевом.
run_seed_out() { : > "$IPSET_LOG"; D4=0 D6=0 sh "$TMP/seed_driver.sh" 2>/dev/null; }

# 9. Комментарий в конце строки не уносит адрес.
cat > "$EXCL" <<'EOF2'
203.0.113.10   # камера в подъезде
203.0.113.11 #без пробела
	203.0.113.12	# с табами
EOF2
run_seed
if [ "$(adds)" = "3" ] && seeded nozapret 203.0.113.10 && seeded nozapret 203.0.113.11 && seeded nozapret 203.0.113.12; then
    ok "адрес с комментарием в конце строки засевается (пробел, без пробела, табы)"
else
    bad "адрес с комментарием в конце строки засевается" \
        "в сет ушло: $(tr '\n' ';' < "$IPSET_LOG")"
fi

# 10. Пустые строки и строки-комментарии безвредны и не считаются пропущенными.
printf '# шапка\n\n203.0.113.20\n\n   \n# хвост\n' > "$EXCL"
out=$(run_seed_out)
if [ "$(adds)" = "1" ] && seeded nozapret 203.0.113.20; then
    ok "пустые строки и строки-комментарии не мешают соседним адресам"
else
    bad "пустые строки и строки-комментарии не мешают" "в сет ушло: $(tr '\n' ';' < "$IPSET_LOG")"
fi
case "$out" in
    *skipped*|*пропущен*) bad "комментарии и пустые строки не считаются пропущенными" "вывод: $out" ;;
    *) ok "комментарии и пустые строки не считаются пропущенными" ;;
esac

# 11. Доменная строка пропускается, НЕ разрешается — и об этом сказано вслух.
# Это ровно то, что обещает подсказка рядом с файлом. Раньше молчаливость была
# половиной беды: человек не мог узнать, что запись не действует.
cat > "$EXCL" <<'EOF2'
cam7.tiandycloud.com
203.0.113.30
example.com   # с комментарием
EOF2
out=$(run_seed_out)
if [ "$(adds)" = "1" ] && seeded nozapret 203.0.113.30 && ! grep -q 'tiandycloud\|example' "$IPSET_LOG"; then
    ok "доменные строки в сет не попадают, адрес рядом — попадает"
else
    bad "доменные строки в сет не попадают" "в сет ушло: $(tr '\n' ';' < "$IPSET_LOG")"
fi
case "$out" in
    *"2 "*skipped*|*skipped*"2"*) ok "засев сообщает, сколько строк пропущено как не-адрес (2)" ;;
    *) bad "засев сообщает, сколько строк пропущено как не-адрес (2)" "вывод: [$out]" ;;
esac

# 12. Файл-спутник с подсказкой создаётся, а сам файл — пустым и без шапки.
ENSURE=$(awk '/^z2k_ensure_user_exclude_file\(\)/{i=1} i{print} i&&/^\}/{exit}' "$INIT")
CLEAN_BASE="$TMP/cleanroom"
mkdir -p "$CLEAN_BASE/ipset"
CLEAN_F="$CLEAN_BASE/ipset/zapret-hosts-user-exclude.txt"
{
    printf '#!/bin/sh\n'
    printf 'ZAPRET_BASE=%s\n' "$CLEAN_BASE"
    printf '%s\n' "$ENSURE"
    printf '"$@"\n'
} > "$TMP/clean_driver.sh"
rm -f "$CLEAN_F"
sh "$TMP/clean_driver.sh" z2k_ensure_user_exclude_file >/dev/null 2>&1
if [ -f "$CLEAN_F" ] && [ ! -s "$CLEAN_F" ]; then
    ok "новый файл исключений создаётся пустым"
else
    bad "новый файл исключений создаётся пустым" "нет файла или в нём шапка"
fi
HINT="$CLEAN_BASE/ipset/zapret-hosts-user-exclude.README.txt"
if [ -s "$HINT" ]; then
    ok "подсказка лежит в файле-спутнике README"
else
    bad "подсказка лежит в файле-спутнике README" "документация потерялась совсем"
fi

# 13. Миграции «вычистить комментарии из файла» больше нет: она существовала
# только ради mdig, а mdig этот файл больше не читает. Молча переписывать
# пользовательский файл без причины нельзя.
if grep -q 'z2k_strip_user_exclude_comments' "$INIT"; then
    bad "миграция z2k_strip_user_exclude_comments удалена" "функция осталась — файл пользователя переписывается без причины"
else
    ok "миграция z2k_strip_user_exclude_comments удалена"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
