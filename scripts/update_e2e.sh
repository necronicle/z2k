#!/bin/sh
# scripts/update_e2e.sh — сквозная проверка обновления на роутере владельца.
#
# Меряет ровно то, ради чего система переписывалась: сколько идёт обновление и
# сколько при этом качается. Точка отсчёта — 4 минуты 34 секунды и ~6 МБ
# (r-79.4 → r-79.6, полная переустановка ради двух изменившихся файлов).
#
# Запуск с мака:  ROUTER_PASS=... sh scripts/update_e2e.sh
# Переменные: ROUTER (192.168.1.1), ROUTER_PORT (222), ROUTER_PASS.
set -u
R="${ROUTER:-192.168.1.1}"; P="${ROUTER_PORT:-222}"
[ -n "${ROUTER_PASS:-}" ] || { echo "ROUTER_PASS не задан" >&2; exit 2; }
command -v sshpass >/dev/null 2>&1 || { echo "нужен sshpass (brew install hudochenkov/sshpass/sshpass)" >&2; exit 2; }
ssh_r() { sshpass -p "$ROUTER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p "$P" "root@$R" "$@"; }
step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# Счётчик байтов WAN-интерфейса. Он общий на весь роутер, поэтому в замер попадёт
# и посторонний трафик — но порядок величины («сотни КБ» против «шести МБ») это
# показывает честно, а стерильной сети у нас всё равно не будет.
RX='cat /sys/class/net/$(ip route show default 2>/dev/null | awk "{print \$5; exit}")/statistics/rx_bytes 2>/dev/null || echo 0'

step "исходное состояние"
BEFORE=$(ssh_r 'cat /opt/zapret2/.z2k-installed-tag 2>/dev/null' | tr -d '\r')
[ -n "$BEFORE" ] || fail "не читается .installed-tag — роутер недоступен или z2k не установлен"
printf 'установлено: %s\n' "$BEFORE"
ssh_r 'sh /opt/zapret2/z2k-auto-update.sh check 2>&1 | tail -5'

RX0=$(ssh_r "$RX" | tr -d '\r'); T0=$(ssh_r 'date +%s' | tr -d '\r')

# Z2K_AU_NO_JITTER=1 обязателен. Плановый разброс 0..90 мин включается по
# признаку «stdin не терминал», а ssh без tty выглядит ровно так — прогон уходил
# спать до полутора часов с пустым выводом. Панель и меню флаг ставят
# (webpanel/cgi/actions.sh, lib/menu.sh), замер обязан вести себя так же.
step "обновление"
ssh_r 'Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1 sh /opt/zapret2/z2k-auto-update.sh apply 2>&1 | tail -25' || fail "обновление вернуло ошибку"

T1=$(ssh_r 'date +%s' | tr -d '\r'); RX1=$(ssh_r "$RX" | tr -d '\r')
AFTER=$(ssh_r 'cat /opt/zapret2/.z2k-installed-tag 2>/dev/null' | tr -d '\r')
printf '\nбыло: %s → стало: %s\nвремя: %s с\nскачано: %s КБ (счётчик WAN, вместе с посторонним трафиком)\n' \
    "$BEFORE" "$AFTER" "$((T1 - T0))" "$(( (RX1 - RX0) / 1024 ))"
[ "$AFTER" != "$BEFORE" ] || printf 'версия не изменилась — либо уже последняя, либо обновление отказало (см. лог выше)\n'

step "сервис жив"
ssh_r 'pgrep -f nfqws2 >/dev/null 2>&1' || fail "nfqws2 не работает после обновления"
printf 'nfqws2 работает\n'
# Коды валидатора: 0 — чисто, 1 — предупреждения, 2 — ошибки. Предупреждения
# («дублирующийся фильтр между профилями») есть на живых роутерах и обновление
# не порочат; падать нужно на ошибках.
ssh_r 'sh /opt/zapret2/z2k-config-validator.sh /opt/zapret2/config >/dev/null 2>&1; [ $? -le 1 ]' \
    || fail "конфиг не проходит валидацию ПОСЛЕ обновления"
printf 'конфиг валиден (ошибок нет)\n'
ssh_r 'sh /opt/zapret2/z2k-diag.sh 2>/dev/null | sed -n "/=== что не так ===/,/^$/p"'

step "дерево сошлось с манифестом"
# Главное свойство новой системы: после успешного обновления расходиться нечему.
ssh_r 'Z2K_AU_SOURCE_ONLY=1 . /opt/zapret2/lib/utils.sh 2>/dev/null
       Z2K_AU_SOURCE_ONLY=1 . /opt/zapret2/lib/auto_update.sh 2>/dev/null
       Z2K_AU_TMP_DIR=/tmp/z2k-au-e2e; mkdir -p "$Z2K_AU_TMP_DIR"
       cp -f /opt/zapret2/UPDATES.json "$Z2K_AU_TMP_DIR/UPDATES.json" 2>/dev/null
       n=$(au_converge_plan "$Z2K_AU_TMP_DIR/UPDATES.json" | awk "END {print NR}")
       echo "расходится файлов: ${n:-?}"
       au_converge_plan "$Z2K_AU_TMP_DIR/UPDATES.json" | head -10
       rm -rf "$Z2K_AU_TMP_DIR"'

step "идемпотентность: второй прогон не делает ничего"
T2=$(ssh_r 'date +%s' | tr -d '\r')
ssh_r 'Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1 sh /opt/zapret2/z2k-auto-update.sh apply 2>&1 | tail -3'
T3=$(ssh_r 'date +%s' | tr -d '\r')
printf 'повторный прогон: %s с\n' "$((T3 - T2))"
[ "$((T3 - T2))" -le 30 ] || fail "повторный прогон занял $((T3 - T2)) с — сходимость не идемпотентна"

printf '\nE2E OK\n'
