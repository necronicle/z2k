#!/bin/sh
# lib/utils.sh - Утилиты, проверки и константы для z2k
# Часть z2k v2.0 - Модульный установщик zapret2 для Keenetic

# ==============================================================================
# КОНСТАНТЫ
# ==============================================================================

# Версия z2k
Z2K_VERSION="2.0.1"

# Пути установки.
#
# Присваивание УСЛОВНОЕ — ровно по той же причине, что и у GITHUB_RAW ниже.
# Раньше эти четыре пути затирались безусловно, и любой, кто выставил их до
# подключения этого файла, молча терял свои значения при первой же перегенерации
# конфига. Вебпанели пришлось это обходить вручную: она сохраняла четвёрку
# вокруг сорсинга и возвращала на место (webpanel/cgi/actions.sh), потому что
# иначе внутри ОДНОГО запроса набор путей оказывался наполовину переключённым —
# ZAPRET2_DIR уже новый, а CONFIG_FILE/WHITELIST_FILE/STATE_FILE ещё старые.
#
# Костыль был лечением симптома. Лечим причину: кто задал путь явно, тот его и
# оставляет за собой; умолчания подставляются только когда переменной нет.
ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_DIR="${CONFIG_DIR:-/opt/etc/zapret2}"
CATEGORY_STRATEGIES_CONF="${CATEGORY_STRATEGIES_CONF:-${CONFIG_DIR}/category_strategies.conf}"
LISTS_DIR="${LISTS_DIR:-${ZAPRET2_DIR}/lists}"

# Z2K-специфичная переменная для init скрипта (не конфликтует с zapret2)
Z2K_INIT_SCRIPT="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

# Обратная совместимость (может перезаписываться модулями zapret2)
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

# Экспортировать для использования в функциях
export ZAPRET2_DIR
export CONFIG_DIR
export LISTS_DIR
export Z2K_INIT_SCRIPT
export INIT_SCRIPT

# Рабочая директория
WORK_DIR="${WORK_DIR:-/tmp/z2k}"
LIB_DIR="${LIB_DIR:-${WORK_DIR}/lib}"

# GitHub URLs. GITHUB_RAW must respect whatever z2k.sh set before
# sourcing this lib — otherwise a bare assignment here would silently
# override cross-branch test installs. Default only kicks in when
# utils.sh is sourced from outside the z2k.sh bootstrap (rare path).
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}"
# Z4R_BASE_URL / Z4R_LISTS_URL / Z2R_BASE_URL удалены: константы указывали на
# сторонние репозитории zapret4rocket и не читались ничем — всё качается через
# GITHUB_RAW + z2k_fetch. Оставлять их значило заявлять зависимость, которой нет.

# VPS SNI-passthrough egress для GitHub — см. z2k.sh для полного docstring.
# RU блокирует Fastly anycast github; наш VPS форвардит SNI-совпавшие
# github(usercontent) хосты на реальный backend с сертом github → обычный
# `--resolve <host>:443:<VPS>` качает по валидному TLS. Транзиентно.
Z2K_VPS_GH_IP="${Z2K_VPS_GH_IP:-213.176.74.63}"

# Бюджет коннекта Layer 0 и число попыток.
#
# Замер 2026-08-21 на живом роутере: здоровый коннект к нашему VPS — 0.075 с
# TCP, 0.185 с вместе с TLS. При этом 13-17% попыток не устанавливаются вовсе:
# SYN до VPS доходит, VPS отвечает SYN-ACK через 14 мкс, обратный пакет
# теряется, а повторные SYN до VPS уже не долетают. Со --connect-timeout 10
# каждый такой случай стоил полные 10.5 с — за одну установку 10 штук, то есть
# 105 с из 405.
#
# curl(1) про --connect-timeout: "The connection phase is considered complete
# when the DNS lookup and requested TCP, TLS or QUIC handshakes are done", то
# есть бюджет покрывает и TLS — меряем против 0.185 с, а не против 0.075 с.
# 3 с = 16-кратный запас к измеренному.
#
# Вторая попытка, а не просто короткий таймаут: Layer 0 существует ради тех, у
# кого прямой github закрыт, и бросать основной путь из-за одного потерянного
# пакета нельзя. Потеря SYN-ACK — событие независимое, повтор стоит 0.27 с.
Z2K_FETCH_VPS_CONNECT_TIMEOUT="${Z2K_FETCH_VPS_CONNECT_TIMEOUT:-8}"
Z2K_FETCH_VPS_TRIES="${Z2K_FETCH_VPS_TRIES:-2}"

# Echo `--resolve h:443:<VPS> ...` для всех github-хостов цепочки редиректов,
# но только для URL, чей origin VPS passthrough-роутит (*.githubusercontent.com,
# github.com/*.github.com). Пусто для jsdelivr/gh-proxy/прочих (пинить нельзя).
_z2k_vps_gh_resolve() {
    [ -n "${Z2K_VPS_GH_IP:-}" ] || return 0
    # Извлечь реальный host (между :// и первым /), чтобы жадный glob не
    # матчил github-хост В ПУТИ (напр. gh-proxy.com/https://raw.github...).
    local _h="${1#*://}"; _h="${_h%%/*}"; _h="${_h%%:*}"
    case "$_h" in
        *.githubusercontent.com|github.com|*.github.com) ;;
        *) return 0 ;;
    esac
    local h
    for h in raw.githubusercontent.com objects.githubusercontent.com \
             release-assets.githubusercontent.com gist.githubusercontent.com \
             github.com codeload.github.com api.github.com; do
        printf ' --resolve %s:443:%s' "$h" "$Z2K_VPS_GH_IP"
    done
}

# Файлы конфигурации
STRATEGIES_CONF="${CONFIG_DIR}/strategies.conf"
CURRENT_STRATEGY_FILE="${CONFIG_DIR}/current_strategy"
QUIC_STRATEGIES_CONF="${CONFIG_DIR}/quic_strategies.conf"
QUIC_STRATEGY_FILE="${CONFIG_DIR}/quic_strategy.conf"
RUTRACKER_QUIC_STRATEGY_FILE="${CONFIG_DIR}/rutracker_quic_strategy.conf"

# Цвета для вывода (если терминал поддерживает)
if [ -t 1 ]; then
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[1;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_RESET='\033[0m'
else
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_RESET=''
fi

# --- z2k shared shell helpers (canonical; keep byte-identical in all 4 copies) ---
#
# КОПИИ, А НЕ ОБЩИЙ ФАЙЛ — по той же причине, что и у _z2k_curl_etag: z2k.sh
# качается через `curl | sh` тогда, когда lib/utils.sh в системе ещё нет, а
# files/z2k-update-lists.sh и files/z2k-geosite.sh запускаются из cron
# самостоятельными скриптами и utils.sh не сорсят вовсе. Забор с этим же
# словарём стоит вокруг awk-фильтра адресов в files/z2k-warp.sh — держим блок
# байт в байт, расхождение стережёт тест.

# z2k_uint ЗНАЧЕНИЕ ДЕФОЛТ [МИН] [МАКС] — печатает целое, годное для `test`.
#
# Ручки приходят из окружения (cron, install.sh, рука человека), и мусор в них
# стоил целого слоя: Z2K_FETCH_VPS_TRIES=abc роняло `test` с «Illegal number» —
# цикл не исполнялся ни разу; Z2K_FETCH_VPS_CONNECT_TIMEOUT="3s" заставляло curl
# выйти с rc=2 и не напечатать ничего. В обоих случаях Layer 0 молча выключался
# на весь прогон, а в поток установки сыпалась ошибка.
#
# Не-число заменяем дефолтом, а выход за границы ЗАЖИМАЕМ, а не сбрасываем в
# дефолт: потолок обязан оставаться потолком, иначе TRIES=100000 вернулся бы к
# двум попыткам вместо обещанных пяти. Ноль уезжает в пол по той же логике:
# --connect-timeout 0 у curl означает «без ограничения вовсе».
z2k_uint() {
    local _zu_v="$1"
    case "$_zu_v" in ''|*[!0-9]*) _zu_v="$2" ;; esac
    if [ -n "${3:-}" ] && [ "$_zu_v" -lt "$3" ]; then _zu_v="$3"; fi
    if [ -n "${4:-}" ] && [ "$_zu_v" -gt "$4" ]; then _zu_v="$4"; fi
    printf '%s' "$_zu_v"
}

