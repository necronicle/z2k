#!/bin/sh
# tests/test_au_steps.sh — последствия исполняются один раз и в правильном порядке.
#
# Ключевое здесь — ВЕТО валидации. Конфиг не прошёл проверку, а перезапуск всё
# равно случился — это роутер без обхода до утра. Поэтому «шаг провалился»
# обязано означать «дальше не идём», а не «идём и надеемся».
#
# И второе: неизвестный шаг. Релиз может объявить действие, которого этот
# исполнитель не знает (роутер отстал на десяток версий). Единственный честный
# ответ — «не могу, нужна полная переустановка», а не тихо пропустить и сдвинуть
# версию.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d) || exit 1; trap 'rm -rf "$SB"' EXIT
Z2K_AU_SOURCE_ONLY=1; export Z2K_AU_SOURCE_ONLY
# shellcheck disable=SC1091
. "$ROOT/lib/utils.sh" 2>/dev/null
# shellcheck disable=SC1091
. "$ROOT/lib/auto_update.sh" 2>/dev/null
Z2K_AU_TMP_DIR="$SB/tmp"; mkdir -p "$Z2K_AU_TMP_DIR"
au_log() { :; }

cat > "$SB/m.json" <<'EOF'
{"current": "p-3",
 "history": [
{"v": "p-1", "type": "patch", "steps": ["restart-service"], "changed_files": ["files/lua/a.lua"]},
{"v": "p-2", "type": "patch", "steps": ["regen-config", "validate-config", "restart-service"], "changed_files": ["lib/config_official.sh"]},
{"v": "p-3", "type": "patch", "steps": ["refresh-binaries", "restart-service"], "changed_files": ["z2k-warpd/builds/x"]},
{"v": "p-4", "type": "patch", "changed_files": ["files/lists/a.txt"]}
]}
EOF

assert_eq "шаги записи читаются" "regen-config validate-config restart-service" \
    "$(au_entry_steps "$SB/m.json" p-2 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "запись без steps — пусто, не ошибка" "" "$(au_entry_steps "$SB/m.json" p-4 | tr '\n' ' ')"
assert_eq "неизвестный тег — пусто" "" "$(au_entry_steps "$SB/m.json" p-99 | tr '\n' ' ')"

assert_eq "объединение трёх релизов: порядок канонический, рестарт один" \
    "regen-config validate-config refresh-binaries restart-service" \
    "$(au_steps_union "$SB/m.json" p-1 p-2 p-3 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "порядок объединения не зависит от порядка тегов" \
    "$(au_steps_union "$SB/m.json" p-1 p-2 p-3 | tr '\n' ' ')" \
    "$(au_steps_union "$SB/m.json" p-3 p-1 p-2 | tr '\n' ' ')"

# Неизвестный шаг НЕ отбрасывается при упорядочивании: он должен дойти до
# au_run_steps и там потребовать полную переустановку. Тихо выкинуть шаг из
# будущего — значит сдвинуть версию, не сделав того, что релиз объявил.
assert_eq "неизвестный шаг переживает упорядочивание" \
    "regen-config restart-service шаг-из-будущего" \
    "$(printf 'restart-service\nшаг-из-будущего\nregen-config\n' | au_steps_ordered | tr '\n' ' ' | sed 's/ $//')"
assert_eq "упорядочивание дедуплицирует" "restart-service" \
    "$(printf 'restart-service\nrestart-service\nrestart-service\n' | au_steps_ordered | tr '\n' ' ' | sed 's/ $//')"

# ВЛОЖЕННЫЙ ВЫЗОВ НЕ ДОЛЖЕН РАЗРУШАТЬ ВНЕШНИЙ.
#
# Так это и вызывается на живом пути: { au_steps_union …; echo reset-state; }
# | au_steps_ordered — внутренний упорядочиватель работает ВНУТРИ внешнего, в
# том же пайпе. Пока имя временного файла бралось из PID, оба брали одно и то
# же имя, внутренний удалял файл из-под внешнего, и объявленные шаги могли
# молча пропасть. На роутере это видно строкой «can't open …/steps.NNNNN».
assert_eq "вложенный вызов не рушит внешний" "regen-config restart-service" \
    "$( { printf 'restart-service\n' | au_steps_ordered; printf 'regen-config\n'; } | au_steps_ordered | tr '\n' ' ' | sed 's/ $//')"
