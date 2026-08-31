#!/bin/sh
# z2k auto-update module
#
# Sourced from /opt/zapret2/z2k-auto-update.sh (fired by z2k-scheduler
# at 02:00) and from lib/menu.sh (manual "Проверить обновления").
#
# Exposes:
#   au_run_apply   — main entry: fetch manifest, decide, apply, health-check
#   au_run_check   — dry-run: fetch manifest, print diff, no apply
#
# Design lives in feedback_z2k_user_overrides_policy.md (memory) and the
# auto-update RFC: shipped files (Strategy.txt / lua / lists in repo) are
# replaced from repo, Z2K_* feature flags are extracted before apply and
# reapplied after, extra-domains.txt is 3-way merged.

# ---------------------------------------------------------------- constants ---

Z2K_AU_BRANCH="${Z2K_AU_BRANCH:-z2k-enhanced}"
Z2K_AU_REPO_RAW="${Z2K_AU_REPO_RAW:-https://raw.githubusercontent.com/necronicle/z2k/${Z2K_AU_BRANCH}}"
Z2K_AU_MANIFEST_URL="${Z2K_AU_MANIFEST_URL:-${Z2K_AU_REPO_RAW}/UPDATES.json}"
Z2K_AU_REINSTALL_URL="${Z2K_AU_REINSTALL_URL:-${Z2K_AU_REPO_RAW}/z2k.sh}"

Z2K_AU_INSTALLED_TAG_FILE="${Z2K_AU_INSTALLED_TAG_FILE:-/opt/zapret2/.z2k-installed-tag}"
Z2K_AU_LOCK_FILE="${Z2K_AU_LOCK_FILE:-/opt/zapret2/.update.lock}"
Z2K_AU_LOG_FILE="${Z2K_AU_LOG_FILE:-/opt/var/log/z2k-auto-update.log}"
Z2K_AU_TMP_DIR="${Z2K_AU_TMP_DIR:-/tmp/z2k_au}"
# Seconds to let the restarted service prove it STAYS up. Not a wait for it to
# come up: au_apply_patch runs `/opt/etc/init.d/S99zapret2 restart` synchronously
# and run_daemon() blocks on z2k_wait_queue_bound until nfqws2 has bound its
# NFQUEUE, so by the time we get here the very thing the first check asks about
# is already guaranteed. This window exists only to catch a daemon that starts,
# binds, and then dies seconds later (the MIPS async-preempt crash loop).
# It was 60s, described as "waiting for the service to settle" — a minute of
# dead time on every update, and a description that made the number look
# load-bearing when it was not.
Z2K_AU_HEALTH_TIMEOUT="${Z2K_AU_HEALTH_TIMEOUT:-5}"
Z2K_AU_HEALTH_GH_URL="${Z2K_AU_HEALTH_GH_URL:-https://github.com}"

# ----------------------------------------------------------- logger / lock ---

au_log() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$Z2K_AU_LOG_FILE")" 2>/dev/null || true
    echo "[$ts] $msg" >> "$Z2K_AU_LOG_FILE" 2>/dev/null || true
    # also stderr so manual menu invocation sees it
    echo "[au] $msg" >&2 2>/dev/null || true
    # syslog tag for journalctl-style inspection
    logger -t z2k-au "$msg" 2>/dev/null || true
}

au_lock_acquire() {
    # ЗАХВАТ ЧЕРЕЗ mkdir, А НЕ «проверил файл — записал файл».
    #
    # Прежняя схема состояла из двух отдельных шагов: `[ -f ... ]` и, если файла
    # нет, `echo $$ > ...`. Между ними ничего не мешает второму процессу пройти
    # ту же проверку — и оба считают, что владеют замком. Ровно этот сценарий
    # здесь достижим: ночной планировщик и человек, нажавший «обновить» в меню
    # или в панели, стартуют независимо, а обновление переписывает init-скрипты
    # и lib/*, которые в этот момент сорсит второй экземпляр.
    #
    # mkdir атомарен: каталог либо создаётся, либо нет, третьего нет. Тот же
    # приём уже используется в lib/install.sh для его собственного замка — здесь
    # просто не был применён. PID кладём внутрь каталога, чтобы сохранить
    # прежнюю диагностику битого замка.
    local _d="${Z2K_AU_LOCK_FILE}.d" pid
    if ! mkdir "$_d" 2>/dev/null; then
        pid=$(cat "$_d/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            au_log "уже работает другой прогон (pid=$pid) — пропускаю"
            return 1
        fi
        au_log "снял зависшую блокировку (процесса ${pid:-?} нет)"
        rm -rf "$_d" 2>/dev/null
        mkdir "$_d" 2>/dev/null || { au_log "lock: не удалось создать $_d"; return 1; }
    fi
    echo "$$" > "$_d/pid" 2>/dev/null
    # Файл прежнего формата оставляем для внешних наблюдателей (диагностика,
    # старые скрипты), но решение о владении принимается ТОЛЬКО по каталогу.
    echo "$$" > "$Z2K_AU_LOCK_FILE" 2>/dev/null || true
    return 0
}

au_lock_release() {
    rm -rf "${Z2K_AU_LOCK_FILE}.d" 2>/dev/null || true
    rm -f "$Z2K_AU_LOCK_FILE" 2>/dev/null || true
}

# -------------------------------------------------------- manifest fetch ---

# --------------------------------------------------- подпись манифеста ---
#
# Манифест — корень доверия: из него берутся и решение «что ставить», и хеши,
# которыми проверяется каждый скачанный файл. Кто подменил манифест, тот
# подменил и эталоны, и дальнейшая сверка подтверждает подмену вместо того,
# чтобы её ловить. Поэтому проверка подписи стоит ДО первого разбора файла.
#
# Пути к ключу и верификатору — переменными, чтобы тест мог подставить свои.
Z2K_AU_PUBKEY="${Z2K_AU_PUBKEY:-${ZAPRET2_DIR:-/opt/zapret2}/etc/z2k-update-pub.pem}"
Z2K_AU_SIG_URL="${Z2K_AU_SIG_URL:-${Z2K_AU_MANIFEST_URL}.sig}"
Z2K_AU_TRUST_PIN="${Z2K_AU_TRUST_PIN:-/opt/etc/z2k/.trust/pinned}"

# au_manifest_verify MANIFEST SIG -> 0 если подпись сошлась.
#
# Единственный поддерживаемый способ — Ed25519. openssl на роутере это умеет
# (проверено на 3.5.5), но `pkeyutl -rawin` появился только в 3.0: на 1.1.1
# такой проверки нет вовсе, и там мы честно возвращаем «нечем проверить».
au_manifest_verify() {
    local m="$1" sig="$2"
    [ -s "$m" ] && [ -s "$sig" ] || return 1
    [ -s "$Z2K_AU_PUBKEY" ] || return 2   # ключа нет — решает вызывающий

    # Свой проверяльщик — ПЕРВЫМ.
    #
    # Он адресуется содержимым: sha256 вшит в z2k.sh, поэтому подменить его на
    # зеркале нельзя. openssl такого свойства не имеет вовсе — он приезжает
    # пакетом из opkg-фида, который на Entware ходит по открытому HTTP, то есть
    # корень доверия зависел бы от канала, ничем не защищённого.
    #
    # openssl остаётся ВТОРЫМ путём, а не фоллбэком-на-пропуск: обе реализации
    # проверяют одну и ту же подпись, поэтому принять результат любой из них
    # безопасно. Дырой было бы «нет проверяльщика — пропустить», а не «есть два».
    local _vbin="${Z2K_AU_VERIFY_BIN:-${ZAPRET2_DIR:-/opt/zapret2}/bin/z2k-verify}"
    if [ -x "$_vbin" ]; then
        "$_vbin" "$Z2K_AU_PUBKEY" "$sig" "$m" >/dev/null 2>&1
        case "$?" in
            0) return 0 ;;
            1) return 1 ;;
            # 2 = позвали неправильно. Это наша ошибка, а не подделка:
            # проваливаемся на openssl, а не объявляем манифест плохим.
        esac
    fi

    local _ossl="${Z2K_AU_OPENSSL:-openssl}"
    command -v "$_ossl" >/dev/null 2>&1 || return 2

    # «Не умею проверять» и «подпись не сошлась» — РАЗНЫЕ состояния, и путать их
    # нельзя. Ed25519 через pkeyutl -rawin появился в OpenSSL 3.0; на 1.1.1
    # такого режима нет вовсе, и голый вызов вернул бы ненулевой код, то есть
    # выглядел бы как ПОДДЕЛКА. С защёлкнутым храповиком это означало бы жёсткий
    # отказ обновляться на ровном месте — у всех, кто не обновлял openssl.
    #
    # Поэтому сначала спрашиваем, поддерживается ли режим вообще.
    if ! "$_ossl" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
        return 2
    fi

    "$_ossl" pkeyutl -verify -rawin -pubin -inkey "$Z2K_AU_PUBKEY" \
        -in "$m" -sigfile "$sig" >/dev/null 2>&1
}

# Видела ли ЭТА коробка хоть раз валидную подпись.
#
# Храповик вместо флаг-дня: критерий не «через два релиза», а «здесь подпись
# уже работала». До первой валидной подписи неподписанный манифест принимается
# (иначе роутер, установленный до появления подписи, не обновится никогда и
# ключа не получит). После — обязателен навсегда, отката к неподписанному нет.
au_trust_pinned() { [ -f "$Z2K_AU_TRUST_PIN" ]; }
au_trust_pin() {
    mkdir -p "$(dirname "$Z2K_AU_TRUST_PIN")" 2>/dev/null
    : > "$Z2K_AU_TRUST_PIN" 2>/dev/null
}

# Тянет ПАРУ (манифест, подпись). 0 — манифест непустой; отсутствие подписи
# здесь не ошибка, её разбирает вызывающий.
au_fetch_pair() {
    local murl="$1" surl="$2" out="$3" sig="$4"
    rm -f "$out" "$sig"
    if command -v z2k_fetch >/dev/null 2>&1; then
        z2k_fetch "$murl" "$out" || return 1
        z2k_fetch "$surl" "$sig" >/dev/null 2>&1 || true
    else
        curl -fsSL --max-time 30 "$murl" -o "$out" || return 1
        curl -fsSL --max-time 30 "$surl" -o "$sig" >/dev/null 2>&1 || true
    fi
    [ -s "$out" ] || return 1
}

# Перетянуть пару В ОБХОД КЭША, оставаясь на ветке, и перепроверить.
#
# Зачем. Манифест и его подпись — два независимых объекта, и тянутся они двумя
# независимыми запросами. По имени ВЕТКИ у каждого свой ключ кэша и свой TTL
# (raw — минуты, jsdelivr — до 12 часов), поэтому сразу после сдвига ветки
# штатно бывает окно, где свежий манифест приезжает со старой подписью. Пара
# не сходится — но это РАССОГЛАСОВАНИЕ ДОСТАВКИ, а не подделка, и разница
# принципиальная: с защёлкнутым храповиком второе означает жёсткий отказ
# обновляться, то есть массовый локаут до истечения чужого кэша. Ровно это и
# случилось на r-75.4 (2026-08-10) и «лечилось» ожиданием.
#
# ПОЧЕМУ НЕ ПО ТЕГУ — здесь стоял ровно такой фоллбэк, и он был дырой.
#
# Идея была: путь по тегу неизменяем, значит рвать нечего. Обоснование
# («худшее — уведут на другой ПОДПИСАННЫЙ нами же релиз») молча предполагало,
# что подписанный тег = опубликованный релиз. Это неверно. release.sh
# подписывает тег и пушит его в staging ДО прогона CI, а публикует ветку робот
# только после зелёного — то есть подписанный тег существует у каждого
# кандидата, включая тот, который CI завалил и который не будет опубликован
# никогда. Тег при этом брался из ЕЩЁ НЕ ПРОВЕРЕННОГО манифеста: враждебное
# зеркало подсовывает branch-манифест, указывающий на такой кандидат, роутер
# уходит по тегу, подпись там честная — и CD-гейт обойдён. Произвольный
# payload так не подсунуть, но «не выкладывать людям то, что не прошло тесты»
# — это и есть смысл всей схемы публикации.
#
# Независимо подтвердить «этот тег уже опубликован» клиент не может: судить об
# этом можно только по ветке, а ветка — ровно то, чему мы в этот момент не
# доверяем. Поэтому правило простое и без исключений: НИКОГДА не принимаем то,
# чего не отдала сама релизная ветка. Рассогласование лечим не прыжком в
# сторону, а честным перезапросом той же пары мимо кэша — первый хоп (VPS
# SNI-passthrough) идёт сквозным TLS до GitHub, так что ответ там свежий.
#
# Полномочий это не добавляет ни на грамм: принимается только то, что отдаёт
# ветка, и только с сошедшейся подписью. Не сошлось и так — отказ, как раньше.
au_repair_torn_pair() {
    local out="$1" sig="$2"
    local _n _m _s
    _n="$(date +%s 2>/dev/null)-$$"
    case "$Z2K_AU_MANIFEST_URL" in
        *\?*) _m="${Z2K_AU_MANIFEST_URL}&z2kcb=${_n}" ;;
        *)    _m="${Z2K_AU_MANIFEST_URL}?z2kcb=${_n}" ;;
    esac
    case "$Z2K_AU_SIG_URL" in
        *\?*) _s="${Z2K_AU_SIG_URL}&z2kcb=${_n}" ;;
        *)    _s="${Z2K_AU_SIG_URL}?z2kcb=${_n}" ;;
    esac

    local _o="${Z2K_AU_TMP_DIR}/UPDATES.retry.json"
    local _g="${_o}.sig"
    if au_fetch_pair "$_m" "$_s" "$_o" "$_g" && au_manifest_verify "$_o" "$_g"; then
        mv -f "$_o" "$out"
        mv -f "$_g" "$sig"
        au_log "пара манифест+подпись перетянута мимо кэша — подпись сошлась"
        return 0
    fi
    rm -f "$_o" "$_g"
    return 1
}

# Fetch UPDATES.json into $Z2K_AU_TMP_DIR/UPDATES.json. Uses z2k_fetch
# for layered CDN/DoH fallback if available; raw curl otherwise.
au_fetch_manifest() {
    mkdir -p "$Z2K_AU_TMP_DIR"
    local out="$Z2K_AU_TMP_DIR/UPDATES.json"
    local sig="${out}.sig"
    # Подпись тянется рядом, тем же транспортом. Её отсутствие — не сетевой
    # сбой, а состояние, которое разбирается ниже вместе с храповиком.
    au_fetch_pair "$Z2K_AU_MANIFEST_URL" "$Z2K_AU_SIG_URL" "$out" "$sig" || return 1

    au_manifest_verify "$out" "$sig"
    local _rc=$?
    # Пара не сошлась — прежде чем звать это подделкой, исключаем рваное
    # чтение: перетягиваем ту же пару с той же ветки мимо кэша.
    if [ "$_rc" != "0" ] && [ "$_rc" != "2" ] && au_repair_torn_pair "$out" "$sig"; then
        _rc=0
    fi
    case "$_rc" in
        0)
            # Первая валидная подпись защёлкивает храповик.
            au_trust_pinned || { au_trust_pin; au_log "подпись манифеста принята впервые — дальше она обязательна"; }
            return 0
            ;;
        2)
            # Проверить нечем: нет ключа (установка старше подписи) или нет
            # подходящего openssl. Пропускаем — но только пока храповик не
            # защёлкнут, иначе это была бы дыра «отними ключ и проверка исчезнет».
            if au_trust_pinned; then
                au_log "ОТКАЗ: подпись уже принималась на этой установке, а проверить её сейчас нечем"
                rm -f "$out" "$sig"
                return 1
            fi
            au_log "подпись не проверяется (нет ключа или openssl без Ed25519) — принимаю, храповик не защёлкнут"
            return 0
            ;;
        *)
            if au_trust_pinned; then
                au_log "ОТКАЗ: манифест без валидной подписи, а эта установка её уже принимала"
                rm -f "$out" "$sig"
                return 1
            fi
            # До первой валидной подписи неподписанный манифест — норма: именно
            # им приедет сам публичный ключ.
            au_log "манифест без валидной подписи — принимаю (подпись здесь ещё ни разу не работала)"
            return 0
            ;;
    esac
}

# ------------------------------------------------- manifest parsing ---