# z2k_connfail КОД_ВОЗВРАТА_CURL КОД_ОТВЕТА — истина, если запрос умер в ФАЗЕ
# СОЕДИНЕНИЯ, то есть от сервера не пришло ничего. Только такой отказ имеет
# смысл повторять: потерянный пакет рукопожатия — событие независимое.
#
# Раньше гейт повтора смотрел на %{time_connect}, и это ловило меньше, чем
# обещало: time_connect считает ОДИН TCP-хендшейк, а --connect-timeout по
# curl(1) ограничивает DNS+TCP+TLS целиком. Замер: коннект в чёрную дыру даёт
# tc=0.000000 (повтор), а «TCP встал, TLS не ответил» — tc=0.032246, то есть
# уходило в break, хотя это ровно тот же класс отказа, ради которого повтор и
# заводился.
#
# Считаем по коду возврата curl В СВЯЗКЕ с кодом ответа: 6 (DNS), 7 (connect
# refused), 28 (timeout), 35 (TLS) при пустом или 000 ответе означают, что
# ответа не было. Тот же rc=28, но с кодом ответа 200 — это упор в --max-time
# на УЖЕ идущей передаче, и повторять его нельзя: повтор просто удваивает цену
# отказа. 5xx, 404, пустое тело и промах sha-гейта — тем более.
z2k_connfail() {
    case "$1" in
        6|7|28|35) ;;
        *) return 1 ;;
    esac
    case "$2" in
        ''|000) return 0 ;;
    esac
    return 1
}
# --- end z2k shared shell helpers ---

# ==============================================================================
# z2k_fetch — загрузка файла с GitHub через цепочку зеркал.
# ==============================================================================
#
# Дублирует функцию из z2k.sh для модулей/скриптов, которые source'ят
# lib/utils.sh напрямую (обход ломается у части ISP на raw.github —
# jsdelivr/gh-proxy/DNS override покрывают все известные сценарии блока).
#
# Слои (пробуем по порядку, первый успех возвращает 0):
#   1. raw.githubusercontent.com
#   2. cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/<path>  (edge TTL 12ч)
#   3. gh-proxy.com/<raw-url>                             (без кеша)
# Четвёртого слоя больше нет: он писал постоянные записи в конфиг роутера,
# см. комментарий в теле функции.
# _z2k_curl_etag — helper для z2k_fetch. See z2k.sh for full docstring.
# Как и с z2k_fetch ниже: не затираем богатую копию из z2k.sh, если она уже в
# области видимости. Сегодня две реализации семантически совпадают, так что
# перетирание безвредно — но именно поэтому оно и опасно: любая фича,
# добавленная в копию z2k.sh, потерялась бы молча, без единого признака.
if ! command -v _z2k_curl_etag >/dev/null 2>&1; then
_z2k_curl_etag() {
    local url="$1" dest="$2" resolve_args="$3" conn_to="${4:-10}"
    local etag_file="${dest}.etag"
    local hdr_file="${dest}.hdr.$$"
    local tmp_body="${dest}.new.$$"
    local old_etag="" http_status curl_rc
    if [ -f "$etag_file" ] && [ -s "$dest" ]; then
        old_etag=$(cat "$etag_file" 2>/dev/null)
    fi
    # $resolve_args (unquoted word-split — намеренно): пусто в обычных вызовах,
    # `--resolve h:443:ip ...` в Layer 0 VPS-хопе.
    # ОГРАНИЧИТЕЛЬ ЗАВИСШЕЙ ПЕРЕДАЧИ. --connect-timeout бюджетирует ТОЛЬКО
    # рукопожатие; после него у передачи оставался один потолок — --max-time 180.
    # Блокировка по SNI рвёт соединение сразу и стоит миллисекунды, а вот
    # ЗАМЕДЛЕНИЕ выглядит как живой канал: байты идут, но по капле. Такой файл
    # держал слой три минуты, и на полутора сотнях файлов обновления это часы
    # вместо перехода к следующему зеркалу. --speed-limit/--speed-time обрывают
    # передачу, если она пятнадцать секунд идёт медленнее килобайта в секунду:
    # медленная, но живая загрузка не страдает, мёртвая отпускает за 15 с.
    if [ -n "$old_etag" ]; then
        http_status=$(curl -sSL --connect-timeout "$conn_to" --max-time 180 --speed-limit "${Z2K_FETCH_STALL_BYTES:-1024}" --speed-time "${Z2K_FETCH_STALL_SECONDS:-15}" $resolve_args \
            -H "If-None-Match: $old_etag" -D "$hdr_file" -o "$tmp_body" \
            -w "%{http_code} %{time_connect}" "$url" 2>/dev/null)
        curl_rc=$?
    else
        http_status=$(curl -sSL --connect-timeout "$conn_to" --max-time 180 --speed-limit "${Z2K_FETCH_STALL_BYTES:-1024}" --speed-time "${Z2K_FETCH_STALL_SECONDS:-15}" $resolve_args \
            -D "$hdr_file" -o "$tmp_body" \
            -w "%{http_code} %{time_connect}" "$url" 2>/dev/null)
        curl_rc=$?
    fi
    # Код ответа и время установления соединения приходят одной строкой — но
    # только пока curl напечатал её целиком. На НЕПУСТОМ выводе без пробела
    # `${x##* }` возвращает СТРОКУ ЦЕЛИКОМ: in=[200] давало CONNECT=[200], и
    # гейт повтора принимал код ответа за время коннекта. Копия в geosite от
    # этого страхуется подстановкой "000 0", здесь не страховало ничто.
    # Нет пробела — значит времени коннекта нет.
    case "$http_status" in
        *' '*) Z2K_LAST_CONNECT="${http_status##* }" ;;
        *)     Z2K_LAST_CONNECT=0 ;;
    esac
    http_status="${http_status%% *}"
    # Отказ ФАЗЫ СОЕДИНЕНИЯ — единственный класс, который стоит повторять на
    # Layer 0 (см. z2k_connfail). Считаем здесь и по СЫРОМУ коду ответа: ниже
    # он местами подменяется на 000 для отчёта вызывающему, и гейт повтора
    # принял бы оборванную на середине передачу за потерянное рукопожатие.
    Z2K_LAST_CONNFAIL=0
    if z2k_connfail "$curl_rc" "$http_status"; then Z2K_LAST_CONNFAIL=1; fi
    [ "$curl_rc" -eq 0 ] || { rm -f "$hdr_file" "$tmp_body"; return 1; }
    case "$http_status" in
        304) rm -f "$hdr_file" "$tmp_body"; return 0 ;;
        200)
            [ ! -s "$tmp_body" ] && { rm -f "$hdr_file" "$tmp_body"; return 1; }
            local new_etag
            new_etag=$(grep -i '^etag:' "$hdr_file" 2>/dev/null | head -1 \
                       | sed 's/^[^:]*:[[:space:]]*//; s/\r$//; s/[[:space:]]*$//')
            mkdir -p "$(dirname "$dest")" 2>/dev/null
            # Провалившийся mv оставил бы dest со СТАРЫМ телом, а ETag ниже
            # записался бы от НОВОГО — и следующий запрос получил бы на это
            # рассогласование честный 304, то есть протухший файл закрепился бы
            # как валидный. Здесь это дополнительно прикрыто sha-гейтом
            # (_z2k_verify_fetched у вызывающего), но полагаться на слой выше
            # в транспорте не нужно: копия в z2k-update-lists.sh уже делает так.
            if ! mv -f "$tmp_body" "$dest"; then
                rm -f "$hdr_file" "$tmp_body" "$etag_file"
                return 1
            fi
            if [ -n "$new_etag" ]; then printf '%s\n' "$new_etag" > "$etag_file"
            else rm -f "$etag_file"; fi
            rm -f "$hdr_file"; return 0 ;;
        *) rm -f "$hdr_file" "$tmp_body"; return 1 ;;
    esac
}
fi

# ==============================================================================
# Аварийные наборы стратегий
# ==============================================================================
#
# ЖИВУТ ЗДЕСЬ, А НЕ В strategies.sh, И ЭТО НЕСУЩЕЕ.
#
# Их зовут два разных потребителя: create_default_strategy_files (установка) и
# _z2k_pool_default в config_official.sh (ЛЮБАЯ пересборка конфига). Второй путь
# чаще: его дёргает вебпанель на каждое переключение тумблера. А вебпанель
# (webpanel/cgi/actions.sh, _gen_libs_source) сорсит ровно два файла — utils.sh
# и config_official.sh, — и strategies.sh среди них нет.
#
# Пока определения лежали в strategies.sh, проверка `command -v` в
# _z2k_pool_default на пути вебпанели всегда была ложной, и роутер с обнулённым
# Strategy.txt получал обратно одиночный fake без circular — ровно то, что
# правка отменяла. Тест этого не видел: он грепал текст исходника.


