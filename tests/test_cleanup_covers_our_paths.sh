#!/bin/sh
# tests/test_cleanup_covers_our_paths.sh — после полной зачистки на роутере не
# должно остаться наших файлов.
#
# ПОЧЕМУ ТЕСТ, А НЕ ВНИМАТЕЛЬНОСТЬ. Список путей в z2k_cleanup.sh набирался
# руками и трижды отставал от жизни: проверка на живом роутере 16.09.2026 нашла
# после «полной очистки» /opt/etc/z2k/webpanel (адрес панели), /opt/etc/z2k-warp
# (регистрация WARP у Cloudflare) и /opt/var/log/z2k-auto-update.log, а сверх
# того — три наших init-скрипта и два хука NDM. Каждый новый файл вне дерева
# /opt/zapret2 — это новый шанс забыть, и заметить пропажу можно только на
# чужом роутере.
#
# Здесь сверяются два множества: пути, которые наш код СОЗДАЁТ вне дерева, и
# шаблоны, которые зачистка УДАЛЯЕТ. Сопоставление — сеткой оболочки (case), то
# есть ровно так, как это сработает на роутере.
#
# Осознанные исключения перечислены в KEEP с причиной: файл принадлежит не нам.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
CLEAN="$HERE/z2k_cleanup.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

[ -f "$CLEAN" ] || { printf '[FAIL] нет %s\n' "$CLEAN"; exit 1; }

# Пути, которые зачистка оставляет намеренно. Сейчас пусто: ключ WARP лежит внутри
# каталога, которым зачистка управляет, а бэкапы удаляются все.
KEEP=''

# Пути, которые наш код создаёт вне /opt/zapret2. Собираются из исходников, а
# не переписываются сюда руками: иначе тест устареет ровно так же, как список в
# самом скрипте.
PATHS=$(grep -rhoE '/opt/(etc|sbin|bin|var)/[A-Za-z0-9_./-]*z2k[A-Za-z0-9_./-]*' \
            "$HERE"/lib/*.sh "$HERE"/files/*.sh "$HERE"/files/init.d/* \
            "$HERE"/webpanel/*.sh "$HERE"/webpanel/cgi/*.sh "$HERE"/z2k.sh 2>/dev/null \
        | sed 's/["'"'"']//g' | sort -u)

if [ -z "$PATHS" ]; then
    no "нашёл пути, которые мы создаём вне дерева (тест ослеп)"
    printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
    exit 1
fi

# Шаблоны удаления из зачистки: всё, что стоит в её списках и глобах.
PATS=$(grep -oE '/opt/(etc|sbin|bin|var)/[A-Za-z0-9_.*/-]+' "$CLEAN" | sort -u)

_missing=""
_checked=0
for p in $PATHS; do
    case " $KEEP " in *" $p "*) continue ;; esac
    # Каталоги состояния проверяем по самому каталогу: удаление /opt/etc/z2k
    # уносит и webpanel/, и .trust/.
    _checked=$((_checked + 1))
    _hit=0
    for pat in $PATS; do
        # Точное совпадение, совпадение по сетке, либо путь лежит ВНУТРИ
        # удаляемого каталога.
        # shellcheck disable=SC2254 # шаблон намеренно разворачивается сеткой
        case "$p" in
            $pat|"$pat"/*) _hit=1; break ;;
        esac
    done
    [ "$_hit" = 1 ] || _missing="$_missing $p"
done

if [ -n "$_missing" ]; then
    no "зачистка покрывает все наши пути вне дерева"
    printf '       не удаляются:\n'
    for m in $_missing; do printf '         %s\n' "$m"; done
else
    ok "зачистка покрывает все наши пути вне дерева (проверено $_checked)"
fi

# Отдельно — те три хвоста из поля: тест обязан краснеть именно на них, если
# кто-то вычеркнет строки обратно.
for must in /opt/etc/z2k /opt/etc/z2k-warp /opt/var/log/z2k-auto-update.log /opt/bin/z2k; do
    if grep -qF -- "$must" "$CLEAN"; then
        ok "зачистка знает про $must"
    else
        no "зачистка знает про $must"
    fi
done

# Все бэкапы наши и уходят. Рабочий opkg.conf при этом остаётся как есть.
if grep -qF -- "/opt/etc/opkg.conf.z2k-bak" "$CLEAN" && grep -qF -- "/opt/etc/opkg.conf.backup" "$CLEAN"; then
    ok "зачистка удаляет бэкапы opkg.conf"
else
    no "зачистка оставляет бэкапы opkg.conf"
fi

# Судьбу штатного lighttpd решает общая функция, см. test_uninstall_restores_router.sh.
if grep -q 'disabled-by-z2k' "$CLEAN"; then
    ok "зачистка разбирается со штатным lighttpd"
else
    no "зачистка разбирается со штатным lighttpd"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
