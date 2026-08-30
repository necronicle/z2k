#!/bin/sh
# tests/test_alert_detector_wiring.sh — поправки к штатному детектору неудач
# доезжают до конфига и не теряются по дороге.
#
# ЗАЧЕМ. Полевой разбор 2026-08-18 на боевом роутере дал два факта, каждый из
# которых стоил нескольких часов:
#
#   1. Нерабочая стратегия не ротировалась ВООБЩЕ. Захват показал, что сервер
#      подтверждает ClientHello целиком, отвечает семибайтовой записью TLS
#      alert (fatal) и закрывается по FIN. Ретрансмитить нечего, RST нет,
#      редиректа нет — у standard_failure_detector нет ни одного события.
#   2. Рабочая стратегия, наоборот, уезжала сама: телефон переслал пакет TLS
#      application data в уже установленной сессии, и штатный детектор
#      засчитал это как провал стратегии (он считает ЛЮБУЮ исходящую
#      ретрансмиссию в пределах maxseq). Двадцать девять успехов не помогли:
#      «net -26/3 content_fresh=false» — и всё равно ротация.
#
# Лечится обёрткой z2k_fail_tls_alert (files/lua/z2k-alert.lua): штатный
# детектор вызывается как есть, но исходящее уходит в него только на
# ClientHello, а к входящим добавлен фатальный алерт до ServerHello.
#
# ЧТО ОХРАНЯЕТСЯ:
#   1. Файл детектора есть и грузится init-скриптом через --lua-init.
#   2. Проводка стоит на rkn_tcp В СГЕНЕРИРОВАННОМ конфиге. Порядок здесь
#      критичен: z2k_strip_custom_detectors вырезает ЛЮБОЙ :failure_detector=,
#      поэтому строка обязана добавляться ПОСЛЕ среза. Поставленная до — молча
#      исчезает, и обе болезни возвращаются без единого красного теста.
#   3. Окно входящих пакетов NFQWS2_TCP_PKT_IN=50: при 30 наблюдение
#      обрывалось на ~20 КБ, а порог успеха у rkn_tcp — 26000, то есть успех
#      не срабатывал никогда и гасить провалы было нечем.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LUA="$ROOT/files/lua/z2k-alert.lua"
INIT="$ROOT/files/S99zapret2.new"

# --- 1. Файл на месте и грузится -----------------------------------------------
if [ -s "$LUA" ]; then
    ok "files/lua/z2k-alert.lua существует"
else
    no "файл детектора существует" "непустой файл" "нет"
fi

if grep -q -- '--lua-init=@\$LUA_Z2K_ALERT' "$INIT"; then
    ok "init-скрипт грузит z2k-alert.lua"
else
    no "init грузит детектор" "--lua-init=@\$LUA_Z2K_ALERT" "нет"
fi

# Обёртка обязана делегировать штатному, а не подменять его: иначе теряются
# входящий RST, DPI-редирект и всё окно 16К-гейта по inseq.
if grep -q 'standard_failure_detector' "$LUA"; then
    ok "обёртка делегирует standard_failure_detector"
else
    no "делегирование штатному" "вызов standard_failure_detector" "нет"
fi
# Ретрансмит — только на ПЕРВОМ запросе соединения, иначе возвращается ложная
# ротация: провалом становится любая потеря пакета в живой сессии. Для TLS это
# ClientHello, для HTTP-пула — http_req; всё остальное отсекается.
if grep -q 'Z2K_FIRST_REQUEST\[desync.l7payload\]' "$LUA" \
   && grep -q 'tls_client_hello = true' "$LUA" \
   && grep -q 'http_req = true' "$LUA"; then
    ok "ретрансмиссия считается только на первом запросе (ClientHello / http_req)"
else
    no "сужение по первому запросу" 'Z2K_FIRST_REQUEST с tls_client_hello и http_req' "нет"
fi
# Уровень alert: 2 = fatal. Уровень 1 (close_notify) — штатное завершение,
# считать его провалом значит ротировать на каждом закрытии сессии.
if grep -qE 'byte\(6\) (~=|==) 2' "$LUA"; then
    ok "провалом считается только fatal-алерт (уровень 2)"