_leftover=0
for _f in "$Z2K_AU_TMP_DIR"/steps.*; do [ -e "$_f" ] && _leftover=$((_leftover + 1)); done
assert_eq "вложенный вызов не оставляет мусора" "0" "$_leftover"

# Каталог исполнителя и каталог сборки — две стороны одного контракта.
# shellcheck disable=SC1091
. "$ROOT/lib/release_map.sh"
assert_eq "исполнитель и сборка знают один и тот же порядок" \
    "$(z2k_all_steps | tr '\n' ' ')" "$(au_step_order | tr '\n' ' ')"

# refresh-binaries крутит цикл ЗА ПАЙПОМ, то есть в подоболочке: присвоение
# оттуда не переживает конец цикла. Провал загрузки бинарника обязан выйти
# наружу ошибкой, а не успехом — иначе версия сдвинется, а движок останется
# старым, и снаружи это выглядит как «обновилось».
mkdir -p "$SB/tmp"
cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<'EOF'
{"files_sha256": {
  "z2k-warpd/builds/z2k-warpd-linux-testarch": "0000000000000000000000000000000000000000000000000000000000000000"
}, "current": "p-1"}
EOF
au_bin_goarch() { echo testarch; }
au_service_for_binary() { echo ""; }
au_download_repo_file() { return 1; }
assert_eq "refresh-binaries: обрыв загрузки виден снаружи" "1" "$(au_step_refresh_binaries; echo $?)"
au_download_repo_file() { printf 'подделка\n' > "$2"; }
assert_eq "refresh-binaries: чужая sha виден снаружи" "1" "$(au_step_refresh_binaries; echo $?)"

# ВЕТО СРАБАТЫВАЕТ НА ОШИБКАХ, А НЕ НА ПРЕДУПРЕЖДЕНИЯХ.
#
# z2k-config-validator.sh различает три исхода: 0 — чисто, 1 — предупреждения
# («дублирующийся фильтр между профилями» и подобное), 2 — ошибки, nfqws2 может
# не запуститься. Наивное «любой ненулевой код = не прошло» превращает штатное
# предупреждение в отказ обновления с откатом — а на роутере владельца такое
# предупреждение есть прямо сейчас, то есть откатывалось бы КАЖДОЕ обновление,
# объявившее validate-config.
mkdir -p "$SB/zd"
ZAPRET2_DIR="$SB/zd"; export ZAPRET2_DIR
_mkval() { printf '#!/bin/sh\nexit %s\n' "$1" > "$SB/zd/z2k-config-validator.sh"; chmod +x "$SB/zd/z2k-config-validator.sh"; }
_mkval 0; assert_eq "валидатор: чисто — идём дальше"          "0" "$(au_step_validate_config; echo $?)"
_mkval 1; assert_eq "валидатор: предупреждения — идём дальше" "0" "$(au_step_validate_config; echo $?)"
_mkval 2; assert_eq "валидатор: ошибки — ВЕТО"                "1" "$(au_step_validate_config; echo $?)"
_mkval 127; assert_eq "валидатор: неизвестный код — ВЕТО"     "1" "$(au_step_validate_config; echo $?)"
rm -f "$SB/zd/z2k-config-validator.sh"
assert_eq "валидатора нет — ВЕТО (доставка не сработала)"     "1" "$(au_step_validate_config; echo $?)"
unset ZAPRET2_DIR

# ОТОЗВАННЫЙ ФАЙЛ СНИМАЕТСЯ С РОУТЕРА.
#
# Сходимость умеет добавлять и обновлять, но не удалять: манифест описывает, что
# должно быть, и молчит о том, чего быть не должно. Обычно лишний файл просто
# лежит — но именно «просто лежит» и стоило обхода: 4pda.bin приехал ко всем,
# init увидел его существование и зарегистрировал блоб с невалидным именем.
mkdir -p "$SB/zd/files/fake"
: > "$SB/zd/files/fake/4pda.bin"
: > "$SB/zd/files/fake/tls_clienthello_4pda_to.bin"
ZAPRET2_DIR="$SB/zd" au_prune_orphans
assert_eq "отозванный файл снят" "0" "$([ -e "$SB/zd/files/fake/4pda.bin" ] && echo 1 || echo 0)"
assert_eq "соседний файл не тронут" "1" "$([ -e "$SB/zd/files/fake/tls_clienthello_4pda_to.bin" ] && echo 1 || echo 0)"
assert_eq "повторный вызов — не ошибка" "0" "$(ZAPRET2_DIR="$SB/zd" au_prune_orphans; echo $?)"

