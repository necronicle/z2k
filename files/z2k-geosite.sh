#!/bin/sh
# z2k-geosite.sh — fetch runetfreedom/russia-blocked-geosite release
# assets and replace z2k production hostlist files.
#
# Phase 12: real geosite migration. Replaces the earlier Phase 2 v2fly
# staging-only prototype. Pulls plain-text .txt release assets directly
# from github.com/runetfreedom/russia-blocked-geosite/releases/latest,
# which is the same source b4 ships as its "RUNET Freedom recommended"
# GeoSite provider. Lists are auto-updated every 6 hours upstream; we
# refresh daily via z2k-update-lists.sh cron and use ETag negotiation
# to avoid re-downloading unchanged files.
#
# Target production paths (overwrites /opt/zapret2/extra_strats/*):
#
#   RKN TCP  ← ru-blocked.txt or ru-blocked-all.txt (RAM-adaptive)
#   YT TCP   ← youtube.txt
#   YT UDP   ← youtube.txt (same source for TCP and QUIC profiles)
#   Discord  ← discord.txt (writes to TCP_Discord.txt and TCP/RKN/Discord.txt)
#
# On the very first replace the existing file is preserved as
# `<name>.shipped` so you can manually revert with `cp *.shipped <name>`
# and a service restart. No automated rollback UI by design.
#
# RKN-список: всегда ru-blocked.txt (~1,7 МБ, ~75 тыс. доменов, отобранный
# antifilter-download-community + re:filter).
#
# Полный ru-blocked-all.txt по умолчанию НЕ берётся. Раньше он выдавался
# роутерам с памятью выше порога, и это перестало быть безобидным: апстрим
# вырос почти вдвое с тех пор, как порог калибровали.
#
# Замерено 2026-08-12 на двух роутерах с одинаковой строкой запуска nfqws2
# (30794 байта, байт в байт) — разница была только в этом файле:
#
#   ru-blocked.txt        74 720 доменов → nfqws2  16,7 МБ RSS
#   ru-blocked-all.txt 1 369 008 доменов → nfqws2 177,4 МБ RSS
#
# То есть ~127 байт памяти на домен, и полный список стоит +157 МБ. На роутере
# с гигабайтом это 18% всей памяти в одном процессе, и nfqws2 становится там
# крупнейшим потребителем — больше xray. Сам апстрим помечает полный список
# как «use with caution».
#
# Кому он всё же нужен — берётся явно: Z2K_GEOSITE_RKN_ASSET=ru-blocked-all.txt.
# Осознанный выбор человека, а не догадка по объёму планок памяти.
#
# У тех, кому большой список уже приехал, он сменится на короткий сам при
# ближайшем обновлении: страж усадки пропускает смену класса списка (см.
# asset_marker ниже), поэтому путь на понижение открыт.
#
# Usage:
#   z2k-geosite.sh fetch                fetch all, replace production lists
#   z2k-geosite.sh show <asset>         fetch one asset to stdout (no write)
#   z2k-geosite.sh status               show current production line counts
#   z2k-geosite.sh --help
#
# Exit codes:
#   0   all targets fetched and applied (or unchanged via ETag)
#   1   fatal: missing dep, unwritable dir, no previous file AND fetch failed
#   2   partial: some targets updated, others kept previous version

set -u

RELEASE_BASE="${Z2K_GEOSITE_RELEASE_BASE:-https://github.com/runetfreedom/russia-blocked-geosite/releases/latest/download}"
ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
EXTRA="${ZAPRET2_DIR}/extra_strats"

# Список ложных срабатываний РКН — ОДНА точка истины на путь. Его читают двое:
# вычитание в конце прогона (subtract_false_positive_from_rkn) и гейт отпечатка
# перед загрузкой RKN (_z2k_rkn_fp_gate). Пока путь был вписан в вычитание
# литералом `/opt/zapret2/lists/...`, любой гейт, посчитавший его иначе (через
# ZAPRET2_DIR), смотрел бы на ДРУГОЙ файл и молча пропускал правку.
FP_LIST="${ZAPRET2_FALSE_POSITIVE_LIST:-${ZAPRET2_DIR}/lists/rkn-false-positive.txt}"

# Отпечаток УЖЕ ПРИМЕНЁННОГО fp-списка. Живёт в /opt/etc, а не в дереве: всё
# внутри ${ZAPRET2_DIR} умирает вместе с ним на каждой переустановке (тот же
# довод, что у persistent-маркеров one-shot purge ниже).
#
# Файл и формат ОБЯЗАНЫ совпадать с гейтом в lib/install.sh (sha256 файла,
# одной строкой). Разойдись они — два гейта считали бы отпечаток по-разному,
# каждый видел бы чужую запись как «список изменился», сносил ETag и
# переписывал маркер: полная перекачка RKN на КАЖДОМ прогоне вместо одной.
Z2K_RKN_FP_MARK="${Z2K_RKN_FP_MARK:-/opt/etc/.z2k-rkn-fp.sha256}"
# Запасной путь для роутеров, где отпечаток посчитать нечем (нет ни sha256sum,
# ни openssl): там сравниваем с копией самого списка. Отдельный файл, а не тот
# же маркер, — именно чтобы не смешивать два формата в одной записи.
Z2K_RKN_FP_COPY="${Z2K_RKN_FP_COPY:-/opt/etc/.z2k-rkn-fp.list}"

# VPS SNI-passthrough egress для GitHub — канон из z2k.sh / z2k-update-lists.sh.
# RU блокирует Fastly/anycast github по IP → прямой fetch с роутера рвётся, и
# именно geosite был ЕДИНСТВЕННЫМ github-загрузчиком z2k без этого хопа: на
# свежей установке в цензурируемой сети его прямой curl падал, geosite
# «using shipped fallback», и юзер оставался на неполном shipped-списке. VPS
# форвардит github-хосты (включая releases-редиректы objects/release-assets/
# codeload) на реальный backend с валидным сертом github. `--resolve` —
# транзиентный, per-request, без записей в конфиг.
Z2K_VPS_GH_IP="${Z2K_VPS_GH_IP:-213.176.74.63}"
# Те же ручки Layer 0, что у трёх остальных копий транспорта (z2k.sh,
# lib/utils.sh, files/z2k-update-lists.sh). Этот файл — ЧЕТВЁРТАЯ точка выхода
# на VPS, и правка бюджета до него не доехала: тут стоял зашитый
# --connect-timeout 15 без повторов, то есть один потерянный пакет
# рукопожатия стоил 15 с на VPS-хопе плюс столько же на прямом, и так на
# каждый ассет — до 45 с на шаге установки, ради экономии на котором всё и
# делалось.
Z2K_FETCH_VPS_CONNECT_TIMEOUT="${Z2K_FETCH_VPS_CONNECT_TIMEOUT:-8}"
Z2K_FETCH_VPS_TRIES="${Z2K_FETCH_VPS_TRIES:-2}"

