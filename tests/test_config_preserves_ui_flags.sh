#!/bin/sh
# tests/test_config_preserves_ui_flags.sh
#
# Каждый флаг, который панель или меню умеют переключать, обязан переживать
# пересоздание конфига.
#
# ЗАЧЕМ. Генератор пишет конфиг С НУЛЯ по фиксированному списку и подменяет
# боевой файл. Ключ, которого в списке нет, ИСЧЕЗАЕТ, а read_flag возвращает
# умолчание — то есть тумблер сам возвращается в исходное положение. Регенерацию
# вызывает любой другой тумблер панели, ночное обновление и переустановка.
#
# Так уже ломались:
#   ENABLED            — остановленный сервис воскресал
#   Z2K_PPE_DEOFFLOAD  — выключенный de-offload включался обратно
#   Z2K_PANEL_AUTH     — пароль на панель снимался сам
#   Z2K_AUTO_UPDATE_ENABLED — issue #38, «бесполезная кнопка отключения
#                             автообновлений»
#
# Три раза один и тот же класс, поэтому проверяем не список руками, а сверку:
# что пишет интерфейс против того, что сохраняет генератор.

DIR="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$DIR/lib/config_official.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

[ -f "$GEN" ] || { echo "нет $GEN"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# Что интерфейс умеет записывать в конфиг.
grep -rhoE 'set_flag "[A-Z0-9_]+"' "$DIR"/webpanel/cgi/*.sh "$DIR"/lib/menu.sh 2>/dev/null \
    | sed 's/set_flag "//; s/"//' | sort -u > "$tmp/written"

# Что генератор вычитывает из старого конфига перед перезаписью.
grep -oE 'safe_config_read "[A-Z0-9_]+"' "$GEN" \
    | sed 's/safe_config_read "//; s/"//' | sort -u > "$tmp/saved"

if [ -s "$tmp/written" ]; then
    ok "нашёл ключи, которые пишет интерфейс ($(wc -l < "$tmp/written" | tr -d ' ') шт.)"
else
    bad "ни одного set_flag не найдено — тест ослеп, проверь пути к webpanel/cgi и lib/menu.sh"
    echo; echo "PASSED: $PASS"; echo "FAILED: $FAIL"; exit 1
fi

# БЕЗ comm: этого апплета в busybox Entware НЕТ вовсе (`command -v comm` пусто,
# `busybox comm` — «applet not found»). На маке и в CI он есть из coreutils, и
# обе сверки ниже молча выдавали пустоту — «ничего не потеряно» и «сторож
# декоративен». awk делает то же и работает везде.
lost=$(awk 'NR==FNR { seen[$0] = 1; next } !seen[$0]' "$tmp/saved" "$tmp/written")
if [ -z "$lost" ]; then
    ok "все переключаемые флаги сохраняются при пересоздании конфига"
else
    bad "флаги теряются при пересоздании конфига — тумблер вернётся сам:"
    printf '       %s\n' $lost
fi

# Мало вычитать — надо ещё и записать обратно. Ключ, прочитанный в saved_X, но
# не выведенный в тело конфига, теряется ровно так же.
#
# Ищем присваивание С НАЧАЛА СТРОКИ: именно так ключи попадают в heredoc,
# которым пишется конфиг. Объявления умолчаний этому не соответствуют — они
# идут с отступом и через `local saved_`. Значение может быть и не прямой
# подстановкой saved_X: строковые ключи (POLICY_NAME) выводятся через
# экранированную промежуточную переменную, и это законно.
missing_emit=""
while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qE "^${key}=" "$GEN" || missing_emit="$missing_emit $key"
done < "$tmp/written"
if [ -z "$missing_emit" ]; then
    ok "каждый сохранённый флаг выводится обратно в конфиг"
else
    bad "прочитаны, но не записаны обратно:$missing_emit"
fi

# Отдельно сторожим сам issue #38: ключ автообновления и его умолчание.
# Умолчание обязано быть 1 — иначе апгрейд с конфига без ключа молча выключит
# автообновление всем, кто его не трогал.
if grep -q 'saved_Z2K_AUTO_UPDATE_ENABLED=$(safe_config_read "Z2K_AUTO_UPDATE_ENABLED" "$config_file" "1")' "$GEN"; then
    ok "issue #38: автообновление сохраняется, умолчание 1"
else
    bad "issue #38: нет сохранения Z2K_AUTO_UPDATE_ENABLED с умолчанием 1"
fi

# Сторож должен ловить пропажу, а не просто существовать. Убираем сохранение
# автообновления из копии генератора и проверяем, что сверка это замечает.
sed '/saved_Z2K_AUTO_UPDATE_ENABLED=$(safe_config_read/d' "$GEN" > "$tmp/gen_broken.sh"
grep -oE 'safe_config_read "[A-Z0-9_]+"' "$tmp/gen_broken.sh" \
    | sed 's/safe_config_read "//; s/"//' | sort -u > "$tmp/saved_broken"
if [ -n "$(awk 'NR==FNR { seen[$0] = 1; next } !seen[$0]' "$tmp/saved_broken" "$tmp/written")" ]; then
    ok "сверка ловит удалённый ключ (проверено на испорченной копии)"
else
    bad "сверка НЕ ловит удалённый ключ — тест декоративный"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" = "0" ]
