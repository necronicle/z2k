#!/bin/sh
# tests/test_warp_masque_tune.sh — подбор плеча десинка под MASQUE.
#
# ЗАЧЕМ. MASQUE — то, на чём WARP работал до нашего движка, и работал надёжно.
# Он выживает ТОЛЬКО под десинком: замер 2026-08-24 — сквозная проба 9 из 9 с
# ним против 0 из 9 без. Десинк применяется по SNI
# consumer-masque.cloudflareclient.com, то есть по записи ротации
# rkn_tcp/cloudflareclient.com — а какое плечо на неё встало, решал случай.
#
# Поле 2026-08-25: MASQUE поднимался за три секунды и умирал через семнадцать —
# «h2: connected», затем «health: h2:443 dead (<nil>)», без ошибки транспорта.
# На роутере владельца в тот же час тот же MASQUE вёз трафик (проба 200 за
# 0.16 с). Разница ровно в плече.
#
# Поле 2026-08-27, второй роутер: подбор перезапускал движок вслепую каждые
# шестнадцать секунд, пока тот стоял на WG-ступени, — плечо десинка по TCP на
# cloudflareclient.com не влияет на WireGuard никак. Отсюда всё, что проверяется
# ниже про форс, замок, курсор и снятие форса в конце.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W="$ROOT/files/z2k-warp.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM
TAB=$(printf '\t')

arm_of() { awk -F'\t' '$1=="rkn_tcp" && $2=="cloudflareclient.com|4" {print $3}' "$1"; }

# Подсовываем окружение: свой файл состояния, ручной «движок» и «готовность».
mk_env() {
    cat > "$SB/env.sh" <<INNER
ZAPRET2_DIR="$SB/zd"
WARP_STATE="$SB/state.tsv"
WARP_STATE_FALLBACK="$SB/state2.tsv"
WARP_INIT="$SB/init.sh"
WARP_TUNE_MAX=6
WARP_TUNE_RUN=4
WARP_TUNE_WAIT=2
WARP_READY_WAIT=2
WARP_TUNE_LOCK="$SB/tune.lock"
WARP_TUNE_CURSOR="$SB/tune.cursor"
$(sed -n '/^WARP_TUNE_KEY=/,/^}/p;/^warp_masque_tune/,/^}/p' "$W")
_wlog() { echo "[z2k-warp] \$*" >&2; }
warp_flag() { cat "$SB/flag" 2>/dev/null || echo 1; }
warp_ready() { [ -f "$SB/ready" ]; }
INNER
}

# Подставной init: пишет, с каким плечом и с каким форсом его дёрнули, и
# «поднимает» туннель, если плечо — good_arm.
mk_init() {
    cat > "$SB/init.sh" <<INNER
#!/bin/sh
echo "\$1 force=\${Z2K_WARP_FORCE:-none}" >> "$SB/calls"
a=\$(awk -F'\t' '\$1=="rkn_tcp" && \$2=="cloudflareclient.com|4" {print \$3}' "$SB/state.tsv")
echo "\$a" > "$SB/arm"
[ "\$1" = "stop" ] || [ -z "\$Z2K_WARP_FORCE" ] || echo "\$a" >> "$SB/arms"
if [ "\$1" != "stop" ] && [ "\$a" = "$1" ]; then touch "$SB/ready"; else rm -f "$SB/ready"; fi
exit 0
INNER
    chmod +x "$SB/init.sh"
}

prep_state() {
    printf '# z2k autocircular state\n# key\thost\tstrategy\tts\tmode\n' > "$SB/state.tsv"
    printf 'rkn_tcp%scloudflareclient.com|4%s7%s1%sauto\n' "$TAB" "$TAB" "$TAB" "$TAB" >> "$SB/state.tsv"
    cp "$SB/state.tsv" "$SB/state2.tsv"
    rm -rf "$SB/ready" "$SB/calls" "$SB/arms" "$SB/tune.cursor" "$SB/flag" "$SB/tune.lock"
}

run_tune() { sh -c ". '$SB/env.sh'; warp_masque_tune" 2>&1; }