_z2k_vps_gh_resolve() {
    [ -n "${Z2K_VPS_GH_IP:-}" ] || return 0
    # Реальный host между :// и первым / (чтобы glob не поймал github В ПУТИ).
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
ETAG_DIR="${ZAPRET2_DIR}/extra_strats/cache/geosite-etag"
TMP_DIR="/tmp/z2k-geosite.$$"

# ПОРОГА ПО ПАМЯТИ БОЛЬШЕ НЕТ, И ВОТ ПОЧЕМУ ОН БЫЛ.
#
# Он появился после полевого случая: на роутере с 489 МБ полный список
# ru-blocked-all (тогда 1,2 млн строк) РОНЯЛ nfqws2. Порог 900 МБ выдавал
# полный список только гигабайтным моделям, где он не убивал процесс.
#
# Правило работало, но решало не ту задачу: «не падает» — это не то же самое,
# что «уместно». Замер 2026-08-12 на гигабайтном роутере: полный список стоит
# 177 МБ RSS против 16,7 МБ у короткого, то есть 18% всей памяти устройства в
# одном процессе. Порог при этом калибровали, когда список был вдвое меньше.
#
# Теперь по умолчанию всем идёт короткий, а полный берётся явной переменной
# Z2K_GEOSITE_RKN_ASSET=ru-blocked-all.txt. Отбор по объёму планок памяти
# угадывал за человека цену охвата — этого больше не делаем.


cleanup() {
    [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

die() {
    echo "z2k-geosite: $1" >&2
    exit 1
}

log() {
    echo "[geosite] $*" >&2
}

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

ensure_deps() {
    command -v curl >/dev/null 2>&1 || die "curl not found"
    command -v awk  >/dev/null 2>&1 || die "awk not found"
    mkdir -p "$TMP_DIR" "$ETAG_DIR" || die "cannot create tmp/etag dirs"
}

# --- RAM-based RKN asset selection ------------------------------------------

pick_rkn_asset() {
    # Явное указание человека уважаем без разговоров — в том числе на полный
    # список: это осознанное решение, и цену его мы назвали в шапке.
    if [ -n "${Z2K_GEOSITE_RKN_ASSET:-}" ]; then
        log "RKN-ассет задан явно: ${Z2K_GEOSITE_RKN_ASSET}"
        echo "$Z2K_GEOSITE_RKN_ASSET"
        return
    fi
    # Выбора по объёму памяти больше нет. Он давал полный список любому
    # роутеру выше порога, а полный список стоит +157 МБ в nfqws2 (замер в
    # шапке) — и вырос вдвое с тех пор, как порог задавали. Отбор по железу
    # угадывал за человека, во что ему обойдётся охват; теперь по умолчанию
    # берём короткий, а полный — только по прямой просьбе.
    echo "ru-blocked.txt"
}

# --- Download an asset ONCE to a canonical tmp file ------------------------
#
# Downloads $asset to $TMP_DIR/$asset and returns one of:
#   0 — fresh content in tmp file, ready for apply
#   3 — upstream unchanged (304 ETag match); tmp file not present
#   1 — fetch failed; tmp file not present
#
# Because a single asset (e.g. youtube.txt, discord.txt) serves multiple
# production targets, we MUST NOT re-download for each target and we
# MUST NOT let the ETag cache block application to later targets. The
# fetch is cached in TMP_DIR for the lifetime of this script run; apply
# is a separate step that consumes the tmp file for each target.
fetch_to_tmp() {
    local asset="$1"
    local url="$RELEASE_BASE/$asset"
    local etag_file="$ETAG_DIR/${asset}.etag"
    local tmp="$TMP_DIR/$asset"
    local hdr="$TMP_DIR/$asset.hdr"

    # Cached within this run: if we've already populated $tmp successfully,
    # reuse it.
    if [ -s "$tmp" ]; then
        return 0
    fi
    # Cached within this run as 304: marker file tells us not to re-download.
    if [ -f "$TMP_DIR/$asset.304" ]; then
        return 3
    fi

    log "fetch $asset"

    local http _vps_resolve
    # Layer 0: VPS SNI-passthrough первым хопом. $_vps_resolve — unquoted,
    # намеренный word-split в `--resolve host:443:ip ...` (пусто → обычный curl).
    #
    # --speed-limit/--speed-time: VPS-попытка обрывается, если скорость упала
    # ниже 1 КБ/с на 30 с. Без этого зависший (принявший TCP, но молчащий) VPS
    # выбирал бы весь --max-time 600, и только потом начинался прямой запрос со
    # своими 600 — до 20 минут на ассет, а их четыре, и всё это на пути установки.
    _vps_resolve=$(_z2k_vps_gh_resolve "$url")
    # Повтор — только для отказа ФАЗЫ СОЕДИНЕНИЯ (см. z2k_connfail), как и в
    # трёх остальных копиях: потеря пакета рукопожатия независима, а вот упор
    # в --max-time на зависшей передаче или ответ 5xx повторять нельзя.
    local _vps_try=0 _vps_tries _vps_raw _ct _vps_rc _vps_ct _gs_direct_took=0 _gs_direct_tried=0
    # --- z2k layer0 vps knobs (canonical; keep byte-identical in all 4 copies) ---
    # Санитайз ручек — в z2k_uint: мусор → дефолт, выход за границы → зажим.
    # Потолок в 5 попыток держит Layer 0 от превращения в многочасовой
    # последовательный перебор ДО того, как будет испробован прямой путь.
    # Вложенность у четвёртой копии своя — сравнивать без ведущих пробелов.
    _vps_tries=$(z2k_uint "${Z2K_FETCH_VPS_TRIES:-2}" 2 1 5)
    _vps_ct=$(z2k_uint "${Z2K_FETCH_VPS_CONNECT_TIMEOUT:-8}" 8 1)
    # --- end z2k layer0 vps knobs ---
    # Бюджет коннекта — короткий ТОЛЬКО когда за спиной есть запасной путь,
    # то есть когда мы идём через VPS. При выключенном Layer 0 этот же запрос
    # И ЕСТЬ прямой, и торопиться с ним нельзя.
    if [ -n "$_vps_resolve" ]; then
        _ct="$_vps_ct"
    else
        _ct=15
    fi
    http="000"

    # ПРЯМОЙ GITHUB — ПЕРВЫМ, ПОКА ОН ОТВЕЧАЕТ.
    #
    # Это четвёртая копия слоя, и до неё порядок «сначала прямой» не доехал
    # вместе с остальными тремя. Цена видна в поле: журнал роутера, 01.09.2026 —
    # `ru-blocked.txt: VPS-хоп не прошёл (HTTP 429), пробую напрямую`, и так на
    # КАЖДОМ списке КАЖДУЮ ночь. 429 отдаёт не наш узел, а GitHub: лимиты там
    # считаются по адресу источника, а через узел ходит весь флот с одного
    # адреса. Прямой путь идёт с адреса самого человека и ни с кем не делится.
    #
    # Вердикт выносится ОДИН РАЗ ЗА ПРОГОН (Z2K_FETCH_DIRECT_OUT), иначе человек
    # с заблокированным GitHub платил бы таймаут на каждом списке. Бюджет
    # короткий — это проба «жив или нет», а не загрузка; но если VPS-хопа нет
    # вовсе, торопиться нельзя: тогда этот запрос И ЕСТЬ единственный.
    if [ "${Z2K_FETCH_DIRECT_FIRST:-1}" = "1" ] && [ "${Z2K_FETCH_DIRECT_OUT:-0}" != "1" ]; then
        local _d_ct _d_raw _d_rc
        _gs_direct_tried=1
        if [ -n "$_vps_resolve" ]; then
            _d_ct=$(z2k_uint "${Z2K_FETCH_DIRECT_CONNECT_TIMEOUT:-3}" 3 1 30)
        else
            _d_ct=15
        fi
        _d_raw=$(curl -sSL --connect-timeout "$_d_ct" --max-time 600 \
                    --speed-limit 1024 --speed-time 30 \
                    --etag-compare "$etag_file" \
                    --etag-save "${etag_file}.new" \
                    -o "$tmp" \
                    -D "$hdr" \
                    -w '%{http_code} %{time_connect}' \
                    "$url" 2>/dev/null) && _d_rc=0 || _d_rc=$?
        [ -n "$_d_raw" ] || _d_raw="000 0"
        if [ "$_d_rc" -eq 0 ]; then http="${_d_raw%% *}"; else http="000"; rm -f "$tmp" 2>/dev/null; fi
        if [ "$http" = "304" ] || { [ "$http" = "200" ] && [ -s "$tmp" ]; }; then
            Z2K_FETCH_DIRECT_CONNFAILS=0; export Z2K_FETCH_DIRECT_CONNFAILS
            _gs_direct_took=1
        else
            # Считаем ТОЛЬКО отказ фазы соединения: 429 или 5xx означают, что
            # путь жив, просто ответ не тот, и выключать его из-за этого нельзя.
            if z2k_connfail "$_d_rc" "${_d_raw%% *}"; then
                Z2K_FETCH_DIRECT_CONNFAILS=$(( ${Z2K_FETCH_DIRECT_CONNFAILS:-0} + 1 ))
                export Z2K_FETCH_DIRECT_CONNFAILS
                if [ "$Z2K_FETCH_DIRECT_CONNFAILS" -ge "$(z2k_uint "${Z2K_FETCH_DIRECT_GIVEUP:-2}" 2 1 20)" ]; then
                    Z2K_FETCH_DIRECT_OUT=1; export Z2K_FETCH_DIRECT_OUT
                    log "  прямой GitHub не отвечает $Z2K_FETCH_DIRECT_CONNFAILS раз подряд — дальше через VPS"
                fi
            fi
            http="000"
        fi
    fi

    while [ "${_gs_direct_took:-0}" != "1" ]; do
        _vps_try=$((_vps_try + 1))
        # shellcheck disable=SC2086
        _vps_raw=$(curl -sSL --connect-timeout "$_ct" --max-time 600 $_vps_resolve \
                    --speed-limit 1024 --speed-time 30 \
                    --etag-compare "$etag_file" \
                    --etag-save "${etag_file}.new" \
                    -o "$tmp" \
                    -D "$hdr" \
                    -w '%{http_code} %{time_connect}' \
                    "$url" 2>/dev/null) && _vps_rc=0 || _vps_rc=$?
        # Код возврата curl и его --write-out нужны ОБА, и по-разному.
        #
        # СЫРОЙ код ответа нужен целым: у соединения, которое УСТАНОВИЛОСЬ и
        # потом встало (обрыв по --speed-time), rc=28, но %{http_code}=200 —
        # ответ был. Затирать его ДО гейта повтора нельзя, иначе гейт примет
        # зависшую передачу за потерянное рукопожатие и повторит то, что
        # повторять запрещено.
        #
        # А вот САМ ОТВЕТ при ненулевом rc принимать нельзя ни в коем случае.
        # curl печатает %{http_code}=200, даже если тело оборвалось на середине
        # (rc=18 partial file, rc=56 reset, rc=23 write error на забитой флешке,
        # rc=28 упор в --speed-time). В $tmp тогда лежит ОГРЫЗОК, непустой — и
        # проверка `-s` его пропускает. Дальше огрызок уезжает в цель, рядом
        # встаёт маркер происхождения, ETag ПОЛНОЙ версии уходит в кеш, и
        # следующий прогон отвечает «unchanged, keep existing». Список замирает
        # огрызком до следующей публикации апстрима, а geosite рапортует
        # «5 ok, 0 failed» и выходит с нулём.
        #
        # На чистом устройстве ловить это больше нечем: страж усадки там
        # намеренно пропущен (происхождения цели ещё нет), а внутренний порог
        # 50% сравнивает нормализованный вывод с тем же огрызком на входе.
        [ -n "$_vps_raw" ] || _vps_raw="000 0"
        Z2K_LAST_CONNFAIL=0
        if z2k_connfail "$_vps_rc" "${_vps_raw%% *}"; then Z2K_LAST_CONNFAIL=1; fi
        if [ "$_vps_rc" -eq 0 ]; then
            http="${_vps_raw%% *}"
        else
            http="000"
            rm -f "$tmp" 2>/dev/null
        fi
        if [ "$http" = "304" ] || { [ "$http" = "200" ] && [ -s "$tmp" ]; }; then break; fi
        # Повторять есть смысл только через VPS: без него это уже прямой запрос,
        # и за ним никого нет.
        [ -n "$_vps_resolve" ] || break
        [ "$_vps_try" -lt "$_vps_tries" ] || break
        # --- z2k layer0 retry gate (canonical; keep byte-identical in all 4 copies) ---
        # Повторяем ТОЛЬКО отказ фазы соединения (см. z2k_connfail).
        # Вложенность у четвёртой копии своя — сравнивать без ведущих пробелов.
        [ "${Z2K_LAST_CONNFAIL:-0}" = "1" ] || break
        # --- end z2k layer0 retry gate ---
    done
    # ЛЮБОЙ неуспех VPS-хопа → прямой запрос, как в каноне z2k_fetch (там слой
    # считается пройденным только на 200 с непустым телом или 304, всё остальное
    # валится на следующий слой). Раньше здесь стояло только `http = 000`, и живой,
    # но отвечающий ошибкой VPS (502 от промаха nginx-мапы, 403, 404) убивал fetch
    # насмерть — geosite уходил в shipped-fallback ДАЖЕ там, где github был доступен
    # напрямую. То есть отказ VPS был жёстче, чем его отсутствие: ровно то, что этот
    # слой обещал не делать.
    if [ -n "$_vps_resolve" ] && [ "$_gs_direct_took" != "1" ] \
       && [ "$_gs_direct_tried" != "1" ] \
       && ! { [ "$http" = "304" ] || { [ "$http" = "200" ] && [ -s "$tmp" ]; }; }; then
        log "  $asset: VPS-хоп не прошёл (HTTP $http), пробую напрямую"
        http=$(curl -sSL --connect-timeout 15 --max-time 600 \
                    --etag-compare "$etag_file" \
                    --etag-save "${etag_file}.new" \
                    -o "$tmp" \
                    -D "$hdr" \
                    -w '%{http_code}' \
                    "$url" 2>/dev/null) || { http="000"; rm -f "$tmp" 2>/dev/null; }
        # Прямой запрос свои 15 с сохраняет: за ним запасного пути нет.
    fi

    # --etag-save пишет в отдельный файл, и сюда его переносим только непустым.
    #
    # Поведение curl при 304 ЗАВИСИТ ОТ ВЕРСИИ, проверено на обеих:
    #   curl 8.7.1  (macOS)            — оставляет файл --etag-save в 0 байт;
    #   curl 8.15.0 (роутеры Entware)  — файл не трогает.
    #
    # На нашем парке (8.15.0) проблемы нет: три прогона geosite подряд на живом
    # роутере дают три 304 и целые etag-файлы. Но версия curl на роутере от нас
    # не зависит, а цена зануления высокая и молчаливая: кеш начинает чередовать
    # 200/304, каждый второй ночной прогон тянет списки целиком, и увидеть это
    # можно только по трафику. Здесь это закрыто для любой версии.
    # Переносим ТОЛЬКО когда ответ принят: 304 либо 200 с непустым телом.
    #
    # Безусловный перенос закреплял отказ на кадр выше того, где это чинилось:
    # апстрим отдаёт 200 + ETag + пустое тело, curl выходит с нулём, ETag уже в
    # рабочем кеше — а ниже мы этот ответ отвергаем. Следующей ночью приходит
    # 304, маркер происхождения совпадает, и ассет заморожен, причём отказ
    # исчезает из отчёта.
    if { [ "$http" = "304" ] || { [ "$http" = "200" ] && [ -s "$tmp" ]; }; } \
       && [ -s "${etag_file}.new" ]; then
        # Результат mv ПРОВЕРЯЕМ (CONTRIBUTING.md: «Запись файла — через
        # временный и mv. Результат mv проверять»). Промах rename выбрасывал
        # свежий ETag и оставлял в кеше ПРОТУХШИЙ, а на протухший сервер
        # отвечает 200 — то есть каждая следующая ночь становилась полной
        # перекачкой ассета, и ни одной строчки об этом в логе. Сносим
        # протухший: одна лишняя перекачка вместо бесконечной серии.
        if ! mv -f "${etag_file}.new" "$etag_file" 2>/dev/null; then
            log "  $asset: не удалось обновить ETag-кеш — сношу протухший"
            rm -f "$etag_file" 2>/dev/null
        fi
    fi
    rm -f "${etag_file}.new" 2>/dev/null

    case "$http" in
        200)
            if [ ! -s "$tmp" ]; then
                log "  $asset: HTTP 200 but empty body"
                rm -f "$tmp"
                return 1
            fi
            log "  $asset: HTTP 200, $(wc -c < "$tmp") bytes"
            return 0
            ;;
        304)
            log "  $asset: unchanged (ETag match)"
            rm -f "$tmp"
            : > "$TMP_DIR/$asset.304"
            return 3
            ;;
        *)
            log "  $asset: HTTP $http"
            rm -f "$tmp"
            return 1
            ;;
    esac
}

