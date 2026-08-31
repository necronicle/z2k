#!/bin/sh
# z2k-scheduler.sh — z2k internal task scheduler.
#
# Replaces Vixie cron for ALL z2k periodic tasks on Keenetic Entware,
# where the cron daemon's crontab reload mechanism is broken: even on a
# fresh `crontab -` + spool-dir mtime update + SIGHUP, the daemon does
# not pick up new entries (see field debug notes around r-26).
#
# Runs as a long-lived process started by S99z2k-scheduler at boot.
# Sleeps ~30s between ticks, fires each registered task once per day at
# the configured HH:MM. Persistent state at $STATE prevents re-firing
# the same minute twice if we wake up multiple times within it.
#
# Tasks (HH:MM <command>):
#   02:00  z2k-auto-update.sh apply       — nightly auto-update check
#   03:00  z2k-stats-upload.sh             — anonymized strategy stats -> VPS
#   03:30  z2k-tcp16-probe.sh              — блок по объёму: сети и имя на каждую
#   04:00  z2k-update-lists.sh             — RKN/YT hostlist refresh
#   06:00  ipset/get_config.sh              — IP-set resolution

export PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin

ZAPRET2_DIR="/opt/zapret2"
PIDFILE="${Z2K_SCHED_PIDFILE:-/var/run/z2k-scheduler.pid}"
LOG="/opt/var/log/z2k-scheduler.log"
# Flash (persistent) state — daily-cadence keys only (fired ≤1×/day). Persisting
# these across reboot is the point: it stops a same-day re-fire after a restart.
STATE="${ZAPRET2_DIR}/.z2k-scheduler-state"
# RAM state — minute-cadence epoch keys (tg-watchdog-epoch / ppe-deoffload-epoch).
# These are rewritten ~2×/min; keeping them on flash burned ~2880 write+rename
# per day (flash wear). They only gate "did we already fire this minute", which
# is meaningless across a reboot, so /tmp (tmpfs) is the correct home.
TMP_STATE="/tmp/.z2k-scheduler-state"

# Don't double-launch.
#
# КОД ВОЗВРАТА ЗДЕСЬ — 3, А НЕ 0, И ЭТО НЕСУЩАЯ ДЕТАЛЬ.
#
# Надзиратель (S99z2k-scheduler) крутит `запустить; sleep 10` вечно. Пока эта
# ветка отдавала 0, «работу уже делает кто-то другой» было для него неотличимо
# от «мой планировщик отработал и завершился» — и он респавнил каждые 10 секунд
# впустую. В поле (роутер Keenetic, 2026-08-09 12:56–12:58) это выглядело как
# чередование «scheduler exited (rc=0) — respawning in 10s» и «already running
# pid 2983» до тех пор, пока чужой процесс не умер сам.
#
# Как в это состояние попадают: OOM убивает надзирателя, а планировщик остаётся
# сиротой; NDM-хук 95-z2k-scheduler-watchdog видит мёртвого надзирателя и
# поднимает стек заново; новый надзиратель запускает планировщик, тот видит
# живой pid сироты — и цикл замыкается. Работа при этом идёт (сирота исправно
# тикает), поэтому снаружи виден только форк-шторм и залитый лог.
if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "z2k-scheduler already running pid $old_pid" >&2
        exit 3
    fi
fi
echo $$ > "$PIDFILE"
# `:` — СПЕЦИАЛЬНЫЙ ВСТРОЕННЫЙ ОПЕРАТОР, А НЕ ВНЕШНИЙ БИНАРНИК.
#
# Здесь стоял `rm -f "$PIDFILE"`, и он падал: на Keenetic `rm` вне /opt НЕ
# СУЩЕСТВУЕТ ВОВСЕ (в /bin только ndm-овские утилиты и sh), единственные копии —
# /opt/bin/rm. Тело трапа исполняется в момент прерывания, и шелл приписывает
# ошибку той строке, на которой процесс застали, — отсюда загадочное
# «z2k-scheduler.sh: line 293: rm: not found» рядом с «Terminated» в журналах.
#
# Последствие не косметическое: pidfile оставался с мёртвым pid. Обычно это
# безвредно, но планировщик форкает около шести детей в минуту, и попадание
# живого чужого процесса на застрявший pid уводит надзирателя в ветку «уже
# запущен другим родителем» — а там встают ВСЕ периодические задачи разом:
# обновление, списки, статистика, сторож туннеля, self-heal NFQUEUE и WARP.
#
# `:` не форкает, не смотрит в PATH и работает даже при отвалившемся /opt —
# то есть ровно в том случае, когда `rm` не работает по определению. Для всех
# читателей pidfile пустой файл равнозначен отсутствию: они делают `cat`, а
# затем `[ -n "$pid" ] && kill -0`.
trap ': > "$PIDFILE"; exit 0' INT TERM HUP