else
    no "фильтр по уровню алерта" "проверка byte(6) на 2 (fatal)" "нет"
fi

# Живой хост не ротируем: политика «успехи гасят провалы» переехала сюда из
# снятой ветки r-49, и без неё три поддельных RST уводят рабочую страту.
if grep -q 'z2k_ok_n' "$LUA"; then
    ok "обёртка ведёт учёт живых ответов хоста"
else
    no "учёт живости" "счётчик z2k_ok_n" "нет"
fi

# --- 1b. Переключателя режима ротации в поставке нет ---------------------------
# Ветка r-49 в движке включалась переменной окружения, а init выводил её по
# подстроке: встретилось failure_detector= — значит режим не нативный. Обёртка
# делегирует штатному детектору, семантика нативная, а режим переворачивался и
# включал чужую логику (в логе — счётчики succ, которых при нативной ротации
# быть не должно). Ручку убрали из проекта целиком.
#
# Имя переменной здесь собирается из кусков намеренно: в исходниках проекта его
# больше нет, и grep по репозиторию не должен находить его снова.
_flag="Z2K_NATIVE""_ROTATION"
_hits=$(grep -rl "$_flag" "$ROOT/files" "$ROOT/lib" "$ROOT/webpanel" "$ROOT/z2k.sh" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_hits" = "0" ]; then
    ok "переключателя режима ротации нет нигде в поставке"
else
    no "ручки режима нет" "0 файлов" "$_hits"
fi

# --- 2. Проводка доезжает до конфига (порядок относительно среза) --------------
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
. "$ROOT/lib/config_official.sh" >/dev/null 2>&1

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
root="$TMP/gen"
mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
         "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" \
         "$root/extra_strats/cache/autocircular" "$root/lists"
for p in TCP/YT TCP/YT_GV TCP/RKN; do echo "example.com" > "$root/extra_strats/$p/List.txt"; done
echo "example.com" > "$root/extra_strats/UDP/YT/List.txt"
echo "w.example.com" > "$root/lists/whitelist.txt"
echo "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:strategy=1" \
    > "$root/extra_strats/TCP/RKN/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=circular:fails=3:time=60:key=yt_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:strategy=1" \
    > "$root/extra_strats/TCP/YT/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=circular:fails=3:time=60:key=gv_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:strategy=1" \
    > "$root/extra_strats/TCP/YT_GV/Strategy.txt"
echo "ENABLED=1" > "$root/config"
# Файл детектора на месте — проводка обязана появиться.
mkdir -p "$root/lua"; cp "$LUA" "$root/lua/z2k-alert.lua"

OUT=$( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null )
RKN=$(printf '%s\n' "$OUT" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" | grep -F 'key=rkn_tcp' | head -1)

case "$RKN" in
    *failure_detector=z2k_fail_tls_alert*)
        ok "rkn_tcp несёт failure_detector=z2k_fail_tls_alert" ;;
    *)
        no "проводка детектора в rkn_tcp" "failure_detector=z2k_fail_tls_alert" "срезана или не добавлена" ;;
esac

# Штатные аргументы обязаны уцелеть рядом с проводкой: детектор их использует.
case "$RKN" in
    *inseq=26000*retrans=2*|*retrans=2*inseq=26000*)
        ok "inseq и retrans на месте рядом с детектором" ;;
    *)
        no "inseq/retrans уцелели" "inseq=26000 и retrans=2" "$RKN" ;;
esac

# HTTP-пул объявляется НИЖЕ блока проводки TLS-пулов, и до 19.08.2026 его туда
# просто забыли добавить: после среза кастомных детекторов он оставался на
# голом standard_failure_detector без единого гварда. Цена — apple.com уехал с
# рабочей первой стратегии на вторую, замер тем же вечером:
#   standard_failure_detector: incoming RST s524 in range s4096   x13/мин
# Сторожим именно связь «пул объявлен ниже — проводка всё равно на нём».
HTTP=$(printf '%s\n' "$OUT" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" | grep -F 'key=http_rkn' | head -1)
case "$HTTP" in
    *failure_detector=z2k_fail_tls_alert*)
        ok "http_rkn несёт failure_detector=z2k_fail_tls_alert" ;;
    *)
        no "проводка детектора в http_rkn" "failure_detector=z2k_fail_tls_alert" "срезана или не добавлена" ;;