# au_manifest_current MANIFEST_PATH -> echoes "current" tag (e.g. "p-23")
au_manifest_current() {
    sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

# au_tag_num и au_tag_type удалены — обе были мертвы. Сравнение версий переехало
# с числового на порядок записей в history (см. ниже), а patch/reinstall берётся
# из поля "type" записи манифеста, а не из префикса тега. Держать их дальше было
# опасно: au_tag_num на дотнутом теге даёт мусор (p-70.1 -> "701"), и первый же
# случайный вызов вернул бы неверный порядок релизов.

# au_history_entries_after MANIFEST_PATH INSTALLED_TAG
# Echoes JSON entry lines for every history entry positioned strictly
# AFTER the entry matching installed_tag.
#
# Семантика — history-order, не numeric. Раньше использовался numeric
# compare на au_tag_num (число после префикса). Это ломалось на смешанной
# p-/r- нумерации: например r-6 (silent_drop fix, выпущен ПОСЛЕ p-7)
# имеет n=6 < 7, и numerically-после-p-7 фильтр его пропускал. История
# в UPDATES.json — авторитативный лог релизов; порядок entries — порядок
# выпуска, регardless of tag-numbering scheme.
#
# Если installed_tag не найден в history (свежая инсталляция / drift) —
# возвращаются ВСЕ entries: caller (au_decide) применит обычную
# patch/reinstall логику и догонит до current.
au_history_entries_after() {
    local manifest="$1"
    local installed_tag="$2"
    awk -v inst="$installed_tag" '
        /^[[:space:]]*\{[[:space:]]*"v"[[:space:]]*:[[:space:]]*"/ {
            line = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            v = line
            if (found) { print $0; next }
            if (v == inst) { found = 1; next }
            buf[++nbuf] = $0
        }
        END {
            # installed_tag not found in history — emit everything we
            # buffered (treat as fresh install).
            if (!found) {
                for (i = 1; i <= nbuf; i++) print buf[i]
            }
        }
    ' "$manifest"
}

# au_tag_in_history MANIFEST_PATH TAG -> return 0 if TAG appears as a history
# "v" entry, 1 otherwise. History is append-only and never pruned (see
# UPDATES.json rollback policy), so any tag we ever wrote is guaranteed to be
# present. A non-empty installed tag that is NOT found here therefore means
# drift/corruption — never a legitimately-behind router — and must not trigger
# the "emit entire history → reinstall" fallback in au_history_entries_after.
au_tag_in_history() {
    local manifest="$1"
    local tag="$2"
    awk -v want="$tag" '
        /^[[:space:]]*\{[[:space:]]*"v"[[:space:]]*:[[:space:]]*"/ {
            line = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            if (line == want) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' "$manifest"
}

# au_entry_field ENTRY_JSON FIELD -> echoes string value or empty
au_entry_field() {
    echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# au_entry_bool ENTRY_JSON FIELD -> echoes "true" or empty.
# JSON booleans are unquoted (true/false), so au_entry_field (which matches
# quoted string values) skips them. Used for optional release-level flags
# like "reset_state": true that toggle install.sh behaviour without
# changing the entry's type field.
au_entry_bool() {
    # Match unquoted boolean literal. JSON allows 0+ whitespace after the
    # `:`, so accept both `"k":true` and `"k": true`. Quoted "true"
    # string values are intentionally not matched (au_entry_field path).
    case "$1" in
        *"\"$2\":true"*|*"\"$2\": true"*|*"\"$2\":  true"*)
            echo "true"
            ;;
    esac
}

# au_entry_changed_files ENTRY_JSON -> echoes file paths (one per line)
au_entry_changed_files() {
    echo "$1" | sed -n 's/.*"changed_files"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
        | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | grep -v '^$' || true
}

# au_manifest_ref MANIFEST TAG -> ref (имя тега) для этой версии из history.
#
# ЗАЧЕМ. Раньше файлы качались с верхушки ветки. Ветка движется: обновление,
# начатое до её движения, доскачивало бы часть файлов уже от СЛЕДУЮЩЕГО релиза,
# и суммы бы не сошлись — обновление отваливалось на ровном месте. Теперь тянем
# по неизменяемому тегу, и «что объявили, то и скачали» держится по построению.
#
# Пустой ответ — легальное состояние: манифесты, выпущенные до этого механизма,
# несут в ref хеш коммита. Он тоже неизменяем и годится как ссылка.
au_manifest_ref() {
    local manifest="$1" tag="$2"
    [ -f "$manifest" ] || return 0
    grep '^[[:space:]]*{"v":' "$manifest" 2>/dev/null \
        | sed -n "s/.*\"v\"[[:space:]]*:[[:space:]]*\"${tag}\".*\"ref\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
        | head -1
}

# База скачивания: неизменяемая ссылка, если она объявлена, иначе ветка.
#
# Z2K_AU_TARGET_REF выставляется перед раскладкой из записи истории целевой
# версии. Пусто — манифест старый и ссылки не знает: ведём себя как раньше,
# иначе обновление встало бы у тех, кто пропустил внедряющий релиз.
au_repo_base() {
    if [ -n "${Z2K_AU_TARGET_REF:-}" ]; then
        printf 'https://raw.githubusercontent.com/necronicle/z2k/%s' "$Z2K_AU_TARGET_REF"
    else
        printf '%s' "$Z2K_AU_REPO_RAW"
    fi
}

# au_manifest_file_sha MANIFEST REPO_PATH -> expected sha256 of that file at
# HEAD, empty when the manifest carries no digest for it.
#
# The map lives at the top level of UPDATES.json (see scripts/gen_file_hashes.sh)
# rather than per-history-entry because we always download from branch HEAD:
# the right expectation is "what HEAD holds", not "what some entry in the window
# shipped". Manifests published before this existed simply have no map, and
# every lookup returns empty — verification is skipped, behaviour unchanged.
#
# `tr -d '\n'` first: the map is pretty-printed one pair per line, and folding
# it to a single line lets [^}] stop exactly at the end of the (flat, no nested
# objects) map.
au_manifest_file_sha() {
    local manifest="$1" path="$2" esc
    [ -f "$manifest" ] || return 0
    # Escape the path for use inside a sed regex — paths carry dots and slashes.
    esc=$(printf '%s' "$path" | sed 's/[][\.*^$/]/\\&/g')
    tr -d '\n' < "$manifest" 2>/dev/null \
        | sed -n 's/.*"files_sha256"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' \
        | tr ',' '\n' \
        | sed -n "s/^[[:space:]]*\"${esc}\"[[:space:]]*:[[:space:]]*\"\([0-9a-fA-F]\{64\}\)\".*/\1/p" \
        | head -1
}

# ---- адреса доставки: из манифеста, а не из пути ---------------------------
#
# install_map едет данными ровно потому, что обновление выполняет СТАРЫЙ
# апдейтер. Пока адреса выводились локальной таблицей, файл нового класса
# писался в лог как «no install target … (skipped)», а версия уезжала вперёд —
# доставки не было, а снаружи всё выглядело успешным.

# au_manifest_has_install_map <manifest> — есть ли карта. Её отсутствие (откат
# манифеста, ручная правка) НЕ повод гадать: вызывающий обязан потребовать
# полную переустановку, а не двигать версию.
au_manifest_has_install_map() {
    grep -q '"install_map"' "$1" 2>/dev/null
}

# au_manifest_install_targets <manifest> <путь в репо> — куда класть (0..N строк).
#
# Ищем ровно `"путь": [ … ]` по всему файлу: с двоеточием и скобкой этот путь
# встречается только в install_map. В files_sha256 у него значение-строка, а в
# changed_files он сам стоит значением — ни то, ни другое под шаблон не попадёт.
au_manifest_install_targets() {
    local manifest="$1" repo_path="$2" esc
    [ -f "$manifest" ] || return 0
    esc=$(printf '%s' "$repo_path" | sed 's/[][\.*^$\/]/\\&/g')
    tr -d '\n' < "$manifest" 2>/dev/null \
        | sed -n "s/.*\"${esc}\"[[:space:]]*:[[:space:]]*\\[\\([^]]*\\)\\].*/\\1/p" \
        | head -1 | tr ',' '\n' \
        | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | grep -v '^$'
}

# au_targets_for <путь в репо> — адреса из скачанного манифеста этого прогона.
au_targets_for() {
    au_manifest_install_targets "$Z2K_AU_TMP_DIR/UPDATES.json" "$1"
}

# ---- сходимость к манифесту --------------------------------------------------
#
# Обновление больше не «применяет дельту», объявленную релизом: оно приводит
# дерево к состоянию, которое манифест описывает целиком. Отсюда три свойства
# даром — прерванное обновление доделывается со следующего запуска, повторное
# ничего не делает, а файл, потерянный старым апдейтером как «no install target»,
# встаёт на место. Не потому что мы это предусмотрели, а потому что он не совпал
# по sha.
#
# Цена сверки измерена на роутере владельца: 89 файлов дерева (2.2 МБ) — меньше
# секунды, вместе с бинарниками и движком (30 МБ) — секунда.

# au_converge_plan <manifest> — что разошлось с манифестом (0..N путей в репо).
# au_manifest_pairs <manifest> — «путь<TAB>sha<TAB>первая цель» одним проходом
# awk, по строке на деливерабл.
#
# ЗАЧЕМ ОДНИМ ПРОХОДОМ. Наивная версия звала au_manifest_install_targets на
# каждый из 145 файлов, а та каждый раз перечитывала манифест целиком (206 КБ)
# и гоняла по нему sed — тридцать мегабайт чтения и три сотни процессов ради
# сверки, которая должна занимать секунду. На arm64 это незаметно, на mipsel —
# десятки секунд, и весь смысл переработки уходит в них.
au_manifest_pairs() {
    awk '
        # install_map: "путь": ["цель", …] — берём первую цель как представителя,
        # остальные копии (списки лежат в двух местах) выравниваются при раскладке.
        /"[^"]+"[[:space:]]*:[[:space:]]*\[/ {
            line = $0
            if (match(line, /"[^"]+"[[:space:]]*:[[:space:]]*\[/)) {
                key = substr(line, RSTART + 1)
                sub(/"[[:space:]]*:[[:space:]]*\[.*/, "", key)
                rest = substr(line, RSTART + RLENGTH)
                sub(/\].*/, "", rest)
                if (match(rest, /"[^"]*"/)) {
                    t = substr(rest, RSTART + 1, RLENGTH - 2)
                    if (t ~ /^\//) target[key] = t
                }
            }
            next
        }
        # files_sha256: "путь": "<64 hex>"
        /"[^"]+"[[:space:]]*:[[:space:]]*"[0-9a-f][0-9a-f]*"/ {
            line = $0
            if (match(line, /"[^"]+"[[:space:]]*:[[:space:]]*"[0-9a-f][0-9a-f]*"/)) {
                seg = substr(line, RSTART, RLENGTH)
                key = substr(seg, 2); sub(/"[[:space:]]*:.*/, "", key)
                val = seg; sub(/.*:[[:space:]]*"/, "", val); sub(/"$/, "", val)
                if (length(val) == 64) sha[key] = val
            }
            next
        }
        END {
            for (k in sha) if (k in target) printf "%s\t%s\t%s\n", k, sha[k], target[k]
        }
    ' "$1" 2>/dev/null
}

# au_converge_plan <manifest> — что разошлось с манифестом (0..N путей в репо).
# Файлы без цели (verify-only бинарники) сюда не попадают: их обновляет
# отдельный шаг refresh-binaries, потому что адрес зависит от арки роутера.
au_converge_plan() {
    local manifest="$1"
    [ -f "$manifest" ] || return 0
    au_manifest_pairs "$manifest" | while IFS="$(printf '\t')" read -r _cp_path _cp_want _cp_first; do
        [ -n "$_cp_path" ] && [ -n "$_cp_first" ] || continue
        if [ ! -f "$_cp_first" ]; then
            printf '%s\n' "$_cp_path"; continue
        fi
        [ "$(z2k_sha256_file "$_cp_first" 2>/dev/null)" = "$_cp_want" ] \
            || printf '%s\n' "$_cp_path"
    done
}

# au_converge_apply <manifest> <файл плана> — доставить перечисленное.
#
# Сначала скачать и проверить ВСЁ, только потом раскладывать. Обрыв связи или
# протухший ответ зеркала на середине не должен оставить дерево наполовину
# новым: до раскладки отказ ничего не стоит, после — это смесь версий, которую
# следующий прогон уже не отличит от нормы.
au_converge_apply() {
    local manifest="$1" plan="$2"
    local dl="$Z2K_AU_TMP_DIR/converge"
    [ -f "$plan" ] || return 0
    rm -rf "$dl"; mkdir -p "$dl" || return 1
    # СЧЁТЧИК ОБЯЗАТЕЛЕН, И ЭТО НЕ УКРАШЕНИЕ. Раньше здесь не было ни строки:
    # человек видел «расходится файлов — 10» и дальше молчание на всё время
    # скачивания. Отличить работу от зависания по такому журналу невозможно, и
    # владелец читал обычное обновление как поломку. Строка на файл печатается
    # ДО загрузки, а не после: смысл её в том, чтобы показать, на чём мы стоим
    # прямо сейчас, а не отчитаться о том, что уже прошло.
    local _ca_n _ca_i=0
    _ca_n=$(awk 'END {print NR}' "$plan" 2>/dev/null); [ -n "$_ca_n" ] || _ca_n=0
    while IFS= read -r _ca_path; do
        [ -n "$_ca_path" ] || continue
        _ca_i=$((_ca_i + 1))
        au_log "  [$_ca_i/$_ca_n] качаю $_ca_path"
        _ca_stage="$dl/$(printf '%s' "$_ca_path" | tr '/' '_')"
        # Эталон вычисляем ДО загрузки и отдаём загрузчику: тогда зеркало с
        # чужими байтами отклоняется как молчащее и пробуется следующее. Раньше
        # он считался после, и первое же несвежее зеркало роняло обновление
        # целиком, хотя рядом были ещё три исправных источника.
        _ca_want=$(au_manifest_file_sha "$manifest" "$_ca_path")
        au_download_repo_file_retry "$_ca_path" "$_ca_stage" "$_ca_want" || return 1
        if [ -n "$_ca_want" ]; then
            _ca_got=$(z2k_sha256_file "$_ca_stage" 2>/dev/null)
            if [ "$_ca_got" != "$_ca_want" ]; then
                # Сюда доходим, только если ВСЕ источники отдали чужое.
                au_log "сходимость: sha не сошлась у $_ca_path ни на одном источнике — раскладки не будет"
                return 1
            fi
        fi
    done < "$plan"

    # ЦЕЛИ БЕРЁМ ОДНИМ ПРОХОДОМ, а не поиском на каждый файл. Прежний вариант
    # склеивал манифест (222 КБ) в одну строку и гонял по ней sed на КАЖДЫЙ путь:
    # доля секунды на файл, но на обновлении в полторы сотни файлов — полминуты
    # молчания между последней скачанной строкой и первым шагом.
    #
    # Осечки копим в файле: цикл идёт за пайпом, то есть в подоболочке, и
    # присвоение rc оттуда наружу не переживает конец цикла — провал раскладки
    # вернулся бы успехом. Тот же приём стоит в refresh-binaries.
    local rc=0
    local cvfail="$Z2K_AU_TMP_DIR/converge.fail"
    rm -f "$cvfail"
    au_targets_bulk "$manifest" "$plan" \
    | while IFS="$(printf '\t')" read -r _ca_path _ca_t; do
        [ -n "$_ca_t" ] || continue
        _ca_stage="$dl/$(printf '%s' "$_ca_path" | tr '/' '_')"
        [ -f "$_ca_stage" ] || continue
        mkdir -p "$(dirname "$_ca_t")" 2>/dev/null
        # Атомарно: временный файл в ТОЙ ЖЕ директории и rename. Голый cp
        # переписывает цель на месте, и прерывание (обрыв питания, OOM —
        # обычное дело на этих коробках) оставляет полуфайл, смертельный
        # для init-скрипта или модуля, который сорсится прямо сейчас.
        # Бит +x восстанавливаем ДО переименования: cp не переносит его
        # надёжно между сборками BusyBox (скачанный файл 0644), и p-42
        # ровно так уронил S99zapret2 в 0644 — «Permission denied» при
        # рестарте.
        _ca_tmp="${_ca_t}.z2k-cv.$$"
        if cp -f "$_ca_stage" "$_ca_tmp" 2>/dev/null; then
            case "$_ca_t" in
                */init.d/*|*.sh) chmod +x "$_ca_tmp" 2>/dev/null || true ;;
            esac
            if ! mv -f "$_ca_tmp" "$_ca_t" 2>/dev/null; then
                rm -f "$_ca_tmp" 2>/dev/null
                au_log "сходимость: не записался $_ca_t (rename)"; echo 1 >> "$cvfail"
            fi
        else
            rm -f "$_ca_tmp" 2>/dev/null
            au_log "сходимость: не записался $_ca_t (copy)"; echo 1 >> "$cvfail"
        fi
    done
    [ -s "$cvfail" ] && rc=1
    rm -f "$cvfail"
    return "$rc"
}

# ---- последствия: каталог шагов ----------------------------------------------
#
# Что выполнить после доставки, объявляет РЕЛИЗ (history[].steps), а исполнитель
# исполняет. Каталог закрытый: шаг, которого здесь нет, — это релиз новее нашего
# кода, и единственный честный ответ на него «не могу, нужна полная установка»,
# а не тихо пропустить и сдвинуть версию.

# au_step_order — КАНОНИЧЕСКИЙ порядок. Исполнитель не доверяет порядку, в
# котором шаги перечислены в манифесте: он их сливает и идёт этим списком.
# Семь изменившихся lua плюс конфиг плюс бинарь дают ОДИН перезапуск в конце,
# а не девять действий. Дублирует z2k_all_steps из lib/release_map.sh намеренно:
# сборка и исполнитель — две стороны контракта, и tests/test_au_steps.sh сверяет,
# что стороны сошлись.
au_step_order() {
    echo regen-strategies
    echo regen-config
    echo validate-config
    echo refresh-binaries
    echo rebuild-panel
    echo reset-state
    echo restart-service
    # Чистка записей ip host — последней: она правит конфигурацию роутера, а не
    # наш обход, и её неудача не должна задерживать подъём сервиса. Порядок
    # обязан совпадать с z2k_all_steps в lib/release_map.sh — это один
    # контракт, и его сторожит tests/test_au_steps.sh.
    echo cleanup-ip-hosts
}

# au_entry_steps <manifest> <тег> — шаги одной записи истории (0..N строк).
# Запись без поля steps — это релиз старого образца: пусто, и это не ошибка.
au_entry_steps() {
    awk -v want="$2" '
        /^[[:space:]]*\{[[:space:]]*"v"[[:space:]]*:/ {
            v = $0; sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", v); sub(/".*/, "", v)
            if (v != want) next
            if ($0 !~ /"steps"/) next
            s = $0
            sub(/.*"steps"[[:space:]]*:[[:space:]]*\[/, "", s); sub(/\].*/, "", s)
            n = split(s, parts, ",")
            for (i = 1; i <= n; i++) {
                gsub(/[[:space:]"]/, "", parts[i])
                if (parts[i] != "") print parts[i]
            }
        }' "$1" 2>/dev/null
}