# We were forked by the OOM-protected supervisor (S99z2k-scheduler sets its
# oom_score_adj to -1000) and inherit that immunity. Reset ours to normal so the
# scheduler AND every heavy task it fires (auto-update reinstall, list refresh)
# stay ordinary OOM candidates — only the tiny supervisor stays protected, and it
# respawns us if we are ever killed. Without this, a leaking task would be immune
# and the OOM killer would take an innocent bystander (nfqws2, dropbear) instead.
echo 0 > "/proc/$$/oom_score_adj" 2>/dev/null || true

# Ensure log dir exists.
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() {
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    printf '[%s] %s\n' "$ts" "$1" >> "$LOG"
}

# $1 - log path (defaults to the scheduler's own $LOG)
rotate_log() {
    local f="${1:-$LOG}"
    [ -f "$f" ] || return
    local lines
    lines=$(wc -l < "$f" 2>/dev/null)
    if [ "${lines:-0}" -gt 1000 ]; then
        # TRUNCATE IN PLACE, never mv. `mv` replaces the inode, and a daemon holding the
        # file open with >> keeps writing into the unlinked one — its log then freezes
        # forever while the file on disk looks fine. That is exactly what happened to the
        # usque engine log: field reports were read from a file the engine had stopped
        # writing to days earlier, and every conclusion drawn from them was unsound.
        tail -800 "$f" > "${f}.tmp" 2>/dev/null && cat "${f}.tmp" > "$f" 2>/dev/null
        rm -f "${f}.tmp" 2>/dev/null
    fi
}