# --- Fetch + apply to ONE target -------------------------------------------
#
# Args: asset, target
# Returns: 0 applied (new content or unchanged-targets-current), 1 failed
fetch_asset() {
    local asset="$1"
    local target="$2"

    mkdir -p "$(dirname "$target")" 2>/dev/null || true

    fetch_to_tmp "$asset"
    local rc=$?

    if [ "$rc" = "0" ]; then
        # Fresh content in TMP_DIR/$asset — apply to this target
        apply_new_list "$TMP_DIR/$asset" "$target" "$asset"
        return $?
    fi
    if [ "$rc" = "3" ]; then
        # Upstream unchanged. But 304 говорит только о том, что НЕ поменялся
        # источник — про содержимое цели он не говорит ничего. Раньше здесь
        # стояла проверка «цель непустая», и этого было мало:
        #
        # curl сохраняет ETag во время скачивания, независимо от того, легло
        # ли содержимое в цель. Если apply_new_list потом отказал (например,
        # сработал страж усадки), ETag всё равно записан — и на следующем
        # прогоне мы получаем 304, видим непустую цель и рапортуем «unchanged,
        # keep existing» с кодом 0. Цель при этом так и держит шипнутый бандл,
        # а отказ ещё и исчезает из вида: счётчик failed обнуляется.
        #
        # Поэтому сверяем происхождение: цель считается актуальной, только если
        # маркер говорит, что её собрал ИМЕННО ЭТОТ источник. Иначе 304 к нашей
        # цели не относится — сносим ETag и качаем заново.
        local prev_asset_304=""
        [ -f "${target}.asset" ] && prev_asset_304=$(cat "${target}.asset" 2>/dev/null)
        if [ -s "$target" ] && [ "$prev_asset_304" = "$asset" ]; then
            log "  $asset → $target: unchanged, keep existing"
            return 0
        fi
        if [ -s "$target" ]; then
            log "  $asset → $target: 304, но в цели другой источник (${prev_asset_304:-неизвестен}) — качаю заново"
        else
            log "  $asset → $target: 304 but target empty, forcing re-download"
        fi
        rm -f "$ETAG_DIR/${asset}.etag" "$TMP_DIR/$asset.304"
        fetch_to_tmp "$asset"
        rc=$?
        if [ "$rc" = "0" ]; then
            apply_new_list "$TMP_DIR/$asset" "$target" "$asset"
            return $?
        fi
        log "  $asset → $target: retry failed"
        return 1
    fi
    # rc=1 fetch failed, keep previous file if any
    if [ -s "$target" ]; then
        log "  $asset → $target: fetch failed, keeping existing"
        return 0
    fi
    log "  $asset → $target: fetch failed, target empty/missing"
    return 1
}