# au_steps_ordered — читает имена шагов со stdin и выдаёт их в каноническом
# порядке, каждый максимум один раз.
#
# ОДНИМ ПРОХОДОМ awk, БЕЗ ВРЕМЕННОГО ФАЙЛА. Так это и вызывается на живом пути:
# { au_steps_union …; echo reset-state; } | au_steps_ordered — внутренний
# упорядочиватель работает ВНУТРИ внешнего, в том же пайпе. Пока имя временного
# файла бралось из PID, оба брали одно имя, внутренний удалял файл из-под
# внешнего, и объявленные шаги могли молча пропасть.
au_steps_ordered() {
    awk -v order="$(au_step_order | tr '\n' ' ')" '
        { gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "" && !($0 in seen)) { seen[$0] = 1; got[++n] = $0 } }
        END {
            k = split(order, o, " ")
            for (i = 1; i <= k; i++) if (o[i] in seen) { print o[i]; done[o[i]] = 1 }
            # Неизвестные — в конец, а НЕ в корзину: они обязаны дойти до
            # au_run_steps и там потребовать полную переустановку. Тихо
            # выкинуть шаг из будущего значит сдвинуть версию, не сделав того,
            # что релиз объявил.
            for (i = 1; i <= n; i++) if (!(got[i] in done)) print got[i]
        }'
}

# au_steps_union <manifest> <тег>… — объединение шагов набора релизов в
# каноническом порядке, каждый максимум один раз.
au_steps_union() {
    local manifest="$1"; shift
    local t
    for t in "$@"; do au_entry_steps "$manifest" "$t"; done | au_steps_ordered
}

# Сорсинг генераторов из доставленного дерева. Тот же приём, что у вебморды
# (_gen_libs_source в webpanel/cgi/actions.sh): модули читаются из ${zd}/lib,
# то есть уже НОВЫЕ — их положила сходимость этим же прогоном.
au_gen_libs_source() {
    local zd="${ZAPRET2_DIR:-/opt/zapret2}" d
    for d in "$zd/lib" /tmp/z2k/lib; do
        [ -f "$d/config_official.sh" ] || continue
        # shellcheck disable=SC1090
        [ -f "$d/utils.sh" ] && . "$d/utils.sh"
        # shellcheck disable=SC1090
        . "$d/config_official.sh" || return 1
        # shellcheck disable=SC1090
        [ -f "$d/strategies.sh" ] && . "$d/strategies.sh"
        return 0
    done
    return 1
}

au_step_regen_strategies() {
    au_gen_libs_source || { au_log "regen-strategies: нет генераторов в ${ZAPRET2_DIR}/lib"; return 1; }
    command -v create_default_strategy_files >/dev/null 2>&1 || {
        au_log "regen-strategies: create_default_strategy_files недоступна"; return 1; }
    create_default_strategy_files >/dev/null 2>&1
}

au_step_regen_config() {
    au_gen_libs_source || { au_log "regen-config: нет генераторов в ${ZAPRET2_DIR}/lib"; return 1; }
    command -v create_official_config >/dev/null 2>&1 || {
        au_log "regen-config: create_official_config недоступна"; return 1; }
    create_official_config "${ZAPRET2_DIR}/config" >/dev/null 2>&1
}

# Валидация — с правом вето. Перезапуск в сломанный конфиг оставляет роутер без
# обхода до утра, поэтому провал здесь обязан остановить всю цепочку.
#
# ДВА КОДА, А НЕ ОДИН. z2k-config-validator.sh различает исходы: 0 — чисто,
# 1 — ПРЕДУПРЕЖДЕНИЯ («дублирующийся фильтр между профилями» и подобное),
# 2 — ошибки, nfqws2 может не запуститься. Наивное «любой ненулевой код = не
# прошло» превращает штатное предупреждение в отказ обновления с откатом, а
# такие предупреждения есть на живых роутерах прямо сейчас — откатывалось бы
# КАЖДОЕ обновление, объявившее этот шаг.
#
# И код наружу нормализуем: rc=2 от валидатора, выпущенный как есть, читается
# вызывающим как «шаг неизвестен» — то есть сломанный конфиг уводил бы в полную
# переустановку вместо отката.
au_step_validate_config() {
    local v="${ZAPRET2_DIR}/z2k-config-validator.sh" rc
    # Валидатор — доставляемый файл, и сходимость кладёт его ДО шагов. Если его
    # тут нет, значит доставка не сработала: проверять нечем, идти дальше нельзя.
    [ -f "$v" ] || { au_log "validate-config: валидатора нет — считаю проверку непройденной"; return 1; }
    # `cmd; rc=$?` ЗДЕСЬ НЕЛЬЗЯ. Этот файл сорсится в z2k.sh, а тот работает
    # под `set -e`: простая команда с ненулевым кодом убивает оболочку ДО
    # присваивания, молча и без единой строки в журнале. Валидатор возвращает 1
    # на одних лишь предупреждениях — то есть почти у всех, — и обновление из
    # терминала умирало ровно тут, возвращая приглашение. Через панель тех же
    # шагов хватало, потому что z2k-auto-update.sh запускается отдельным
    # процессом и `set -e` в нём нет. Форма `|| rc=$?` от errexit защищена:
    # команда стоит слева от ||, а это условный контекст.
    rc=0
    sh "$v" "${ZAPRET2_DIR}/config" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) au_log "validate-config: предупреждения, ошибок нет — продолжаю"; return 0 ;;
        *) au_log "validate-config: конфиг не прошёл проверку (код $rc) — вето на перезапуск"; return 1 ;;
    esac
}

# Бинарники: цель зависит от арки роутера, поэтому в install_map их нет и
# сходимость их не трогает. Здесь — адресно: своя сборка, сверка по манифесту,
# атомарная подмена, перезапуск владельца.
au_bin_goarch() {
    local hw ba
    hw=$(get_arch 2>/dev/null || uname -m)
    ba=$(map_arch_to_bin_arch "$hw" 2>/dev/null || true)
    case "$ba" in
        linux-arm64)    echo arm64 ;;
        linux-arm)      echo arm ;;
        linux-mipsel)   echo mipsle ;;
        linux-mips64el) echo mips64le ;;
        linux-mips64)   echo mips64le ;;
        linux-mips)     echo mips ;;
        linux-x86_64)   echo amd64 ;;
        linux-x86)      echo 386 ;;
        linux-riscv64)  echo riscv64 ;;
        linux-ppc)      echo ppc64 ;;
    esac
}

au_step_refresh_binaries() {
    local manifest="$Z2K_AU_TMP_DIR/UPDATES.json"
    # Опознание арки живёт в utils.sh (get_arch, map_arch_to_bin_arch). Штатный
    # вход его подключает, но полагаться на вызывающего нельзя: ровно на такой
    # неявной зависимости шаг очистки записей молчал у всех.
    au_gen_libs_source >/dev/null 2>&1 || true
    local goarch; goarch=$(au_bin_goarch)
    [ -n "$goarch" ] || { au_log "refresh-binaries: арка не опознана"; return 1; }
    # Осечки копим в файле, а не в переменной: цикл ниже идёт за пайпом, то есть
    # в подоболочке — присвоение оттуда не переживает конец цикла, и провал
    # загрузки вернулся бы наружу успехом.
    local fail="$Z2K_AU_TMP_DIR/refresh-binaries.fail"
    mkdir -p "$(dirname "$fail")" 2>/dev/null
    rm -f "$fail"
    # Все сборки под нашу арку, объявленные манифестом.
    grep -oE '"[^"]+/builds/[^"]+-linux-'"$goarch"'"[[:space:]]*:' "$manifest" 2>/dev/null \
    | sed 's/"[[:space:]]*:.*//; s/^"//' | sort -u \
    | while IFS= read -r _rb_path; do
        [ -n "$_rb_path" ] || continue
        _rb_base=$(basename "$_rb_path")
        _rb_name="${_rb_base%-linux-$goarch}"
        # Каталог переопределим ради тестов: живой путь — /opt/sbin.
        _rb_dest="${Z2K_AU_SBIN:-/opt/sbin}/${_rb_name}"
        _rb_want=$(au_manifest_file_sha "$manifest" "$_rb_path")
        # ОБНОВЛЯЕМ, А НЕ СТАВИМ. Отсутствующий бинарник — это не «его надо
        # доставить», а «его тут не должно быть»: z2k-warpd ставится только
        # кнопкой «Установить WARP», а tg-mtproxy-client и z2k-detect — самой
        # установкой. Без этой проверки шаг тянул семь мегабайт движка WARP на
        # роутеры, где WARP никто не включал, и панель после этого показывала
        # его установленным.
        if [ ! -f "$_rb_dest" ]; then
            continue
        fi
        if [ -n "$_rb_want" ] \
           && [ "$(z2k_sha256_file "$_rb_dest" 2>/dev/null)" = "$_rb_want" ]; then
            continue
        fi
        _rb_tmp="${_rb_dest}.z2k-au.$$"
        rm -f "$_rb_tmp" "${_rb_tmp}.etag" 2>/dev/null
        # Бинарники — мегабайты против килобайтов у остального дерева, и на
        # медленном канале это единственное место, где обновление стоит долго.
        # Молчать здесь нельзя ровно по той же причине, что и в сходимости.
        au_log "refresh-binaries: качаю $_rb_name (файл большой, это дольше остального)"
        if ! au_download_repo_file "$_rb_path" "$_rb_tmp" "$_rb_want"; then
            au_log "refresh-binaries: не скачался $_rb_path"; rm -f "$_rb_tmp"; echo 1 >> "$fail"; continue
        fi
        rm -f "${_rb_tmp}.etag" 2>/dev/null
        if [ -n "$_rb_want" ] && [ "$(z2k_sha256_file "$_rb_tmp" 2>/dev/null)" != "$_rb_want" ]; then
            au_log "refresh-binaries: sha не сошлась у $_rb_path — рабочий бинарник не трогаю"
            rm -f "$_rb_tmp"; echo 1 >> "$fail"; continue
        fi
        chmod +x "$_rb_tmp" 2>/dev/null
        # Владельца останавливаем ДО подмены: mv атомарен и ETXTBSY не даёт, но
        # оставленный работать старый процесс продолжил бы крутить старый код.
        for _rb_svc in $(au_service_for_binary "$_rb_name"); do
            [ -x "$_rb_svc" ] && "$_rb_svc" stop >/dev/null 2>&1
        done
        if mv -f "$_rb_tmp" "$_rb_dest" 2>/dev/null; then
            au_log "refresh-binaries: обновлён $_rb_dest"
        else
            rm -f "$_rb_tmp" 2>/dev/null
            au_log "refresh-binaries: не записался $_rb_dest"; echo 1 >> "$fail"
        fi
        for _rb_svc in $(au_service_for_binary "$_rb_name"); do
            [ -x "$_rb_svc" ] && "$_rb_svc" start >/dev/null 2>&1
        done
    done
    if [ -s "$fail" ]; then rm -f "$fail"; return 1; fi
    rm -f "$fail"
    return 0
}

# Init-скрипты, владеющие бинарником. У tg-mtproxy-client их два: S98tg-tunnel
# держит :1443 (Telegram), S97z2k-http-tunnel — :1444 (cdnbase); оба гоняют один
# файл, поэтому подменять его можно только остановив оба.
au_service_for_binary() {
    case "$1" in
        z2k-rt-proxy)      echo "/opt/etc/init.d/S96z2k-rt-proxy" ;;
        z2k-detect)        echo "/opt/etc/init.d/S98z2k-detect" ;;
        z2k-warpd)         echo "/opt/etc/init.d/S51z2k-warp" ;;
        tg-mtproxy-client) echo "/opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97z2k-http-tunnel" ;;
    esac
}

# Панель: lighttpd.conf шаблонизируется установщиком (@PORT@/@BIND@), поэтому
# доставленный файл сам по себе ничего не меняет. Установщик читает
# сохранённые port/bind из дерева, так что адрес панели не сбрасывается.
# Панель: lighttpd.conf собирается из шаблона подстановкой @PORT@/@BIND@/
# @WWW_DIR@, поэтому доставленный файл сам по себе ничего не меняет.
#
# ЗВАТЬ УСТАНОВЩИК ПАНЕЛИ ОТСЮДА НЕЛЬЗЯ, и это проверено на роутере: он живёт в
# ${zd}/webpanel/install.sh, но исходники панели (www/, init.d/) лежат рядом с
# ним только во время установки. Запущенный на месте он говорит «source files
# missing or empty — refusing to touch the installed panel» и возвращает 1. То
# есть шаг в прежнем виде провалился бы на каждом роутере.
#
# Подставляем сами, из того, что на роутере уже есть: шаблон .in и сохранённые
# порт с адресом. Ни один плейсхолдер не должен остаться — иначе панель поднимет
# конфиг с @PORT@ и умрёт, поэтому проверяем и отказываемся.
au_step_rebuild_panel() {
    local zd="${ZAPRET2_DIR:-/opt/zapret2}"
    local tpl="$zd/webpanel/lighttpd.conf.in"
    local dst="$zd/webpanel/lighttpd.conf"
    local port bind www tmp
    [ -f "$tpl" ] || { au_log "rebuild-panel: шаблона $tpl нет — пересобирать не из чего"; return 1; }
    port=$(tr -dc '0-9' < "$zd/webpanel/port" 2>/dev/null)
    bind=$(tr -d '[:space:]' < "$zd/webpanel/bind" 2>/dev/null)
    www="$zd/www"
    [ -n "$port" ] || { au_log "rebuild-panel: не читается сохранённый порт"; return 1; }
    [ -n "$bind" ] || { au_log "rebuild-panel: не читается сохранённый адрес"; return 1; }
    tmp="${dst}.z2k-au.$$"
    sed -e "s|@WWW_DIR@|${www}|g" -e "s|@PORT@|${port}|g" -e "s|@BIND@|${bind}|g" \
        "$tpl" > "$tmp" 2>/dev/null || { rm -f "$tmp"; au_log "rebuild-panel: подстановка не удалась"; return 1; }
    if grep -q '@[A-Z_]*@' "$tmp" 2>/dev/null; then
        au_log "rebuild-panel: в конфиге остался плейсхолдер $(grep -o '@[A-Z_]*@' "$tmp" | head -1) — панель не трогаю"
        rm -f "$tmp"; return 1
    fi
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; au_log "rebuild-panel: не записался $dst"; return 1; }
    au_log "rebuild-panel: конфиг панели пересобран (порт $port, адрес $bind)"
    [ -x /opt/etc/init.d/S96z2k-webpanel ] && /opt/etc/init.d/S96z2k-webpanel restart >/dev/null 2>&1
    return 0
}

