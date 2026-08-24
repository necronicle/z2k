#!/bin/sh
# tests/test_release_steps.sh — последствия релиза объявляются данными.
#
# Список шагов НЕ пишется руками: он выводится из git-диффа по таблице
# release_map. Человек не может забыть то, чего не набирает — тот же приём,
# что уже спас нас на списке файлов.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/lib/release_map.sh"

m() { z2k_steps_merged "$@" | tr '\n' ' ' | sed 's/ $//'; }

assert_eq "три lua → один рестарт" "restart-service" \
    "$(m files/lua/a.lua files/lua/b.lua files/lua/c.lua)"
assert_eq "lua + конфиг + бинарь → перегенерация, проверка, бинарь, ОДИН рестарт" \
    "regen-config validate-config refresh-binaries restart-service" \
    "$(m files/lua/a.lua lib/config_official.sh z2k-warpd/builds/z2k-warpd-linux-mips)"
assert_eq "только списки → ничего" "" "$(m files/lists/a.txt files/lists/b.txt)"
assert_eq "стратегии идут перед конфигом" \
    "regen-strategies regen-config validate-config restart-service" \
    "$(m lib/strategies.sh)"
assert_eq "порядок не зависит от порядка файлов" \
    "$(m lib/strategies.sh z2k-warpd/builds/x webpanel/lighttpd.conf)" \
    "$(m webpanel/lighttpd.conf z2k-warpd/builds/x lib/strategies.sh)"
assert_eq "пустой набор" "" "$(m)"
assert_eq "список файлов со stdin" "regen-config validate-config restart-service" \
    "$(printf 'files/lua/a.lua\nlib/config_official.sh\n' | z2k_steps_merged - | tr '\n' ' ' | sed 's/ $//')"

# Контракт: у каждого шага из таблиц есть место в каноническом порядке.
missing=""
for f in lib/strategies.sh lib/config_official.sh files/lua/x.lua webpanel/lighttpd.conf \
         z2k-warpd/builds/x files/S99zapret2.new files/fake/f files/extra_strats/a/Strategy.txt; do
    for s in $(z2k_steps_for "$f"); do
        z2k_all_steps | grep -qx "$s" || missing="$missing $s"
    done
done
assert_eq "все объявляемые шаги есть в порядке исполнения" "" "$missing"

# Бинарник шагов требует, а доставляемым НЕ считается: цель зависит от арки и в
# install_map его нет. Если release.sh посчитает шаги по списку заявленного, а не
# по всему диффу, релиз с новым движком приедет без refresh-binaries — файл на
# месте, сервис на старом.
assert_eq "бинарник в одиночку даёт refresh-binaries" "refresh-binaries" \
    "$(m z2k-warpd/builds/z2k-warpd-linux-arm64)"
if grep -q 'z2k_steps_merged - < "\$CHANGED"' "$ROOT/scripts/release.sh"; then
    ok "шаги считаются по всему диффу, а не по списку заявленного"
else
    no "шаги считаются по всему диффу" "z2k_steps_merged - < \$CHANGED" "по \$DELIVERABLE — бинарники выпадут"
fi

# release.sh обязан объявлять шаги, а не оставлять их человеку.
REL="$ROOT/scripts/release.sh"
if grep -q 'z2k_steps_merged' "$REL"; then
    ok "release.sh выводит шаги из диффа"
else
    no "release.sh выводит шаги из диффа" "вызов z2k_steps_merged" "не найден"
fi
if grep -q '"steps"' "$REL"; then
    ok "шаги попадают в запись релиза"
else
    no "шаги попадают в запись релиза" "поле steps" "не найдено"
fi
# type и changed_files пишутся БЕССРОЧНО: старый апдейтер, встретив запись без
# type, посчитает её патчем без файлов, ничего не доставит и СДВИНЕТ версию.
for _f in '"type"' '"changed_files"' '"full_install"'; do
    if grep -q "$_f" "$REL"; then ok "запись релиза несёт $_f"
    else no "запись релиза несёт $_f" "поле есть" "нет"; fi
done

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