# Args: $1 new content file, $2 target path, $3 asset name (for log)
# Отказ применения: снять ETag, но ровно ОДИН раз на версию апстрима.
#
# Просто снимать ETag на каждом отказе нельзя. Отказы бывают двух родов, и по
# коду они неразличимы:
#   * разовый — обрубок нормализации при нехватке места в /tmp (а /tmp здесь
#     RAM), провал записи. Такому повтор нужен: следующей ночью пройдёт;
#   * стойкий — апстрим правда опубликовал список ниже 80% от нынешнего.
#     Такому повтор бесполезен, а стоит он полной перекачки КАЖДУЮ ночь:
#     ru-blocked ~1.7 МБ, а ru-blocked-all на согласившихся роутерах ~33 МБ,
#     и всё это через нормализацию в тмпфс. Раньше цена была один 304.
#
# Различаем по факту: запоминаем ETag отвергнутой версии. Совпал с текущим —
# эту версию мы уже пробовали, ETag не трогаем (значит будет дешёвый 304 и
# цель останется прежней). Не совпал — версия новая, даём ей одну попытку.
_z2k_geosite_reject() {
    local _rj_asset="$1"
    local _rj_etag="$ETAG_DIR/${_rj_asset}.etag"
    local _rj_mark="$ETAG_DIR/${_rj_asset}.rejected"
    local _rj_cur="" _rj_prev=""
    # Отметка на один прогон: у ассета бывает несколько целей, и снимать
    # карантин можно только когда легли ВСЕ (уборка в конце fetch_all).
    : > "$TMP_DIR/${_rj_asset}.apply-failed" 2>/dev/null
    [ -f "$_rj_etag" ] && _rj_cur=$(cat "$_rj_etag" 2>/dev/null)
    [ -f "$_rj_mark" ] && _rj_prev=$(cat "$_rj_mark" 2>/dev/null)
    if [ -n "$_rj_cur" ] && [ "$_rj_cur" = "$_rj_prev" ]; then
        log "  $_rj_asset: эта версия апстрима уже отвергалась — ETag оставляем, чтобы не качать её каждую ночь"
        return 0
    fi
    [ -n "$_rj_cur" ] && printf '%s' "$_rj_cur" > "$_rj_mark" 2>/dev/null
    rm -f "$_rj_etag" 2>/dev/null
    return 0
}