# Сброс состояния автоподбора. Объявляется вручную — при сдвиге нумерации пулов
# накопленная статистика начинает указывать не на те стратегии.
#
# ПУТЬ БЫЛ НЕВЕРНЫЙ, и это стоило бы молчаливого «сделано»: state.tsv лежит в
# extra_strats/cache/autocircular/, а не в корне ${zd}. Шаг удалял
# несуществующий файл и возвращал успех — то есть релиз, объявивший сброс, его
# бы не выполнил, и никто бы не узнал. Проверено на роутере владельца.
#
# Снимаем тот же набор, что и переустановка (lib/install.sh): сам state, его
# lock/tmp и запасную копию в /tmp — иначе сброшенная ротация тут же поднимет
# старую статистику из кэша.
au_step_reset_state() {
    local zd="${ZAPRET2_DIR:-/opt/zapret2}"
    local ac="$zd/extra_strats/cache/autocircular"
    rm -f "${STATE_FILE:-$ac/state.tsv}" \
          "$ac/state.tsv.lock" "$ac/state.tsv.tmp" \
          /tmp/z2k-autocircular-state.tsv 2>/dev/null
    au_log "reset-state: состояние автоподбора сброшено"
    return 0
}

# Скачать файл сходимости с ПОВТОРАМИ.
#
# ЗАЧЕМ. Один несостоявшийся файл ронял всю доставку и откатывал обновление
# целиком — без единой повторной попытки. На дёрганом канале это означает «не
# обновится никогда»: человек с 25.08.2026 стоял на p-79.14, и каждую ночь
# журнал повторял одно и то же — «[1/47] качаю …», «не скачался», «откат».
# Шесть ночей подряд, каждый раз на ПЕРВОМ файле прогона, причём файл был
# каждую ночь разный. То есть падал не файл, а первая же загрузка.
#
# z2k_fetch и так обходит четыре источника, но ровно один раз. Повтор берёт то,
# что источники отдают через несколько секунд: у этого человека в тех же
# журналах сыплются и списки, и туннель — канал не мёртвый, а рваный.
#
# Когда всё исправно, повторов не происходит вовсе, то есть цена нулевая.
#
# В журнал уходит ПРИЧИНА, а не только факт. Прежняя строка «не скачался <файл>»
# не давала ничего: не видно ни сколько было попыток, ни что ответили источники,
# и разбор упирался в догадки.
au_download_repo_file_retry() {
    local _path="$1" _dest="$2" _want="$3"
    local _tries _try=0 _pause
    _tries=$(z2k_uint "${Z2K_AU_FILE_TRIES:-3}" 3 1 10)
    while :; do
        _try=$((_try + 1))
        if au_download_repo_file "$_path" "$_dest" "$_want"; then
            [ "$_try" -gt 1 ] && au_log "  $_path: получен с попытки $_try"
            return 0
        fi
        if [ "$_try" -ge "$_tries" ]; then
            au_log "сходимость: не скачался $_path за $_try попыт(ки) — последний ответ ${Z2K_LAST_HTTP:-нет}, отказ соединения ${Z2K_LAST_CONNFAIL:-0}, слой VPS ${Z2K_FETCH_VPS_OUT:-0}"
            return 1
        fi
        # Пауза растёт: первая заминка обычно короткая, а если источник лёг
        # всерьёз, долбить его чаще смысла нет.
        _pause=$((_try * 3))
        au_log "  $_path: попытка $_try не удалась (ответ ${Z2K_LAST_HTTP:-нет}), жду ${_pause}с"
        sleep "$_pause"
    done
}

au_step_restart_service() {
    local init="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
    [ -f "$init" ] || { au_log "restart-service: $init нет"; return 1; }
    # Бит +x: патч-путь на некоторых сборках BusyBox его ронял (p-42), и прямой
    # запуск падал с rc 126.
    chmod +x "$init" 2>/dev/null
    "$init" restart >/dev/null 2>&1
}

# Вычистить наши ip host записи из конфига роутера.
#
# Четвёртый слой скачивания писал их постоянно и на каждую неудачную попытку;
# слой снят 30.08.2026, но у людей накопленное осталось — по три-четыре строки
# на домен при 256 слотах у Keenetic. Обновление обязано прибирать за прошлыми
# версиями: реинсталл это уже делает, а сходимость шла мимо.
#
# Идемпотентно и дёшево: одно чтение running-config. Гейт на доступность —
# как у regen-config: функция живёт в lib/install.sh, и в контексте, где её нет,
# шаг просто пропускается, а не валит обновление.
au_step_cleanup_ip_hosts() {
    # Функцию надо СНАЧАЛА подключить. Раньше здесь стояла только проверка на
    # наличие, и она не проходила никогда: функция жила в install.sh, который
    # апдейтер не подключает. Шаг молча писал «функция недоступна» и не делал
    # ничего — записи ip host не чистились ни у кого (жалоба 31.08.2026).
    # Теперь функция в utils.sh, и он подключается тем же путём, что и
    # генераторы конфига.
    au_gen_libs_source >/dev/null 2>&1 || true
    command -v cleanup_legacy_ip_hosts >/dev/null 2>&1 || {
        au_log "cleanup-ip-hosts: функция недоступна, пропускаю"; return 0; }
    cleanup_legacy_ip_hosts >/dev/null 2>&1
    return 0
}

# au_run_step <шаг> — rc: 0 сделано, 1 шаг провалился, 2 шага не знаем.
au_run_step() {
    case "$1" in
        regen-strategies) au_step_regen_strategies ;;
        regen-config)     au_step_regen_config ;;
        validate-config)  au_step_validate_config ;;
        refresh-binaries) au_step_refresh_binaries ;;
        rebuild-panel)    au_step_rebuild_panel ;;
        reset-state)      au_step_reset_state ;;
        restart-service)  au_step_restart_service ;;
        cleanup-ip-hosts) au_step_cleanup_ip_hosts ;;
        *) au_log "неизвестный шаг «$1» — нужна полная переустановка"; return 2 ;;
    esac
}

# au_step_human <шаг> — как назвать шаг в журнале. Идентификаторы вроде
# «regen-strategies» нужны коду, а человеку нужно знать, что делают с его
# роутером. Неизвестный шаг печатаем как есть: соврать хуже, чем не перевести.
au_step_human() {
    case "$1" in
        regen-strategies) printf 'пересобираю стратегии' ;;
        regen-config)     printf 'пересобираю конфиг' ;;
        validate-config)  printf 'проверяю конфиг' ;;
        refresh-binaries) printf 'обновляю бинарники' ;;
        rebuild-panel)    printf 'пересобираю веб-панель' ;;
        reset-state)      printf 'сбрасываю состояние стратегий' ;;
        restart-service)  printf 'перезапускаю сервис' ;;
        cleanup-ip-hosts) printf 'убираю записи от прежних версий' ;;
        *)                printf '%s' "$1" ;;
    esac
}

# au_run_steps <шаг>… — по порядку, до первой осечки. Останов, а не «идём
# дальше и надеемся»: провал валидации обязан отменить перезапуск.
au_run_steps() {
    local s rc
    for s in "$@"; do
        au_log "шаг: $(au_step_human "$s")"
        rc=0
        au_run_step "$s" || rc=$?
        if [ "$rc" != 0 ]; then
            au_log "шаг «$(au_step_human "$s")» не удался (код $rc) — дальше не идём"
            return "$rc"
        fi
    done
    return 0
}

# ------------------------------------------------------------ decide ---

# au_decide INSTALLED_TAG MANIFEST_PATH
# Echoes (line 1 is the verdict, line 2+ are changed file paths):
#   none                                                  (nothing to do)
#   patch <target_tag>                                    (apply changed files)
#   reinstall <target_tag>                                (full reinstall, preserve state)
#   reinstall <target_tag> reset_state                    (full reinstall, wipe autocircular state)
#
# reset_state is set when *any* history entry in the diff window has
# "reset_state": true. This is the per-release switch for detector or
# strategy changes that invalidate the persisted autocircular state.
# Webpanel / list-only releases keep state by omitting the flag.
au_decide() {
    local installed_tag="$1"
    local manifest="$2"

    # Normalize: strip ALL whitespace / CR. A tag stored as "r-54.1\r" (CRLF
    # write) or " r-54.1 " would fail the exact `v == inst` match downstream
    # and fall into au_history_entries_after's "not found → emit ALL history"
    # path → a full reinstall (+reset_state, since the window then spans
    # entries that carry it) fires EVERY night even though nothing changed.
    installed_tag=$(printf '%s' "$installed_tag" | tr -d '[:space:]')

    local current
    current=$(au_manifest_current "$manifest")
    if [ -z "$current" ]; then
        au_log "в манифесте нет поля current"
        echo "none"
        return 0
    fi

    # Empty tag is NOT a fresh install — fresh installs have no tag file and
    # are handled by au_run_apply's first-run branch (mark current, no apply).
    # An empty tag reaching here means a truncated/corrupt .z2k-installed-tag;
    # refuse to interpret it as "behind by the entire history".
    if [ -z "$installed_tag" ]; then
        au_log "отметка версии пуста или испорчена — обновления не будет (вслепую переустанавливать не станем)"
        echo "none"
        return 0
    fi

    # Non-empty tag absent from append-only history = drift/corruption, never
    # a legitimately-behind router. Skip rather than blind-reinstall to current.
    if ! au_tag_in_history "$manifest" "$installed_tag"; then
        au_log "версии '$installed_tag' нет в истории релизов — обновления не будет (вслепую переустанавливать не станем)"
        echo "none"
        return 0
    fi

    local entries
    entries=$(au_history_entries_after "$manifest" "$installed_tag")

    # Empty diff window → installed_tag IS current (or beyond). Nothing
    # to do. Раньше тут сидел numeric `current_n <= installed_n` shortcut,
    # но он ломался на смешанной p-/r- нумерации (r-6 num=6 vs p-7 num=7)
    # и на drift-сценариях (installed_tag отсутствует в history).
    # Entries-emptiness check одинаково корректен для обоих случаев:
    # au_history_entries_after для unknown installed возвращает всю
    # history (treat as fresh install), для совпадения возвращает только
    # entries после.
    if [ -z "$(echo "$entries" | grep -v '^[[:space:]]*$' | head -1)" ]; then
        echo "none"
        return 0
    fi

    # Смешанное дерево после неполного отката патчем не лечится: патч кладёт
    # только изменённые файлы и достроит один гибрид до другого. Любой вердикт
    # здесь становится reinstall, пока маркер не снят успешной переустановкой.
    local has_reinstall=0
    if au_tree_is_dirty; then
        au_log "дерево помечено как смешанное — вердикт принудительно reinstall"
        has_reinstall=1
    fi

    # any reinstall in the diff window → reinstall to current
    # any reset_state=true in the diff window → wipe autocircular state
    local has_reset_state=0
    local files=""
    local entry etype cf rs
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        etype=$(au_entry_field "$entry" "type")
        [ "$etype" = "reinstall" ] && has_reinstall=1
        rs=$(au_entry_bool "$entry" "reset_state")
        [ "$rs" = "true" ] && has_reset_state=1
        cf=$(au_entry_changed_files "$entry")
        [ -n "$cf" ] && files="${files}
${cf}"
    done <<EOF
$entries
EOF

    # de-duplicate files
    files=$(echo "$files" | sort -u | grep -v '^$' || true)

    if [ "$has_reinstall" = "1" ]; then
        if [ "$has_reset_state" = "1" ]; then
            printf 'reinstall %s reset_state\n%s\n' "$current" "$files"
        else
            printf 'reinstall %s\n%s\n' "$current" "$files"
        fi
    else
        # patch path cannot wipe state — patches are surgical file
        # replacements, not full reinstalls. If a release author needs
        # state wiped, type must be "reinstall".
        printf 'patch %s\n%s\n' "$current" "$files"
    fi
}

# -------------------------------------------------- Z2K_* feature flags ---

# Extract Z2K_* feature flags from the active config to a backup file.
au_save_feature_flags() {
    local out="$1"
    local config_file="${ZAPRET2_DIR:-/opt/zapret2}/config"
    [ -f "$config_file" ] || return 0
    grep -E '^Z2K_[A-Z0-9_]+=' "$config_file" > "$out" 2>/dev/null || true
    if [ -s "$out" ]; then
        au_log "saved $(wc -l < "$out") feature flags"
    fi
    return 0
}