# Список отзыва ЯВНЫЙ, а не «всё, чего нет в манифесте»: удаление по разнице
# снесло бы пользовательские файлы в тех же каталогах — списки, ключи, свои
# стратегии, — и цена ошибки там несопоставима с пользой уборки.
: > "$SB/zd/files/fake/пользовательский.bin"
ZAPRET2_DIR="$SB/zd" au_prune_orphans
assert_eq "чужой файл в том же каталоге цел" "1" "$([ -e "$SB/zd/files/fake/пользовательский.bin" ] && echo 1 || echo 0)"

# REBUILD-PANEL СОБИРАЕТ КОНФИГ САМ, А НЕ ЗОВЁТ УСТАНОВЩИК.
#
# Прежняя версия звала ${zd}/webpanel/install.sh. Проверено на роутере: он там
# лежит, но исходники панели (www/, init.d/) рядом с ним есть только во время
# установки, поэтому запущенный на месте он отвечает «source files missing or
# empty — refusing to touch the installed panel» и возвращает 1. Шаг провалился
# бы на КАЖДОМ роутере — и не проваливался лишь потому, что ни разу не вызывался.
mkdir -p "$SB/zd/webpanel" "$SB/zd/www"
printf 'server.document-root = "@WWW_DIR@"\nserver.port = @PORT@\nserver.bind = "@BIND@"\n' > "$SB/zd/webpanel/lighttpd.conf.in"
printf '8088' > "$SB/zd/webpanel/port"
printf '192.168.1.1\n' > "$SB/zd/webpanel/bind"
# Зовём НАСТОЯЩУЮ функцию из lib/auto_update.sh, которую этот файл засорсил
# выше. Ниже по файлу лежат одноимённые заглушки — они для другой фазы теста, и
# линтер на раннере (версия строже локальной) видит только их, считая вызов
# опережающим. Порядок здесь несущий: сперва настоящие тела на песочнице, потом
# заглушки для проверки порядка и вето.
# shellcheck disable=SC2218
ZAPRET2_DIR="$SB/zd" au_step_rebuild_panel; _rc=$?
assert_eq "пересборка прошла" "0" "$_rc"
assert_eq "порт подставлен"   "1" "$(grep -c 'server.port = 8088' "$SB/zd/webpanel/lighttpd.conf")"
assert_eq "адрес подставлен"  "1" "$(grep -c '192.168.1.1' "$SB/zd/webpanel/lighttpd.conf")"
assert_eq "плейсхолдеров не осталось" "0" "$(grep -c '@[A-Z_]*@' "$SB/zd/webpanel/lighttpd.conf")"

# Незакрытый плейсхолдер — отказ, а не битый конфиг: панель с @PORT@ не поднимется.
printf 'server.port = @PORT@\nfoo = @UNKNOWN@\n' > "$SB/zd/webpanel/lighttpd.conf.in"
cp -f "$SB/zd/webpanel/lighttpd.conf" "$SB/zd/webpanel/lighttpd.conf.keep"
assert_eq "остался плейсхолдер — отказ" "1" "$(ZAPRET2_DIR="$SB/zd" au_step_rebuild_panel; echo $?)"
assert_eq "живой конфиг не испорчен" "0" "$(grep -c '@UNKNOWN@' "$SB/zd/webpanel/lighttpd.conf")"

# Нет шаблона или нет сохранённого порта — тоже отказ, а не молчаливый успех.
rm -f "$SB/zd/webpanel/lighttpd.conf.in"
assert_eq "нет шаблона — отказ" "1" "$(ZAPRET2_DIR="$SB/zd" au_step_rebuild_panel; echo $?)"
printf 'x = @PORT@\n' > "$SB/zd/webpanel/lighttpd.conf.in"; : > "$SB/zd/webpanel/port"
assert_eq "нет порта — отказ" "1" "$(ZAPRET2_DIR="$SB/zd" au_step_rebuild_panel; echo $?)"
unset ZAPRET2_DIR