apply_new_list() {
    local newf="$1"
    local target="$2"
    local asset="$3"

    # Normalize + dedupe. Runetfreedom assets use v2fly domain-list
    # prefix format (`domain:`, `full:`, `regexp:`, `keyword:`, optional
    # trailing `@attr` tags). nfqws2 hostlist only understands plain
    # domain lines (suffix match). We strip `domain:`/`full:` to bare
    # domain, drop `regexp:`/`keyword:` (not expressible), clear
    # trailing `@attr`, then sort -u. Without this the daemon parses
    # literal "domain:youtube" strings and matches nothing — which is
    # how the Phase 2 prototype failed live on the test router.
    # sort -u здесь ещё и дедуплицирует: у ru-blocked ~0.3% дублей после
    # слияния источников, а nfqws2 грузит hostlist быстрее на уникальном
    # отсортированном списке. Делается всегда, переключателя нет.
    local final="$TMP_DIR/$asset.normalized"
    awk '
        /^[[:space:]]*#/ { next }
        NF == 0 { next }
        {
            d = $1
            sub(/^domain:/, "", d)
            sub(/^full:/, "", d)
            if (d ~ /^regexp:/) next
            if (d ~ /^keyword:/) next
            # Strip v2fly attribute suffix. The attribute may be
            # preceded by space or colon separator (runetfreedom
            # produces domain:ggpht.cn:@cn format). The colon MUST
            # be consumed or the domain ends up with a trailing
            # colon that nfqws2 will not match on.
            sub(/[[:space:]:]*@[a-zA-Z0-9_.-]+.*$/, "", d)
            if (length(d) > 0 && d ~ /[a-zA-Z0-9]/) print d
        }
    ' "$newf" | sort -u > "$final"

    # --- Проверка того, что нормализация вообще отработала --------------------
    #
    # До 2026-08-05 результат этой пары НЕ проверялся ничем. Если awk или sort
    # обрывались на полпути — а список у ru-blocked-all это 1.37 млн строк,
    # 33 МБ на входе и 24 МБ на выходе, и всё это через /tmp, который на
    # Keenetic лежит в оперативке, — в $final оставался обрубок или ноль байт.
    # Дальше cp и mv отрабатывали успешно (пустой файл копируется прекрасно), и
    # рабочий список молча заменялся пустым. В журнал при этом писалось
    # «applied, 0 lines», то есть отчёт об успехе.
    #
    # Проверять статус конвейера бесполезно: `awk | sort` возвращает статус
    # ПОСЛЕДНЕЙ команды, и убитый по памяти awk оставляет sort с усечённым
    # входом, который тот успешно сортирует и выходит нулём. Поэтому смотрим на
    # содержимое: сколько строк пришло и сколько вышло.
    #
    # Замер на живом ru-blocked-all: 1374049 → 1369027, то есть 99.6%. Отбрасывать
    # тут почти нечего (regexp:/keyword: в этом ассете нет вовсе), так что порог
    # 50% — это не тонкая настройка, а грубая отсечка обрубков.
    # `wc -l` дополняет число пробелами слева, поэтому счётчики прогоняются
    # через tr ДО проверки «только цифры» — иначе проверка отбрасывает нормальный
    # ответ как мусор и обнуляет его, и страж срабатывает на здоровом списке.
    local in_n out_n
    in_n=$(grep -cvE '^[[:space:]]*(#|$)' "$newf" 2>/dev/null | tr -d ' \t')
    out_n=$(wc -l < "$final" 2>/dev/null | tr -d ' \t')
    case "$in_n" in ''|*[!0-9]*) in_n=0 ;; esac
    case "$out_n" in ''|*[!0-9]*) out_n=0 ;; esac

    # ЛЮБОЙ отказ применения ниже снимает ETag этого ассета.
    #
    # curl сохраняет ETag во время СКАЧИВАНИЯ, и fetch_to_tmp переносит его в
    # рабочий кеш сразу по ответу 200 — то есть ещё до того, как выяснится,
    # ляжет ли содержимое в цель. Если применение потом откажет, ETag всё равно
    # записан, и следующий прогон получает честный 304: цель непустая, маркер
    # происхождения совпадает (обычный случай — источник тот же), и fetch_asset
    # рапортует «unchanged, keep existing» с кодом 0. Отказ закрепляется и
    # ИСЧЕЗАЕТ ИЗ ОТЧЁТА: fail_count обнуляется, строки «N failed» больше нет.
    #
    # Маркер происхождения тут не спасает: он ловит только ЧУЖОЙ источник в
    # цели, а при неизменном имени ассета не ловит ничего.
    #
    # Раньше замок ломала установка: она звала geosite с --force и сносила кеш
    # целиком на каждом реинстале. Делать это перестали, значит замок надо
    # снимать там, где он возникает. Для разового отказа (обрубок нормализации
    # при нехватке места в /tmp, провал записи) это буквально разница между
    # «повторим следующей ночью» и «замолчали до смены апстрима».
    if [ "$out_n" -eq 0 ]; then
        log "  $asset: нормализация дала пустой результат из $in_n строк — список НЕ трогаем"
        rm -f "$final"; _z2k_geosite_reject "$asset"
        return 1
    fi
    if [ "$in_n" -gt 0 ] && [ "$((out_n * 100 / in_n))" -lt 50 ]; then
        log "  $asset: нормализация потеряла больше половины ($in_n → $out_n строк) — список НЕ трогаем"
        rm -f "$final"; _z2k_geosite_reject "$asset"
        return 1
    fi

    # --- Страж усадки: сравниваем то, что ЛЯЖЕТ, с тем, что лежит --------------
    #
    # Раньше страж сравнивал СКАЧАННЫЙ файл с тем, что на диске. Это разные
    # вещи: скачанный в формате v2fly (`domain:example.com`), а на диске уже
    # голые домены. Замер: 33.4 МБ против 24.1 МБ — сырой на 39% толще просто
    # из-за приставок. Значит у стража был дутый запас: апстрим мог обрезать
    # список на 40%, и проверка «не меньше 80% от старого» всё равно проходила.
    # Теперь сравниваются два файла одного формата, в строках.
    #
    # pick_rkn_asset намеренно переключается между большим ru-blocked-all и
    # маленьким ru-blocked по объёму памяти, и оба пишут в эту же цель. Маленький
    # это ~5% от большого, поэтому при смене класса страж обязан пропустить —
    # иначе путь на понижение мёртв. Класс запоминается в .asset рядом с целью.
    local asset_marker="${target}.asset"
    local prev_asset=""
    [ -f "$asset_marker" ] && prev_asset=$(cat "$asset_marker" 2>/dev/null)
    # Отсутствие маркера — это «происхождение цели неизвестно», а НЕ «тот же
    # класс». Раньше пустой prev_asset попадал в enforce-ветку, и получался
    # вечный замок: установка кладёт шипнутый бандл без маркера, апстримный
    # список против него всегда меньше 80%, применение отвергается, маркер не
    # пишется — состояние не меняется никогда. Сравнивать бандл с апстримом
    # некорректно по своей природе: это разные источники, а не усадка одного.
    #
    # Проверка неизвестного происхождения живёт ЗДЕСЬ, а не только в разметке
    # бандла установкой: разметка появляется лишь при переустановке, а этот
    # файл доезжает и патчем — то есть на роутерах, которые переустановку не
    # проходили, замок иначе остался бы висеть.
    if [ -s "$target" ] && [ -z "$prev_asset" ]; then
        log "  $asset: происхождение цели неизвестно — страж усадки пропущен"
    elif [ -s "$target" ] && [ "$prev_asset" = "$asset" ]; then
        local old_n
        old_n=$(wc -l < "$target" 2>/dev/null | tr -d ' \t')
        case "$old_n" in ''|*[!0-9]*) old_n=0 ;; esac
        if [ "$old_n" -gt 0 ] && [ "$((out_n * 100 / old_n))" -lt 80 ]; then
            log "  $asset: новый список $out_n строк < 80% от нынешних $old_n — список НЕ трогаем"
            rm -f "$final"; _z2k_geosite_reject "$asset"
            return 1
        fi
    elif [ -s "$target" ] && [ "$prev_asset" != "$asset" ]; then
        log "  $asset: смена класса списка ($prev_asset → $asset) — страж усадки пропущен"
    fi

    # First-run backup: save the shipped snapshot next to the target so
    # manual rollback is a one-command cp. Only do this if we don't
    # already have a .shipped backup.
    local shipped="${target}.shipped"
    if [ ! -e "$shipped" ] && [ -s "$target" ]; then
        cp "$target" "$shipped" && log "  $asset: saved shipped backup → ${shipped##*/}"
    fi

    # Atomic rename over target. mv is atomic within same filesystem.
    # nfqws2 re-reads the file only on restart, so no concurrent
    # reader to worry about — but we still want to avoid torn writes
    # if the install script is killed mid-copy.
    local target_tmp="${target}.probe"
    cp "$final" "$target_tmp" && mv "$target_tmp" "$target" \
        || { log "  $asset: failed to write $target"
             _z2k_geosite_reject "$asset"
             return 1; }

    # Record which asset produced this target so the shrink guard above can
    # tell an intentional big↔small class switch (bypass guard) from a genuine
    # truncation regression (enforce guard).
    printf '%s\n' "$asset" > "$asset_marker" 2>/dev/null || true
    # Применилось — но карантин здесь НЕ снимаем: он ключуется ассетом, а целей
    # у ассета бывает несколько (youtube.txt → TCP/YT и UDP/YT). Отмечаем
    # только факт успеха этой цели; снимет карантин уборка в конце fetch_all,
    # и только если у ассета не отвалилась ни одна цель.
    : > "$TMP_DIR/${asset}.applied" 2>/dev/null

    local lines
    lines=$(wc -l < "$target" 2>/dev/null || echo 0)
    log "  $asset: applied, $lines lines"
    return 0
}

# --- Subtract googlevideo entries from YT list -----------------------------
#
# runetfreedom's youtube.txt includes `googlevideo.com` apex and various
# `*.googlevideo.com` subdomains. We route googlevideo through its own
# `extra_strats/TCP/YT_GV/List.txt` profile (gv_tcp) with strategies tuned
# for bulk-video CDN traffic, NOT through yt_tcp (which is tuned for
# youtube.com itself). nfqws2 is first-match-wins, so any googlevideo
# entry left in YT/List sends GV traffic to yt_tcp before gv_tcp gets a
# chance — exactly the «много ротаций на GV» bug fixed in r-17.
# Run unconditionally after fetch (even on 304/cached) so the on-disk
# list stays clean if upstream adds googlevideo entries later.
subtract_googlevideo_from_yt() {
    local yt_target="$EXTRA/TCP/YT/List.txt"
    [ -s "$yt_target" ] || return 0

    local before after removed filtered
    before=$(wc -l < "$yt_target" 2>/dev/null || echo 0)
    filtered="$TMP_DIR/yt.filtered"

    awk '{
        d = $0
        sub(/\r$/, "", d)
        if (d == "googlevideo.com") next
        if (d ~ /\.googlevideo\.com$/) next
        print d
    }' "$yt_target" > "$filtered" || {
        log "YT subtract: awk failed, keeping original list"
        rm -f "$filtered"
        return 1
    }

    after=$(wc -l < "$filtered" 2>/dev/null || echo 0)
    removed=$((before - after))
    if [ "$removed" -gt 0 ]; then
        mv "$filtered" "$yt_target" || {
            log "YT subtract: rename failed"
            return 1
        }
        log "YT: removed $removed googlevideo overlap(s) ($before → $after lines) — gv_tcp profile gets these via YT_GV/List.txt"
    else
        rm -f "$filtered"
        log "YT: no googlevideo overlaps in upstream youtube.txt"
    fi
    return 0
}