# Reapply Z2K_* feature flags from backup over the active config.
# Only flags that already exist in the new config are replaced; new-config
# defaults stand for absent (deprecated) flags.
au_reapply_feature_flags() {
    local backup="$1"
    local config_file="${ZAPRET2_DIR:-/opt/zapret2}/config"
    [ -f "$backup" ] && [ -s "$backup" ] || return 0
    [ -f "$config_file" ] || return 1

    local applied=0 skipped=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local flag_name="${line%%=*}"
        if grep -q "^${flag_name}=" "$config_file"; then
            # escape & and / for sed
            local escaped
            escaped=$(printf '%s\n' "$line" | sed 's/[&/\\]/\\&/g')
            sed -i "s|^${flag_name}=.*|${escaped}|" "$config_file"
            applied=$((applied + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < "$backup"
    au_log "feature flags reapplied: $applied set, $skipped skipped (deprecated)"
    return 0
}

# ------------------------------------------------ карта путей — на сборке ---
#
# au_install_paths() и au_reinstall_required() жили здесь и потому опаздывали
# на релиз: обновление выполняет СТАРЫЙ апдейтер, и правило, добавленное в
# релизе N, при переходе НА N не действовало — файл нового класса писался в лог
# как «no install target … (skipped)», а версия уезжала вперёд.
#
# Теперь таблицы читает только сборка — lib/release_map.sh, — а результат едет
# в UPDATES.json данными: install_map (куда класть) и history[].steps (что
# делать после). Роутер ничего не выводит из пути, он исполняет присланное.

# Download a single repo file via z2k_fetch (or curl) into a target.
# au_download_repo_file ПУТЬ ЦЕЛЬ [ОЖИДАЕМЫЙ_SHA256]
#
# ТРЕТИЙ ПАРАМЕТР ОБЯЗАН ПЕРЕДАВАТЬСЯ ВЕЗДЕ, ГДЕ ЭТАЛОН ИЗВЕСТЕН. Без него
# z2k_fetch принимает ответ ЛЮБОГО зеркала, лишь бы это был не HTML с ошибкой,
# — а зеркала кэшируют ветку и отдают байты прошлого релиза. Дальше сверка
# ловит расхождение, но уже поздно: источник не помечен негодным, следующий
# хоп не пробуется, и обновление падает целиком.
#
# Так и легло обновление у пользователя 26.08.2026 (диагностика 1007):
# p-79.10 -> p-79.17, тридцать три файла скачаны, на webpanel/www/js/pages/warp.js
# sha не сошлась — «раскладки не будет», откат. Манифест при этом сходился сам
# с собой в обоих релизах, и сам файл между ними не менялся: расходились
# доставленные байты, то есть отвечало несвежее зеркало.
#
# Ожидание передаётся ПАРАМЕТРОМ, а не глобальной переменной. Прежде его
# выставляли снаружи, и получилось ровно то, что бывает с такой связью: путь
# патча и загрузка z2k.sh выставляли, сходимость и бинарники — забыли, а
# заметить это по коду вызова было нельзя.
au_download_repo_file() {
    local repo_path="$1"
    local target="$2"
    local want_sha="${3:-}"
    local url rc _cb _cburl
    url="$(au_repo_base)/${repo_path}"
    mkdir -p "$(dirname "$target")"
    if command -v z2k_fetch >/dev/null 2>&1; then
        # z2k_fetch сверяет КАЖДЫЙ хоп сам и отклоняет зеркало с чужими байтами
        # так же, как молчащее, — переходя к следующему.
        if [ -n "$want_sha" ]; then
            Z2K_FETCH_SHA256="$want_sha"; export Z2K_FETCH_SHA256
        fi
        # `cmd || rc=$?`, а НЕ `cmd; rc=$?`: скрипт сорсится в z2k.sh под
        # `set -e`, и вторая форма убивает оболочку на самой команде, до
        # присваивания, молча. Слева от `||` команда стоит в условии, и errexit
        # там не срабатывает.
        rc=0
        z2k_fetch "$url" "$target" || rc=$?
        unset Z2K_FETCH_SHA256
        [ "$rc" = "0" ] && { [ -s "$target" ] || [ -f "$target" ]; } && return 0

        # ПЕРЕЗАПРОС МИМО КЭША. Перебор зеркал не спасает от единственной
        # причины, общей для ВСЕХ зеркал сразу: релизная ветка только что
        # переехала, а кэши ещё несколько минут отдают до-релизные байты.
        # Манифест этим уже защищён (au_repair_torn_pair), файлы — не были, и
        # окно после каждой публикации гарантированно ловило того, кто
        # проверился первым: манифест свежий, файл старый, sha не сходится,
        # откат. Так лёг r-80.1 на первом же роутере.
        #
        # Ждать истечения кэша — не решение: обновление и так уже объявлено,
        # а роутер уходит в откат и следующую попытку делает через сутки.
        # Спрашиваем те же зеркала ещё раз, но с уникальным параметром: для
        # кэша это другой объект, и он идёт за ним к первоисточнику.
        #
        # Только когда ждём КОНКРЕТНЫЕ байты: без эталона перезапрос ничего не
        # доказывает, а лишний обход зеркал стоит времени на этих коробках.
        if [ -n "$want_sha" ]; then
            local _cb _cburl
            _cb="$(date +%s 2>/dev/null)-$$"
            case "$url" in
                *\?*) _cburl="${url}&z2kcb=${_cb}" ;;
                *)     _cburl="${url}?z2kcb=${_cb}" ;;
            esac
            Z2K_FETCH_SHA256="$want_sha"; export Z2K_FETCH_SHA256
            rc=0
            z2k_fetch "$_cburl" "$target" || rc=$?
            unset Z2K_FETCH_SHA256
            if [ "$rc" = "0" ] && { [ -s "$target" ] || [ -f "$target" ]; }; then
                au_log "  $repo_path: зеркала отдали несвежее, перезапрос мимо кэша помог"
                return 0
            fi
        fi
    else
        # Резервный путь без z2k_fetch — одно зеркало, перебирать нечего, но
        # молча принять чужие байты нельзя и здесь.
        if curl -fsSL --max-time 30 "$url" -o "$target" && { [ -s "$target" ] || [ -f "$target" ]; }; then
            if [ -z "$want_sha" ] || [ "$(z2k_sha256_file "$target" 2>/dev/null)" = "$want_sha" ]; then
                return 0
            fi
            rm -f "$target" "${target}.etag" 2>/dev/null
            # Тот же перезапрос мимо кэша, что и выше: причина промаха здесь
            # ровно та же, а запасной путь ходит к одному источнику и обязан
            # уметь пробить его кэш сам.
            if [ -n "$want_sha" ]; then
                _cb="$(date +%s 2>/dev/null)-$$"
                case "$url" in
                    *\?*) _cburl="${url}&z2kcb=${_cb}" ;;
                    *)     _cburl="${url}?z2kcb=${_cb}" ;;
                esac
                if curl -fsSL --max-time 30 "$_cburl" -o "$target" \
                   && [ "$(z2k_sha256_file "$target" 2>/dev/null)" = "$want_sha" ]; then
                    au_log "  $repo_path: источник отдал несвежее, перезапрос мимо кэша помог"
                    return 0
                fi
                rm -f "$target" "${target}.etag" 2>/dev/null
            fi
        fi
    fi
    # Download failed. Distinguish a file DELETED upstream (a later release in
    # the patch window removed it — e.g. a dropped feature) from a transient
    # network failure. A 404 must NOT abort the whole patch (that permanently
    # strands every router crossing that version window — the z2k-discord-voice-
    # pin.sh / r-57 incident); a transient error SHOULD abort so we retry rather
    # than apply a half-patch. No -f here so curl reports the real 4xx status.
    # rc: 0=ok, 2=deleted(404), 1=transient/other.
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null)
    [ "$code" = "404" ] && return 2
    return 1
}

# Скачать z2k.sh, которым потом ПЕРЕУСТАНАВЛИВАЕТСЯ всё дерево от root.
#
# Этот путь срабатывает сам, по расписанию, без человека — поэтому он опаснее
# ручной установки: там команду набирает пользователь, здесь не набирает никто.
# До 2026-08-08 он тянул скрипт вообще без сверки, хотя эталон для z2k.sh уже
# лежал в карте files_sha256 и патч-путь рядом (au_apply_patch) им пользовался.
# То есть механизм проверки доставлялся непроверенным.
#
# Теперь дайджест обязателен, когда манифест его знает: не совпало — зеркало
# пропускается как не ответившее, а если не совпало нигде, обновление не
# применяется. Это ровно тот fail-closed, который здесь дёшев: отказ оставляет
# человека на работающей старой версии, а не без обхода.
#
# Манифесты, выпущенные до появления карты сумм, дайджеста не несут. Тогда
# поведение прежнее (иначе такие роутеры больше никогда не обновятся), но
# gh-proxy из списка зеркал выпадает: это анонимный сторонний реверс-прокси,
# он терминирует TLS на своём сертификате и может отдать что угодно — пускать
# его туда, где сверять не с чем, значит отдавать ему root на роутере.
au_download_reinstall_script() {
    local target="$1"
    # По неизменяемой ссылке: переустановка тянет z2k.sh, а он тянет lib/* —
    # с верхушки ветки человек поставил бы не ту версию, которую ему объявили.
    local url
    url="$(au_repo_base)/z2k.sh"
    local jsdelivr="" gh_proxy=""
    local want_sha got_sha rc

    rm -f "$target"

    want_sha=$(au_manifest_file_sha "$Z2K_AU_TMP_DIR/UPDATES.json" "z2k.sh")
    if [ -n "$want_sha" ]; then
        au_log "reinstall: z2k.sh ожидается с sha256 ${want_sha}"
    else
        au_log "reinstall: в манифесте нет sha256 для z2k.sh — ставим без проверки содержимого, gh-proxy исключён"
    fi

    if command -v z2k_fetch >/dev/null 2>&1; then
        # z2k_fetch сверяет каждый хоп сам, если ему передан ожидаемый дайджест.
        [ -n "$want_sha" ] && { Z2K_FETCH_SHA256="$want_sha"; export Z2K_FETCH_SHA256; }
        z2k_fetch "$url" "$target"
        rc=$?
        unset Z2K_FETCH_SHA256
        [ "$rc" = "0" ] && [ -s "$target" ] && return 0
        rm -f "$target"
    fi

    case "$url" in
        https://raw.githubusercontent.com/*)
            local rest owner repo branch path
            rest="${url#https://raw.githubusercontent.com/}"
            owner="${rest%%/*}"; rest="${rest#*/}"
            repo="${rest%%/*}"; rest="${rest#*/}"
            branch="${rest%%/*}"; path="${rest#*/}"
            jsdelivr="https://cdn.jsdelivr.net/gh/${owner}/${repo}@${branch}/${path}"
            [ -n "$want_sha" ] && gh_proxy="https://gh-proxy.com/${url}"
            ;;
    esac

    for url in "$(au_repo_base)/z2k.sh" "$jsdelivr" "$gh_proxy"; do
        [ -z "$url" ] && continue
        au_log "переустановка: качаю z2k.sh с $url"
        if curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$target" \
           && [ -s "$target" ]; then
            if [ -z "$want_sha" ]; then
                return 0
            fi
            got_sha=$(z2k_sha256_file "$target" 2>/dev/null)
            if [ -z "$got_sha" ]; then
                # Считать нечем — а раз дайджест известен, «не проверили» здесь
                # значит «не знаем, что запускаем от root». Это отказ.
                au_log "reinstall: нечем посчитать sha256 — отказ (эталон известен, проверка обязательна)"
                rm -f "$target"
                return 1
            fi
            if [ "$got_sha" = "$want_sha" ]; then
                return 0
            fi
            au_log "reinstall: sha256 не сошёлся у $url (получено ${got_sha}) — зеркало пропущено"
        fi
        rm -f "$target"
    done

    return 1
}

# -------------------------------------------------- 3-way merge: extras ---

# extra-domains.txt is the only file where users append their own domains.
# Merge: new_runtime = shipped_new ∪ (current_runtime − shipped_old).
au_merge_extra_domains() {
    local zd="${ZAPRET2_DIR:-/opt/zapret2}"
    local shipped_old="${zd}/files/lists/extra-domains.txt"
    local runtime="${zd}/lists/extra-domains.txt"
    local shipped_new="$1"   # path to freshly downloaded shipped version

    if [ ! -f "$shipped_new" ]; then
        au_log "merge extra-domains: shipped_new missing, skipping"
        return 1
    fi

    local user_extras="$Z2K_AU_TMP_DIR/extra-domains.user_extras"
    if [ -f "$shipped_old" ] && [ -f "$runtime" ]; then
        grep -vxFf "$shipped_old" "$runtime" 2>/dev/null > "$user_extras" || true
    elif [ -f "$runtime" ]; then
        # no baseline known — treat all runtime lines as user extras, but
        # only those NOT already in shipped_new (avoid duplicates)
        grep -vxFf "$shipped_new" "$runtime" 2>/dev/null > "$user_extras" || true
    else
        : > "$user_extras"
    fi

    # Update shipped baseline first (shipped_old gets replaced)
    mkdir -p "$(dirname "$shipped_old")"
    cp -f "$shipped_new" "$shipped_old"

    # Build new runtime: shipped_new + user-only lines (deduped)
    {
        cat "$shipped_new"
        if [ -s "$user_extras" ]; then
            cat "$user_extras"
        fi
    } | awk '!seen[$0]++' > "$runtime.tmp"
    mv -f "$runtime.tmp" "$runtime"

    local user_n
    user_n=$(wc -l < "$user_extras" 2>/dev/null || echo 0)
    au_log "merged extra-domains: ${user_n} user-only lines preserved"
    return 0
}

# NB: WARP lists are not merged here. The per-game lists are pulled live from
# medvedeff-true/ru-gaming-blocklist by z2k-update-lists.sh
# (update_warp_game_list) into lists/warp/games/, which the daily refresh owns
# outright; the user's own lists next to it are never touched by an update.

# ----------------------------------------------------------- apply paths ---

# Apply patch: download every changed_file, place into install target.
# extra-domains.txt is 3-way merged, everything else is straight replace.
au_apply_patch() {
    local target_tag="$1"
    shift
    local files="$*"

    # Пин на неизменяемую ссылку целевой версии: всё, что скачает эта раскладка,
    # приедет из ОДНОГО объявленного среза.
    Z2K_AU_TARGET_REF=$(au_manifest_ref "$Z2K_AU_TMP_DIR/UPDATES.json" "$target_tag")
    export Z2K_AU_TARGET_REF
    [ -n "$Z2K_AU_TARGET_REF" ] \
        && au_log "файлы тянем по неизменяемой ссылке $Z2K_AU_TARGET_REF" \
        || au_log "в манифесте нет ref для $target_tag — тянем с ветки (старый манифест)"

    if [ -z "$files" ]; then
        au_log "patch with no files — nothing to do"
        return 0
    fi

    # Адреса доставки берутся из install_map манифеста. Нет карты — значит
    # манифест старше исполнителя (откат манифеста, ручная правка), и гадать по
    # шаблонам путей нельзя: именно так файл нового класса терялся, а версия
    # уезжала вперёд. Честно говорим «не могу» и уходим на полную переустановку.
    if ! au_manifest_has_install_map "$Z2K_AU_TMP_DIR/UPDATES.json"; then
        au_log "в манифесте нет install_map — патчем доставить нечем, нужна полная переустановка"
        return 2
    fi


    # Start from an EMPTY staging dir. It used to be mkdir -p only, never
    # cleaned, so a file staged by an earlier run survived here alongside its
    # .etag sidecar — and the next run could present that stale pair to a
    # mirror, take the 304, count it a successful download, and install the old
    # file while the version tag moved forward. Only our subdir: the parent also
    # holds .install_rc and the fetched installer, which the reinstall path is
    # in the middle of using.
    rm -rf "$Z2K_AU_TMP_DIR/dl"
    mkdir -p "$Z2K_AU_TMP_DIR/dl"
    local saved_flags="$Z2K_AU_TMP_DIR/feature-flags.backup"
    au_save_feature_flags "$saved_flags"

    # 1) download all files first to staging — atomic-ish: if any download
    # fails, we abort before touching live files.
    local repo_path stage _dl_rc deleted_paths="" _want_sha
    while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        stage="$Z2K_AU_TMP_DIR/dl/$(echo "$repo_path" | tr '/' '_')"
        # Hand the expected digest to z2k_fetch: a mirror answering with the
        # wrong bytes is then skipped exactly like one that did not answer, and
        # if every mirror is stale the download fails outright instead of
        # installing old content under a new version number.
        # Манифест — корень доверия, он по построению отсутствует в собственной
        # карте сумм: проверять себя самим собой бессмысленно. Раньше это
        # выглядело как дефект — в лог обновления шла строка «в манифесте нет
        # sha256, содержимое не проверяется», и человек читал её как поломку.
        #
        # Заодно он качался ВТОРОЙ раз: обновление уже скачало его в начале,
        # чтобы вообще решить, что ставить. Берём тот файл, а не тянем заново.
        if [ "$repo_path" = "UPDATES.json" ]; then
            if cp -f "$Z2K_AU_TMP_DIR/UPDATES.json" "$stage" 2>/dev/null; then
                au_log "patch: UPDATES.json — беру уже скачанный манифест (он и есть корень доверия)"
                _dl_rc=0
            else
                au_log "patch: UPDATES.json — не удалось взять скачанный манифест"
                _dl_rc=1
            fi
        else
            _want_sha=$(au_manifest_file_sha "$Z2K_AU_TMP_DIR/UPDATES.json" "$repo_path")
            [ -n "$_want_sha" ] || \
                au_log "patch: $repo_path — в манифесте нет sha256, содержимое не проверяется"
            au_download_repo_file "$repo_path" "$stage" "$_want_sha"
            _dl_rc=$?
        fi
        unset Z2K_FETCH_SHA256
        if [ "$_dl_rc" = "2" ]; then
            # Deleted upstream (404) — a later release in this window removed it.
            # Do NOT abort; record it so step 2 deletes the stale local copy.
            au_log "patch: $repo_path removed upstream (404) — skipping, will delete local copy"
            deleted_paths="$deleted_paths $repo_path"
            continue
        elif [ "$_dl_rc" != "0" ]; then
            au_log "patch: failed to download $repo_path — aborting"
            return 1
        fi
    done <<EOF
$files
EOF

    # 2) install each file
    #
    # ОТКАЗ УСТАНОВКИ ОБЯЗАН ДОЙТИ ДО ВЫЗЫВАЮЩЕГО. Ниже обе ветки отказа (cp и
    # mv) раньше только писали в лог и шли к следующему файлу, а функция затем
    # безусловно доходила до записи installed-tag и `return 0`. Вся остальная
    # машинерия обновления — au_rollback_patch, маркер «смешанное дерево»
    # au_mark_dirty_tree — висит на единственной ветке `if ! au_apply_patch`,
    # то есть при частичной установке не срабатывала НИКОГДА.
    #
    # Почему это не теоретическое: файлы качаются в Z2K_AU_TMP_DIR (/tmp, ОЗУ), а
    # раскладываются в /opt (флешка). Это разные точки монтирования, и ровно /opt
    # у этого проекта регулярно уходит в read-only или в ENOSPC (мёртвый NAND,
    # power-loss). Скачивание при этом проходит, а установка части файлов — нет.
    # Дальше installed-tag продвигался на новую версию, и следующий прогон
    # сравнивал теги, видел совпадение и не делал ничего. Роутер оставался на
    # смеси старого и нового навсегда, без единого признака в статусе.
    local _au_install_failed=0
    local targets target _del_targets _dt
    while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        # Deleted upstream (404 in step 1) → remove the stale local target(s), skip.
        case " $deleted_paths " in
            *" $repo_path "*)
                _del_targets=$(au_targets_for "$repo_path")
                while IFS= read -r _dt; do
                    [ -z "$_dt" ] && continue
                    [ -e "$_dt" ] && rm -f "$_dt" 2>/dev/null && \
                        au_log "patch: removed $_dt (deleted upstream)"
                done <<EOF_DEL
