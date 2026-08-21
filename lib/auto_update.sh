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
            au_log "lock held by pid=$pid, skipping"
            return 1
        fi
        au_log "stale lock removed (pid=${pid:-?} not alive)"
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
        au_log "manifest has no current field"
        echo "none"
        return 0
    fi

    # Empty tag is NOT a fresh install — fresh installs have no tag file and
    # are handled by au_run_apply's first-run branch (mark current, no apply).
    # An empty tag reaching here means a truncated/corrupt .z2k-installed-tag;
    # refuse to interpret it as "behind by the entire history".
    if [ -z "$installed_tag" ]; then
        au_log "installed tag empty/corrupt — no update (refusing blind reinstall)"
        echo "none"
        return 0
    fi

    # Non-empty tag absent from append-only history = drift/corruption, never
    # a legitimately-behind router. Skip rather than blind-reinstall to current.
    if ! au_tag_in_history "$manifest" "$installed_tag"; then
        au_log "installed tag '$installed_tag' not in history — no update (refusing blind reinstall)"
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

# --------------------------------------------- repo path → install path ---

# Map a repo-relative path (e.g. "files/lua/z2k-detectors.lua") to one or
# more on-disk install paths. Echoes one path per line. Empty if the repo
# path has no runtime install target (e.g. lib/, tests/).
au_install_paths() {
    local repo_path="$1"
    local zd="${ZAPRET2_DIR:-/opt/zapret2}"
    case "$repo_path" in
        files/lua/*)
            echo "${zd}/lua/${repo_path#files/lua/}"
            ;;
        files/lists/extra-domains.txt)
            # Both shipped baseline and runtime merged copy. Caller treats
            # these as a special case for 3-way merge.
            echo "${zd}/files/lists/extra-domains.txt"
            echo "${zd}/lists/extra-domains.txt"
            ;;
        files/lists/*.txt)
            # IP/host lists that install.sh dual-copies (files/lists/ + lists/).
            echo "${zd}/files/lists/${repo_path#files/lists/}"
            echo "${zd}/lists/${repo_path#files/lists/}"
            ;;
        files/extra_strats/*/Strategy.txt)
            echo "${zd}/extra_strats/${repo_path#files/extra_strats/}"
            ;;
        files/extra_strats/*)
            echo "${zd}/extra_strats/${repo_path#files/extra_strats/}"
            ;;
        files/fake/*)
            echo "${zd}/files/fake/${repo_path#files/fake/}"
            ;;
        files/etc/*)
            echo "${zd}/etc/${repo_path#files/etc/}"
            ;;
        files/init.d/S98z2k-detect)
            # z2k-detect daemon init script — install.sh copies to
            # /opt/etc/init.d (Entware standard), not into $ZAPRET2_DIR.
            echo "/opt/etc/init.d/S98z2k-detect"
            ;;
        files/init.d/S96z2k-rt-proxy)
            # rt-proxy daemon init script — install.sh copies to
            # /opt/etc/init.d (Entware standard), not into $ZAPRET2_DIR.
            echo "/opt/etc/init.d/S96z2k-rt-proxy"
            ;;
        files/init.d/S98tg-tunnel)
            # TG-tunnel supervisor — install.sh copies to /opt/etc/init.d,
            # NOT into $ZAPRET2_DIR. Without this case a patch misplaced it to
            # ${zd}/init.d/ (via files/init.d/* below), missing the live script.
            echo "/opt/etc/init.d/S98tg-tunnel"
            ;;
        files/init.d/S99z2k-scheduler)
            # Same trap, found by the completeness test rather than by another field failure:
            # install.sh:2770 deploys it to /opt/etc/init.d, so a patch touching the scheduler
            # was landing in ${zd}/init.d/ and never reaching the running system.
            echo "/opt/etc/init.d/S99z2k-scheduler"
            ;;
        files/init.d/S51z2k-warp)
            # WARP tunnel supervisor — install.sh copies it to /opt/etc/init.d, NOT into
            # $ZAPRET2_DIR. Without this case a patch touching it lands in ${zd}/init.d/ and is
            # silently lost while installed_tag advances — the r-59.9 failure, again.
            echo "/opt/etc/init.d/S51z2k-warp"
            ;;
        files/init.d/S97z2k-http-tunnel)
            # http-tunnel supervisor — same /opt/etc/init.d placement as above.
            echo "/opt/etc/init.d/S97z2k-http-tunnel"
            ;;
        files/ndm/92-z2k-rt-proxy-redirect.sh)
            echo "/opt/etc/ndm/netfilter.d/92-z2k-rt-proxy-redirect.sh"
            ;;
        files/000-zapret2.sh)
            # Primary NDM netfilter.d recovery hook — install.sh copies it to
            # /opt/etc/ndm/netfilter.d/, NOT into $ZAPRET2_DIR. Without this case
            # it fell into files/*.sh below and a patch misplaced it to
            # ${zd}/000-zapret2.sh, silently skipping the real hook (r-59.9).
            echo "/opt/etc/ndm/netfilter.d/000-zapret2.sh"
            ;;
        files/init.d/*)
            echo "${zd}/init.d/${repo_path#files/init.d/}"
            ;;
        files/S99zapret2.new)
            echo "/opt/etc/init.d/S99zapret2"
            ;;
        files/*.sh|files/*.lua)
            echo "${zd}/${repo_path#files/}"
            ;;
        lib/*)
            # Library scripts (auto_update.sh, install.sh, config*.sh,
            # utils.sh, …) live under $ZAPRET2_DIR/lib at runtime.
            # Without this mapping patch-type releases silently skipped
            # all lib/* changes (no install target).
            echo "${zd}/${repo_path}"
            ;;
        UPDATES.json)
            # The manifest itself ships with the install so that an
            # offline `z2k diag` can show installed_tag context.
            echo "${zd}/${repo_path}"
            ;;
        z2k.sh)
            # Top-level entrypoint. Reinstall flow re-downloads this
            # script separately via au_download_reinstall_script, but
            # patch-type releases touching z2k.sh need the mapping too.
            echo "${zd}/${repo_path}"
            ;;
        webpanel/cgi/*.sh)
            # Webpanel CGI handlers — auth.sh / actions.sh / api.sh.
            # webpanel/install.sh deploys to ${zd}/webpanel/cgi/.
            echo "${zd}/webpanel/cgi/${repo_path#webpanel/cgi/}"
            ;;
        webpanel/www/*)
            # Webpanel static assets — lighttpd serves from ${zd}/www
            # (NOT ${zd}/webpanel/www — webpanel/install.sh copies to
            # the lighttpd document-root which is a separate path).
            echo "${zd}/www/${repo_path#webpanel/www/}"
            ;;
        webpanel/init.d/S96z2k-webpanel)
            echo "/opt/etc/init.d/S96z2k-webpanel"
            ;;
        webpanel/install.sh|webpanel/uninstall.sh)
            echo "${zd}/webpanel/${repo_path#webpanel/}"
            ;;
        webpanel/lighttpd.conf)
            # Generated at install time from a template with @PORT@/@BIND@
            # substitution — see au_reinstall_required() below for the other
            # half of this: patch can't re-template it, so a plain "no target
            # here" is not enough, changing it must force a reinstall release.
            : ;;
        tests/*)
            : # tests are dev/CI artifacts; not shipped to runtime.
            ;;
        *)
            : # no runtime target
            ;;
    esac
}

# repo path -> "1" if a patch release cannot deliver a change to it at all,
# and reinstall is the ONLY route. Empty otherwise (includes paths with no
# runtime target whatsoever, e.g. tests/, scripts/ — those are not "needs
# reinstall", they're "never shipped").
#
# WHY THIS IS SEPARATE FROM au_install_paths(). An empty au_install_paths()
# result is ambiguous on its own: it means either "this repo path has no
# runtime existence at all" (tests/, scripts/, docs — safe to ignore) or "this
# DOES reach the router, but only via a step that a patch cannot repeat"
# (an install-time generator, an arch-specific binary, a build-time template).
# scripts/release.sh used to special-case each of the second kind by hand as
# they were found (mtproxy-client, then z2k-detect/z2k-verify, then
# lib/config_official.sh/strategies.sh) — and exactly that pattern is how
# webpanel/lighttpd.conf slipped through: it carries a comment right above,
# "if lighttpd.conf actually changes, ship as reinstall", and nothing ever
# read that comment. A single table that release.sh actually consults closes
# the whole class at once instead of one more special case at a time.
au_reinstall_required() {
    local repo_path="$1"
    case "$repo_path" in
        */builds/*)
            # Arch-specific binaries. au_install_paths() has no target for
            # them at all (the target depends on the router's architecture),
            # so a patch would not deliver them — it would silently drop them
            # from changed_files while the version number moves forward.
            echo 1 ;;
        lib/config_official.sh|lib/strategies.sh)
            # Install-time generators: their code runs exactly once, during
            # step_create_config_and_init, and the result (config,
            # extra_strats/*/Strategy.txt) is written to disk as plain files.
            # A patch overwrites the .sh source but does not re-run it — an
            # already-installed router keeps the old generated output.
            echo 1 ;;
        webpanel/lighttpd.conf)
            # Templated with @PORT@/@BIND@ substitution at install time
            # (webpanel/install.sh). A patch has no re-templating step, so it
            # would overwrite nothing and the router keeps the stale config.
            echo 1 ;;
    esac
}