# Every z2k log lives in tmpfs, i.e. in RAM on a 500 MB box, and NOTHING capped
# any of them except the scheduler's own. Measured on the owner's router before
# adding this: rt-proxy 18 KB / 185 lines, all z2k logs together 592 KB, tmpfs at
# 21% - so this is insurance against a chatty failure mode (a flapping pool logs
# per demotion), not a fix for observed growth. Reuses rotate_log rather than
# introducing a second rotation mechanism.
rotate_all_logs() {
    local d="${Z2K_LOG_DIR:-/tmp/z2k-log}"
    [ -d "$d" ] || return
    for f in "$d"/*.log; do
        [ -f "$f" ] || continue
        rotate_log "$f"
    done
}

# $1 state file, $2 key
last_fired_in() {
    local file="$1" key="$2"
    [ -f "$file" ] || return
    awk -F= -v k="$key" '$1==k {print $2}' "$file" | tail -1
}

# $1 state file, $2 key, $3 value
mark_fired_in() {
    local file="$1" key="$2" val="$3"
    if [ -f "$file" ]; then
        awk -F= -v k="$key" '$1!=k' "$file" > "${file}.tmp"
    else
        : > "${file}.tmp"
    fi
    printf '%s=%s\n' "$key" "$val" >> "${file}.tmp"
    mv "${file}.tmp" "$file"
}

# Daily-cadence keys live on flash ($STATE) so a same-day reboot can't re-fire.
last_fired_for_key() { last_fired_in "$STATE" "$1"; }
mark_fired() { mark_fired_in "$STATE" "$1" "$2"; }

# Run one task in background, with output captured into the scheduler log.
run_task() {
    local label="$1"
    shift
    log "fire $label: $*"
    ( "$@" >> "$LOG" 2>&1; log "done $label (exit $?)" ) &
}

# Время файла: busybox stat поддерживает -c %Y; если его нет — молчим и
# считаем, что перезапускаться не по чему.
_z2k_mtime() { stat -c %Y "$1" 2>/dev/null || echo ""; }

log "scheduler started (pid $$, $(uname -srm))"

# Seed the per-game WARP lists if there are none.
#
# This lives HERE, and not only in the updater, for a reason worth remembering:
# an update is applied by the updater ALREADY on the router, i.e. the previous
# release. So a hook added to lib/auto_update.sh cannot run during the very
# update that ships it — p-67.9 shipped exactly such a hook and it did nothing,
# because p-67.8's updater executed that update. The scheduler, by contrast, is
# RESTARTED by any patch carrying files/z2k-scheduler.sh, so this runs the new
# code on the update that introduces it.
#
# Same empty-directory gate as the updater's: once lists exist this costs one
# `ls` per service start and never touches the network.
if [ -x "${ZAPRET2_DIR}/z2k-update-lists.sh" ] && \
   [ -z "$(ls "${ZAPRET2_DIR}/lists/warp/games/"*.txt 2>/dev/null)" ]; then
    run_task warp-games-seed sh "${ZAPRET2_DIR}/z2k-update-lists.sh" warp-games
fi

# Записи ip host от прежних версий — чистим РОВНО ОДИН РАЗ.
#
# Их писал снятый четвёртый слой скачивания: постоянная запись на КАЖДУЮ
# неудачную попытку. Тянутся с 23 апреля, у людей накопилось по три-четыре
# строки на домен при 256 слотах статического DNS у Keenetic.
#
# Один раз — это не экономия, а требование: чистка правит конфигурацию роутера
# и сохраняет её, и делать это по расписанию у человека за спиной незачем.
# Записи наши, они больше не появляются (слой снят), значит достаточно убрать
# унаследованное и поставить отметку.
#
# Чистка здесь, а не шагом обновления, по двум причинам: шага нет в
# каноническом списке, а апдейтеры до r-81 о нём и не знают — незнакомый шаг
# они трактуют как «из будущего» и уходят в полную переустановку.
#
# Планировщик перезапускается, когда обновление везёт его файл, — этого и
# достаточно: отметки нет только у тех, у кого чистка ещё не проходила.
_cl_done="${ZAPRET2_DIR}/state/ip-hosts-cleanup.done"
if [ ! -f "$_cl_done" ] && [ -r "${ZAPRET2_DIR}/lib/utils.sh" ]; then
    mkdir -p "${ZAPRET2_DIR}/state" 2>/dev/null
    # Отметку ставим ПОСЛЕ чистки и только при её успехе: иначе оборванный
    # прогон закрыл бы себе путь навсегда, а записи остались бы висеть.
    # Функция может быть ещё не доставлена: обновление кладёт файлы по одному,
    # и планировщик способен подняться раньше, чем приедет новый utils.sh.
    # Тогда молча откладываем до следующего старта — отметку не ставим, иначе
    # чистка не случится никогда. В журнале это выглядело как «sh:
    # cleanup_legacy_ip_hosts: not found» (диагностика пользователя 31.08.2026).
    run_task cleanup-ip-hosts sh -c \
        ". ${ZAPRET2_DIR}/lib/utils.sh >/dev/null 2>&1
         if command -v cleanup_legacy_ip_hosts >/dev/null 2>&1; then
             cleanup_legacy_ip_hosts && date +%s > \"$_cl_done\"
         else
             echo \"чистка отложена: utils.sh ещё не обновлён\"
         fi"
fi

# СТАРТ СЛУЖБЫ — ЭТО И ЕСТЬ УСТАНОВКА И ОБНОВЛЕНИЕ.
#
# Отдельных крючков в установщике и обновлении не нужно: и то, и другое
# перезапускает службу, а планировщик стартует вместе с ней. Здесь мы меряем
# линию (если ещё не мерили) и приводим имя в порядок — селектор сам сперва
# проверит текущее и полезет в перебор только если оно перестало пробивать.
#
# Дроссель на час. Перезапусков бывает много подряд — NDM дёргает службу на
# каждое переподключение, и self-heal тоже, — а платить за каждый лишний
# запрос незачем. Отметка лежит в /tmp: переживать перезагрузку ей ни к чему,
# после неё как раз и надо проверить заново.
_sni_stamp=/tmp/z2k-sni-refresh.ts
_sni_now=$(date +%s 2>/dev/null || echo 0)
_sni_last=$(cat "$_sni_stamp" 2>/dev/null || echo 0)
case "$_sni_last" in ''|*[!0-9]*) _sni_last=0 ;; esac

# Дроссель разный для двух разных случаев, и это важно.
#
# «Уже мерили» — час: перемер нужен редко, а перезапусков бывает много подряд.
# «Не мерили ни разу» — десять минут: тут механизм ВЫКЛЮЧЕН, и держать человека
# без обхода целый час из-за отметки в /tmp неправильно. Отметка переживает
# переустановку (она в /tmp, а не в /opt), поэтому иначе переустановка могла
# оставить механизм выключенным на час, ничем этого не показав.
# Совсем без дросселя нельзя: проба, которая падает, устроила бы шторм на
# каждом перезапуске службы.
if [ -s "${ZAPRET2_DIR}/state/tcp16.flag" ]; then
    _sni_gap=3600
else
    _sni_gap=600
fi
if [ $((_sni_now - _sni_last)) -ge "$_sni_gap" ]; then
    echo "$_sni_now" > "$_sni_stamp" 2>/dev/null
    # Проверяем ЧИТАЕМОСТЬ, а не бит запуска: запускаем через sh, а бит
    # patch-путь на части сборок BusyBox терял (p-42). Гвард строже вызова —
    # это тихая осечка, а тихих осечек в этом механизме уже было довольно.
    if [ ! -r "${ZAPRET2_DIR}/z2k-tcp16-probe.sh" ]; then
        log "проба линии: файла нет — пропускаю"
    elif [ -s "${ZAPRET2_DIR}/state/tcp16.flag" ]; then
        : # линия уже измерена, перемер — ночным слотом
    else
        run_task tcp16-probe sh "${ZAPRET2_DIR}/z2k-tcp16-probe.sh"
    fi
fi

# ПЕРЕЗАПУСК САМОГО СЕБЯ, КОГДА ФАЙЛ ОБНОВИЛСЯ.
#
# Путь сходимости выполняет только те шаги, что объявил релиз, и планировщик в
# них не входит: новый код приезжал на диск и ждал перезагрузки роутера —
# то есть неделями. Так одноразовая чистка записей и проба линии не начинались
# у людей вовсе.
#
# Сравниваем время файла с тем, что было при старте, и переходим на новый код
# через exec. Зацикливания нет по построению: после exec отметка снимается
# заново с того же файла, и следующая проверка совпадёт.
_self="${ZAPRET2_DIR}/z2k-scheduler.sh"
_self_mtime=$(_z2k_mtime "$_self")

# Отметка «на диске лежит ровно тот код, что сейчас в памяти». По ней init
# главной службы понимает, что после обновления нас надо перезапустить: сама
# сходимость этого не делает, и до 31.08.2026 новый код планировщика ждал
# перезагрузки роутера. Пишем её и здесь, и в init'е — значения совпадают,
# лишнего перезапуска не будет.
[ -n "$_self_mtime" ] && echo "$_self_mtime" > /tmp/z2k-scheduler.mtime 2>/dev/null

while true; do
    _now_mtime=$(_z2k_mtime "$_self")
    if [ -n "$_now_mtime" ] && [ "$_now_mtime" != "$_self_mtime" ]; then
        log "файл планировщика обновлён — перехожу на новый код"
        exec sh "$_self"
    fi
    hhmm=$(date +%H:%M)
    today=$(date +%Y-%m-%d)
    now_epoch=$(date +%s)

    # Daily tasks — gate on date-key so each only fires once per day even
    # if our 30s tick passes through the same minute twice.
    case "$hhmm" in
        02:00)
            if [ "$(last_fired_for_key auto-update)" != "$today" ]; then
                mark_fired auto-update "$today"
                run_task auto-update "${ZAPRET2_DIR}/z2k-auto-update.sh" apply
            fi
            ;;
        03:00)
            # Anonymized strategy-stats upload (gated on Z2K_STATS inside the
            # script; silent no-op on opt-out / network failure).
            if [ "$(last_fired_for_key stats-upload)" != "$today" ]; then
                mark_fired stats-upload "$today"
                run_task stats-upload "${ZAPRET2_DIR}/z2k-stats-upload.sh"
            fi
            ;;
        # ЕСЛИ ЛИНИЯ ТАК И НЕ ИЗМЕРЕНА — ПОВТОРЯТЬ, НЕ ДОЖИДАЯСЬ НОЧИ.
        #
        # Раньше проба запускалась только при старте службы и в 03:30. На свежей
        # установке она проигрывает гонку установщику (замер 31.08.2026:
        # планировщик в 22:21:15, бинарник в 22:21:54) — и механизм оставался
        # выключенным до ночи, а человек всё это время видел «не измерялась».
        # Перезапуска службы может не случиться вовсе.
        #
        # Поэтому пока флага нет, повторяем каждые десять минут. Как только
        # линия измерена — с блоком или без, — эта ветка замолкает навсегда:
        # дальше работает ночной перемер.
        *)
            if [ ! -s "${ZAPRET2_DIR}/state/tcp16.flag" ] \
               && [ -r "${ZAPRET2_DIR}/z2k-tcp16-probe.sh" ]; then
                _rt_now=$(date +%s 2>/dev/null || echo 0)
                _rt_last=$(cat /tmp/z2k-sni-refresh.ts 2>/dev/null || echo 0)
                case "$_rt_last" in ''|*[!0-9]*) _rt_last=0 ;; esac
                if [ $((_rt_now - _rt_last)) -ge 600 ]; then
                    echo "$_rt_now" > /tmp/z2k-sni-refresh.ts 2>/dev/null
                    run_task tcp16-probe sh "${ZAPRET2_DIR}/z2k-tcp16-probe.sh"
                fi
            fi
            ;;
    esac

    case "$hhmm" in
        03:30)
            # Свежесть имени из белого списка провайдера.
            #
            # Оно протухает: замер 30.08.2026 — имя работало в 17:19 и
            # перестало через час. Раз в сутки проверяем текущее одним
            # запросом и, если перестало пробивать, подбираем заново (около
            # тридцати секунд). Заодно раз в неделю перемеряется сама линия:
            # провайдер может блок и снять, тогда механизм уходит из конфига.
            if [ "$(last_fired_for_key sni-refresh)" != "$today" ]; then
                mark_fired sni-refresh "$today"
                if [ -r "${ZAPRET2_DIR}/z2k-tcp16-probe.sh" ]; then
                    run_task sni-refresh sh "${ZAPRET2_DIR}/z2k-tcp16-probe.sh"
                else
                    log "проба линии: файла нет — ночной перемер пропущен"
                fi
            fi
            ;;
        04:00)
            if [ "$(last_fired_for_key update-lists)" != "$today" ]; then
                mark_fired update-lists "$today"
                run_task update-lists "${ZAPRET2_DIR}/z2k-update-lists.sh"
            fi
            ;;
        06:00)
            if [ "$(last_fired_for_key get-config)" != "$today" ]; then
                mark_fired get-config "$today"
                log "fire get-config: ZAPRET_BASE=${ZAPRET2_DIR} ${ZAPRET2_DIR}/ipset/get_config.sh"
                (
                    ZAPRET_BASE="${ZAPRET2_DIR}" "${ZAPRET2_DIR}/ipset/get_config.sh" >> "$LOG" 2>&1
                    log "done get-config (exit $?)"
                ) &
            fi
            ;;
    esac

    # Minute-cadence task: tg-tunnel-watchdog. Mirrors the old
    # `* * * * *` cron entry. Tracked by unix timestamp so we fire it
    # ~1×/min even though our tick runs ~2×/min.
    if [ -x "${ZAPRET2_DIR}/tg-tunnel-watchdog.sh" ]; then
        last_wd=$(last_fired_in "$TMP_STATE" tg-watchdog-epoch)
        case "$last_wd" in ''|*[!0-9]*) last_wd=0 ;; esac
        if [ "$((now_epoch - last_wd))" -ge 55 ]; then
            mark_fired_in "$TMP_STATE" tg-watchdog-epoch "$now_epoch"
            "${ZAPRET2_DIR}/tg-tunnel-watchdog.sh" >/dev/null 2>&1 &
        fi
    fi

    # Minute-cadence task: сторож детектора блокировок. Тем же способом, что и
    # tg-tunnel-watchdog выше. Отдельная задача, а не проверка внутри той:
    # у detect другой признак отказа — он может быть ЖИВ и при этом жечь ядро
    # (спин-горутина при asyncpreemptoff=1 не вытесняется), и «поднять, если
    # упал» такого не ловит.
    if [ -x "${ZAPRET2_DIR}/z2k-detect-watchdog.sh" ]; then
        last_dwd=$(last_fired_in "$TMP_STATE" detect-watchdog-epoch)
        case "$last_dwd" in ''|*[!0-9]*) last_dwd=0 ;; esac
        if [ "$((now_epoch - last_dwd))" -ge 55 ]; then
            mark_fired_in "$TMP_STATE" detect-watchdog-epoch "$now_epoch"
            "${ZAPRET2_DIR}/z2k-detect-watchdog.sh" >/dev/null 2>&1 &
        fi
    fi

    # Minute-cadence task: потолок отладочного лога.
    #
    # traffic_debug_rotate внутри S99zapret2 срабатывает ТОЛЬКО при старте
    # сервиса, а лог с 19.08.2026 пишется в /tmp, то есть в оперативку. Флаг,
    # забытый включённым на ночь без единого рестарта, растёт без предела:
    # замеренные 475 МБ за 17 часов при 500 МБ ОЗУ — это OOM, ради которого
    # потолок и заводили. Дёшево: при выключенной отладке verb выходит сразу.
    if [ -x /opt/etc/init.d/S99zapret2 ]; then
        last_dbg=$(last_fired_in "$TMP_STATE" debug-rotate-epoch)
        case "$last_dbg" in ''|*[!0-9]*) last_dbg=0 ;; esac
        if [ "$((now_epoch - last_dbg))" -ge 55 ]; then
            mark_fired_in "$TMP_STATE" debug-rotate-epoch "$now_epoch"
            /opt/etc/init.d/S99zapret2 debug_rotate >/dev/null 2>&1 &
        fi
    fi

    # Per-flow PPE de-offload re-assert (mangle FORWARD/PREROUTING). The NDM hook
    # (94-z2k-ppe-deoffload.sh) handles event-driven re-apply after netfilter
    # regen; this is the secondary net AND the boot-time apply (the rule is
    # self-contained — no ipset/order dependency — so this lands it as soon as
    # the scheduler ticks). No-ops cleanly where the firmware `-j PPE` target is
    # absent or the user disabled the layer.
    if [ -r "${ZAPRET2_DIR}/z2k-ppe-deoffload.sh" ]; then
        last_ppe=$(last_fired_in "$TMP_STATE" ppe-deoffload-epoch)
        case "$last_ppe" in ''|*[!0-9]*) last_ppe=0 ;; esac
        if [ "$((now_epoch - last_ppe))" -ge 55 ]; then
            mark_fired_in "$TMP_STATE" ppe-deoffload-epoch "$now_epoch"
            ( . "${ZAPRET2_DIR}/z2k-ppe-deoffload.sh"
              z2k_ppe_user_disabled || z2k_ppe_ensure_rules ) >/dev/null 2>&1 &
        fi
    fi

    # NFQUEUE self-heal (minute-cadence). Standalone script (mirrors the
    # tg-watchdog / ppe-deoffload pattern) re-applies the firewall when nfqws2 is
    # running and the WAN is up but its NFQUEUE rules are GONE — the boot-race
    # (fw_nfqws_post4/pre4 SKIP rule insertion when the WAN iface isn't detected
    # yet at start_fw and never retry -> NFQUEUE=0 with a live nfqws2, incl.
    # CGNAT/late-WAN topologies) and the secondary net for NDM wiping our rules
    # (the netfilter.d hook is the event-driven primary). Idempotent + coalesced
    # with the hook via the shared restart-fw mutex.
    if [ -x "${ZAPRET2_DIR}/z2k-nfqueue-selfheal.sh" ]; then
        last_sh=$(last_fired_in "$TMP_STATE" nfq-selfheal-epoch)
        case "$last_sh" in ''|*[!0-9]*) last_sh=0 ;; esac
        if [ "$((now_epoch - last_sh))" -ge 55 ]; then
            mark_fired_in "$TMP_STATE" nfq-selfheal-epoch "$now_epoch"
            "${ZAPRET2_DIR}/z2k-nfqueue-selfheal.sh" >/dev/null 2>&1 &
        fi
    fi

    # WARP: selfheal каждые 25 с — ставит/снимает маршрут по status.json
    # движка z2k-warpd (fail open: мёртвый туннель = трафик напрямую, а не в
    # чёрную дыру) и поднимает демон, если он не запущен. No-op при
    # GAME_WARP_ENABLED=0 или без установленного движка.
    if [ -r "${ZAPRET2_DIR}/z2k-warp.sh" ]; then
        last_warp=$(last_fired_in "$TMP_STATE" warp-selfheal-epoch)
        case "$last_warp" in ''|*[!0-9]*) last_warp=0 ;; esac
        if [ "$((now_epoch - last_warp))" -ge 25 ]; then
            mark_fired_in "$TMP_STATE" warp-selfheal-epoch "$now_epoch"
            sh "${ZAPRET2_DIR}/z2k-warp.sh" selfheal >/dev/null 2>&1 &
        fi
    fi

    # Rotate logs occasionally (cheap, only every minute boundary).
    if [ "$(date +%S)" -lt 30 ]; then
        rotate_log
        rotate_all_logs
    fi

    sleep 30
done