$_del_targets
EOF_DEL
                continue ;;
        esac
        stage="$Z2K_AU_TMP_DIR/dl/$(echo "$repo_path" | tr '/' '_')"
        targets=$(au_targets_for "$repo_path")
        if [ -z "$targets" ]; then
            au_log "patch: no install target for $repo_path (skipped)"
            continue
        fi

        # extra-domains.txt: 3-way merge (handles both /files/lists/ and /lists/)
        if [ "$repo_path" = "files/lists/extra-domains.txt" ]; then
            au_merge_extra_domains "$stage"
            continue
        fi

        while IFS= read -r target; do
            [ -z "$target" ] && continue
            mkdir -p "$(dirname "$target")"
            # Atomic install: write to a temp in the SAME directory, set perms,
            # then rename over the target. A bare `cp -f` truncates+rewrites the
            # target in place (same inode); an interruption mid-copy (power loss,
            # OOM kill — both common on these boxes) leaves a half-written file —
            # catastrophic for a directly-executed init script or a lib being
            # sourced during this very update. rename() is atomic and leaves any
            # running process's old inode intact until it exits.
            #
            # Restore the executable bit BEFORE the rename. `cp` does NOT reliably
            # preserve it across BusyBox builds (the downloaded stage is 0644);
            # p-42 first shipped a DIRECTLY-EXECUTED file (S99zapret2) and on
            # routers where cp dropped +x the init script became 0644 →
            # "Permission denied" (rc 126) on restart. chmod the known-exec targets.
            _au_tmp="${target}.z2k-au.$$"
            if cp -f "$stage" "$_au_tmp" 2>/dev/null; then
                case "$target" in
                    */init.d/*|*.sh)
                        chmod +x "$_au_tmp" 2>/dev/null || true ;;
                esac
                if mv -f "$_au_tmp" "$target" 2>/dev/null; then
                    au_log "patch: installed $repo_path -> $target"
                else
                    rm -f "$_au_tmp" 2>/dev/null
                    au_log "patch: FAILED to install $repo_path -> $target (rename)"
                    _au_install_failed=$((_au_install_failed + 1))
                fi
            else
                rm -f "$_au_tmp" 2>/dev/null
                au_log "patch: FAILED to stage $repo_path -> $target (copy)"
                _au_install_failed=$((_au_install_failed + 1))
            fi
        done <<EOF_TARGETS
$targets
EOF_TARGETS
    done <<EOF
$files
EOF

    # 2a) хоть один файл не встал — это НЕ успех.
    #
    # Возвращаемся с ошибкой ДО записи installed-tag: тег — единственное, по чему
    # следующий прогон понимает, нужно ли обновляться, и продвинуть его на
    # версию, которая разложена наполовину, значит закрыть себе путь к
    # исправлению навсегда. Вызывающий (au_run_apply) на ненулевом коде откатит
    # патч и пометит дерево смешанным — ровно то, ради чего эти механизмы и
    # написаны.
    if [ "$_au_install_failed" -gt 0 ]; then
        au_log "patch: не установлено файлов: $_au_install_failed — тег НЕ продвигаем, отдаём ошибку для отката"
        return 1
    fi

    # 3) reapply feature flags (config might have been replaced if it was
    # in changed_files). For pure lua/list patches this is a no-op.
    au_reapply_feature_flags "$saved_flags"

    # 4) write installed tag
    #
    # Проверяем запись: пустой или ненаписанный тег уводит следующий прогон в
    # ветку «installed tag empty/corrupt → no update», и обновлений не будет
    # больше НИКОГДА — молча, до ручного вмешательства. Файлы при этом уже
    # разложены, так что откатывать нечего; сообщаем и возвращаем ошибку, чтобы
    # это попало в лог и в статус, а не растворилось.
    if ! au_write_installed_tag "$target_tag"; then
        au_log "patch: НЕ удалось записать installed-tag — следующий прогон не увидит обновлений"
        return 1
    fi

    # 5) smart restart — figure out which services actually need to be
    # bounced based on which files changed. Without this, patches that
    # replace init.d scripts (e.g. p-27 replaced S98tg-tunnel) leave the
    # OLD code still running in memory until reboot — defeats the point
    # of shipping the fix. S99zapret2 always restarts because the nfqws2
    # input set (lua / hostlists / config / fake blobs) goes through it.
    local restart_set="S99zapret2"
    local geosite_refresh=0 geosite_force=0
    local f
    while IFS= read -r f; do
        case "$f" in
            files/init.d/S98tg-tunnel)         restart_set="$restart_set S98tg-tunnel" ;;
            files/init.d/S97z2k-http-tunnel)   restart_set="$restart_set S97z2k-http-tunnel" ;;
            files/init.d/S96z2k-rt-proxy)      restart_set="$restart_set S96z2k-rt-proxy" ;;
            files/init.d/S51z2k-warp)          restart_set="$restart_set S51z2k-warp" ;;
            files/init.d/S99z2k-scheduler)     restart_set="$restart_set S99z2k-scheduler" ;;
            files/z2k-scheduler.sh)            restart_set="$restart_set S99z2k-scheduler" ;;
            files/init.d/S98z2k-detect)        restart_set="$restart_set S98z2k-detect" ;;
            webpanel/*)                        restart_set="$restart_set S96z2k-webpanel" ;;
            files/z2k-geosite.sh)
                # Новая логика geosite — нужен immediate refresh, иначе она
                # применится только при следующем scheduler tick (раз в сутки).
                #
                # ФОРСИРУЕМ снос ETag-кеша ТОЛЬКО здесь. Правка самого скрипта
                # способна поменять что угодно в разборе и нормализации, а на
                # 304 цель не пересобирается вовсе — значит новый код к старому
                # содержимому цели не применится. Цена (полная перекачка всех
                # ассетов) платится за смену кода, а не за смену одной строки в
                # списке.
                geosite_refresh=1; geosite_force=1 ;;
            files/lists/rkn-false-positive.txt)
                # Список ложных срабатываний — тот же immediate refresh, но БЕЗ
                # форса. Раньше здесь стоял общий FORCE_REFETCH=1, и правка
                # одной строки в fp-списке стоила повторной перекачки ВСЕХ
                # четырёх ассетов (RKN + youtube + discord), хотя пересобрать
                # надо ровно RKN. Инвариант «сменился fp-список → RKN собрать
                # заново» теперь держит сам z2k-geosite.sh (_z2k_rkn_fp_gate,
                # гейт по отпечатку перед fetch RKN) — и держит на ВСЕХ путях,
                # включая ночной cron и правку списка рукой, куда форс отсюда
                # не доставал никогда.
                geosite_refresh=1 ;;
        esac
    done <<EOF
$files
EOF

    # Dedup + restart each service exactly once
    local svc
    for svc in $(echo "$restart_set" | tr ' ' '\n' | sort -u); do
        [ -z "$svc" ] && continue
        if [ -x "/opt/etc/init.d/$svc" ]; then
            au_log "patch: restart $svc"
            # Вывод перезапуска СОХРАНЯЕМ. Раньше он уходил в /dev/null, и при
            # отказе в журнале оставалось только «returned non-zero» — то есть
            # ровно ничего. Дальше health-check видел мёртвый nfqws2, откатывал
            # исправный патч, и человек читал «непонятно что не так».
            _rst_out=$(mktemp 2>/dev/null || echo /tmp/z2k-au-restart.$$)
            if ! "/opt/etc/init.d/$svc" restart > "$_rst_out" 2>&1; then
                au_log "patch: $svc restart returned non-zero — вот что он сказал:"
                tail -12 "$_rst_out" 2>/dev/null | while IFS= read -r _l; do
                    [ -n "$_l" ] && au_log "patch:   $_l"
                done
            fi
            rm -f "$_rst_out" 2>/dev/null
        fi
    done

    # Geosite immediate refresh: если изменился z2k-geosite.sh или
    # rkn-false-positive.txt — apply filter без ожидания scheduler tick.
    #
    # ПУТЬ: скрипт живёт в ${zd}/z2k-geosite.sh, а НЕ в ${zd}/files/. Здесь
    # стояло `${zd}/files/z2k-geosite.sh` — такого файла на роутере нет вообще
    # (au_install_paths для `files/*.sh` кладёт в ${zd}/), поэтому guard всегда
    # был ложным и ветка молча не выполнялась НИ РАЗУ: логика приезжала, а
    # обещанный немедленный refresh не запускался. Найдено проверкой на живом
    # роутере 2026-08-06. Проверяем -r, а не -x: запускаем через `sh`, бит
    # исполнения не нужен и на части установок не выставлен.
    if [ "$geosite_refresh" = "1" ] && [ -r "${zd}/z2k-geosite.sh" ]; then
        au_log "patch: triggering geosite refresh (filter applied immediately)"
        # FORCE_REFETCH=0 — это НЕ «выключено», а «форс только там, где он
        # нужен»: geosite читает эту переменную как признак сноса ETag-кеша, и
        # передавать её значением дешевле, чем городить две ветки вызова.
        FORCE_REFETCH="$geosite_force" sh "${zd}/z2k-geosite.sh" fetch >/dev/null 2>&1 || \
            au_log "patch: geosite refresh returned non-zero (continuing)"
    fi

    au_log "patch applied: $target_tag"
    return 0
}

# Apply reinstall: rerun z2k.sh in non-interactive mode. install.sh handles
# all the bookkeeping. Contract environment install.sh observes:
#   Z2K_AUTO_UPDATE=1            — non-interactive auto-update context
#   Z2K_AU_TARGET_TAG=<tag>      — release tag being applied
#   Z2K_AU_FEATURE_FLAGS_BACKUP  — path to saved Z2K_* flags
#   Z2K_RESET_STATE=1            — (optional) wipe autocircular state.tsv
#                                  instead of restoring from backup
#
# Second arg `reset_state` (literal string) toggles Z2K_RESET_STATE.
au_apply_reinstall() {
    local target_tag="$1"
    local reset_state="$2"

    # Тот же пин: z2k.sh и всё, что он тянет, приезжают из объявленного среза.
    Z2K_AU_TARGET_REF=$(au_manifest_ref "$Z2K_AU_TMP_DIR/UPDATES.json" "$target_tag")
    export Z2K_AU_TARGET_REF
    [ -n "$Z2K_AU_TARGET_REF" ] \
        && au_log "переустановка по неизменяемой ссылке $Z2K_AU_TARGET_REF" \
        || au_log "в манифесте нет ref для $target_tag — переустановка с ветки"
    local saved_flags="$Z2K_AU_TMP_DIR/feature-flags.backup"
    local reinstall_script="$Z2K_AU_TMP_DIR/z2k-reinstall.sh"
    au_save_feature_flags "$saved_flags"

    mkdir -p "$Z2K_AU_TMP_DIR"
    if ! au_download_reinstall_script "$reinstall_script"; then
        au_log "reinstall failed: could not fetch z2k.sh from any mirror"
        return 1
    fi

    local reset_env=""
    if [ "$reset_state" = "reset_state" ]; then
        reset_env="Z2K_RESET_STATE=1"
        au_log "reinstall: wiping autocircular state (release reset_state flag)"
    fi

    au_log "reinstall: launching z2k.sh install"
    # shellcheck disable=SC2086
    # Pipe through `tee -a` so install output reaches BOTH:
    #  (a) the persistent /opt/var/log/z2k-auto-update.log (auditable later)
    #  (b) our own stdout — which the caller (z2k-auto-update.sh apply
    #      invoked from update_apply_async / scheduler) redirects to either the
    #      per-job /tmp/z2k-job-<id>.log (webpanel) or the manual user
    #      terminal. Without the tee, install steps got swallowed by the
    #      append-to-file redirect and the user saw only "reinstall:
    #      launching" + 60s of silence + "reinstall applied".
    # `pipefail` is bash-only; in BusyBox sh the pipe's exit code is the
    # last command (tee), so we capture install.sh exit via PIPESTATUS-
    # equivalent using a separate file.
    local rc_file="$Z2K_AU_TMP_DIR/.install_rc"
    rm -f "$rc_file"
    (
        # GITHUB_RAW передаём явно: z2k.sh тянет lib/*, списки и бинарники сам,
        # и без пина взял бы их с верхушки ветки — то есть человек получил бы не
        # ту версию, которую ему объявили.
        env Z2K_AUTO_UPDATE=1 Z2K_AU_TARGET_TAG="$target_tag" \
            Z2K_AU_FEATURE_FLAGS_BACKUP="$saved_flags" \
            ${Z2K_AU_TARGET_REF:+GITHUB_RAW="https://raw.githubusercontent.com/necronicle/z2k/$Z2K_AU_TARGET_REF"} \
            $reset_env \
            sh "$reinstall_script" install 2>&1
        echo "$?" > "$rc_file"
    ) | tee -a "$Z2K_AU_LOG_FILE"
    local rc
    rc=$(cat "$rc_file" 2>/dev/null || echo 1)
    rm -f "$rc_file"
    if [ "$rc" -ne 0 ]; then
        au_log "переустановка не удалась, код $rc"
        return 1
    fi

    # install.sh may have already written the tag, but enforce it here too.
    if ! au_write_installed_tag "$target_tag"; then
        au_log "переустановка: НЕ удалось записать отметку версии — следующий прогон не увидит обновлений"
        return 1
    fi
    au_log "переустановка выполнена: $target_tag"
    return 0
}

# ----------------------------------------------------------- health-check ---

au_health_check() {
    # Override via Z2K_AU_HEALTH_TIMEOUT env var (set before sourcing the module).
    local timeout="$Z2K_AU_HEALTH_TIMEOUT"
    au_log "проверка после обновления: жду ${timeout} с, потом смотрю, всё ли живо"
    sleep "$timeout"

    # nfqws2 was already confirmed up and queue-bound by the restart itself.
    # Failing here therefore does not mean "too slow to start" — it means the
    # daemon came up and then died, which is a genuine reason to roll back.
    if ! pgrep -f nfqws2 >/dev/null 2>&1; then
        # Сравниваем с тем, что было ДО обновления. Если nfqws2 не работал и
        # раньше, патч ни при чём: откатывать его бессмысленно, а главное —
        # вредно. Раньше этой проверки не было, и на роутере, где сервис не
        # поднимается по своей причине (нет модулей ядра, нет ipset bitmap:port),
        # КАЖДОЕ обновление откатывалось само. Человек не мог обновиться никогда
        # и не понимал почему.
        if [ "${Z2K_AU_NFQWS_WAS_ALIVE:-1}" = "0" ]; then
            au_log "проверка: nfqws2 не работает, но он и ДО обновления не работал — обновление ни при чём, оставляем"
            au_log "проверка: разберитесь, почему не стартует сервис (диагностика: раздел «что не так»)"
        else
            au_log "проверка не пройдена: nfqws2 запустился и умер"
            return 1
        fi
    fi

    # A patch can ship a shell script with a SYNTAX error that does not stop the
    # already-running nfqws2 (so the pgrep above still passes) yet bricks the next
    # boot, the menu, or the webpanel. Parse-check the critical installed scripts
    # — the init script, every sourced lib, and the root-running CGI. A parse
    # error here means the patch is broken and must roll back. These are all
    # POSIX-sh on the router, so `sh -n` is the right check.
    local _zd="${ZAPRET2_DIR:-/opt/zapret2}" _bad=""
    for _s in /opt/etc/init.d/S99zapret2 "$_zd"/lib/*.sh "$_zd"/webpanel/cgi/*.sh; do
        [ -f "$_s" ] || continue
        sh -n "$_s" 2>/dev/null || _bad="$_bad $_s"
    done
    if [ -n "$_bad" ]; then
        au_log "проверка не пройдена: синтаксическая ошибка в файлах:$_bad"
        return 1
    fi

    # Остальные сервисы z2k. Гейтом их НЕ делаем — обход держит nfqws2, и ронять
    # из-за упавшей вебпанели исправное обновление хуже, чем жить без панели.
    # Но и молчать нельзя: раньше health-check смотрел исключительно на nfqws2,
    # поэтому отказ tg-туннеля, rt-proxy, планировщика или панели засчитывался
    # как «обновление прошло успешно», и человек узнавал об этом от Telegram,
    # который перестал работать. Теперь это видно в логе обновления.
    #
    # Проверяем только те, что реально установлены: набор сервисов зависит от
    # включённых фич, и отсутствующий init-скрипт — не отказ.
    # Смотрим ТОЛЬКО на те, что работали до обновления (au_snapshot_services).
    # Сервис, выключенный флагом, до обновления не работал и после не работает —
    # обновление тут ни при чём, и сообщать не о чем.
    local _svc _svc_pat _down=""
    for _svc in ${Z2K_AU_SVC_ALIVE:-}; do
        _svc_pat=$(au_service_pattern "$_svc") || continue
        pgrep -f "$_svc_pat" >/dev/null 2>&1 || _down="$_down $_svc"
    done
    if [ -n "$_down" ]; then
        au_log "проверка: ВНИМАНИЕ, после обновления не работают:$_down"
        au_log "проверка: обход (nfqws2) жив, откат не делаем — но эти сервисы нужно поднять"
    fi

    # GitHub reachability is an ADVISORY signal — NOT a health gate. The probe
    # hits a bare hostname (DNS-dependent) and github.com is not bypassed, so on
    # a router whose provider blocks GitHub or whose DoH resolver is broken it
    # fails even when the update is perfectly sound. Rolling back on this alone
    # churned good updates every night (revert tag → re-apply → fail → revert…),
    # which is exactly what users with a broken upstream DNS reported. nfqws2 is
    # alive and every installed script parses clean (the two checks above) — that
    # already proves the update is healthy. A failed probe only logs a warning.
    if ! curl -fsS --max-time 10 -o /dev/null "$Z2K_AU_HEALTH_GH_URL"; then
        au_log "проверка: до GitHub не достучались — на обновление это не влияет, обход жив и файлы целы"
    fi

    au_log "проверка пройдена: всё живо"
    return 0
}

# au_snapshot_services — какие сервисы z2k работали ДО обновления.
#
# ЗАЧЕМ. Health-check раньше ругался на любой неработающий сервис из списка. Но
# половина из них выключается флагом: Z2K_DISCOVER по умолчанию OFF, поэтому
# «ВНИМАНИЕ, после обновления не работают: S98z2k-detect» получал весь флот при
# КАЖДОМ обновлении — на здоровом роутере, где сервис и не должен работать.
# Такую строку перестают читать, а вместе с ней перестают замечать настоящую.
#
# Ругаться надо не на «выключен», а на «работал и перестал»: это ровно то, что
# может сломать обновление, и это не зависит ни от одного флага фич. Ту же
# логику мы уже применяем к nfqws2 (Z2K_AU_NFQWS_WAS_ALIVE).
au_services_list() {
    printf '%s\n' S98tg-tunnel S96z2k-rt-proxy S99z2k-scheduler S98z2k-detect S96z2k-webpanel
}

au_service_pattern() {
    case "$1" in
        S98tg-tunnel)      printf 'tg-mtproxy-client' ;;
        S96z2k-rt-proxy)   printf 'rt-proxy' ;;
        S99z2k-scheduler)  printf 'z2k-scheduler' ;;
        S98z2k-detect)     printf 'z2k-detect' ;;
        S96z2k-webpanel)   printf 'lighttpd' ;;
        *)                 return 1 ;;
    esac
}

au_snapshot_services() {
    local _s _p _alive=""
    for _s in $(au_services_list); do
        [ -x "/opt/etc/init.d/$_s" ] || continue
        _p=$(au_service_pattern "$_s") || continue
        pgrep -f "$_p" >/dev/null 2>&1 && _alive="$_alive $_s"
    done
    Z2K_AU_SVC_ALIVE="$_alive"
    export Z2K_AU_SVC_ALIVE
}

# Re-applied when health-check fails. Two different snapshots are in play:
# the reinstall path is covered by install.sh, which calls
# create_rollback_snapshot("pre-reinstall") before it touches anything and
# saves binaries alongside the config; the patch path is covered here, by a
# focused snapshot of just the files this patch replaces.
# Пометить дерево как смешанное: патч лёг частично, откат тоже лёг частично.
#
# Это состояние нельзя лечить ещё одним патчем — патч кладёт только изменённые
# файлы и достроит гибрид до другого гибрида. Лечит только полная переустановка,
# поэтому маркер читается в au_decide и превращает любой следующий вердикт
# в reinstall. Файл лежит рядом с тегом, то есть переживает перезагрузку.
Z2K_AU_DIRTY_TREE_FILE="${Z2K_AU_DIRTY_TREE_FILE:-/opt/zapret2/.z2k-tree-dirty}"

# Записать installed-tag и убедиться, что записалось именно то.
#
# Пустой или обрезанный тег — это не «обновление не применилось», это «обновлений
# не будет больше никогда»: au_decide на пустом теге уходит в ветку
# «empty/corrupt → no update (refusing blind reinstall)» и остаётся там навсегда.
# Поэтому пишем через временный файл и перечитываем результат.
au_write_installed_tag() {
    local tag="$1"
    local tmp="${Z2K_AU_INSTALLED_TAG_FILE}.new.$$"
    [ -n "$tag" ] || { au_log "отказ: попытка записать ПУСТОЙ installed-tag"; return 1; }
    mkdir -p "$(dirname "$Z2K_AU_INSTALLED_TAG_FILE")" 2>/dev/null
    if ! printf '%s\n' "$tag" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    if ! mv -f "$tmp" "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    # Перечитать: на умирающем NAND запись «проходит», а файл потом пустой.
    local back
    back=$(tr -d '[:space:]' < "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)
    [ "$back" = "$(printf '%s' "$tag" | tr -d '[:space:]')" ] || return 1
    return 0
}

au_mark_dirty_tree() {
    local from="$1" to="$2"
    mkdir -p "$(dirname "$Z2K_AU_DIRTY_TREE_FILE")" 2>/dev/null
    printf 'partial-patch from=%s to=%s\n' "${from:-?}" "${to:-?}" \
        > "$Z2K_AU_DIRTY_TREE_FILE" 2>/dev/null || return 1
    au_log "дерево помечено как смешанное — следующее обновление пойдёт только через reinstall"
    return 0
}

au_tree_is_dirty() {
    [ -s "$Z2K_AU_DIRTY_TREE_FILE" ]
}

au_clear_dirty_tree() {
    rm -f "$Z2K_AU_DIRTY_TREE_FILE" 2>/dev/null
}

# Возвращает 0 ТОЛЬКО если восстановлено всё до последнего файла.
#
# До 2026-08-08 функция возвращала 0 безусловно: восстановление идёт в
# `find | while` (подоболочка), каждый cp/mv заглушён 2>/dev/null, коды возврата
# никуда не собирались. Оба вызова результат игнорировали, и следом писался
# старый тег. Итог частичного отката: дерево наполовину новое, тег старый —
# и следующей ночью тот же патч льётся на гибрид, которого никто не тестировал.
#
# Счётчик неудач ведём в файле, а не в переменной: тело `find | while` выполняется
# в подоболочке (POSIX sh, не bash), и присваивание оттуда до нас не доходит.
au_rollback_patch() {
    local pre_dir="$Z2K_AU_TMP_DIR/pre-apply"
    [ -d "$pre_dir" ] || return 1
    au_log "rollback: restoring pre-apply files"
    cd "$pre_dir" || return 1

    local fail_file="$Z2K_AU_TMP_DIR/.rollback_failed"
    rm -f "$fail_file"

    find . -type f | while read -r f; do
        local target="${f#./}"
        target="/$target"
        # Atomic restore (same rationale as au_apply_patch): temp + rename so a
        # crash mid-rollback can't leave a half-written init script. Preserve the
        # exec bit on scripts before the rename.
        _au_rb="${target}.z2k-rb.$$"
        if cp -f "$f" "$_au_rb" 2>/dev/null; then
            case "$target" in
                */init.d/*|*.sh) chmod +x "$_au_rb" 2>/dev/null || true ;;
            esac
            if ! mv -f "$_au_rb" "$target" 2>/dev/null; then
                rm -f "$_au_rb" 2>/dev/null
                printf '%s\n' "$target" >> "$fail_file"
            fi
        else
            rm -f "$_au_rb" 2>/dev/null
            printf '%s\n' "$target" >> "$fail_file"
        fi
    done

    if [ -x /opt/etc/init.d/S99zapret2 ]; then
        /opt/etc/init.d/S99zapret2 restart >/dev/null 2>&1 || true
    fi

    if [ -s "$fail_file" ]; then
        local n
        n=$(wc -l < "$fail_file" 2>/dev/null | tr -d ' ')
        au_log "rollback: НЕ восстановлено файлов: ${n:-?}"
        while IFS= read -r _fp; do
            [ -n "$_fp" ] && au_log "rollback:   не восстановлен $_fp"
        done < "$fail_file"
        rm -f "$fail_file"
        return 1
    fi
    rm -f "$fail_file"
    au_log "rollback: восстановлены все файлы"
    return 0
}

# Snapshot files about to be replaced (called from au_apply_patch before
# any cp -f). Mirrors target paths under $Z2K_AU_TMP_DIR/pre-apply/.
# au_targets_bulk <манифест> <файл со списком путей> — «путь<TAB>цель» для ВСЕХ
# целей за ОДИН проход по манифесту.
#
# ЗАЧЕМ ОТДЕЛЬНАЯ ФУНКЦИЯ. au_manifest_install_targets ищет цели ОДНОГО пути и
# ради этого склеивает манифест (222 КБ) в одну строку и гоняет по ней sed с
# `.*` по обоим краям. Один вызов — доли секунды, но вызовов столько же,
# сколько файлов, и на большом обновлении это десятки секунд молчания. Здесь
# весь список разбирается за один проход, и цена перестаёт зависеть от числа
# файлов.
au_targets_bulk() {
    awk -v plist="$2" '
        BEGIN { while ((getline p < plist) > 0) if (p != "") want[p] = 1 }
        /"[^"]+"[[:space:]]*:[[:space:]]*\[/ {
            key = $0
            if (!match(key, /"[^"]+"[[:space:]]*:[[:space:]]*\[/)) next
            rest = substr(key, RSTART + RLENGTH)
            key = substr(key, RSTART + 1); sub(/"[[:space:]]*:[[:space:]]*\[.*/, "", key)
            if (!(key in want)) next
            sub(/\].*/, "", rest)
            n = split(rest, parts, ",")
            for (i = 1; i <= n; i++) {
                t = parts[i]
                gsub(/^[[:space:]]*"/, "", t); gsub(/"[[:space:]]*$/, "", t)
                if (t ~ /^\//) print key "\t" t
            }
        }
    ' "$1"
}

