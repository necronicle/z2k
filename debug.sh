#!/bin/sh
# debug.sh - Диагностика модулей ядра для z2k на Keenetic

echo "╔══════════════════════════════════════════════════╗"
echo "║  z2k - Диагностика модулей ядра                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. ИНФОРМАЦИЯ О СИСТЕМЕ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Архитектура: $(uname -m)"
echo "Ядро: $(uname -r)"
echo "Версия Keenetic: $(cat /etc/version 2>/dev/null || echo 'не определена')"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. ДИРЕКТОРИИ С МОДУЛЯМИ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Системные модули:"
ls -la /lib/modules/ 2>/dev/null || echo "Директория не существует"
echo ""

echo "Entware модули:"
ls -la /opt/lib/modules/ 2>/dev/null || echo "Директория не существует"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. НАЛИЧИЕ ФАЙЛОВ МОДУЛЕЙ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for mod in xt_NFQUEUE xt_multiport xt_connbytes nfnetlink_queue; do
    echo "Модуль: $mod"
    find /lib/modules/ -name "${mod}.ko" 2>/dev/null || echo "  Файл не найден"
done
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. ЗАГРУЖЕННЫЕ МОДУЛИ (lsmod)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Все netfilter модули:"
lsmod | grep -E 'nf|xt_' | head -20
echo ""
echo "Интересующие нас модули:"
for mod in xt_NFQUEUE xt_multiport xt_connbytes nfnetlink_queue; do
    if lsmod | grep -q "^${mod} "; then
        echo "  ✓ $mod загружен"
    else
        echo "  ✗ $mod НЕ загружен"
    fi
done
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. ВЕРСИИ MODPROBE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Системный modprobe:"
which /sbin/modprobe && /sbin/modprobe --version 2>&1 | head -3
echo ""
echo "Entware modprobe:"
which /opt/sbin/modprobe && /opt/sbin/modprobe --version 2>&1 | head -3
echo ""
echo "Дефолтный modprobe:"
which modprobe && modprobe --version 2>&1 | head -3
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6. ПОПЫТКА ЗАГРУЗКИ ЧЕРЕЗ /sbin/modprobe"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for mod in xt_NFQUEUE xt_multiport xt_connbytes; do
    echo "Попытка загрузки: $mod"
    /sbin/modprobe "$mod" 2>&1
    echo "Exit code: $?"
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7. ПОПЫТКА ЗАГРУЗКИ ЧЕРЕЗ insmod"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kernel_ver=$(uname -r)
mod_path="/lib/modules/${kernel_ver}"

echo "Путь к модулям: $mod_path"
echo ""

for mod in xt_NFQUEUE.ko xt_multiport.ko xt_connbytes.ko; do
    mod_file=$(find "$mod_path" -name "$mod" 2>/dev/null | head -1)
    if [ -n "$mod_file" ]; then
        echo "Попытка загрузки: $mod_file"
        /sbin/insmod "$mod_file" 2>&1
        echo "Exit code: $?"
    else
        echo "Файл $mod не найден"
    fi
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "8. DMESG (последние 30 строк)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
dmesg | tail -30
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "9. ПРОВЕРКА ЗАВИСИМОСТЕЙ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ip_tables:"
lsmod | grep ip_tables
echo ""
echo "x_tables:"
lsmod | grep x_tables
echo ""
echo "nfnetlink:"
lsmod | grep nfnetlink
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "10. СОСТОЯНИЕ ПОСЛЕ ПОПЫТОК ЗАГРУЗКИ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
lsmod | grep -E 'xt_NFQUEUE|xt_multiport|xt_connbytes|nfnetlink_queue'
echo ""

echo "╔══════════════════════════════════════════════════╗"
echo "║  Диагностика завершена                          ║"
echo "╚══════════════════════════════════════════════════╝"
