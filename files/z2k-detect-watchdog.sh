#!/bin/sh
# z2k-detect-watchdog.sh — сторож детектора блокировок.
#
# ЗАЧЕМ. У z2k-detect не было сторожа вообще, и это опаснее, чем кажется:
# отказ там не выглядит как отказ.
#
#   * Демон УМЕР — детектор просто перестаёт дописывать домены. Обход при этом
#     работает (nfqws2 от detect не зависит), поэтому человек ничего не замечает
#     месяцами, а автохостлист тихо стоит.
#
#   * Демон ЖИВ, но крутит ядро вхолостую. Это реальный класс: горутина,
#     попавшая в бесконечный цикл, при GODEBUG=asyncpreemptoff=1 (а он у нас
#     обязателен на MIPS) не вытесняется. Прецедент в проекте уже был —
#     осиротевший спиннер прожил 141 час CPU, и заметили его только по
#     load average.
#
# Поэтому проверяем ДВЕ вещи, а не одну: что процесс есть и что он не жжёт
# процессор. Второе — то, чего обычный «поднять, если упал» не ловит.
#
# Запускается планировщиком раз в минуту (см. files/z2k-scheduler.sh).
# Per [[reference_cron_path_entware]]: PATH задаём явно, системный не содержит
# /opt/bin, где живут pidof/awk.
PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin
export PATH

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONF="${CONF:-$ZAPRET2_DIR/config}"
INIT="${INIT:-/opt/etc/init.d/S98z2k-detect}"
LOG="${LOG:-/opt/var/log/z2k-detect-watchdog.log}"
STATE="${STATE:-/tmp/z2k-detect-wd}"

# Порог загрузки процессора, при котором считаем демона зациклившимся.
# Детектор в норме почти не считает: его работа — ждать DNS-событий и изредка
# ходить по сети. Устойчивые 80% на нашем железе означают не работу, а цикл.
CPU_LIMIT="${CPU_LIMIT:-80}"
# Сколько подряд замеров выше порога нужно, чтобы вмешаться. Один замер ловит
# нормальный всплеск на старте, поэтому требуем три подряд — три минуты.
CPU_STRIKES="${CPU_STRIKES:-3}"

_log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$LOG" 2>/dev/null
}

# Фича выключена — сторожить нечего. Молча выходим: это не отказ.
_flag=$(grep -m1 '^Z2K_DISCOVER=' "$CONF" 2>/dev/null | cut -d= -f2 | tr -dc '0-9')
[ "$_flag" = "1" ] || { rm -f "$STATE" 2>/dev/null; exit 0; }

[ -x "$INIT" ] || exit 0

pid=$(pidof z2k-detect 2>/dev/null | awk '{print $1}')

# --- случай 1: демон не работает ---------------------------------------------
if [ -z "$pid" ]; then
    _log "z2k-detect не работает при Z2K_DISCOVER=1 — поднимаю"
    "$INIT" start >/dev/null 2>&1
    rm -f "$STATE" 2>/dev/null
    exit 0
fi

# --- случай 2: демон жив, но жжёт процессор ----------------------------------
#
# Берём мгновенную загрузку процесса. На BusyBox `top -b -n1` даёт колонку %CPU;
# если её нет, тихо выходим — сторож не должен падать из-за формата вывода.
cpu=$(top -b -n1 2>/dev/null | awk -v p="$pid" '$1 == p { print $(NF-2); exit }' | tr -dc '0-9')
[ -n "$cpu" ] || exit 0

strikes=$(cat "$STATE" 2>/dev/null | tr -dc '0-9')
[ -n "$strikes" ] || strikes=0

if [ "$cpu" -ge "$CPU_LIMIT" ] 2>/dev/null; then
    strikes=$((strikes + 1))
    printf '%s' "$strikes" > "$STATE" 2>/dev/null
    if [ "$strikes" -ge "$CPU_STRIKES" ]; then
        _log "z2k-detect держит ${cpu}% процессора ${strikes} замера подряд — похоже на зацикливание, перезапускаю"
        _log "если повторяется — это баг детектора, а не среды: приложите /var/log/z2k-detect.log"
        "$INIT" restart >/dev/null 2>&1
        rm -f "$STATE" 2>/dev/null
    fi
    exit 0
fi

# Норма — счётчик сбрасываем, иначе редкие всплески за час накопились бы
# в ложный перезапуск.
[ "$strikes" != "0" ] && rm -f "$STATE" 2>/dev/null
exit 0