# au_snapshot_for_patch <пути> — копия текущих файлов на случай отката.
#
# СПИСОК РАЗБИРАЕТСЯ ПО СЛОВАМ, А НЕ ПО СТРОКАМ, и это не мелочь. Вызывающий
# передаёт план одной строкой через пробел; разбор `while read` видел в ней
# ОДИН путь «a b c d e», искал его цели в манифесте и, разумеется, не находил.
# Замер на роутере владельца: 42 секунды и НОЛЬ снятых файлов — то есть
# откатывать в случае провала было бы нечего, а человек всё это время смотрел
# на молчащий журнал. Разделение по IFS принимает оба вида списка.
au_snapshot_for_patch() {
    local files="$*"
    local snap="$Z2K_AU_TMP_DIR/pre-apply"
    rm -rf "$snap"
    mkdir -p "$snap"
    local plist="$Z2K_AU_TMP_DIR/snap.paths"
    local repo_path target relpath dst
    : > "$plist"
    for repo_path in $files; do
        [ -n "$repo_path" ] && printf '%s\n' "$repo_path" >> "$plist"
    done
    [ -s "$plist" ] || { rm -f "$plist"; return 0; }
    au_targets_bulk "$Z2K_AU_TMP_DIR/UPDATES.json" "$plist" \
    | while IFS="$(printf '\t')" read -r repo_path target; do
        [ -n "$target" ] || continue
        [ -f "$target" ] || continue
        relpath="${target#/}"
        dst="$snap/$relpath"
        mkdir -p "$(dirname "$dst")"
        cp -f "$target" "$dst"
    done
    rm -f "$plist"
    return 0
}

# au_prune_orphans — снять с роутера файлы, которые мы поставляли, а потом
# отозвали.
#
# Сходимость умеет добавлять и обновлять, но не удалять: манифест описывает, что
# ДОЛЖНО быть, и молчит о том, чего быть не должно. Обычно это безобидно — лишний
# файл просто лежит. Но именно «просто лежит» и стоило обхода: files/fake/4pda.bin
# приехал ко всем, init-скрипт увидел его существование и зарегистрировал блоб с
# именем, которого движок не принимает.
#
# Список ЯВНЫЙ и короткий, а не «всё, чего нет в манифесте». Удалять по разнице
# означало бы снести пользовательские файлы в тех же каталогах — списки, ключи,
# собственные стратегии, — и цена ошибки там несопоставима с пользой уборки.
au_prune_orphans() {
    local zd="${ZAPRET2_DIR:-/opt/zapret2}" f
    # Список — через set --, а не `for f in "..."`: пути содержат пробелы, и
    # разбирать их словами нельзя, а единственный элемент в кавычках shellcheck
    # справедливо считает ошибкой. Аргументов у функции нет, затирать нечего.
    set -- "$zd/files/fake/4pda.bin"
    for f do
        [ -e "$f" ] || continue
        rm -f "$f" 2>/dev/null && au_log "убран отозванный файл: $f"
    done
    return 0
}