# Аварийный пул на случай, когда манифест стратегий не прочитался.
#
# ПОЧЕМУ ОН ОБЯЗАН НЕСТИ circular. Прежний аварийный дефолт был одиночным
# статическим `fake:blob=fake_default_tls:repeats=4` — без ротации вообще. Это
# строго хуже, чем у любого соседнего проекта: у конкурента три стратегии под
# circular лежат статикой в пакете и не могут не прочитаться, а мы в той же
# ситуации оставались с одним приёмом и без единого запасного.
#
# Техника здесь не выдумана: слоты 1-3 повторяют то, что уже стоит в боевых
# пулах (fake+multisplit, multisplit со сдвигом, fake+fakedsplit). Блоб только
# встроенный в движок: в аварии скачанных файлов из files/fake/ может не быть
# тоже, и ссылаться на них — значит получить пул, который не стартует.
z2k_emergency_tcp_pool() {
    local key="$1"
    printf '%s' "--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello --out-range=-s34228 --lua-desync=circular:fails=3:retrans=2:maxseq=16384:time=60:key=${key}:nld=2 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:tls_mod=rnd,dupsid,sni=www.google.com:strategy=1 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1,midsld:strategy=1 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1:strategy=2 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:tcp_ts=-1000:badsum:strategy=3 --lua-desync=fakedsplit:payload=tls_client_hello:dir=out:pos=1:strategy=3"
}

# Лесенка repeats 11/6/3 — не произвол: её дважды пытались срезать и дважды
# откатывали по живым поломкам мобильного QUIC.
#
# ФИЛЬТРЫ ПЕРЕД circular — ЧАСТЬ ПОРОГА, А НЕ ОФОРМЛЕНИЕ.
#
# Ключ и пороги здесь скопированы с боевого пула (config_official.sh: quic_udp),
# а `--in-range=a --out-range=a --payload=all` при копировании потерялись, и
# осталось `--payload=quic_initial`. Порог от них зависит напрямую: udp_in=3
# требует ЧЕТЫРЁХ входящих пакетов на успех, а входящие серверные QUIC после
# Initial уже не quic_initial — с узким фильтром детектор их просто не видит,
# успех недостижим в принципе, и пул ротируется на здоровом трафике. Ключ
# автостейта у него общий с боевым (yt_quic), так что ложные провалы уезжают
# ещё и в общее состояние. Форма фильтров обязана совпадать с боевой.
z2k_emergency_quic_pool() {
    printf '%s' "--filter-udp=443 --filter-l7=quic --in-range=a --out-range=a --payload=all --lua-desync=circular:fails=3:time=60:udp_in=3:udp_out=5:key=yt_quic:nld=2 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=11:strategy=1 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=6:strategy=2 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=3:strategy=3"
}

# --- запись ключа в config -------------------------------------------------
#
# ЕДИНСТВЕННАЯ писалка конфига. Раньше их было шесть: канон в webpanel/cgi/
# actions.sh и пять инлайн-копий в lib/menu.sh. Копии не экранировали значение,
# и это не косметика — конфиг ИСПОЛНЯЕТСЯ как скрипт (files/S99zapret2.new:
# `. "$ZAPRET_CONFIG"`), поэтому голое POLICY_NAME=Через ВПН уводит второе слово
# на исполнение как команду.
#
# Расхождение уже стоило поведения: вебпанель кириллические имена политики
# принимает (там аккуратный подсчёт символов UTF-8), а меню их отвергало
# фильтром [A-Za-z0-9_-] — один и тот же параметр вёл себя по-разному в
# зависимости от того, откуда его правят.
set_flag() {
    # set_flag <key> <value> <file>
    local key="$1" val="$2" file="$3"
    [ -f "$file" ] || { echo "file not found: $file" >&2; return 1; }
    # Конфиг ИСПОЛНЯЕТСЯ как скрипт (files/S99zapret2.new: `. "$ZAPRET_CONFIG"`),
    # поэтому голое POLICY_NAME=Через ВПН уводит второе слово на исполнение как
    # команду. Всё, что не является голым безопасным словом, пишем в ОДИНАРНЫХ
    # кавычках: двойные оставили бы работающими $ и обратную кавычку. Внутренний
    # апостроф закрывается и вставляется отдельно ('\''), как это делает shell.
    #
    # Значения из [A-Za-z0-9_.-] (то есть все флаги 0/1) остаются голыми
    # намеренно: ровно так их пишет генератор (lib/config_official.sh), и на этот
    # вид завязаны проверки вида `grep -q "^ENABLED=1"` в files/000-zapret2.sh и
    # z2k-nfqueue-selfheal.sh. Один ключ не должен выглядеть в конфиге
    # по-разному в зависимости от того, кто его последним трогал.
    local _val _esc
    case "$val" in
        ''|*[!A-Za-z0-9_.-]*) _val="'$(printf '%s' "$val" | sed "s/'/'\\\\''/g")'" ;;
        *) _val="$val" ;;
    esac
    # Второй слой — для sed: разделитель здесь слэш, & в замене означает «весь
    # совпавший текст», а обратный слэш мог прийти из экранирования апострофа.
    _esc=$(printf '%s' "$_val" | sed 's/[&/\\]/\\&/g')

    # ЗАМОК ВОКРУГ ЧТЕНИЯ-ИЗМЕНЕНИЯ-ЗАПИСИ.
    #
    # Ниже grep решает, править существующую строку или дописать новую, а sed -i
    # переписывает файл целиком. Между этими шагами другой процесс успевает
    # сделать ровно то же самое, и его правка исчезает: sed -i на BusyBox пишет
    # временный файл и переименовывает его поверх, то есть побеждает тот, кто
    # закончил вторым, а первый флаг возвращается к прежнему значению.
    #
    # Это не редкость. В конфиг через set_flag пишут больше десятка тумблеров
    # вебпанели, меню и сам планировщик; человек щёлкает переключатели подряд,
    # каждый уходит отдельным CGI-запросом, и один из них откатывается сам собой
    # через секунду. Списки в панели от этого уже защищены (_list_lock в
    # webpanel/cgi/actions.sh), а главный конфиг — единственное, что писалось
    # без всякой защиты вообще.
    #
    # Чиним здесь, а не в четырнадцати вызовах: set_flag — единственная дверь к
    # этой записи, и замок в ней закрывает заодно меню, которое к _list_lock
    # доступа не имеет.
    #
    # Имя замка НАМЕРЕННО отличается от того, что берёт _list_lock: если когда-
    # нибудь вызывающий возьмёт список под замок и внутри позовёт set_flag на тот
    # же путь, одинаковое имя дало бы взаимную блокировку намертво, а разное —
    # просто два независимых замка.
    local _lk="${file}.z2k-flaglock" _n=0
    while ! mkdir "$_lk" 2>/dev/null; do
        # Держатель мог уйти вместе с убитым CGI. Замок старше минуты — битый:
        # критическая секция здесь это единицы миллисекунд.
        if [ -n "$(find "$_lk" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rmdir "$_lk" 2>/dev/null
            continue
        fi
        _n=$((_n + 1))
        if [ "$_n" -gt 100 ]; then
            echo "config busy: $file" >&2
            return 1
        fi
        usleep 20000 2>/dev/null || sleep 1
    done

    if grep -q "^${key}=" "$file"; then
        sed -i "s/^${key}=.*/${key}=${_esc}/" "$file"
    else
        printf '%s=%s\n' "$key" "$_val" >> "$file"
    fi
    _sf_rc=$?
    rmdir "$_lk" 2>/dev/null
    return $_sf_rc
}

