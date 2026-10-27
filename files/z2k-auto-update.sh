#!/bin/sh
# z2k-auto-update.sh — entry point for both cron and manual menu.
#
# Usage:
#   z2k-auto-update.sh [apply|check]
#     apply (default) — triggered by z2k-scheduler.sh at 02:00; sleeps
#                       a per-host deterministic jitter (0..60min) so the
#                       184-router fleet doesn't hit GitHub in one second,
#                       then downloads manifest, decides patch/reinstall,
#                       applies, health-checks.
#     check           — dry-run: print what would happen, no apply. Used by
#                       the "Проверить обновления" menu item.
#
# Triggered by z2k-scheduler.sh at 02:00 daily (replacing cron, which
# is broken on Keenetic Entware — see r-26 field notes).
#
# Mark's call: only z2k-enhanced participates; master users don't get
# auto-updates.

# Cron on Entware ships a tiny PATH that misses awk/grep/curl/etc.
# (see reference_cron_path_entware.md).
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

ZAPRET2_DIR="/opt/zapret2"
ACTION="${1:-apply}"

# Branch gate — apply only for z2k-enhanced
BRANCH_FILE="${ZAPRET2_DIR}/.z2k-branch"
if [ ! -f "$BRANCH_FILE" ] || [ "$(cat "$BRANCH_FILE" 2>/dev/null)" != "z2k-enhanced" ]; then
    if [ "$ACTION" = "check" ]; then
        echo "Авто-обновление работает только на ветке z2k-enhanced."
    fi
    exit 0
fi