# --- Inject sign-in endpoints upstream youtube.txt omits -------------------
#
# runetfreedom's youtube.txt does NOT carry the YouTube / Apple-TV account
# sign-in endpoints (oauth2.googleapis.com = the device-login OAuth poll,
# accounts.google.com / accounts.youtube.com = the sign-in itself). The
# set-top login rides these over BOTH TLS and HTTP/3 (QUIC). Without them in
# the YT lists the login flow gets ZERO nfqws2 treatment and sign-in hangs on
# offload routers. The shipped snapshot carries them, but fetch_asset
# overwrites the LIVE list from upstream — so we re-inject them here, into both
# the TCP and the QUIC YT lists, on every fetch (idempotent, suffix-safe dedup).
YT_LOGIN_DOMAINS="accounts.google.com accounts.youtube.com oauth2.googleapis.com"

inject_yt_login_domains() {
    local list d added
    for list in "$EXTRA/TCP/YT/List.txt" "$EXTRA/UDP/YT/List.txt"; do
        [ -f "$list" ] || continue
        added=0
        for d in $YT_LOGIN_DOMAINS; do
            grep -qxF "$d" "$list" 2>/dev/null || { printf '%s\n' "$d" >> "$list"; added=$((added+1)); }
        done
        [ "$added" -gt 0 ] && log "YT login: injected $added sign-in domain(s) into ${list#"$EXTRA"/}"
    done
    return 0
}

# Video-serving Google domains that ride the googlevideo profiles (gv_tcp over
# TLS, QUIC YT profile over UDP) but that upstream youtube.txt omits. Paired
# with googlevideo.com — same handling. Injected ONLY into the lists that carry
# googlevideo (TCP/YT_GV + UDP/YT), NOT TCP/YT (yt_tcp), where googlevideo is
# intentionally stripped (subtract_googlevideo_from_yt) — keeping these out of
# yt_tcp so the gv_tcp profile (first-match by its own hostlist) handles them.
# UDP/YT is overwritten by the youtube.txt fetch, so re-add post-fetch;
# TCP/YT_GV is static but injected too for durability across list-only updates
# (where a full reinstall hasn't redeployed the shipped file). Idempotent.
YT_VIDEO_DOMAINS="video.google.com"

inject_yt_video_domains() {
    local list d added
    for list in "$EXTRA/TCP/YT_GV/List.txt" "$EXTRA/UDP/YT/List.txt"; do
        [ -f "$list" ] || continue
        added=0
        for d in $YT_VIDEO_DOMAINS; do
            grep -qxF "$d" "$list" 2>/dev/null || { printf '%s\n' "$d" >> "$list"; added=$((added+1)); }
        done
        [ "$added" -gt 0 ] && log "YT video: injected $added video domain(s) into ${list#"$EXTRA"/}"
    done
    return 0
}

# --- Subtract YT + googlevideo from RKN list -------------------------------
#
# runetfreedom's ru-blocked / ru-blocked-all lists include YouTube and
# googlevideo domains. config_official.sh chains profiles as
# RKN TCP → YouTube TCP → YouTube GV → QUIC YT, and nfqws2 is first-match-
# wins, so any overlapping domain gets the generic RKN strategy instead of
# the dedicated YT/GV one. We strip YT + googlevideo entries from the RKN
# list after all assets are written so each domain reaches exactly the
# profile it was tuned for.
#
# Matching is suffix-aware: if the YT list contains "youtube.com",
# "m.youtube.com" in RKN is dropped too (nfqws2 hostlist does suffix
# matching, so leaving the child entry in RKN would also be caught by
# RKN first). googlevideo.com is hard-coded because YT GV uses
# --hostlist-domains=googlevideo.com instead of a file.
subtract_yt_from_rkn() {
    local rkn_target="$EXTRA/TCP/RKN/List.txt"
    local yt_target="$EXTRA/TCP/YT/List.txt"

    [ -s "$rkn_target" ] || return 0

    local exclude="$TMP_DIR/rkn.exclude"
    : > "$exclude"
    [ -s "$yt_target" ] && cat "$yt_target" >> "$exclude"

    local before after removed filtered
    before=$(wc -l < "$rkn_target" 2>/dev/null || echo 0)
    filtered="$TMP_DIR/rkn.filtered"

    awk -v excl="$exclude" '
        BEGIN {
            while ((getline line < excl) > 0) {
                sub(/\r$/, "", line)
                if (length(line) > 0) ex[line] = 1
            }
            close(excl)
        }
        {
            d = $0
            sub(/\r$/, "", d)
            if (d == "googlevideo.com") next
            if (d ~ /\.googlevideo\.com$/) next
            tmp = d
            if (tmp in ex) next
            while (sub(/^[^.]*\./, "", tmp)) {
                if (tmp in ex) next
            }
            print d
        }
    ' "$rkn_target" > "$filtered" || {
        log "RKN subtract: awk failed, keeping original list"
        rm -f "$filtered"
        return 1
    }

    after=$(wc -l < "$filtered" 2>/dev/null | tr -d ' \t')
    case "$after" in ''|*[!0-9]*) after=0 ;; esac
    case "$before" in ''|*[!0-9]*) before=0 ;; esac

    # Тот же случай, что и в apply_new_list: awk может отдать нулевой статус,
    # а файл оставить обрубком (не заметил ошибку записи, кончилось место в
    # /tmp — а он на Keenetic в оперативке). Тогда `removed` выходит огромным,
    # и обрубок уезжает поверх рабочего списка. Вычитать тут положено доли
    # процента (YouTube это ~180 доменов из 1.37 млн), поэтому порог в половину
    # — грубая отсечка, а не тонкая настройка.
    if [ "$after" -eq 0 ] || { [ "$before" -gt 0 ] && [ "$((after * 100 / before))" -lt 50 ]; }; then
        log "RKN subtract: результат обрублен ($before → $after строк) — список НЕ трогаем"
        rm -f "$filtered"
        return 1
    fi

    removed=$((before - after))
    if [ "$removed" -gt 0 ]; then
        mv "$filtered" "$rkn_target" || {
            log "RKN subtract: rename failed"
            return 1
        }
        log "RKN: removed $removed YT/googlevideo overlaps ($before → $after lines)"
    else
        rm -f "$filtered"
        log "RKN: no YT/googlevideo overlaps found"
    fi
    return 0
}

