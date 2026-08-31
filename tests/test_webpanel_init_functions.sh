#!/bin/sh
# tests/test_webpanel_init_functions.sh — в init-скриптах не должно быть
# вызовов несуществующих функций и повторных объявлений.
#
# Повод: правка однажды затёрла заголовок `_z2k_webpanel_wait_start() {`,
# приклеив к нему комментарий. Получилось три поломки разом: осиротевшая
# строка выполнялась как команда («_z2k_webpanel_wait_#: not found» при каждой
# установке), тело сторожа досталось функции start(), а настоящий start(),
# объявленный ниже, его перекрыл. Сторож отложенного монтирования (issue #21)
# не существовал месяцами, и никто этого не видел: панель стартовала.
#
# Проверяются все наши init-скрипты, а не один: класс ошибки общий.
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

SCRIPTS=$(ls "$DIR"/webpanel/init.d/* "$DIR"/files/init.d/* 2>/dev/null)
[ -n "$SCRIPTS" ] || { echo "не нашёл init-скриптов"; exit 1; }

dupes=""
orphans=""
for f in $SCRIPTS; do
    b=$(basename "$f")

    # 1. Повторные объявления: в sh побеждает последнее, и первое молча теряется.
    d=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) *\{' "$f" | sed 's/() *{//' | sort | uniq -d)
    [ -n "$d" ] && dupes="$dupes $b:$(printf '%s' "$d" | tr '\n' ',')"

    # 2. Вызовы функций, которых нет. Берём имена в нашем стиле (со
    #    подчёркиванием или префиксом), чтобы не спорить с внешними командами.
    defined=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) *\{' "$f" | sed 's/() *{//' | sort -u)
    called=$(grep -oE '(^|[;&|[:space:]])(_[A-Za-z0-9_]+|[a-z]+_[a-z_]+)\b' "$f" \
             | sed 's/^[^A-Za-z_]*//' | sort -u)
    for c in $called; do
        printf '%s\n' "$defined" | grep -qx "$c" && continue
        # Не наша функция — не наше дело: считаем только те имена, что где-то
        # в этом же файле объявлены как функции с другим написанием, либо
        # начинаются с нашего префикса.
        case "$c" in
            _z2k_*|z2k_*)
                grep -q "^${c}() *{" "$f" || orphans="$orphans $b:$c" ;;
        esac
    done
done

[ -z "$dupes" ] && ok "нет повторных объявлений функций" \
                || bad "объявлены дважды:$dupes"
[ -z "$orphans" ] && ok "нет вызовов необъявленных функций z2k" \
                  || bad "вызываются, но не объявлены:$orphans"

# 3. И синтаксис — оболочкой, близкой к роутерной.
badsyn=""
for f in $SCRIPTS; do
    dash -n "$f" 2>/dev/null || badsyn="$badsyn $(basename "$f")"
done
[ -z "$badsyn" ] && ok "все init-скрипты разбираются" || bad "не разбираются:$badsyn"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