# --- целостность файла стратегий -------------------------------------------
#
# ЖИВЁТ ЗДЕСЬ, А НЕ В config_official.sh, по той же причине, что и аварийные
# пулы выше: проверку зовёт не только генерация конфига, но и диагностика, а
# копия, вложенная внутрь чужой функции, снаружи не видна вовсе — две копии
# одной проверки расходятся молча.
#
# USB-флешка умеет тихо отдавать вместо содержимого сплошные 0x00/0xFF (мёртвый
# блок NAND: размер и mtime целы, данных нет — полевой случай 2026-08-06,
# роутер владельца, два файла из трёх). Такой мусор, попав в обработку
# NFQWS2_OPT, вешает генерацию в бесконечный цикл и пишет на диск конфиг-мину,
# которая роняет nfqws2 на следующем рестарте.
#
# Проверяем три признака:
#   1. NUL/0xFF-байты — в строке опций их быть не может;
#   2. хотя бы один `--`, то есть файл вообще похож на набор опций. Намеренно
#      НЕ требуем `--lua-desync`: пользовательская стратегия может состоять из
#      одних фильтров, и отвергать её было бы ложным срабатыванием;
#   3. завершающий перевод строки. Все писатели этих файлов кладут его
#      безусловно (lib/strategies.sh: `echo "$params" >`, вебпанель:
#      `printf '%s\n'`), поэтому его отсутствие — признак обрыва записи на
#      середине: тот же умирающий носитель, пойманный за другой конец.
# Смысловую валидность всё равно проверяет nfqws2 --dry-run у вызывающего.
z2k_strategy_file_sane() {
    local _f="$1" _junk _tail
    # Арифметическое сравнение, а не строковое: `wc -c` на части платформ
    # (BSD/busybox-вариантах) паддит вывод пробелами, и `[ "  0" != "0" ]`
    # дало бы ложный REJECT на исправном файле; в `-gt` ведущие пробелы
    # съедаются числовым контекстом.
    _junk=$(tr -cd '\000\377' < "$_f" | wc -c)
    [ "${_junk:-0}" -gt 0 ] 2>/dev/null && return 1
    grep -q -- "--" "$_f" || return 1
    # Подстановка команды срезает завершающие переводы строки: у целого файла
    # последний байт даёт ПУСТУЮ строку, у обрезанного — сам символ. Отсутствие
    # tail (или нечитаемый файл) трактуем как «проверить нечем» и пропускаем:
    # отказ в генерации конфига дороже непойманного обрыва.
    _tail=$(tail -c 1 "$_f" 2>/dev/null) || _tail=""
    [ -z "$_tail" ] || return 1
    return 0
}

# z2k_sha256_file FILE -> hex digest on stdout, empty if it cannot be computed.
# busybox ships sha256sum on Entware and openssl-util is a declared dependency,
# so in practice one of these always exists.
# z2k_host_jitter <макс_секунд> — своя для каждого роутера задержка 0..макс-1.
#
# ЗАЧЕМ. Ночные задачи стоят на точных минутах (02:00 обновление, 03:00
# статистика, 04:00 списки). Без разброса весь флот делает их одновременно:
# роутер получает пик нагрузки в одну и ту же минуту, наш VPS — весь флот
# разом, GitHub — тоже.
#
# ПОЧЕМУ НЕ cksum. Раньше считали через `cksum`, которого на Entware НЕТ, а
# следом стояло «не посчиталось — значит ноль». Тихий сбой превращался в
# «ноль у всех», и разброса не было НИКОГДА, ни на одном роутере (замер на
# роутере владельца: fire 02:00:20 → done 02:00:22 вместо +46 минут).
#
# ПОЭТОМУ ЗДЕСЬ НЕТ ПУТИ, ВЕДУЩЕГО В НОЛЬ ДЛЯ ВСЕХ. Не сошлось с md5sum —
# пробуем sha256sum, не вышло и это — берём pid и время: пусть значение
# будет неповторяемым, лишь бы не общим. Разное время у всех важнее, чем
# одинаковое от ночи к ночи у одного.
#
# В хеш идёт hostname ПЛЮС MAC: заводские имена у части моделей совпадают,
# а MAC свой у каждого.
z2k_host_jitter() {
    local max="${1:-5400}" host hex j
    case "$max" in ''|*[!0-9]*) max=5400 ;; esac
    [ "$max" -gt 0 ] || max=5400
    host=$(hostname 2>/dev/null)
    [ -n "$host" ] || host=$(cat /proc/sys/kernel/hostname 2>/dev/null)
    host="${host}$(cat /sys/class/net/*/address 2>/dev/null | head -1)"
    hex=""
    if command -v md5sum >/dev/null 2>&1; then
        hex=$(printf '%s' "$host" | md5sum 2>/dev/null | cut -c1-6)
    fi
    case "$hex" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) hex="" ;;
    esac
    if [ -z "$hex" ] && command -v sha256sum >/dev/null 2>&1; then
        hex=$(printf '%s' "$host" | sha256sum 2>/dev/null | cut -c1-6)
        case "$hex" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
            *) hex="" ;;
        esac
    fi
    j=""
    [ -n "$hex" ] && j=$(( 0x$hex % max )) 2>/dev/null
    case "$j" in
        ''|*[!0-9]*) j=$(( ($$ + $(date +%s 2>/dev/null || echo 1)) % max )) ;;
    esac
    echo "$j"
}