# --- Subtract hand-curated false positives ----------------------------------
#
# В upstream `ru-blocked` / `ru-blocked-all` геосайт иногда попадают
# домены которые по факту НЕ заблокированы РКН (например play.google.com —
# free apps работают, заблокирован только paid billing со стороны Google
# санкциями). Обрабатывать их nfqws2 — лишний CPU + засорение state.tsv.
#
# Список ведётся в /opt/zapret2/lists/rkn-false-positive.txt (shipped через
# install.sh из files/lists/rkn-false-positive.txt). Match exact-line
# (НЕ suffix) — мы не хотим случайно выпилить заблокированный subdomain.
subtract_false_positive_from_rkn() {
    local rkn_target="$EXTRA/TCP/RKN/List.txt"
    local fp_list="$FP_LIST"

    [ -s "$rkn_target" ] || return 0
    [ -s "$fp_list" ] || return 0

    local exclude="$TMP_DIR/rkn.false-positive.exclude"
    : > "$exclude"
    # Strip comments / empty / CRLF, normalize lowercase.
    awk '
        { sub(/\r$/, ""); sub(/[[:space:]]+$/, "") }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        { print tolower($0) }
    ' "$fp_list" > "$exclude"
    [ -s "$exclude" ] || { rm -f "$exclude"; return 0; }

    local before after removed filtered
    before=$(wc -l < "$rkn_target" 2>/dev/null || echo 0)
    filtered="$TMP_DIR/rkn.false-positive.filtered"

    awk -v excl="$exclude" '
        BEGIN {
            while ((getline line < excl) > 0) {
                sub(/\r$/, "", line)
                if (length(line) > 0) ex[line] = 1
            }
            close(excl)
        }
        {
            d = $0
            sub(/\r$/, "", d)
            if (d in ex) next
            print d
        }
    ' "$rkn_target" > "$filtered" || {
        log "RKN false-positive subtract: awk failed, keeping original list"
        rm -f "$filtered" "$exclude"
        return 1
    }

    after=$(wc -l < "$filtered" 2>/dev/null || echo 0)
    removed=$((before - after))
    if [ "$removed" -gt 0 ]; then
        mv "$filtered" "$rkn_target" || {
            log "RKN false-positive subtract: rename failed"
            rm -f "$exclude"
            return 1
        }
        log "RKN: removed $removed hand-curated false positives ($before → $after lines)"
    else
        rm -f "$filtered"
        log "RKN false-positive: no overlaps with curated list"
    fi
    rm -f "$exclude"
    return 0
}

