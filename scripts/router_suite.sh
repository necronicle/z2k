#!/bin/sh
# scripts/router_suite.sh — прогнать тест-сьют НА РОУТЕРЕ, а не на маке.
#
# ЗАЧЕМ. Сьют идёт под bash/dash с утилитами GNU, а код живёт под ash с
# утилитами busybox из Entware. Разница не косметическая, и она стоила поля
# дважды за один день:
#
#   * issue #43 — `od -An -c`: busybox Entware такой опции не знает, stderr был
#     закрыт, проверка целостности не проходила НИ РАЗУ, и переустановка
#     объявляла повреждёнными все 43 файла игровых списков WARP;
#   * pkill — апплета нет в сборке вовсе, а вызовов было восемь: снять зависший
#     lighttpd, добить планировщик, движок WARP, осиротевший tcpdump. Ни одна
#     страховка не срабатывала ни разу.
#
# Ни то, ни другое поймать на маке нельзя ПО ПОСТРОЕНИЮ: там другой od и есть
# pkill. Контейнер тоже не годится — проверено: busybox из alpine собран
# полнее, `od -An` в нём работает. Достоверен только сам роутер.
#
# ПРОД НЕ ПОРТИМ. Перед PATH встаёт каталог обёрток: чтение (-S, -L, list -n,
# -vnL) уходит в настоящий бинарник, любая мутация (-A/-I/-D/-F/-X/-Z,
# ipset create/add/del/destroy/flush/swap/restore, ndmc, opkg, reboot)
# отклоняется и пишется в журнал. Плюс снимок состояния до и после: если
# firewall, ipset или /opt/zapret2 всё-таки сдвинулись — скажем об этом громко.
#
# Дерево уезжает в /tmp (tmpfs): на флешку роутера тестовый мусор не пишем.
#
# Использование:
#   Z2K_ROUTER_SSH="sshpass -p ... ssh -p 222 root@192.168.1.1" sh scripts/router_suite.sh
set -e

SSH="${Z2K_ROUTER_SSH:?задайте Z2K_ROUTER_SSH, например: ssh -p 222 root@192.168.1.1}"
LAB="${Z2K_ROUTER_LAB:-/tmp/z2k-lab}"
OUT="${Z2K_ROUTER_OUT:-/tmp/router-suite.log}"
RPATH='/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin'

rsh() { $SSH "export PATH=$RPATH; $1"; }

say() { printf '\n━━━ %s\n' "$1"; }

# ---------------------------------------------------------------- снимок ----
snapshot() {
    rsh '
      printf "iptables-filter %s\n" "$(iptables -w -S 2>/dev/null | md5sum | cut -d" " -f1)"
      printf "iptables-nat    %s\n" "$(iptables -w -t nat -S 2>/dev/null | md5sum | cut -d" " -f1)"
      printf "iptables-mangle %s\n" "$(iptables -w -t mangle -S 2>/dev/null | md5sum | cut -d" " -f1)"
      printf "ipsets          %s\n" "$(ipset list -n 2>/dev/null | sort | md5sum | cut -d" " -f1)"
      printf "zapret2-tree    %s\n" "$(ls -lR /opt/zapret2 2>/dev/null | md5sum | cut -d" " -f1)"
      printf "config          %s\n" "$(md5sum /opt/zapret2/config 2>/dev/null | cut -d" " -f1)"
      printf "nfqws2-pids     %s\n" "$(pgrep nfqws2 2>/dev/null | tr "\n" " ")"
      printf "initd           %s\n" "$(ls /opt/etc/init.d 2>/dev/null | md5sum | cut -d" " -f1)"
    '
}

say 'снимок состояния ДО'
before=$(snapshot); printf '%s\n' "$before"
# Эталон живого конфига — чтобы не гадать, а восстановить побайтово.
rsh 'cp -f /opt/zapret2/config /tmp/z2k-config.pristine 2>/dev/null || true'

# --------------------------------------------------------------- обёртки ----
say 'ставлю обёртки: чтение пропускаем, запись отклоняем'
rsh "rm -rf $LAB; mkdir -p $LAB/guard $LAB/tmp"
$SSH "cat > $LAB/guard/iptables" <<'GUARD'
#!/bin/sh
# Мутирующие ключи iptables/ip6tables. -S/-L/-C и -t только для чтения.
for a in "$@"; do
    case "$a" in
        -A|-I|-D|-R|-F|-X|-N|-Z|-P|--flush|--delete-chain|--new-chain|--policy)
            echo "[guard] отклонено: iptables $*" >> /tmp/z2k-lab/guard.log
            exit 1 ;;
    esac