z2k_sha256_file() {
    [ -f "$1" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    else
        return 1
    fi
}

# _z2k_verify_fetched DEST — gate a just-fetched file against the digest the caller
# expects, passed in $Z2K_FETCH_SHA256. Unset (the common case) = accept.
#
# Why this exists: every hop below terminates TLS somewhere we do not control
# (jsdelivr, gh-proxy) or answers from a cache (a 304 leaves whatever is already
# on disk). Without this the transport decides what gets installed, and a mirror
# that is merely STALE is indistinguishable from one that is fresh — the router
# silently keeps an old file while the version tag moves forward. That is not
# hypothetical: it stranded a user on a revision from two days earlier across
# five consecutive releases (issue #26), and no log anywhere showed a failure.
#
# On mismatch the local copy AND its etag are destroyed. Dropping the etag is
# the load-bearing half: leaving it would let the next hop send If-None-Match,
# collect a 304, and re-accept the very bytes we just rejected.
#
# If no digest tool exists we accept and warn rather than fail: refusing every
# update on such a router is a worse outcome than the status quo it inherits.
_z2k_verify_fetched() {
    local dest="$1" src="${2:-}" want="${Z2K_FETCH_SHA256:-}" got
    [ -n "$want" ] || return 0
    got=$(z2k_sha256_file "$dest" 2>/dev/null)
    if [ -z "$got" ]; then
        printf '[z2k_fetch] нечем посчитать sha256 — проверка содержимого пропущена\n' >&2
        return 0
    fi
    [ "$got" = "$want" ] && return 0
    # ИМЯ ИСТОЧНИКА В СООБЩЕНИИ ОБЯЗАТЕЛЬНО. Без него журнал говорит «байты не
    # те», но не говорит ОТКУДА, и разбор случая упирается в догадки: у нас
    # четыре слоя, и виноват всегда ровно один. Ровно так и вышло с диагностикой
    # 26.08.2026 — установить зеркало по журналу было нельзя.
    printf '[z2k_fetch] %s: содержимое не совпало с ожидаемым (ждали %.12s…, получили %.12s…) — источник отклонён\n' \
        "${src:-источник}" "$want" "$got" >&2
    rm -f "$dest" "${dest}.etag" 2>/dev/null
    return 1
}

# Если z2k_fetch уже определён (из z2k.sh — там богатая версия с DoH layer 5
# и chunked range-fallback), не затираем — иначе проигрываем фичи каждый раз
# когда utils.sh sourcится после z2k.sh. Локальная версия ниже остаётся как
# минимально-достаточный fallback для standalone-сценариев (webpanel CGI,
# tests/test_utils.sh, z2k-diag) где z2k.sh не вызывался.
if ! command -v z2k_fetch >/dev/null 2>&1; then
z2k_fetch() {
    local src="$1"
    local dest="$2"
    local url

    case "$src" in
        http://*|https://*) url="$src" ;;
        /*) url="${GITHUB_RAW}${src}" ;;
        *)  url="${GITHUB_RAW}/${src}" ;;
    esac

    # Coverage:
    #   raw.githubusercontent.com — jsdelivr CDN + gh-proxy reverse.
    #   github.com/<o>/<r>/releases/download/<tag>/<asset> — gh-proxy
    #     mirrors release tarballs (jsdelivr НЕ зеркалит releases).
    local jsdelivr="" gh_proxy=""
    case "$url" in
        https://raw.githubusercontent.com/*)
            local _rest="${url#https://raw.githubusercontent.com/}"
            local _owner="${_rest%%/*}";  _rest="${_rest#*/}"
            local _repo="${_rest%%/*}";   _rest="${_rest#*/}"
            local _branch="${_rest%%/*}"; _rest="${_rest#*/}"
            jsdelivr="https://cdn.jsdelivr.net/gh/${_owner}/${_repo}@${_branch}/${_rest}"
            gh_proxy="https://gh-proxy.com/${url}"
            ;;
        https://github.com/*/releases/download/*)
            gh_proxy="https://gh-proxy.com/${url}"
            ;;
    esac

    # gh-proxy — только там, где результат кто-то проверит.
    #
    # Разница между зеркалами не в надёжности, а в том, кто владеет ключом от
    # TLS. jsdelivr и gh-proxy оба терминируют соединение у себя, но jsdelivr —
    # Fastly с юрлицом, а gh-proxy анонимный сторонний прокси. Layer 0 (VPS)
    # безопасен: там подменяется только адрес назначения, TLS остаётся сквозным
    # до GitHub, и подделать его нельзя.
    #
    # Отключаем gh-proxy для файлов РЕПОЗИТОРИЯ без известного дайджеста. Это
    # ровно один важный случай — сам манифест: он корень доверия и сверять его
    # не с чем по построению. Подменённый манифест несёт ЧУЖИЕ хеши, и после
    # него проверка каждого следующего файла подтверждает подмену вместо того,
    # чтобы её ловить.
    #
    # Релиз-ассетам gh-proxy ОСТАВЛЯЕМ. Они не «непроверенные» — просто
    # проверяются не здесь, а ниже по течению: бинарники движка против
    # апстримного sha256sum.txt, install_bin.sh против нашего пина. И это
    # единственное их запасное зеркало: jsdelivr релизы не зеркалит вовсе, так
    # что отнять gh-proxy у тарбола значит оставить часть людей без движка.
    case "$url" in
        https://raw.githubusercontent.com/*)
            [ -z "${Z2K_FETCH_SHA256:-}" ] && gh_proxy=""
            ;;
    esac

    # Layer 0: VPS SNI-passthrough egress — первичный путь для github (RU
    # блокирует прямые github-IP). На сбой тихо валимся в цепочку ниже.
    # Each hop is gated by _z2k_verify_fetched: a mirror that answers with the wrong
    # bytes (stale cache, truncated body) is treated exactly like one that did
    # not answer at all, and we move to the next.
    local _vps_resolve; _vps_resolve=$(_z2k_vps_gh_resolve "$url")

    # ПРЯМОЙ GITHUB — ПЕРВЫМ, ПОКА ОН ОТВЕЧАЕТ.
    #
    # Раньше первым шёл наш VPS. Смысл в том, что часть провайдеров режет
    # адреса GitHub, и таким людям прямой путь закрыт совсем. Но у этого
    # порядка есть цена, которую видно только на масштабе: ВЕСЬ флот ходит к
    # GitHub с ОДНОГО адреса — нашего узла, — а лимиты там считаются по адресу
    # источника. Пока роутеров было немного, потолок не доставали; чем больше
    # флот, тем чаще упираемся, и хуже всего в момент публикации, когда все
    # идут разом. Замер 31.08.2026: в тишине узел получает ответ за 25 мс, под
    # нагрузкой появляются зависания в три секунды и обрывы.
    #
    # Поэтому порядок обратный: сначала пробуем прямой путь — он идёт с адреса
    # самого человека и ни с кем не делится, — и только если он не отвечает,
    # уходим на узел.
    #
    # ВЕРДИКТ ВЫНОСИТСЯ ОДИН РАЗ ЗА ПРОГОН. Иначе человек с заблокированным
    # GitHub платил бы таймаут на КАЖДОМ файле, а их в обновлении полсотни.
    # Механизм тот же, что у размыкателя слоя VPS ниже: считаем подряд идущие
    # отказы ФАЗЫ СОЕДИНЕНИЯ, после второго прямой путь выключается до конца
    # прогона. Успех счётчик обнуляет.
    #
    # Бюджет короткий: три секунды на решение «жив или нет». Это не загрузка,
    # это проба; здоровое соединение укладывается в десятки миллисекунд.
    #
    # Z2K_FETCH_DIRECT_FIRST=0 возвращает прежний порядок одной переменной.
    if [ -n "$_vps_resolve" ] && [ "${Z2K_FETCH_DIRECT_FIRST:-1}" = "1" ] \
       && [ "${Z2K_FETCH_DIRECT_OUT:-0}" != "1" ]; then
        local _d_ct
        _d_ct=$(z2k_uint "${Z2K_FETCH_DIRECT_CONNECT_TIMEOUT:-3}" 3 1 30)
        if _z2k_curl_etag "$url" "$dest" "" "$_d_ct" \
           && _z2k_verify_fetched "$dest" "GitHub напрямую"; then
            Z2K_FETCH_DIRECT_CONNFAILS=0; export Z2K_FETCH_DIRECT_CONNFAILS
            return 0
        fi
        # Отказ по СОДЕРЖИМОМУ сюда не идёт: там виноват не путь, и выключать
        # его из-за одного расхождения значит терять быстрый путь на ровном
        # месте. Считаем только отказы соединения — как и у слоя VPS.
        if [ "${Z2K_LAST_CONNFAIL:-0}" = "1" ]; then
            Z2K_FETCH_DIRECT_CONNFAILS=$(( ${Z2K_FETCH_DIRECT_CONNFAILS:-0} + 1 ))
            export Z2K_FETCH_DIRECT_CONNFAILS
            if [ "$Z2K_FETCH_DIRECT_CONNFAILS" -ge "$(z2k_uint "${Z2K_FETCH_DIRECT_GIVEUP:-2}" 2 1 20)" ]; then
                Z2K_FETCH_DIRECT_OUT=1; export Z2K_FETCH_DIRECT_OUT
                printf '[z2k_fetch] прямой GitHub не отвечает %s раз подряд — дальше через VPS\n' \
                    "$Z2K_FETCH_DIRECT_CONNFAILS" >&2
            fi
        fi
    fi

    # Слой 0 отключён размыкателем ниже, если VPS не отвечал подряд.
    if [ -n "$_vps_resolve" ] && [ "${Z2K_FETCH_VPS_OUT:-0}" != "1" ]; then
        local _vps_tries _vps_ct
        # --- z2k layer0 vps knobs (canonical; keep byte-identical in all 4 copies) ---
        # Санитайз ручек — в z2k_uint: мусор → дефолт, выход за границы → зажим.
        # Потолок в 5 попыток держит Layer 0 от превращения в многочасовой
        # последовательный перебор ДО того, как будет испробован прямой путь.
        # Вложенность у четвёртой копии своя — сравнивать без ведущих пробелов.
        _vps_tries=$(z2k_uint "${Z2K_FETCH_VPS_TRIES:-2}" 2 1 5)
        _vps_ct=$(z2k_uint "${Z2K_FETCH_VPS_CONNECT_TIMEOUT:-8}" 8 1)
        # --- end z2k layer0 vps knobs ---
        local _vps_try=0
        while [ "$_vps_try" -lt "$_vps_tries" ]; do
            _vps_try=$((_vps_try + 1))
            if _z2k_curl_etag "$url" "$dest" "$_vps_resolve" \
                   "$_vps_ct" \
               && _z2k_verify_fetched "$dest" "VPS"; then
                Z2K_FETCH_VPS_CONNFAILS=0; export Z2K_FETCH_VPS_CONNFAILS
                return 0
            fi
            # --- z2k layer0 retry gate (canonical; keep byte-identical in all 4 copies) ---
            # Повторяем ТОЛЬКО отказ фазы соединения (см. z2k_connfail).
            # Вложенность у четвёртой копии своя — сравнивать без ведущих пробелов.
            [ "${Z2K_LAST_CONNFAIL:-0}" = "1" ] || break
            # --- end z2k layer0 retry gate ---
        done
        # --- z2k layer0 breaker (canonical; keep byte-identical in all 4 copies) ---
        # Мёртвый VPS не должен стоить бюджета НА КАЖДОМ файле. Обновление тянет
        # полторы сотни файлов, и при 8 с в две попытки это сорок минут чистого
        # ожидания там, где ответ известен уже после первого. Считаем ПОДРЯД
        # идущие отказы ФАЗЫ СОЕДИНЕНИЯ; после второго слой 0 отключается до
        # конца прогона, любой его успех счётчик обнуляет.
        #
        # Отказ по СОДЕРЖИМОМУ сюда не идёт намеренно: там виноват не канал, и
        # следующий файл с того же VPS может прийти целым. Отключать слой из-за
        # одного расхождения значит терять первичный путь на ровном месте.
        if [ "${Z2K_LAST_CONNFAIL:-0}" = "1" ]; then
            # Считаем ПОПЫТКИ, а не вызовы: две подряд и есть исчерпанный
            # бюджет слоя. По вызовам порог не взводился бы на первом файле,
            # то есть ровно там, где ответ уже известен.
            Z2K_FETCH_VPS_CONNFAILS=$(( ${Z2K_FETCH_VPS_CONNFAILS:-0} + _vps_try ))
            export Z2K_FETCH_VPS_CONNFAILS
            if [ "$Z2K_FETCH_VPS_CONNFAILS" -ge "$(z2k_uint "${Z2K_FETCH_VPS_GIVEUP:-2}" 2 1 20)" ]; then
                Z2K_FETCH_VPS_OUT=1; export Z2K_FETCH_VPS_OUT
                printf '[z2k_fetch] VPS не отвечает %s раз подряд — слой 0 отключён до конца прогона\n' \
                    "$Z2K_FETCH_VPS_CONNFAILS" >&2
            fi
        fi
        # --- end z2k layer0 breaker ---
    fi

    if _z2k_curl_etag "$url" "$dest" && _z2k_verify_fetched "$dest" "GitHub напрямую"; then return 0; fi
    [ -n "$jsdelivr" ] && _z2k_curl_etag "$jsdelivr" "$dest" && _z2k_verify_fetched "$dest" "jsdelivr" && return 0
    [ -n "$gh_proxy" ] && _z2k_curl_etag "$gh_proxy" "$dest" && _z2k_verify_fetched "$dest" "gh-proxy" && return 0

    # ЧЕТВЁРТЫЙ СЛОЙ (ndmc "ip host") УБРАН 30.08.2026.
    #
    # Он писал ПОСТОЯННЫЕ записи в конфиг роутера пользователя. Приём был
    # скопирован из чужого проекта (zapret4rocket) коммитом f4897e2 от 23.04,
    # и в описании того коммита прямым текстом стоит «not tested».
    #
    # На поле это дало помойку: у GitHub много адресов, CDN отдаёт разные, и
    # каждый неудачный заход добавлял ещё строку. У пользователя набралось по
    # три-четыре записи на домен, а у Keenetic под статический DNS всего 256
    # слотов. Лезть в конфиг роутера ради четвёртой попытки скачивания мы
    # права не имеем.
    #
    # Накопленное вычищается z2k_ndmc_cleanup() — при установке, обновлении и
    # удалении.

    return 1
}
fi  # ! command -v z2k_fetch