# RESET-STATE УДАЛЯЕТ ТОТ ФАЙЛ, КОТОРЫЙ ЕСТЬ.
#
# Путь был неверный: state.tsv лежит в extra_strats/cache/autocircular/, а не в
# корне ${zd}. Шаг удалял несуществующий файл и возвращал успех — релиз,
# объявивший сброс, его бы не выполнил, и никто бы не узнал. Найдено прогоном на
# роутере владельца, а не по коду.
mkdir -p "$SB/zd/extra_strats/cache/autocircular"
printf 'rkn_tcp\thost\t1\t0\tauto\n' > "$SB/zd/extra_strats/cache/autocircular/state.tsv"
: > "$SB/zd/extra_strats/cache/autocircular/state.tsv.lock"
: > "$SB/zd/extra_strats/cache/autocircular/telemetry.tsv"
# Зовём НАСТОЯЩУЮ функцию из lib/auto_update.sh, которую этот файл засорсил
# выше. Ниже по файлу лежат одноимённые заглушки — они для другой фазы теста, и
# линтер на раннере (версия строже локальной) видит только их, считая вызов
# опережающим. Порядок здесь несущий: сперва настоящие тела на песочнице, потом
# заглушки для проверки порядка и вето.
# shellcheck disable=SC2218
ZAPRET2_DIR="$SB/zd" au_step_reset_state
assert_eq "state.tsv снят"        "0" "$([ -e "$SB/zd/extra_strats/cache/autocircular/state.tsv" ] && echo 1 || echo 0)"
assert_eq "lock тоже снят"        "0" "$([ -e "$SB/zd/extra_strats/cache/autocircular/state.tsv.lock" ] && echo 1 || echo 0)"
assert_eq "телеметрия не тронута" "1" "$([ -e "$SB/zd/extra_strats/cache/autocircular/telemetry.tsv" ] && echo 1 || echo 0)"
assert_eq "повторный вызов — успех" "0" "$(ZAPRET2_DIR="$SB/zd" au_step_reset_state; echo $?)"
unset ZAPRET2_DIR

# Исполнение: подменяем действия наблюдаемыми заглушками.
: > "$SB/done.log"
au_step_regen_strategies(){ echo regen-strategies >> "$SB/done.log"; }
au_step_regen_config()    { echo regen-config >> "$SB/done.log"; }
au_step_validate_config() { echo validate-config >> "$SB/done.log"; [ -f "$SB/bad" ] && return 1; return 0; }
au_step_refresh_binaries(){ echo refresh-binaries >> "$SB/done.log"; }
au_step_rebuild_panel()   { echo rebuild-panel >> "$SB/done.log"; }
au_step_reset_state()     { echo reset-state >> "$SB/done.log"; }
au_step_restart_service() { echo restart-service >> "$SB/done.log"; }

assert_eq "успешный прогон" "0" "$(au_run_steps regen-config validate-config restart-service; echo $?)"
assert_eq "порядок исполнения" "regen-config validate-config restart-service" "$(tr '\n' ' ' < "$SB/done.log" | sed 's/ $//')"

: > "$SB/done.log"; touch "$SB/bad"
assert_eq "валидация провалилась — rc 1" "1" "$(au_run_steps regen-config validate-config restart-service; echo $?)"
assert_eq "ВЕТО: перезапуска не было" "0" "$(grep -c restart-service "$SB/done.log")"
rm -f "$SB/bad"

: > "$SB/done.log"
assert_eq "неизвестный шаг → rc 2 (нужна полная установка)" "2" "$(au_run_steps regen-config шаг-из-будущего restart-service; echo $?)"
assert_eq "неизвестный шаг: ничего после него не выполнялось" "regen-config" "$(tr '\n' ' ' < "$SB/done.log" | sed 's/ $//')"

: > "$SB/done.log"
assert_eq "пустой набор шагов — успех, ничего не делаем" "0" "$(au_run_steps; echo $?)"
assert_eq "пустой набор: журнал пуст" "0" "$(wc -l < "$SB/done.log" | tr -d ' ')"

# Каждый шаг из каталога исполним: обёртка не должна молча промахиваться мимо
# имени функции.
_unimpl=""
for s in $(au_step_order); do
    au_run_step "$s" >/dev/null 2>&1
    [ "$?" = 2 ] && _unimpl="$_unimpl $s"
done
assert_eq "у каждого шага каталога есть исполнитель" "" "$_unimpl"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