esac

# --- 2в. Инстанс circular не должен быть сужен по payload ----------------------
# Движок зовёт lua-инстанс только на подходящем payload. Если --payload= стоит
# ПЕРЕД circular, детектор не увидит ни одного входящего пакета С ДАННЫМИ, и
# разом умирают: правило вставшего потока, фатальный TLS-алерт, сверка TTL и
# гвард живости — им всем нужен пейлоад. Доедут только ClientHello и пустые
# пакеты, то есть RST вообще без гвардов.
#
# Замер 19.08.2026 на боевом роутере, до правки:
#   key="yt_tcp"  ... payload_type= empty tls_client_hello
#   key="gv_tcp"  ... payload_type= all
#   key="rkn_tcp" ... payload_type= all
# Сторожим порядок токенов у всех трёх TLS-пулов сразу.
for _key in rkn_tcp yt_tcp gv_tcp; do
    _prof=$(printf '%s\n' "$OUT" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" \
            | grep -F "key=$_key" | head -1)
    if [ -z "$_prof" ]; then
        no "пул $_key присутствует в конфиге" "профиль" "не найден"
        continue
    fi
    _gated=$(printf '%s' "$_prof" | tr ' ' '\n' | awk '
        /^--payload=/       { if (!seen_circular) gated = 1 }
        /^--lua-desync=circular:/ { seen_circular = 1 }
        END { print gated + 0 }')
    if [ "$_gated" = "0" ]; then
        ok "$_key: circular не сужен по payload (детектор видит данные)"
    else
        no "$_key: сужение circular по payload" "--payload= после circular" "стоит перед ним"
    fi
done

# --- 2b. Нет файла — нет и проводки --------------------------------------------
# Иначе движок валится в error() на каждом пакете профиля, и профиль РКН
# становится пустышкой при зелёном статусе сервиса.
rm -f "$root/lua/z2k-alert.lua"
OUT_NOLUA=$( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null )
RKN_NOLUA=$(printf '%s\n' "$OUT_NOLUA" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" | grep -F 'key=rkn_tcp' | head -1)
case "$RKN_NOLUA" in
    *failure_detector=*)
        no "без lua-файла проводки нет" "нет failure_detector" "проводка осталась" ;;
    *)
        ok "без lua-файла профиль остаётся на чистом штатном детекторе" ;;
esac
HTTP_NOLUA=$(printf '%s\n' "$OUT_NOLUA" | awk -f "$ROOT/tests/lib/nfqws2_flatten.awk" | grep -F 'key=http_rkn' | head -1)
case "$HTTP_NOLUA" in
    *failure_detector=*)
        no "без lua-файла http_rkn тоже без проводки" "нет failure_detector" "проводка осталась" ;;
    *)
        ok "без lua-файла http_rkn остаётся на чистом штатном детекторе" ;;
esac

# --- 3. Окно входящих ----------------------------------------------------------
# Число живёт в z2k_reply_pkt_cap: его читает и тело конфига, и сторож обрыва
# (ему потолок нужен, чтобы отличать «поток встал» от «мы ослепли»). Разъедься
# они — сторож начнёт судить вслепую, поэтому проверяем саму функцию.
_pkt_in=$(sed -n '/^z2k_reply_pkt_cap()/,/^}/p' "$ROOT/lib/config_official.sh" \
          | grep -oE 'echo 50' | head -1 | grep -oE '[0-9]+')
if [ "$_pkt_in" = "50" ]; then
    ok "NFQWS2_TCP_PKT_IN при включённом пакете = 50"
else
    no "окно входящих" "50" "${_pkt_in:-не найдено}"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