# ==============================================================================
# ФУНКЦИИ ВЫВОДА
# ==============================================================================

print_success() {
    printf "${COLOR_GREEN}[[OK]]${COLOR_RESET} %s\n" "$1"
}

print_error() {
    printf "${COLOR_RED}[[FAIL]]${COLOR_RESET} %s\n" "$1" >&2
}

print_warning() {
    printf "${COLOR_YELLOW}[!]${COLOR_RESET} %s\n" "$1"
}

print_info() {
    printf "${COLOR_BLUE}[i]${COLOR_RESET} %s\n" "$1"
}

print_header() {
    printf "\n${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
    printf "${COLOR_BLUE}  %s${COLOR_RESET}\n" "$1"
    printf "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n\n"
}

print_separator() {
    printf "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
}

# ==============================================================================
# ПРОВЕРКИ СИСТЕМЫ
# ==============================================================================

# Проверка прав root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Требуются права root для установки"
        print_info "Запустите: sudo sh z2k.sh"
        return 1
    fi
    return 0
}

# Получить архитектуру Entware (предпочтительно для выбора бинарников)
get_entware_arch() {
    local opkg_bin="opkg"
    [ -x /opt/bin/opkg ] && opkg_bin="/opt/bin/opkg"
    command -v "$opkg_bin" >/dev/null 2>&1 || return 1

    "$opkg_bin" print-architecture 2>/dev/null | awk '
        $1 == "arch" && $2 != "all" {
            prio = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
            if (prio >= max) { max = prio; arch = $2 }
        }
        END { if (arch != "") print arch }
    '
}

map_arch_to_bin_arch() {
    case "$1" in
        aarch64|arm64|*aarch64*|*arm64*) echo "linux-arm64" ;;
        armv7l|armv6l|arm|*armv7*|*armv6*|arm*) echo "linux-arm" ;;
        x86_64|amd64|*x86_64*|*amd64*) echo "linux-x86_64" ;;
        i386|i486|i586|i686|x86) echo "linux-x86" ;;
        *mipsel64*|*mips64el*|*mips64le*) echo "linux-mips64el" ;;
        *mips64*) echo "linux-mips64" ;;
        *mipsel*) echo "linux-mipsel" ;;
        *mips*) echo "linux-mips" ;;
        *lexra*) echo "linux-lexra" ;;
        *ppc*) echo "linux-ppc" ;;
        *riscv64*) echo "linux-riscv64" ;;
        *) return 1 ;;
    esac
}

# Detect endianness from ELF header of a binary
detect_endianness() {
    local bin=""
    for f in /opt/bin/opkg /opt/bin/busybox /opt/sbin/nfqws2; do
        [ -f "$f" ] && bin="$f" && break
    done
    [ -z "$bin" ] && return 1
    # ELF EI_DATA is byte 6 (offset 5): \x01=LE, \x02=BE
    # dd + comparison works on any busybox
    local byte
    byte=$(dd if="$bin" bs=1 skip=5 count=1 2>/dev/null)
    case "$byte" in
        "$(printf '\x01')") echo "le" ;;
        "$(printf '\x02')") echo "be" ;;
        *) return 1 ;;
    esac
}

# Получить архитектуру системы (с приоритетом Entware)
get_arch() {
    local entware_arch
    entware_arch=$(get_entware_arch)
    if [ -n "$entware_arch" ]; then
        echo "$entware_arch"
        return
    fi

    local arch
    arch=$(uname -m)

    # uname -m returns "mips" for both mips and mipsel — detect endianness from ELF
    if [ "$arch" = "mips" ]; then
        local endian
        endian=$(detect_endianness)
        if [ "$endian" = "le" ]; then
            echo "mipsel"
            return
        fi
    fi

    echo "$arch"
}

# Проверка, установлен ли zapret2
is_zapret2_installed() {
    [ -d "$ZAPRET2_DIR" ] && [ -x "${ZAPRET2_DIR}/nfq2/nfqws2" ]
}

# Проверка, запущен ли сервис zapret2
is_zapret2_running() {
    if [ -f "$INIT_SCRIPT" ]; then
        pgrep -f "nfqws2" >/dev/null 2>&1
    else
        return 1
    fi
}

# Получить статус сервиса
get_service_status() {
    if is_zapret2_running; then
        echo "Активен"
    elif is_zapret2_installed; then
        echo "Остановлен"
    else
        echo "Не установлен"
    fi
}

# Получить текущую стратегию
get_current_strategy() {
    if [ -f "$CURRENT_STRATEGY_FILE" ]; then
        safe_config_read "CURRENT_STRATEGY" "$CURRENT_STRATEGY_FILE" "не задана"
    else
        echo "не задана"
    fi
}

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

# Безопасное чтение значения из config файла (без eval)
# Использование: val=$(safe_config_read "KEY" "/path/to/config")
safe_config_read() {
    local key=$1
    local file=$2
    local default=${3:-""}

    if [ ! -f "$file" ]; then
        echo "$default"
        return 0
    fi

    local raw
    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -1)
    if [ -z "$raw" ]; then
        echo "$default"
        return 0
    fi

    # Извлечь значение после первого '=', удалить кавычки и пробелы
    local val
    val=$(printf '%s' "$raw" | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
    # Empty value (e.g. `KEY=` with nothing after equals) must fall back
    # to default, not propagate as "". Same fix as webpanel/cgi/actions.sh
    # read_flag (Владислав's JSON breakage, 2026-04-15). Without this,
    # create_official_config reads empty → emits empty → toggle → regen →
    # reads empty again: infinite empty-value cycle.
    [ -z "$val" ] && val="$default"
    echo "$val"
}

# Создать резервную копию файла
backup_file() {
    local file=$1
    local backup
    backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    local max_backups=5  # Хранить только последние 5 бэкапов

    if [ -f "$file" ]; then
        # Очистить старые бэкапы, оставив только последние (max_backups - 1)
        # -1 потому что сейчас создадим еще один
        # Удалить старые бэкапы напрямую (без subshell)
        ls -t "${file}.backup."* 2>/dev/null | tail -n +${max_backups} | xargs rm -f 2>/dev/null || true

        # Создать новый бэкап
        cp "$file" "$backup" || return 1
        print_info "Резервная копия: $backup"
    fi
    return 0
}

# Восстановить из резервной копии
restore_backup() {
    local file=$1
    local backup

    # Найти последний backup
    backup=$(ls -t "${file}.backup."* 2>/dev/null | head -n 1)

    if [ -n "$backup" ] && [ -f "$backup" ]; then
        cp "$backup" "$file" || return 1
        print_success "Восстановлено из: $backup"
        return 0
    else
        print_error "Резервная копия не найдена"
        return 1
    fi
}