done
exec /opt/sbin/iptables "$@"
GUARD
$SSH "cat > $LAB/guard/ipset" <<'GUARD'
#!/bin/sh
case "$1" in
    list|-L|-n|test|help|-h|version|-v) exec /opt/sbin/ipset "$@" ;;
esac
echo "[guard] отклонено: ipset $*" >> /tmp/z2k-lab/guard.log
exit 1
GUARD
for blocked in ndmc opkg reboot halt poweroff; do
    $SSH "cat > $LAB/guard/$blocked" <<GUARD
#!/bin/sh
echo "[guard] отклонено: $blocked \$*" >> /tmp/z2k-lab/guard.log
exit 1
GUARD
done
rsh "cp $LAB/guard/iptables $LAB/guard/ip6tables; chmod 755 $LAB/guard/*"

# ------------------------------------------------------------------ дерево --
say 'везу дерево в tmpfs'
tar cf - --exclude='./.git' --exclude='./node_modules' --exclude='*/builds/*' \
         --exclude='./archive' . 2>/dev/null \
  | $SSH "export PATH=$RPATH; cd $LAB && tar xf -"

# ------------------------------------------------------------------ прогон --
#
# КОРЕНЬ УСТАНОВКИ ПОДМЕНЯЕМ НА ЛАБОРАТОРНЫЙ. Набор, забывший переопределить
# ZAPRET2_DIR, на маке молча ничего не делает (каталога нет) и зеленеет, а на
# роутере пишет в ЖИВОЙ /opt/zapret2 — так 2026-08-27 в конфиг владельца уехал
# TMPDIR прогонного окружения. Подмена превращает такую забывчивость из аварии
# в безобидную запись в /tmp; набор, задающий свои пути, её не замечает.
# Наборы, которым нужны отгружаемые бинарники: builds/ — это 194 МБ, а tmpfs
# роутера всего 226 МБ. Везти их некуда, а на флешку тестовый груз не пишем.
# Пропуск ОБЪЯВЛЕН: 42 красных «файла нет» маскировали настоящие находки.
Z2K_SKIP='test_build_matrix test_rt_proxy_binary_drift'
export Z2K_SKIP

say 'гоню сьют под ash + busybox (корень установки — лабораторный)'
rsh "mkdir -p $LAB/fakeroot/opt/zapret2"
rsh "cd $LAB && TMPDIR=$LAB/tmp Z2K_TEST_SH=/bin/sh PATH=$LAB/guard:$RPATH \
     ZAPRET2_DIR=$LAB/fakeroot/opt/zapret2 \
     CONFIG_FILE=$LAB/fakeroot/opt/zapret2/config \
     Z2K_AU_INSTALLED_TAG_FILE=$LAB/fakeroot/opt/zapret2/.z2k-installed-tag \
     Z2K_SKIP_SUITES='$Z2K_SKIP' sh tests/run_all.sh" > "$OUT" 2>&1 || true

say 'итог'
grep -E 'Test suites run|Общее время|Total passed|Total failed|Total skipped' "$OUT" || true

say 'наборы с провалами'
awk '/^>>> Running/{s=$2} /^\[FAIL\]/{print s": "$0}' "$OUT" | head -80

say 'что обёртки отклонили (попытки записи в прод)'
rsh "cat $LAB/guard.log 2>/dev/null | sort | uniq -c | sort -rn | head -20" || true

say 'снимок состояния ПОСЛЕ'
after=$(snapshot); printf '%s\n' "$after"
if [ "$before" = "$after" ]; then
    printf '\nПРОД НЕ СДВИНУЛСЯ — все восемь отпечатков совпали.\n'
    rsh 'rm -f /tmp/z2k-config.pristine'
else
    # Конфиг восстанавливаем САМИ и сразу: он единственный из отпечатков, чья
    # порча ломает роутер, а не просто расходится с эталоном.
    rsh 'if ! cmp -s /tmp/z2k-config.pristine /opt/zapret2/config 2>/dev/null; then
             cp -f /tmp/z2k-config.pristine /opt/zapret2/config && echo "конфиг восстановлен из эталона"
         fi; rm -f /tmp/z2k-config.pristine' || true
    printf '\n!!! СОСТОЯНИЕ ИЗМЕНИЛОСЬ — разбирать немедленно:\n'
    printf '%s\n' "$before" > /tmp/z2k-snap-before.txt
    printf '%s\n' "$after"  > /tmp/z2k-snap-after.txt
    diff /tmp/z2k-snap-before.txt /tmp/z2k-snap-after.txt || true
fi

say 'убираю за собой'
rsh "rm -rf $LAB"
printf 'полный лог: %s\n' "$OUT"