# --- Гейт отпечатка fp-списка ------------------------------------------------
#
# ЧТО ЗДЕСЬ ЛОМАЛОСЬ. subtract_false_positive_from_rkn умеет только ВЫЧИТАТЬ, и
# работает он по цели, которая уже лежит на диске. Домен, который мы из
# rkn-false-positive.txt УБРАЛИ (перепроверили — он таки блокируется), обратно
# в цель не попадёт никогда: она собирается один раз при загрузке апстрима, а
# дальше только урезается. Апстрим при этом не менялся, значит на всех
# последующих прогонах приходит 304, цель не пересобирается, и правка живёт
# только в файле списка.
#
# Ровно это и есть штатный саппорт-флоу: «домен ошибочно исключён из обхода» →
# убрали строку из fp-списка → выкатили. Версия уезжала вперёд, в описании
# релиза домен обещан, а в хостлисте он по-прежнему вычтен — до ближайшего
# переиздания апстрима, то есть на неопределённый срок.
#
# ИНВАРИАНТ: содержимое RKN/List.txt есть функция ДВУХ входов — апстримного
# ассета и fp-списка. Условный запрос стережёт только первый вход. Значит
# второй надо стеречь отдельно: запоминаем отпечаток применённого fp-списка и
# при его смене сносим ETag ассетов RKN — тогда придёт 200, apply_new_list
# положит полный апстрим, и вычитание пойдёт уже НОВЫМ списком.
#
# ПОЧЕМУ ЗДЕСЬ, А НЕ В УСТАНОВКЕ. Такой же гейт стоит в lib/install.sh, но он
# закрывает один путь — переустановку. Тот же файл доезжает патчем, правится
# рукой (см. инструкцию в шапке самого fp-списка) и перечитывается ночным
# cron'ом, а хостлист собирает ВСЕГДА этот скрипт. Гейт на входе в fetch_all
# работает на всех путях сразу.
#
# ОТПЕЧАТОК ПИШЕМ В МОМЕНТ СНОСА ETag, а не после успешной сборки — так же, как
# в install.sh. Если загрузка потом не удастся, ETag'а всё равно уже нет, и
# полная перекачка просто уедет на ближайший ночной прогон. Обратный порядок
# (писать после успеха) означал бы полную перекачку КАЖДУЮ ночь всё время, пока
# апстрим отвергается стражем усадки, — ровно та цена, ради избавления от
# которой заведён карантин .rejected.
_z2k_geosite_sha256() {
    [ -f "$1" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    else
        return 1
    fi
}

_z2k_rkn_fp_gate() {
    [ -f "$FP_LIST" ] || return 0

    local _fp_now="" _fp_was="" _fp_changed=0
    _fp_now=$(_z2k_geosite_sha256 "$FP_LIST" 2>/dev/null)
    if [ -n "$_fp_now" ]; then
        _fp_was=$(cat "$Z2K_RKN_FP_MARK" 2>/dev/null)
        [ "$_fp_now" = "$_fp_was" ] || _fp_changed=1
    else
        # Считать нечем. Раньше в этом месте (install.sh) просто ничего не
        # делали, и правка fp-списка на таком роутере не доезжала до хостлиста
        # вовсе. Список — полтора килобайта, так что держим его копию и
        # сравниваем побайтно: тот же ответ, без единого внешнего инструмента.
        if [ -f "$Z2K_RKN_FP_COPY" ]; then
            _fp_was=x
            cmp -s "$FP_LIST" "$Z2K_RKN_FP_COPY" 2>/dev/null || _fp_changed=1
        else
            _fp_changed=1
        fi
    fi
    [ "$_fp_changed" = "1" ] || return 0

    # Какой из двух ассетов RKN выбран, решает pick_rkn_asset; снимаем оба —
    # несуществующий ETag снести не жалко.
    rm -f "$ETAG_DIR/ru-blocked.txt.etag" "$ETAG_DIR/ru-blocked-all.txt.etag" 2>/dev/null

    mkdir -p "$(dirname "$Z2K_RKN_FP_MARK")" 2>/dev/null || true
    if [ -n "$_fp_now" ]; then
        printf '%s\n' "$_fp_now" > "$Z2K_RKN_FP_MARK" 2>/dev/null || true
    else
        cp -f "$FP_LIST" "$Z2K_RKN_FP_COPY" 2>/dev/null || true
    fi

    # Пустой предыдущий отпечаток — это первый прогон с гейтом, а не правка
    # списка. Одна перекачка тут неизбежна (что применено к цели, мы не знаем),
    # но объявлять её сменой списка неверно.
    [ -n "$_fp_was" ] && \
        log "список ложных срабатываний РКН изменился — RKN собираем из апстрима заново"
    return 0
}

# --- One-shot state cleanup ------------------------------------------------
#
# 2026-05-24 false-positive subtract убрал play.google.com и
# snap-storage-cdn.l.google.com из RKN. autocircular использует nld=2 SLD
# ключ — оба домена раньше писались в state.tsv под ключом `google.com`.
# Эта запись больше не валидна (заблокированные subdomains используют свои
# ключи), но autocircular не удаляет stale entries сам. One-shot purge с
# marker-файлом — выполнится один раз при следующем после patch refresh.
purge_stale_google_state() {
    local state="$EXTRA/cache/autocircular/state.tsv"
    local marker="$EXTRA/cache/autocircular/.google_purge_2026_05_24.done"
    [ -f "$marker" ] && return 0
    mkdir -p "$(dirname "$marker")" 2>/dev/null
    if [ -f "$state" ]; then
        local tmp="$state.purge.tmp"
        awk -F'\t' '!($1=="rkn_tcp" && $2=="google.com")' "$state" > "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        cat "$tmp" > "$state" && rm -f "$tmp"
        log "purged stale 'rkn_tcp google.com' state entry (one-shot)"
    fi
    touch "$marker"
}

purge_stale_instagram_state() {
    local state="$EXTRA/cache/autocircular/state.tsv"
    # КРИТИЧНО: marker в /opt/etc (persistent Entware root), НЕ в $EXTRA/cache.
    # Это был корень бага p-38: прежний marker жил в
    # $EXTRA/cache/autocircular/ который сносится rm/mv "$ZAPRET2_DIR" при
    # каждом auto-update reinstall → purge срабатывал на КАЖДОМ update,
    # стирая рабочую instagram-страту (жалоба @jet_sk_ya). Persistent
    # marker в /opt/etc переживает reinstall → purge действительно one-shot.
    # Цель purge — однократно сбросить застрявшую (до p-34) instagram.com
    # страту, залипшую на 40+ из-за browser-cancel false-positive в
    # silent_drop_detector. После сброса autocircular переподберёт рабочую.
    local marker="/opt/etc/.z2k-instagram-purge-2026-05-28.done"
    [ -f "$marker" ] && return 0
    mkdir -p "$(dirname "$marker")" 2>/dev/null
    if [ -f "$state" ]; then
        local tmp="$state.purge.tmp"
        awk -F'\t' '!($1=="rkn_tcp" && $2=="instagram.com")' "$state" > "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        cat "$tmp" > "$state" && rm -f "$tmp"
        log "purged stale 'rkn_tcp instagram.com' state entry (one-shot, persistent marker)"
    fi
    touch "$marker"
}

# --- Fetch all targets ------------------------------------------------------

fetch_all() {
    ensure_deps

    # --force clears ETag cache before fetch. Used at install time so a
    # reinstall always re-applies the latest upstream even when the
    # router already had a stale ETag pointing to the same upstream
    # version but a different (shipped) local file.
    if [ "${FORCE_REFETCH:-0}" = "1" ]; then
        log "force: clearing ETag cache in $ETAG_DIR"
        rm -f "$ETAG_DIR"/*.etag 2>/dev/null || true
    fi

    # Второй вход RKN-хостлиста — список ложных срабатываний. ETag стережёт
    # только апстрим, поэтому смену fp-списка проверяем отдельно и ДО загрузки:
    # иначе правка списка не доедет до цели, пока не переиздастся апстрим.
    _z2k_rkn_fp_gate || log "fp-гейт: non-fatal failure, continuing"

    local rkn_asset
    rkn_asset=$(pick_rkn_asset)

    local ok_count=0
    local fail_count=0
    local step_rc

    fetch_asset "$rkn_asset"   "$EXTRA/TCP/RKN/List.txt" && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    fetch_asset "youtube.txt"  "$EXTRA/TCP/YT/List.txt"  && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    fetch_asset "youtube.txt"  "$EXTRA/UDP/YT/List.txt"  && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    fetch_asset "discord.txt"  "$EXTRA/TCP/RKN/Discord.txt" && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    # TCP_Discord.txt mirror path used by some config_official.sh branches
    fetch_asset "discord.txt"  "$EXTRA/TCP_Discord.txt"  && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))

    # --- снятие карантина: ОДИН раз на ассет и только при полном успехе -------
    #
    # Маркер .rejected ключуется АССЕТОМ, а целей у ассета бывает несколько:
    # youtube.txt обслуживает TCP/YT и UDP/YT, discord.txt — тоже две. После
    # разной постобработки у парных целей разное число строк, и 80%-страж
    # усадки способен отвергнуть одну, приняв другую.
    #
    # Пока маркер снимала сама apply_new_list, это давало вечную ночную
    # перекачку: успешная цель снимала отметку, отвергнутая тут же ставила её
    # заново и сносила ETag — и так каждую ночь вместо одного дешёвого 304.
    # Инвариант, который держим здесь: карантин снимается, только если ВСЕ цели
    # ассета применились в ЭТОМ прогоне. Отметки ставят apply_new_list
    # (.applied) и _z2k_geosite_reject (.apply-failed); обе лежат в TMP_DIR, то
    # есть живут ровно один прогон.
    local _qa
    for _qa in "$rkn_asset" youtube.txt discord.txt; do
        [ -f "$TMP_DIR/${_qa}.applied" ] || continue
        [ -f "$TMP_DIR/${_qa}.apply-failed" ] && continue
        rm -f "$ETAG_DIR/${_qa}.rejected" 2>/dev/null
    done

    log "fetch summary: $ok_count ok, $fail_count failed"

    # Strip googlevideo entries from YT list FIRST (so RKN subtract below
    # uses the cleaned YT list, not the upstream version that carries
    # googlevideo entries).
    subtract_googlevideo_from_yt || log "YT subtract: non-fatal failure, continuing"

    # Re-add the sign-in endpoints upstream youtube.txt omits (set-top login
    # over TLS + QUIC). Before the RKN subtract so they reach the YT profile,
    # not RKN. Idempotent.
    inject_yt_login_domains || log "YT login inject: non-fatal failure, continuing"

    # Re-add video.google.com to the googlevideo-carrying lists (TCP/YT_GV +
    # UDP/YT) — survives the youtube.txt overwrite. Before the RKN subtract so
    # it lands in the YT/GV profiles, not RKN. Idempotent.
    inject_yt_video_domains || log "YT video inject: non-fatal failure, continuing"

    # Strip YT + googlevideo overlaps from RKN list (enhanced branch only).
    # Runs unconditionally — even on all-304 runs an older on-disk RKN list
    # may still carry overlaps from a time before this step existed, or from
    # newly-added entries in the YT list.
    subtract_yt_from_rkn || log "RKN subtract: non-fatal failure, continuing"

    # Strip hand-curated false positives (domains в upstream RKN, но НЕ
    # заблокированные по факту). Перепроверено через web search 2026-05-24.
    subtract_false_positive_from_rkn || log "RKN false-positive subtract: non-fatal failure, continuing"

    # One-shot cleanup: убрать stale `rkn_tcp google.com` запись из state.tsv.
    # autocircular использует nld=2 SLD ключ, поэтому play.google.com / snap-
    # storage-cdn.l.google.com (теперь убраны из RKN) ранее писались в state
    # под ключом google.com. Marker гарантирует one-shot — повторно не запустится.
    purge_stale_google_state || log "google state purge: non-fatal failure, continuing"

    # One-shot (persistent marker в /opt/etc) сброс застрявшей до-p-34
    # instagram.com страты. Marker переживает reinstall — в отличие от
    # удалённого в p-38 варианта, который purg'ил каждый update. Targeted:
    # трогает только запись rkn_tcp/instagram.com, остальной state цел.
    purge_stale_instagram_state || log "instagram state purge: non-fatal failure, continuing"

    if [ "$ok_count" = "0" ]; then
        log "all targets failed"
        return 1
    fi
    if [ "$fail_count" != "0" ]; then
        return 2
    fi
    return 0
}

# --- show: single asset to stdout ------------------------------------------

show_asset() {
    local asset="${1:-}"
    [ -z "$asset" ] && die "show: asset name required (e.g. ru-blocked.txt)"
    ensure_deps
    curl -fsSL --connect-timeout 15 --max-time 600 \
         "$RELEASE_BASE/$asset" || die "fetch $asset failed"
}

# --- status: current production line counts --------------------------------

status_report() {
    local f
    for f in "$EXTRA/TCP/RKN/List.txt" \
             "$EXTRA/TCP/YT/List.txt" \
             "$EXTRA/UDP/YT/List.txt" \
             "$EXTRA/TCP/RKN/Discord.txt" \
             "$EXTRA/TCP_Discord.txt"; do
        if [ -s "$f" ]; then
            printf '%s  %s lines\n' "$f" "$(wc -l < "$f")"
        else
            printf '%s  (missing or empty)\n' "$f"
        fi
    done
    if [ -d "$ETAG_DIR" ]; then
        echo
        echo "ETag cache: $ETAG_DIR"
        for f in "$ETAG_DIR"/*; do
            [ -e "$f" ] || continue
            size=$(wc -c < "$f" 2>/dev/null || echo 0)
            printf '  %s  %sB\n' "$(basename "$f")" "$size"
        done
    fi
}

# --- dispatch ---------------------------------------------------------------

usage() {
    sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//;s/^#$//' | head -n 46
}

cmd="${1:-fetch}"
[ $# -gt 0 ] && shift
case "$cmd" in
    fetch)
        for arg in "$@"; do
            case "$arg" in
                --force|-f) FORCE_REFETCH=1 ;;
                *) die "unknown fetch arg: $arg" ;;
            esac
        done
        fetch_all
        ;;
    show)                    show_asset "$@" ;;
    status)                  status_report ;;
    -h|--help|help)          usage ;;
    *)                       die "unknown command: $cmd" ;;
esac