# Очистить старые бэкапы для файла
cleanup_backups() {
    local file=$1
    local keep=${2:-5}  # По умолчанию хранить 5 последних

    local all_backups
    all_backups=$(ls -t "${file}.backup."* 2>/dev/null)

    if [ -z "$all_backups" ]; then
        print_info "Бэкапы не найдены для $file"
        return 0
    fi

    local total_count
    total_count=$(echo "$all_backups" | wc -l)

    if [ "$total_count" -le "$keep" ]; then
        print_info "Бэкапов: $total_count (в пределах нормы)"
        return 0
    fi

    # Удалить старые бэкапы напрямую (xargs — без subshell mutation)
    local deleted
    deleted=$(echo "$all_backups" | tail -n +$((keep + 1)) | xargs rm -f 2>/dev/null; echo "$all_backups" | tail -n +$((keep + 1)) | wc -l | tr -d ' ')

    print_success "Очищено бэкапов: ${deleted}, осталось: ${keep}"
    return 0
}

# Проверить бинарный файл
verify_binary() {
    local binary=$1

    if [ ! -f "$binary" ]; then
        print_error "Файл не найден: $binary"
        return 1
    fi

    if [ ! -x "$binary" ]; then
        print_error "Файл не исполняемый: $binary"
        return 1
    fi

    # Различаем «не запускается» и «запустился, но баннер незнакомый». Раньше
    # оба случая давали return 0 с одним предупреждением, поэтому ветка
    # «[FAIL] nfqws2 не запускается» у единственного вызывающего была
    # недостижима, и шаг проверки рапортовал «[OK] nfqws2 работает» про
    # бинарник чужой архитектуры. Первый настоящий гейт стоял только на шаге
    # 12/12 — то есть после слима binaries/, копирования дерева в /opt и правок
    # роутера, а на чистой установке откатывать уже нечего.
    if ! "$binary" --version >/dev/null 2>&1; then
        print_error "Бинарник не запускается: $binary"
        return 1
    fi

    local version_output
    version_output=$("$binary" --version 2>&1 | head -1)

    if echo "$version_output" | grep -q "github version"; then
        return 0
    fi

    # Запускается, но баннер не наш — это не повод рушить установку: шаг 12
    # проверит баннер строго и сам решит.
    print_warning "Неожиданный баннер версии: $binary"
    return 0
}

# Каталоги с модулями прошивки. В поле встречаются обе раскладки:
# /lib/modules/<kver> (4.9-ndm-5) и /lib/system-modules/<kver> (NDMS 5.1.2, issue
# #27) — на второй первый каталог существует, но содержит только метаданные, без
# единого .ko. Ищем в обоих. /opt сюда не входит: лежащая там копия от другого
# ядра — это неверный ABI.
Z2K_MODDIRS=
z2k_module_dirs() {
    local kv d
    if [ -z "$Z2K_MODDIRS" ]; then
        kv=$(uname -r 2>/dev/null)
        for d in "/lib/modules/$kv" "/lib/system-modules/$kv" /lib/modules /lib/system-modules; do
            [ -d "$d" ] && Z2K_MODDIRS="$Z2K_MODDIRS $d"
        done
    fi
    echo "$Z2K_MODDIRS"
}

# Есть ли возможность, которую даёт модуль? Спрашиваем реестр ядра, а не lsmod:
# на стоковой прошивке почти всё это встроено, lsmod не показывает ничего, и
# "модуль не загружен" — ложь. Именно из-за lsmod установщик ругался на модули,
# которые на самом деле на месте.
z2k_module_present() {
    case "$1" in
        xt_multiport)    grep -qw multiport /proc/net/ip_tables_matches 2>/dev/null ;;
        xt_connbytes)    grep -qw connbytes /proc/net/ip_tables_matches 2>/dev/null ;;
        xt_connmark)     grep -qw connmark  /proc/net/ip_tables_matches 2>/dev/null ;;
        xt_CONNMARK)     grep -qw CONNMARK  /proc/net/ip_tables_targets 2>/dev/null ;;
        xt_NFQUEUE)      grep -qw NFQUEUE   /proc/net/ip_tables_targets 2>/dev/null ;;
        nfnetlink_queue) [ -e /proc/net/netfilter/nfnetlink_queue ] ;;
        *)               lsmod 2>/dev/null | grep -q "^$1 " ;;
    esac
}

# Путь к .ko модуля $1 в дереве прошивки, если он там есть.
z2k_module_ko() {
    local m="$1" d f
    for d in $(z2k_module_dirs); do
        f="$d/$m.ko"
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    f=$(find /lib -name "$m.ko" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && { echo "$f"; return 0; }
    return 1
}

# insmod $1 из дерева прошивки. 0 только если .ko найден И принят ядром.
z2k_insmod_fw() {
    local f
    f=$(z2k_module_ko "$1") || return 1
    insmod "$f" 2>/dev/null
}

# Будет ли модуль доступен к моменту старта сервиса: либо возможность уже в ядре,
# либо есть .ko, который загрузчик подтянет. Нужно для предполётной проверки,
# которая бежит ДО загрузки модулей и иначе ругалась бы на всё подряд.
z2k_module_obtainable() {
    z2k_module_present "$1" || z2k_module_ko "$1" >/dev/null
}

# Проверка загрузки модуля ядра
check_kernel_module() {
    z2k_module_present "$1"
}

# Загрузка модуля ядра
load_kernel_module() {
    local module=$1

    # Встроен в ядро или уже загружен — делать и говорить нечего.
    if z2k_module_present "$module"; then
        return 0
    fi

    print_info "Загрузка модуля: $module"

    # modprobe в PATH — из Entware, он ищет в /opt/lib/modules/<kver>, которого на
    # Keenetic нет. Поэтому после него грузим .ko по абсолютному пути сами.
    modprobe "$module" 2>/dev/null
    z2k_module_present "$module" && { print_success "Модуль $module загружен"; return 0; }

    z2k_insmod_fw "$module"
    if z2k_module_present "$module"; then
        print_success "Модуль $module загружен"
        return 0
    fi

    print_error "Модуль $module недоступен в этой прошивке — правила, которым он нужен, установлены не будут"
    return 1
}

# Умеет ли ядро делать ipset типа bitmap:port. Проверяем не наличием .ko, а
# попыткой создать сет: тип может быть вкомпилен в ядро (тогда файла нет вовсе),
# а может отсутствовать в прошивке целиком — и различить это можно только так.
# Важно, потому что на bitmap:port висят zport_tcp/zport_udp, а на них — ВСЕ
# правила nfqws; запасного пути через --dport в движке нет, так что недоступный
# тип означает полностью нерабочий пакетный обход (issue #27).
z2k_bitmap_port_available() {
    # Без ipset проверить нечем. Отвечаем "доступен", чтобы не пугать ложной
    # тревогой: ipset ставится шагом раньше, и его собственное отсутствие — это
    # отдельная ошибка, о которой сообщает тот шаг.
    command -v ipset >/dev/null 2>&1 || return 0

    if ! z2k_module_present ip_set_bitmap_port; then
        z2k_insmod_fw ip_set_bitmap_port || true
    fi

    ipset destroy z2k_probe_bitmap 2>/dev/null
    if ipset create z2k_probe_bitmap bitmap:port range 0-65535 2>/dev/null; then
        ipset destroy z2k_probe_bitmap 2>/dev/null
        return 0
    fi
    return 1
}

# Получить версию nfqws2
get_nfqws2_version() {
    local nfqws2="${ZAPRET2_DIR}/nfq2/nfqws2"

    if [ -x "$nfqws2" ]; then
        "$nfqws2" --help 2>&1 | head -n 1 | awk '{print $NF}' || echo "unknown"
    else
        echo "not installed"
    fi
}

# Показать информацию о системе
show_system_info() {
    print_header "Информация о системе"

    printf "%-20s: %s\n" "Архитектура" "$(get_arch)"
    printf "%-20s: %s\n" "Entware" "$([ -d /opt ] && echo 'установлен' || echo 'не установлен')"
    printf "%-20s: %s\n" "Свободное место" "$(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo 'unknown')"
    printf "%-20s: %s\n" "zapret2" "$(is_zapret2_installed && echo 'установлен' || echo 'не установлен')"
    printf "%-20s: %s\n" "nfqws2 версия" "$(get_nfqws2_version)"
    printf "%-20s: %s\n" "Сервис" "$(get_service_status)"
    printf "%-20s: %s\n" "Текущая стратегия" "#$(get_current_strategy)"

    print_separator
}

# Запрос подтверждения у пользователя
confirm() {
    local _ans_l=""
    local prompt=${1:-"Продолжить?"}
    local default=${2:-"Y"}
    local answer=""

    while true; do
        if [ "$default" = "Y" ]; then
            printf "%s [Y/n]: " "$prompt"
        else
            printf "%s [y/N]: " "$prompt"
        fi

        if ! read -r answer </dev/tty; then
            return 1
        fi

        answer=$(printf '%s' "$answer" | tr -d "$(printf '\r\b\177')" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        # СРАВНЕНИЕ ЦЕЛИКОМ, А НЕ КЛАССАМИ СИМВОЛОВ.
        #
        # Раньше здесь стояло `*[Дд]|*[Дд][Аа]` и `*[Нн][Ее][Тт]`. В bash, где
        # это писалось, оно работает. На роутере оболочка BusyBox ash, и там
        # класс `[Дд]` — это не «одна из двух букв», а НАБОР БАЙТОВ: Д = D0 94,
        # д = D0 B4, то есть {D0, 94, B4}. Сопоставляется последний байт строки.
        #
        # Последствия, проверенные исполнением на dash:
        #   «отмена»  → ДА   (последние байты D0 B0: D0 попал в набор от «Д»,
        #                     B0 — в набор от «А», сработало `*[Дд][Аа]`)
        #   «неа»     → ДА
        #   «нет»     → не распознано вовсе, переспрос по кругу
        # То есть человек, набравший «отмена» на вопрос «Вы уверены? Это действие
        # необратимо!» (lib/install.sh), получал согласие. Эта функция охраняет
        # десять мест, включая восстановление конфигурации и выключение входа по
        # паролю в вебпанель.
        #
        # Полные строки в case сравниваются побайтово и целиком, поэтому ведут
        # себя одинаково в любой оболочке и локали. Регистр ASCII приводим через
        # tr (он трогает только A-Z, кириллицу не портит), а кириллические формы
        # перечисляем явно — их немного, и это честнее, чем полагаться на
        # локаль, которой на роутере может не быть вовсе.
        _ans_l=$(printf '%s' "$answer" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
        case "$_ans_l" in
            "")
                [ "$default" = "Y" ] && return 0
                return 1
                ;;
            y|yes|д|Д|да|Да|ДА|дА)
                return 0
                ;;
            n|no|н|Н|нет|Нет|НЕТ|нЕт|неа|Неа|НЕА)
                return 1
                ;;
            *)
                print_warning "Введите y/n"
                ;;
        esac
    done
}

