#!/bin/sh
# tests/test_restart_step_respects_user_off.sh — выключенный пользователем
# обход не должен валить обновление.
#
# Повод: 05.09.2026, роутер Марка, обновление p-82.10 -> p-82.12.
# `start` в init-скрипте отвечает 1, когда ENABLED != 1: это не «не смог
# запуститься», а «не должен запускаться». Но `restart` отдаёт наружу тот же
# код, шаг restart-service считался проваленным, и обновление откатывалось
# целиком.
#
# Цена высокая и незаметная: человек выключил обход — и с этого момента КАЖДЫЙ
# выпуск, объявляющий restart-service, качал файлы, падал и откатывался каждую
# ночь. Версия не двигалась, то есть застревало и всё остальное, включая
# правки, к обходу отношения не имеющие.
#
# Тест исполняет НАСТОЯЩУЮ функцию из lib/auto_update.sh в песочнице.
# POSIX sh (busybox ash).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM

# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh"       >/dev/null 2>&1
# shellcheck source=/dev/null
. "$ROOT/lib/auto_update.sh" >/dev/null 2>&1
command -v au_step_restart_service >/dev/null 2>&1 || { echo "нет au_step_restart_service"; exit 1; }

# Init, который ведёт себя как настоящий: при ENABLED!=1 отвечает 1.
mk_init() {
    cat > "$SB/init" <<'INIT'
#!/bin/sh
en=$(grep -m1 '^ENABLED=' "$ZAPRET2_DIR/config" 2>/dev/null | cut -d= -f2 | tr -d '" ')
[ "$en" = "1" ] || { echo "zapret2 is disabled in config"; exit 1; }
echo started > "$ZAPRET2_DIR/started"
exit 0
INIT
    chmod +x "$SB/init"
}
mk_init
Z2K_AU_LOG_FILE="$SB/au.log"; export Z2K_AU_LOG_FILE

# 1. Обход выключен пользователем — шаг обязан пройти и ничего не запускать.
printf 'ENABLED=0\n' > "$SB/config"
rm -f "$SB/started"
ZAPRET2_DIR="$SB" INIT_SCRIPT="$SB/init" au_step_restart_service >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "при выключенном обходе шаг проходит (обновление не откатится)"
else
    bad "при выключенном обходе шаг вернул $rc — обновление откатится и застрянет навсегда"
fi
[ -f "$SB/started" ] && bad "шаг запустил службу вопреки выбору человека" \
                     || ok "служба осталась выключенной, как человек и хотел"

# 2. Обход включён и запускается — шаг проходит и служба поднята.
printf 'ENABLED=1\n' > "$SB/config"
rm -f "$SB/started"
ZAPRET2_DIR="$SB" INIT_SCRIPT="$SB/init" au_step_restart_service >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$SB/started" ]; then
    ok "при включённом обходе служба перезапускается"
else
    bad "при включённом обходе шаг не поднял службу (rc=$rc)"
fi

# 3. Обход включён, но перезапуск ЛОМАЕТСЯ — это по-прежнему провал.
#    Иначе правка превратила бы настоящую поломку в тихий успех.
printf 'ENABLED=1\n' > "$SB/config"
printf '#!/bin/sh\nexit 1\n' > "$SB/init"; chmod +x "$SB/init"
ZAPRET2_DIR="$SB" INIT_SCRIPT="$SB/init" au_step_restart_service >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
    ok "настоящая поломка перезапуска по-прежнему валит шаг"
else
    bad "сломанный перезапуск объявлен успехом — обновление проедет поверх мёртвой службы"
fi

# 4. Выключенный обход: сигнал всё равно снимается. Включать обход ради
#    проверки нельзя (чужой трафик, да и апдейтер может умереть между
#    «включил» и «выключил»), поэтому берётся та же проверка, что делает сам
#    `start`, — валидатор конфига. Он не двигает ни одного пакета.
mk_init
printf 'ENABLED=0\n' > "$SB/config"
printf '#!/bin/sh\ntouch "$(dirname "$1")/validated"\nexit 0\n' > "$SB/z2k-config-validator.sh"
chmod +x "$SB/z2k-config-validator.sh"
rm -f "$SB/validated" "$SB/started"
ZAPRET2_DIR="$SB" INIT_SCRIPT="$SB/init" au_step_restart_service >/dev/null 2>&1
if [ -f "$SB/validated" ]; then
    ok "при выключенном обходе конфиг всё равно проверяется"
else
    bad "конфиг не проверен — про такой роутер мы не узнаем ничего до дня, когда человек включит обход"
fi
[ -f "$SB/started" ] && bad "обход был включён ради проверки — так делать нельзя" \
                     || ok "обход ради проверки не включался"

# 5. Конфиг не прошёл проверку — это повод для записи в журнал, но НЕ для
#    отката: иначе роутер с выключенным обходом снова застрянет навсегда.
printf '#!/bin/sh\nexit 2\n' > "$SB/z2k-config-validator.sh"; chmod +x "$SB/z2k-config-validator.sh"
ZAPRET2_DIR="$SB" INIT_SCRIPT="$SB/init" au_step_restart_service >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
    ok "непрошедший конфиг не откатывает обновление на выключенном роутере"
else
    bad "непрошедший конфиг валит шаг — роутер с выключенным обходом опять застрянет"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