# ---- новый путь обновления ---------------------------------------------------
#
# Порядок операций здесь — это и есть безопасность обновления:
#   снимок → доставка → шаги → health-check → и ТОЛЬКО ПОТОМ версия.
# Версия последней: пока не доказано, что живо, роутер считает себя на прежней и
# завтра попробует снова. Обратный порядок дал бы «тег новый, поведение старое» —
# состояние, которое снаружи неотличимо от успеха.
#
# rc: 0 — обновились, 1 — не вышло (откатились, версия на месте),
#     2 — нужна полная переустановка (шаг из будущего).
au_apply_converge() {
    local target_tag="$1"; shift
    local manifest="$Z2K_AU_TMP_DIR/UPDATES.json"
    local plan="$Z2K_AU_TMP_DIR/converge.plan"
    local rc

    au_converge_plan "$manifest" > "$plan"
    # Не `grep -c . || echo 0`: на пустом файле grep печатает 0 И возвращает 1,
    # так что запасная ветка дописывала второй ноль, и дальше «-eq 0» падало на
    # нечисловом значении — идемпотентный прогон снимал снимок и лез работать.
    local n; n=$(awk 'END {print NR}' "$plan" 2>/dev/null)
    [ -n "$n" ] || n=0

    if [ "$n" -eq 0 ] && [ -z "$*" ]; then
        # Дерево уже совпадает с манифестом и делать нечего. Это штатный исход
        # повторного прогона, а не ошибка: сходимость идемпотентна.
        au_log "дерево совпадает с манифестом — только отметка версии"
        au_write_installed_tag "$target_tag" || {
            au_log "ВНИМАНИЕ: тег не записался — обновления встанут"; return 1; }
        return 0
    fi

    au_log "нужно обновить файлов: $n"
    au_snapshot_for_patch "$(tr '\n' ' ' < "$plan")" || {
        au_log "снимок не снялся — обновление отменено"; return 1; }

    # СЧЁТЧИК ПОДРЯД ИДУЩИХ НЕУДАЧ ДОСТАВКИ.
    #
    # Застрявшее состояние обязано лечиться само. У человека (диагностика
    # 31.08.2026) обновление падало ШЕСТЬ НОЧЕЙ ПОДРЯД на первом же файле, и
    # каждый раз всё повторялось с нуля: тот же путь, тот же отказ, тот же
    # откат. Ни одной попытки выйти из тупика не предпринималось, и человек
    # стоял на версии от 25 августа, пока не написал сам.
    #
    # Причина отказа может быть какой угодно — канал, зеркало, DNS. Но
    # бесконечное повторение одного и того же действия с одним и тем же итогом
    # — это наш дефект независимо от причины. После третьей неудачи уходим на
    # полную переустановку: путь другой, тянет один архив вместо полусотни
    # файлов, и у этого человека он работал (так он и получил p-79.14).
    #
    # Возврат 2 — уже существующий сигнал «падаю на полную переустановку», тот
    # же, что и для незнакомого шага. Отдельного канала заводить не нужно.
    # Каталог создаём ЗАРАНЕЕ и записи не даём уронить прогон.
    #
    # Апдейтер работает под set -e, и перенаправление в несуществующий каталог
    # убивает оболочку МОЛЧА — после успешной доставки, то есть в самом плохом
    # месте. Поймала репетиция релиза, на живых роутерах этого никто бы не
    # связал со счётчиком. Счётчик — вспомогательный: не записался, значит в
    # худшем случае эскалация случится позже, а ронять из-за него обновление
    # нельзя ни при каком исходе.
    _ac_fails_file="${ZAPRET2_DIR:-/opt/zapret2}/state/au-delivery-fails"
    mkdir -p "$(dirname "$_ac_fails_file")" 2>/dev/null || true
    if ! au_converge_apply "$manifest" "$plan"; then
        au_log "доставка не удалась — откат"
        au_rollback_patch || au_mark_dirty_tree "$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)" "$target_tag"
        _ac_fails=$(z2k_uint "$(cat "$_ac_fails_file" 2>/dev/null)" 0 0 999)
        _ac_fails=$((_ac_fails + 1))
        printf '%s\n' "$_ac_fails" > "$_ac_fails_file" 2>/dev/null || true
        if [ "$_ac_fails" -ge "$(z2k_uint "${Z2K_AU_DELIVERY_GIVEUP:-3}" 3 1 20)" ]; then
            au_log "доставка не удаётся $_ac_fails раз подряд — ухожу на полную переустановку"
            printf '0\n' > "$_ac_fails_file" 2>/dev/null || true
            return 2
        fi
        au_log "неудач доставки подряд: $_ac_fails (на третьей уйду на полную переустановку)"
        return 1
    fi
    printf '0\n' > "$_ac_fails_file" 2>/dev/null || true

    au_prune_orphans

    rc=0
    au_run_steps "$@" || rc=$?
    if [ "$rc" = 2 ]; then
        # Шаг из будущего: файлы уже разложены, но что с ними делать — мы не
        # знаем. Возвращаем дерево как было и уходим за полной переустановкой.
        au_log "шаг неизвестен — откат и полная переустановка"
        au_rollback_patch || au_mark_dirty_tree "$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)" "$target_tag"
        return 2
    fi
    if [ "$rc" != 0 ]; then
        au_log "шаги провалились — откат"
        if au_rollback_patch; then
            # Конфиг мог быть перегенерирован из новых файлов — вернуть его к
            # тому, что описывают вернувшиеся.
            au_run_steps regen-config restart-service >/dev/null 2>&1
        else
            au_mark_dirty_tree "$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)" "$target_tag"
        fi
        return 1
    fi

    if ! au_health_check; then
        au_log "проверка не пройдена — откат"
        if au_rollback_patch; then
            au_run_steps regen-config restart-service >/dev/null 2>&1
        else
            au_mark_dirty_tree "$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)" "$target_tag"
        fi
        return 1
    fi

    au_write_installed_tag "$target_tag" || {
        au_log "ВНИМАНИЕ: обновились, но тег не записался — следующей ночью прогон повторится вхолостую"
        return 1; }
    au_log "обновление завершено: $target_tag"
    return 0
}

# ------------------------------------------------------ main entry points ---

# au_run_check — dry run: show what would happen, don't apply.
au_run_check() {
    if ! au_fetch_manifest; then
        echo "Не удалось получить UPDATES.json (проверьте интернет)"
        return 1
    fi
    local manifest="$Z2K_AU_TMP_DIR/UPDATES.json"

    local installed
    if [ -f "$Z2K_AU_INSTALLED_TAG_FILE" ]; then
        installed=$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)
    else
        installed="(не установлен)"
    fi

    local current
    current=$(au_manifest_current "$manifest")

    echo "Установлено: $installed"
    echo "В репозитории: $current"

    local decision
    decision=$(au_decide "$installed" "$manifest")
    local action target_tag reset_state
    action=$(echo "$decision" | head -1 | awk '{print $1}')
    target_tag=$(echo "$decision" | head -1 | awk '{print $2}')
    reset_state=$(echo "$decision" | head -1 | awk '{print $3}')

    case "$action" in
        none)
            echo "Обновлений нет — установлена актуальная версия."
            return 0
            ;;
        patch)
            echo "Доступно обновление (PATCH) до $target_tag:"
            ;;
        reinstall)
            if [ "$reset_state" = "reset_state" ]; then
                echo "Доступно обновление (REINSTALL + wipe autocircular state) до $target_tag:"
            else
                echo "Доступно обновление (REINSTALL) до $target_tag:"
            fi
            ;;
    esac

    # show changelog: descriptions of new entries
    local entries entry v desc etype
    entries=$(au_history_entries_after "$manifest" "$installed")
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        v=$(au_entry_field "$entry" "v")
        desc=$(au_entry_field "$entry" "desc")
        etype=$(au_entry_field "$entry" "type")
        # %b, а не echo: в манифесте переводы строк лежат как литеральные \n,
        # и echo печатал бы их как есть. Описание r-72 — 2430 символов и 14
        # переводов, то есть в меню по SSH человек получил бы одну строку на
        # 2.4 КБ. Вебпанель не затронута, там JSON.parse.
        printf '  [%s %s] %b\n' "$v" "$etype" "$desc"
    done <<EOF
$entries
EOF

    return 0
}

# au_run_apply — main: fetch, decide, apply, health-check, rollback if bad.
au_run_apply() {
    if ! au_lock_acquire; then
        return 1
    fi
    # Ensure the lock is released no matter how we exit
    trap 'au_lock_release' EXIT INT TERM HUP

    if ! au_fetch_manifest; then
        au_log "manifest fetch failed"
        au_lock_release
        return 1
    fi
    local manifest="$Z2K_AU_TMP_DIR/UPDATES.json"

    local installed
    if [ -f "$Z2K_AU_INSTALLED_TAG_FILE" ]; then
        installed=$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)
        # Normalize for the empty-check below (au_decide trims again itself).
        installed=$(printf '%s' "$installed" | tr -d '[:space:]')
    fi
    if [ -z "$installed" ]; then
        # No tag file (pre-versioning / fresh install) OR an empty/truncated
        # one (botched write, NDM wipe, disk-full). In BOTH cases applying
        # nothing and resyncing the tag to current is correct: a router that
        # has been running is at current, and treating an empty tag as
        # "behind by the entire history" would blind-reinstall (+reset_state)
        # every night — the exact false-reinstall users reported.
        local current
        current=$(au_manifest_current "$manifest")
        if [ -n "$current" ]; then
            if au_write_installed_tag "$current"; then
                au_log "tag missing/empty — resynced installed=$current (no apply)"
            else
                au_log "tag missing/empty — resync НЕ удался, следующий прогон снова упрётся в пустой тег"
            fi
        fi
        au_lock_release
        return 0
    fi

    local decision action target_tag reset_state files
    decision=$(au_decide "$installed" "$manifest")
    action=$(echo "$decision" | head -1 | awk '{print $1}')
    target_tag=$(echo "$decision" | head -1 | awk '{print $2}')
    reset_state=$(echo "$decision" | head -1 | awk '{print $3}')
    files=$(echo "$decision" | tail -n +2)

    # --- НОВЫЙ ПУТЬ -----------------------------------------------------------
    #
    # Условий три: манифест несёт карту адресов, ни один релиз окна не помечен
    # аварийным флагом, и все объявленные шаги нам известны. Иначе — старый путь,
    # он никуда не делся и остаётся аварийным выходом.
    #
    # Тип релиза (patch/reinstall) здесь не смотрим намеренно: «reinstall» был
    # признанием бессилия — доставить объявленное патчем было нечем. Теперь
    # доставка и последствия выражаются адресно, и полная переустановка нужна
    # только тому, что не является нашими файлами (пакеты opkg, движок, структура
    # каталогов) — это и объявляет full_install.
    if [ "$action" != "none" ] && au_manifest_has_install_map "$manifest"; then
        local _tags _tag _e _full="" _reset="" _steps
        _tags=$(au_history_entries_after "$manifest" "$installed" \
                | sed -n 's/.*"v"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        for _tag in $_tags; do
            _e=$(grep "^[[:space:]]*{\"v\": \"$_tag\"" "$manifest" | head -1)
            [ -n "$(au_entry_bool "$_e" full_install)" ] && _full=1
            # Старый флаг релиза «сбросить состояние автоподбора». Он появился
            # до каталога шагов и раньше работал только через полную
            # переустановку. Новый путь обязан его уважать — иначе релиз со
            # сдвигом нумерации пулов приедет, а накопленная статистика
            # останется указывать не на те стратегии.
            [ "$(au_entry_bool "$_e" reset_state)" = "true" ] && _reset=1
        done
        if [ -n "$_full" ]; then
            au_log "релиз помечен как требующий полной переустановки — иду старым путём"
        else
            # shellcheck disable=SC2086
            _steps=$( { au_steps_union "$manifest" $_tags
                        [ -n "$_reset" ] && echo reset-state; } | au_steps_ordered | tr '\n' ' ')
            _steps_h=""
            for _sh in $_steps; do _steps_h="$_steps_h, $(au_step_human "$_sh")"; done
            if [ -n "$_steps" ]; then
                au_log "обновление $installed -> $target_tag; после доставки: ${_steps_h#, }"
            else
                au_log "обновление $installed -> $target_tag; после доставки делать ничего не нужно"
            fi
            if pgrep -f nfqws2 >/dev/null 2>&1; then
                Z2K_AU_NFQWS_WAS_ALIVE=1
            else
                Z2K_AU_NFQWS_WAS_ALIVE=0
                au_log "внимание: nfqws2 не работает ЕЩЁ ДО обновления"
            fi
            export Z2K_AU_NFQWS_WAS_ALIVE
            au_snapshot_services
            # shellcheck disable=SC2086
            au_apply_converge "$target_tag" $_steps
            case "$?" in
                0)
                    # Прибрать за прежними версиями безусловно, не полагаясь на
                    # то, что релиз перечислил шаг в манифесте: мусор в конфиге
                    # роутера накопился ДО того, как этот шаг появился.
                    au_step_cleanup_ip_hosts
                    au_lock_release; return 0 ;;
                2) au_log "падаю на полную переустановку" ;;
                *) au_lock_release; return 1 ;;
            esac
            action="reinstall"
        fi
    fi

    case "$action" in
        none)
            au_log "no update needed (installed=$installed)"
            au_lock_release
            return 0
            ;;
        patch)
            au_log "starting patch: $installed -> $target_tag"
            # Состояние сервиса ДО патча — чтобы health-check не назначал
            # виноватым обновление за то, что было сломано и без него.
            if pgrep -f nfqws2 >/dev/null 2>&1; then
                Z2K_AU_NFQWS_WAS_ALIVE=1
            else
                Z2K_AU_NFQWS_WAS_ALIVE=0
                au_log "внимание: nfqws2 не работает ЕЩЁ ДО обновления"
            fi
            export Z2K_AU_NFQWS_WAS_ALIVE
            au_snapshot_services
            au_snapshot_for_patch "$files"
            if ! au_apply_patch "$target_tag" "$files"; then
                au_log "patch apply failed, rolling back"
                if ! au_rollback_patch; then
                    # Дерево осталось смешанным. Тег НЕ трогаем: пусть он
                    # указывает на то, что реально лежит хотя бы частично, —
                    # иначе следующей ночью тот же патч поедет на гибрид.
                    au_log "ВНИМАНИЕ: откат неполный — дерево в смешанном состоянии, нужен reinstall"
                    au_mark_dirty_tree "$installed" "$target_tag"
                fi
                au_lock_release
                return 1
            fi
            if ! au_health_check; then
                au_log "post-patch health-check failed, rolling back"
                if au_rollback_patch; then
                    # restore the previous tag — только если откат ПОЛНЫЙ,
                    # иначе тег соврёт про содержимое дерева.
                    # shellcheck disable=SC2154
                    au_write_installed_tag "$installed" \
                        || au_log "ВНИМАНИЕ: откат полный, но тег не вернулся — обновления могут встать"
                else
                    au_log "ВНИМАНИЕ: откат неполный — тег не возвращаем, нужен reinstall"
                    au_mark_dirty_tree "$installed" "$target_tag"
                fi
                au_lock_release
                return 1
            fi
            ;;
        reinstall)
            au_log "starting reinstall: $installed -> $target_tag (reset_state=${reset_state:-no})"
            # То же, что и для патча: health-check не должен винить обновление
            # за сервис, который не работал и до него.
            if pgrep -f nfqws2 >/dev/null 2>&1; then
                Z2K_AU_NFQWS_WAS_ALIVE=1
            else
                Z2K_AU_NFQWS_WAS_ALIVE=0
                au_log "внимание: nfqws2 не работает ЕЩЁ ДО обновления"
            fi
            export Z2K_AU_NFQWS_WAS_ALIVE
            au_snapshot_services
            if ! au_apply_reinstall "$target_tag" "$reset_state"; then
                au_log "reinstall apply failed"
                # install.sh took a rollback snapshot before it started (config
                # + binaries), but nothing rolls it back on its own — the
                # auto-timer that used to promise that never ran and is gone.
                # Recovery is the operator's `z2k rollback`. We just bail and
                # leave the breadcrumb.
                au_lock_release
                return 1
            fi
            if ! au_health_check; then
                au_log "post-reinstall health-check failed"
                # nothing more we can do automatically — leave breadcrumb
                # for the operator. Tag stays as target_tag because the
                # reinstall did write files; manual rollback via
                # rollback_to_snapshot is available.
                au_lock_release
                return 1
            fi
            # Переустановка разложила дерево целиком — смешанного состояния
            # больше нет, снимаем маркер. Только здесь: патч его снять не может
            # по построению, он кладёт лишь часть файлов.
            au_clear_dirty_tree
            ;;
    esac

    # Pull the per-game WARP lists when there are none, so the router that first
    # receives this feature does not sit on an empty WARP page until the nightly
    # refresh — up to a day of "the feature does nothing", which is a poor first
    # screen for what is now the only way WARP gets any addresses at all.
    #
    # Gated on the directory being EMPTY rather than on a one-shot marker. That
    # makes it a single fetch in practice (once lists exist, every later update
    # skips it — the nightly refresh owns them from then on) and it still
    # self-heals the one case a marker would strand: a router that has never
    # had the lists at all. (A reinstall now carries games/ forward — see the
    # warp-games backup block in install.sh — so the common path no longer
    # arrives here empty; a fresh install still does.)
    #
    # Backgrounded and non-fatal: the update is already finished and healthy
    # here, so an unreachable list mirror must not stretch it, fail it, or roll
    # back a perfectly good update.
    _au_zd="${ZAPRET2_DIR:-/opt/zapret2}"
    if [ -x "$_au_zd/z2k-update-lists.sh" ] && \
       [ -z "$(ls "$_au_zd/lists/warp/games/"*.txt 2>/dev/null)" ]; then
        au_log "no WARP game lists yet — fetching them in the background"
        ( sh "$_au_zd/z2k-update-lists.sh" warp-games >/dev/null 2>&1 || true ) &
    fi

    au_log "update OK: now at $target_tag"
    au_lock_release
    trap - EXIT INT TERM HUP
    return 0
}
