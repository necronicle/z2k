#!/bin/sh
# tests/test_storage_cache.sh — барьеры журнала доходят до носителя.
#
# ЗАЧЕМ. Измерено на роутере 2026-08-10 (ядро 4.9-ndm-5):
#
#   sd 0:0:0:0: [sda] No Caching mode page found
#   sd 0:0:0:0: [sda] Assuming drive cache: write through
#   /sys/block/sda/queue/write_cache = write through
#
# USB-флешка не отдаёт SCSI caching mode page, ядро решает, что кэша записи
# нет, и блочный слой ЗАВЕРШАЕТ REQ_PREFLUSH/REQ_FUA, не отправляя их
# устройству. jbd2 просит сброс перед каждой фиксацией — сброс никуда не идёт.
# Кэш у флешки при этом есть, и при обрыве питания она теряет уже записанное:
# в образе «умершей» флешки потерянные блоки читаются сплошным 0xFF прогонами
# ровно по 16 КБ (гранулярность трансляции внутри накопителя), а никогда не
# писавшиеся области — нулями. Носитель при этом читается целиком без ошибок.
#
# Лечится переводом очереди в write back. Настройка слетает при каждом
# переподключении накопителя, поэтому её обязан переставлять хук на события
# USB, а не только установка.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LIB="$ROOT/files/z2k-storage-cache.sh"
HOOK="$ROOT/files/ndm/96-z2k-storage-cache.sh"
INST="$ROOT/lib/install.sh"

[ -f "$LIB" ]  || { printf '[FAIL] нет %s\n' "$LIB"; exit 1; }
[ -f "$HOOK" ] || { printf '[FAIL] нет %s\n' "$HOOK"; exit 1; }

# --- 1. Разбор имени устройства — поведенчески, на настоящей функции ---------
#
# /opt может быть на sda1, на mmcblk0p1, на nvme0n1p1. Ошибка здесь означает,
# что ручку либо не найдут вовсе, либо тронут чужое устройство.
# shellcheck disable=SC1090
. "$LIB"
_tmp=$(mktemp -d "${TMPDIR:-/tmp}/z2k-sc.XXXXXX") || exit 1
trap 'rm -rf "$_tmp"' EXIT INT TERM

_check_parse() {
    _got=$(z2k_sc_disk_from_src "$1" 2>/dev/null)
    if [ "$_got" = "$2" ]; then
        ok "имя диска из $1 -> $2"
    else
        no "имя диска из $1" "$2" "${_got:-<пусто>}"
    fi
}
_check_parse /dev/sda1      sda
_check_parse /dev/sdb12     sdb
_check_parse /dev/mmcblk0p1 mmcblk0
_check_parse /dev/nvme0n1p1 nvme0n1
# Не блочное устройство (overlay, tmpfs) — обязан отказать, а не выдумать имя.
if z2k_sc_disk_from_src "overlay" >/dev/null 2>&1; then
    no "не-блочный источник отвергается" "отказ" "принят"
else
    ok "не-блочный источник (/opt не с диска) отвергается"
fi

# --- 2. Ничего не делаем, где делать нечего ----------------------------------
#
# Ручка write_cache появилась в ядре 4.8. На более старом её нет, и это НЕ
# ошибка: функция обязана тихо выйти, а не сыпать в лог и не возвращать сбой.
if awk '/^z2k_sc_apply\(\) \{/,/^\}/' "$LIB" | grep -q '\[ -w "\$knob" \] || return 0'; then
    ok "отсутствие ручки (ядро старше 4.8) — тихий выход, а не ошибка"
else
    no "проверка наличия ручки перед записью" "[ -w \$knob ] || return 0" "не найдено"
fi
if awk '/^z2k_sc_apply\(\) \{/,/^\}/' "$LIB" | grep -q 'write back" \] && return 0'; then
    ok "повторный вызов ничего не переписывает (идемпотентность)"
else
    no "ранний выход, если режим уже write back" "проверка текущего значения" "не найдено"
fi

# --- 3. Пользователь может отключить -----------------------------------------
if grep -q 'Z2K_STORAGE_WRITEBACK' "$LIB"; then
    ok "есть выключатель Z2K_STORAGE_WRITEBACK"
else
    no "выключатель Z2K_STORAGE_WRITEBACK" "чтение флага из конфига" "нет"
fi

# --- 4. Хук стоит на событиях USB, а не на netfilter --------------------------
#
# Политика слетает при переподключении накопителя. netfilter.d про это событие
# ничего не знает — хук обязан лежать в usb.d.
if grep -q 'ndm/usb.d/96-z2k-storage-cache.sh' "$HOOK"; then
    ok "хук объявляет себя как usb.d (событие подключения накопителя)"
else
    no "хук предназначен для usb.d" "путь ndm/usb.d в шапке" "не найдено"
fi
if grep -q '/opt/etc/ndm/usb.d/96-z2k-storage-cache.sh' "$INST"; then
    ok "установка кладёт хук именно в usb.d"
else
    no "деплой хука в /opt/etc/ndm/usb.d/" "deploy_critical_file в usb.d" "не найдено"
fi
if grep -q 'mkdir -p .*ndm/usb.d' "$INST"; then
    ok "каталог usb.d создаётся до раскладки"
else
    no "создание /opt/etc/ndm/usb.d" "mkdir -p" "не найдено"
fi

# --- 5. Логика в общей библиотеке, а не продублирована ------------------------
#
# Хук, установка и ручной вызов обязаны делать одно и то же. Копия логики в
# хуке рано или поздно разойдётся с библиотекой.
if grep -q 'write_cache' "$HOOK"; then
    no "хук не содержит своей копии логики" "только вызов z2k_sc_apply" "в хуке своя работа с write_cache"
else
    ok "хук только зовёт общую функцию, своей копии логики не держит"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