# User gate — Z2K_AUTO_UPDATE_ENABLED (default 1, i.e. unchanged behaviour).
#
# Stops the UNATTENDED nightly apply only. `check` stays allowed so the dashboard
# can still say "доступна p-67.9" to someone who updates by hand, and a manual
# apply stays allowed too (Z2K_AU_MANUAL=1, set by the panel and the menu) —
# otherwise flipping this off would leave a user with no way to ever update
# again, which is not what "отключить автообновление" means.
#
# NOT named Z2K_AUTO_UPDATE: that name is already an ENV marker meaning "this
# reinstall was started by the updater", read by lib/install.sh and z2k.sh to
# decide config-merge and non-interactive behaviour. A config key of the same
# name set to 0 could reach those checks and silently change how a reinstall
# merges the user's config.
#
# ЧИТАЕМ ОТКАЗ, А НЕ РАЗРЕШЕНИЕ, И ЭТО НЕ ПРИДИРКА К ФОРМЕ.
#
# Здесь стоял `awk -F=` по первой строке со снятием кавычек и пробелов. Замер
# 16.09.2026 (tests/test_auto_update_toggle.sh, раздел «кривой конфиг»): гейт
# ОТКРЫВАЛСЯ, то есть роутер обновлялся ночью при выключенном тумблере, на
# каждом из этих конфигов —
#
#   Z2K_AUTO_UPDATE_ENABLED=0<CR>     конфиг правили в Windows-редакторе
#   Z2K_AUTO_UPDATE_ENABLED=0<TAB>    правили руками
#   Z2K_AUTO_UPDATE_ENABLED=0 # выключил      то же
#   export Z2K_AUTO_UPDATE_ENABLED=0  так пишут те, кто знает, что конфиг
#                                     исполняется как скрипт
#   две строки: =1, ниже =0           awk брал ПЕРВУЮ, а оболочка при
#                                     `. config` применяет последнюю
#
# Все пять для человека выглядят как выключённое автообновление, и ни один не
# оставляет следа: ночью роутер обновляется, утром никто не понимает, почему.
#
# Поэтому здесь ищется ОТКАЗ: если ХОТЬ ОДНА строка конфига присваивает ключу
# ноль — планового обновления не будет. Неоднозначный конфиг для необратимого
# действия без человека решается в пользу бездействия.
#
# Хвостовой комментарий и пробелы срезаются ТОЛЬКО здесь и только потому, что
# значение — цифра. В общем читателе флагов (read_flag) так делать нельзя:
# там же лежат имена политик и пароли, в которых и решётка, и пробел
# законны.
au_read_off() {
    awk '
        /^[[:space:]]*(export[[:space:]]+)?Z2K_AUTO_UPDATE_ENABLED[[:space:]]*=/ {
            v = $0
            sub(/^[^=]*=/, "", v)
            sub(/#.*$/, "", v)
            gsub(/\r/, "", v)
            gsub(/[[:space:]"'"'"']/, "", v)
            if (v == "0") { print "off"; exit }
        }' "${ZAPRET2_DIR}/config" 2>/dev/null
}

AU_OFF=$(au_read_off)

# МЕТКИ РУЧНОГО ЗАПУСКА СНИМАЕМ СРАЗУ И НАСОВСЕМ.
#
# Обе приходят из окружения: панель зовёт нас как
# `env Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1 sh z2k-auto-update.sh apply`, меню —
# как `Z2K_AU_NO_JITTER=1 au_run_apply`. Они относятся К ЭТОМУ запуску и ни к
# какому другому, но переменная окружения наследуется ВСЕМ деревом потомков, а
# в этом дереве есть установщик, и он на шаге 12 делает
# `/opt/etc/init.d/S99z2k-scheduler restart`. Планировщик — вечный демон: он
# уносил обе метки в себе до следующей перезагрузки и раздавал их каждому
# ночному запуску через run_task.
#
# Для человека это выглядело так: автообновление выключено, он один раз нажал
# «Обновить» в панели — и следующей ночью роутер обновился сам, потому что
# гейт ниже видел Z2K_AU_MANUAL=1 и считал плановый запуск ручным. Плюс
# утёкший Z2K_AU_NO_JITTER снимал разброс 0..60 мин, и такие роутеры ходили на
# GitHub ровно в 02:00:00 все вместе.
#
# Поэтому: прочитали в свои переменные (не в окружении) и unset. Дальше по
# дереву метки не уедут ни в установщик, ни в планировщик.
AU_MANUAL="${Z2K_AU_MANUAL:-0}"
AU_NO_JITTER="${Z2K_AU_NO_JITTER:-0}"
unset Z2K_AU_MANUAL Z2K_AU_NO_JITTER

au_abort_if_disabled() {
    if [ "$AU_OFF" = "off" ] && [ "$ACTION" = "apply" ] && [ "$AU_MANUAL" != "1" ]; then
        echo "Автообновление отключено в настройках — плановое обновление пропущено."
        # И СЛЕД В ЖУРНАЛЕ ОБНОВЛЕНИЙ. Раньше отказ уходил только в stdout, который
        # ловил планировщик в свой лог, а журнал обновлений молчал — по нему нельзя
        # было отличить «гейт сработал» от «ночь не наступала». Ровно этого следа не
        # хватило, чтобы разобрать жалобу «выключил, а оно обновилось».
        _au_log_file="${Z2K_AU_LOG_FILE:-/opt/var/log/z2k-auto-update.log}"
        mkdir -p "$(dirname "$_au_log_file")" 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') [auto-update] отключено в настройках — плановое обновление пропущено" \
            >> "$_au_log_file" 2>/dev/null
        exit 0
    fi
}

au_abort_if_disabled

# Source utils.sh FIRST so the layered z2k_fetch() (raw → jsdelivr → gh-proxy →
# ndmc DNS-override) is in scope. auto_update.sh's fetch helpers fall back to a
# bare `curl raw.githubusercontent.com` whenever `command -v z2k_fetch` is false
# — which it always was on this cron path, because only auto_update.sh was
# sourced. Result: the nightly auto-update had NO CDN/mirror fallback and went
# silently dead whenever GitHub raw was blocked or DNS-poisoned (the exact
# RU-ISP scenario the fallback exists for). The menu [U] path already gets it
# via z2k.sh → utils.sh; this makes the unattended path match.
#
# РАЗРЫВ, О КОТОРОМ НАДО ЗНАТЬ. «Match» здесь неточно: интерактивный путь идёт
# через z2k.sh, где z2k_fetch определён БОГАЧЕ — там есть пятый слой (DoH через
# 1.1.1.1 с пинами edge-IP), написанный под сценарий, когда ТСПУ глушит и SNI,
# и рекурсивный резолвер. Здесь z2k.sh не вызывается, поэтому в области
# видимости остаётся версия из utils.sh: четыре слоя, без DoH.
#
# Это осознанно (тянуть сюда весь z2k.sh ради одного слоя дороже, чем польза),
# но помнить надо вот что: без человека работает ИМЕННО этот путь, и отказ на
# нём некому заметить. Если появится отчёт «обновления не приходят у тех, у
# кого ручное обновление работает» — смотреть сюда первым делом.
. "${ZAPRET2_DIR}/lib/utils.sh"

# Source the auto-update module (installed at /opt/zapret2/lib/auto_update.sh)
. "${ZAPRET2_DIR}/lib/auto_update.sh"

case "$ACTION" in
    apply)
        # Разброс 0..60 мин — только для планового пути. Ручной apply (из меню
        # или панели) ждать не должен, поэтому гейт по stdin (не tty) и
        # Z2K_AU_NO_JITTER. Сам расчёт — z2k_host_jitter (lib/utils.sh): он
        # НИКОГДА не возвращает ноль всем сразу, чего не скажешь о прежнем
        # `cksum`, отсутствующем на Entware, — с ним флот обновлялся ровно
        # в 02:00:00, все вместе.
        if [ ! -t 0 ] && [ "$AU_NO_JITTER" != "1" ]; then
            JITTER=$(z2k_host_jitter 3600)
            au_log "ночной разброс: жду ${JITTER}с"
            sleep "$JITTER"
            # За час ночного разброса (00..60 мин) человек мог выключить
            # автообновление в панели или меню: перечитываем конфиг перед стартом.
            AU_OFF=$(au_read_off)
            au_abort_if_disabled
        fi
        au_run_apply
        ;;
    check)
        au_run_check
        ;;
    *)
        echo "usage: z2k-auto-update.sh [apply|check]"
        exit 1
        ;;
esac