# Download a single repo file via z2k_fetch (or curl) into a target.
au_download_repo_file() {
    local repo_path="$1"
    local target="$2"
    local url
    url="$(au_repo_base)/${repo_path}"
    mkdir -p "$(dirname "$target")"
    if command -v z2k_fetch >/dev/null 2>&1; then
        z2k_fetch "$url" "$target" && { [ -s "$target" ] || [ -f "$target" ]; } && return 0
    else
        curl -fsSL --max-time 30 "$url" -o "$target" && { [ -s "$target" ] || [ -f "$target" ]; } && return 0
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
        au_log "reinstall: fetching z2k.sh from $url"
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
            if [ -n "$_want_sha" ]; then
                Z2K_FETCH_SHA256="$_want_sha"; export Z2K_FETCH_SHA256
            else
                au_log "patch: $repo_path — в манифесте нет sha256, содержимое не проверяется"
            fi
            au_download_repo_file "$repo_path" "$stage"
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
                _del_targets=$(au_install_paths "$repo_path")
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
        targets=$(au_install_paths "$repo_path")
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
    local geosite_refresh=0
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
            files/z2k-geosite.sh|files/lists/rkn-false-positive.txt)
                # New geosite logic or false-positive list — нужен immediate
                # refresh, иначе filter применится только при следующем
                # scheduler tick (раз в сутки).
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
        FORCE_REFETCH=1 sh "${zd}/z2k-geosite.sh" fetch >/dev/null 2>&1 || \
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
        au_log "reinstall failed rc=$rc"
        return 1
    fi

    # install.sh may have already written the tag, but enforce it here too.
    if ! au_write_installed_tag "$target_tag"; then
        au_log "reinstall: НЕ удалось записать installed-tag — следующий прогон не увидит обновлений"
        return 1
    fi
    au_log "reinstall applied: $target_tag"
    return 0
}