mk_env

# --- третье плечо держит -----------------------------------------------------
prep_state
mk_init 3
run_tune >/dev/null 2>&1; rc=$?
assert_eq "подбор нашёл рабочее плечо" "0" "$rc"
assert_eq "остановился на третьем"     "3" "$(arm_of "$SB/state.tsv")"
assert_eq "закреплено как ручное"      "manual" "$(awk -F'\t' '$1=="rkn_tcp" && $2=="cloudflareclient.com|4" {print $5}' "$SB/state.tsv")"
assert_eq "запасной файл тоже обновлён" "3" "$(arm_of "$SB/state2.tsv")"
# Перебор идёт с движком, ЗАКРЕПЛЁННЫМ на h2: плечо десинка влияет только на
# MASQUE, и перезапускать движок, стоящий на WG-ступени, бессмысленно.
assert_eq "перебор идёт под форсом h2" "3" "$(grep -c 'restart force=h2' "$SB/calls")"
# И форс ВСЕГДА снимается последним перезапуском — иначе роутер остался бы без
# запасных WG-адресов навсегда.
assert_eq "последний перезапуск без форса" "restart force=none" "$(tail -1 "$SB/calls")"
assert_eq "курсор запомнил плечо"      "3" "$(cat "$SB/tune.cursor")"

# --- ни одно не держит: возвращаем как было ---------------------------------
prep_state
mk_init 99
run_tune >/dev/null 2>&1; rc=$?
assert_eq "неудача возвращает 1" "1" "$rc"
# Врать ротатору про «ручной выбор», который ничего не дал, значит запретить ему
# искать самому.
assert_eq "прежнее плечо возвращено" "7" "$(arm_of "$SB/state.tsv")"
# Заход ограничен: пятьдесят плеч по WARP_TUNE_WAIT — это двадцать минут без
# лестницы, и всё это время человек без WARP по нашей вине.
assert_eq "за заход ровно WARP_TUNE_RUN плеч" "4" "$(grep -c 'restart force=h2' "$SB/calls")"

# --- второй заход продолжает с курсора, а не с начала пула -------------------
mk_init 99
: > "$SB/calls"; : > "$SB/arms"
run_tune >/dev/null 2>&1
assert_eq "второй заход стартует с пятого" "5" "$(head -1 "$SB/arms")"
assert_eq "и обходит пул по кругу"         "5 6 1 2" "$(tr '\n' ' ' < "$SB/arms" | sed 's/ $//')"
# Курсор после первого захода = 4, после второго обходит потолок (6) и садится
# на 2: плечи 5,6,1,2.
assert_eq "курсор обошёл потолок пула" "2" "$(cat "$SB/tune.cursor")"

# --- второй подборщик не запускается ----------------------------------------
prep_state
mk_init 3
mkdir -p "$SB/tune.lock"
run_tune >/dev/null 2>&1; rc=$?
assert_eq "занятый замок — второй заход не идёт" "1" "$rc"
assert_eq "и движок никто не трогал" "0" "$([ -f "$SB/calls" ] && wc -l < "$SB/calls" | tr -d ' ' || echo 0)"
rmdir "$SB/tune.lock"

# --- WARP выключили посреди подбора -----------------------------------------
prep_state
mk_init 99
echo 0 > "$SB/flag"
run_tune >/dev/null 2>&1; rc=$?
assert_eq "выключенный WARP прекращает подбор" "1" "$rc"
assert_eq "и демон остаётся остановленным" "stop force=none" "$(tail -1 "$SB/calls")"

# --- подключение к enable ----------------------------------------------------
assert_eq "подбор запускается из enable" "1" "$(grep -c 'warp_masque_tune && warp_pbr_up' "$W")"
assert_eq "и переживает обрыв сессии"    "1" "$(grep -c "trap '' HUP" "$W")"
# Маршрут ставится только по ДОКАЗАННОЙ готовности — иначе игровой ipset уедет
# в чёрную дыру.
assert_eq "маршрут только после успеха"  "1" "$(grep -c 'warp_masque_tune && warp_pbr_up' "$W")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