# Пауза с сообщением
pause() {
    local message=${1:-"Нажмите Enter для продолжения..."}
    printf "%s" "$message"
    read -r _ </dev/tty
}

# Очистить экран (если в интерактивном режиме)
clear_screen() {
    if [ -t 1 ]; then
        clear
    fi
}

# ==============================================================================
# ИНИЦИАЛИЗАЦИЯ
# ==============================================================================

# Создать рабочую директорию
init_work_dir() {
    mkdir -p "$WORK_DIR" "$LIB_DIR" || {
        print_error "Не удалось создать $WORK_DIR"
        return 1
    }
    return 0
}

# Очистка рабочей директории
cleanup_work_dir() {
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
        print_info "Рабочая директория очищена"
    fi
}

# Обработчик прерывания (Ctrl+C)
interrupt_handler() {
    printf "\n"
    print_warning "Прервано пользователем"
    cleanup_work_dir
    exit 130
}

# Установить обработчики сигналов
setup_signal_handlers() {
    trap 'interrupt_handler' INT TERM
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ (для использования в других модулях)
# ==============================================================================

# Все функции автоматически доступны после source этого файла


# Force-push снёс код, но записи в running-config persistent (system save).
# Юзеры с этого окна страдают: github проксируется через VPS Frankfurt → 5-10x
# медленнее, AI-домены идут через мёртвый теперь nginx-cloak-passthrough.
#
# Этот cleanup при каждом install убирает любые ip host записи с нашими VPS-IP
# и MГТС CF alt-anycast. Idempotent: на чистом роутере noop.
#
# NB: каждый вызов ndmc в z2k префиксован `LD_LIBRARY_PATH=`. На KeenOS 4.3+/5.x,
# когда LD_LIBRARY_PATH содержит Entware-пути (/opt/lib), ndmc грузит несовместимый
# OpenSSL и падает `system failed [0xcffd0060]` / `Cli::Main: failed to initialize`
# на КАЖДОМ вызове (установка идёт через `curl|sh` в этом замусоренном окружении →
# отсюда «портянка» и не ставится). Очистка переменной для конкретного вызова
# заставляет ndmc взять системный OpenSSL. (root cause подтверждён 2026-06-22,
# forum.keenetic.ru/topic/20203)
cleanup_legacy_ip_hosts() {
    command -v ndmc >/dev/null 2>&1 || return 0
    # 213.176.74.63 / 79.137.196.7 — always-purge legacy VPS Frankfurt IPs.
    # 2.58.104.1 — also a legitimate CF alt-anycast that z2k-classify
    # recommends for МГТС L3 bypass (z2k-classify/src/main.c:115-122,
    # recipe.c:376,417). DO NOT delete entries pointing CF SLDs at it —
    # those are user-applied L3 bypasses and must survive the cleanup.
    # Heuristic: hostname containing "cloudflare" is a classifier-emitted
    # L3 bypass; everything else on 2.58.104.1 was the legacy Module-3
    # МГТС catch-all and gets purged.
    local entries
    entries=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
        | awk '
            /^ip host/ {
                host = $3; ip = $4
                if (ip == "213.176.74.63" || ip == "79.137.196.7") {
                    # Пины релея WhatsApp указывают на VPS законно — это
                    # рабочий обход, а не наследие DNS-проекта. Их сохраняем.
                    #
                    # Ticketmaster отсюда УБРАН 31.08.2026 по просьбе
                    # пользователей: он занимал 22 записи статического DNS из
                    # 256 доступных, ради одного сайта. Теперь эти записи
                    # подпадают под общее правило и снимаются чисткой.
                    if (tolower(host) ~ /whatsapp\.(com|net)$/) next
                    print; next
                }
                if (ip == "2.58.104.1") {
                    if (tolower(host) ~ /cloudflare/) next
                    print
                }
                # 4pda.to — пины ставились r-77.2 (19.08.2026) под блок по
                # адресу, который в тот же день сняли. Домен убран из HOSTS,
                # значит обновлять эти записи больше некому: адреса Cloudflare
                # ротирует, и через недели они станут мёртвыми — сайт перестанет
                # открываться у тех, у кого без нас открывался бы. Снимаем при
                # первом же обновлении, независимо от адреса.
                if (tolower(host) == "4pda.to" || tolower(host) ~ /\.4pda\.to$/) print

                # GITHUB И ЗЕРКАЛА — наш собственный мусор, снятый 30.08.2026
                # вместе с четвёртым слоем скачивания. Тот слой писал ПОСТОЯННУЮ
                # запись на КАЖДУЮ неудачную попытку, а у GitHub много адресов и
                # CDN отдаёт разные — у людей набралось по три-четыре строки на
                # домен. У Keenetic под статический DNS всего 256 слотов.
                #
                # Снимаем ПО ИМЕНИ, а не по адресу: эти записи указывают на
                # адреса самого GitHub, под правило «наши VPS-IP» выше они не
                # попадают. Список имён закрытый — ровно те семь, что писал тот
                # слой, — поэтому чужого не заденем: человек, прописавший свой
                # ip host для github, в этот набор не попадёт разве что чудом,
                # а вот всё, что попало, писали мы.
                if (tolower(host) == "github.com"          ||
                    tolower(host) == "api.github.com"      ||
                    tolower(host) == "codeload.github.com" ||
                    tolower(host) == "raw.githubusercontent.com"            ||
                    tolower(host) == "objects.githubusercontent.com"        ||
                    tolower(host) == "release-assets.githubusercontent.com" ||
                    tolower(host) == "gist.githubusercontent.com"           ||
                    tolower(host) == "cdn.jsdelivr.net"    ||
                    tolower(host) == "gh-proxy.com") print
            }' || true)
    # Under z2k.sh `set -e`, `[ -z "$x" ] && return 0` aborts the script
    # when $x is non-empty (the [ exits 1 because -z is false). Use if/fi.
    if [ -z "$entries" ]; then return 0; fi

    local removed=0 line
    local IFS_orig="$IFS"
    IFS='
'
    for line in $entries; do
        IFS="$IFS_orig"
        LD_LIBRARY_PATH= ndmc -c "no $line" >/dev/null 2>&1 && removed=$((removed + 1))
        IFS='
'
    done
    IFS="$IFS_orig"

    if [ "$removed" -gt 0 ]; then
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
        print_info "Очищено $removed записей ip host, оставшихся от прежних версий"
    fi
    # Учётный файл четвёртого слоя. Сам слой снят, писать в него больше некому,
    # а его наличие вводило бы в заблуждение при разборе следующей жалобы.
    rm -f "${ZAPRET2_DIR:-/opt/zapret2}/state/ndmc-managed.txt" 2>/dev/null || true
    return 0
}