# ----------------------------------------------------------- health-check ---

au_health_check() {
    # Override via Z2K_AU_HEALTH_TIMEOUT env var (set before sourcing the module).
    local timeout="$Z2K_AU_HEALTH_TIMEOUT"
    au_log "health-check: ${timeout}s stability window, then checking"
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
            au_log "health-check: nfqws2 не работает, но он и ДО обновления не работал — патч ни при чём, оставляем"
            au_log "health-check: разберитесь, почему не стартует сервис (диагностика: раздел «что не так»)"
        else
            au_log "health-check FAILED: nfqws2 died after start"
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
        au_log "health-check FAILED: syntax error in installed script(s):$_bad"
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
    local _svc _svc_pat _down=""
    for _svc in S98tg-tunnel S96z2k-rt-proxy S99z2k-scheduler S98z2k-detect S96z2k-webpanel; do
        [ -x "/opt/etc/init.d/$_svc" ] || continue
        case "$_svc" in
            S98tg-tunnel)      _svc_pat="tg-mtproxy-client" ;;
            S96z2k-rt-proxy)   _svc_pat="rt-proxy" ;;
            S99z2k-scheduler)  _svc_pat="z2k-scheduler" ;;
            S98z2k-detect)     _svc_pat="z2k-detect" ;;
            S96z2k-webpanel)   _svc_pat="lighttpd" ;;
            *)                 continue ;;
        esac
        pgrep -f "$_svc_pat" >/dev/null 2>&1 || _down="$_down $_svc"
    done
    if [ -n "$_down" ]; then
        au_log "health-check: ВНИМАНИЕ, после обновления не работают:$_down"
        au_log "health-check: обход (nfqws2) жив, откат не делаем — но эти сервисы нужно поднять"
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
        au_log "health-check: github unreachable (advisory only — update kept; nfqws2 alive + scripts parse clean)"
    fi

    au_log "health-check OK"
    return 0
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
au_snapshot_for_patch() {
    local files="$*"
    local snap="$Z2K_AU_TMP_DIR/pre-apply"
    rm -rf "$snap"
    mkdir -p "$snap"
    local repo_path targets target relpath dst
    while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        targets=$(au_install_paths "$repo_path")
        while IFS= read -r target; do
            [ -z "$target" ] && continue
            [ -f "$target" ] || continue
            relpath="${target#/}"
            dst="$snap/$relpath"
            mkdir -p "$(dirname "$dst")"
            cp -f "$target" "$dst"
        done <<EOF_T
$targets
EOF_T
    done <<EOF_F
$files
EOF_F
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
