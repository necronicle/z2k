#!/bin/sh
# tests/test_update_transition.sh — стенд перехода: обновление обязано ПРИВОДИТЬ
# К ЭФФЕКТУ, а не просто класть файлы на диск.
#
# ЗАЧЕМ ЭТО ЕСТЬ. Шесть выпусков подряд (r-81.1 … r-81.6) чинили механизм,
# который у людей так и не включался. Каждый фикс проверялся реинсталлом или
# запуском руками — то есть способом, при котором дефект невидим: реинсталл
# поднимает всё заново. Сценарий «стоит старая версия → приехало обновление →
# случился эффект» не прогонялся ни разу.
#
# Здесь проверяются два свойства, на которых держится вся доставка:
#
#   1. Шаг обновления исполняет файл, лежащий на диске НА МОМЕНТ ШАГА, а не
#      тот, что был там в начале прогона. Без этого свойства правка не может
#      подействовать на том же обновлении, которое её привезло, — а именно так
#      и вышло с lib/auto_update.sh и lib/utils.sh: обновление исполняет
#      ПРЕДЫДУЩАЯ версия, уже загруженная в память.
#
#   2. Файл, несущий работу после обновления, объявляет шаг, который эту работу
#      запустит. files/z2k-scheduler.sh не объявлял НИ ОДНОГО шага: релиз,
#      меняющий только планировщик, не запускал ничего.
#
# POSIX sh (busybox ash).
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждал [$2], получил [$3]"; fi; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT

# --- 1. Шаг исполняет то, что лежит на диске НА МОМЕНТ ШАГА -------------------
# Гоняем НАСТОЯЩИЙ au_step_restart_service. Подменяем init между подключением
# библиотеки и вызовом шага — ровно то, что делает доставка файлов.
au_log() { :; }
ZAPRET2_DIR="$SB/opt/zapret2"; mkdir -p "$ZAPRET2_DIR"
# shellcheck source=/dev/null
. "$ROOT/lib/auto_update.sh" 2>/dev/null

INIT="$SB/S99zapret2"
printf '#!/bin/sh\necho СТАРЫЙ >> "%s/ran.log"\n' "$SB" > "$INIT"
chmod +x "$INIT"

if ! command -v au_step_restart_service >/dev/null 2>&1; then
    bad "au_step_restart_service не подключилась — стенд не может работать"
else
    : > "$SB/ran.log"
    # доставка: файл на диске заменён НОВОЙ версией
    printf '#!/bin/sh\necho НОВЫЙ >> "%s/ran.log"\n' "$SB" > "$INIT"
    chmod +x "$INIT"
    INIT_SCRIPT="$INIT" au_step_restart_service >/dev/null 2>&1
    eq "шаг исполняет init, лежащий на диске на момент шага" "НОВЫЙ" "$(cat "$SB/ran.log" 2>/dev/null)"
fi

# --- 2. Файлы, несущие работу после обновления, объявляют шаг ------------------
# shellcheck source=/dev/null
. "$ROOT/lib/release_map.sh"
for f in files/z2k-scheduler.sh files/init.d/S99z2k-scheduler files/z2k-tcp16-probe.sh files/S99zapret2.new; do
    steps=$(z2k_steps_for "$f" | tr '\n' ' ')
    case " $steps " in
        *" restart-service "*) ok "$f объявляет restart-service" ;;
        *) bad "$f не объявляет шага — релиз с ним одним не запустит ничего" ;;
    esac
done

# --- 3. Объявленный шаг известен исполнителю ---------------------------------
# Незнакомый шаг старые апдейтеры трактуют как «из будущего» и уходят в полную
# переустановку. Поэтому объявлять можно только то, что есть в каноническом
# порядке И в порядке исполнителя.
all=$(z2k_all_steps | tr '\n' ' ')
case " $all " in
    *" restart-service "*) ok "restart-service есть в каноническом порядке" ;;
    *) bad "restart-service пропал из z2k_all_steps" ;;
esac
order=$(au_step_order 2>/dev/null | tr '\n' ' ')
case " $order " in
    *" restart-service "*) ok "restart-service есть в порядке исполнителя" ;;
    *) bad "restart-service пропал из au_step_order" ;;
esac

# --- 4. Порядок исполнителя и карта релиза не разъехались --------------------
# Они дублируют друг друга намеренно; расхождение означает шаг, который релиз
# объявит, а исполнитель не узнает.
a=$(z2k_all_steps | sort | tr '\n' ' ')
b=$(au_step_order 2>/dev/null | sort | tr '\n' ' ')
eq "набор шагов совпадает у карты релиза и исполнителя" "$a" "$b"

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
