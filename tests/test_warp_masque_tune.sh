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

# Подсовываем окружение: свой файл состояния, ручной «движок» и «готовность».
mk_env() {
    cat > "$SB/env.sh" <<INNER
ZAPRET2_DIR="$SB/zd"
WARP_STATE="$SB/state.tsv"
WARP_STATE_FALLBACK="$SB/state2.tsv"
WARP_INIT="$SB/init.sh"
WARP_TUNE_MAX=4
WARP_TUNE_WAIT=2
$(sed -n '/^WARP_TUNE_KEY=/,/^}/p;/^warp_masque_tune/,/^}/p' "$W")
_wlog() { echo "[z2k-warp] \$*" >&2; }
warp_ready() { [ -f "$SB/ready" ]; }
INNER
    printf '#!/bin/sh\ntouch "%s/restarted.$(cat "%s/arm" 2>/dev/null)"\n[ "$(cat "%s/arm" 2>/dev/null)" = "%s" ] && touch "%s/ready"\nexit 0\n' \
        "$SB" "$SB" "$SB" "$1" "$SB" > "$SB/init.sh"
    chmod +x "$SB/init.sh"
}

# Функция закрепления должна писать плечо ДО перезапуска — иначе движок
# поднимется на старом. Ловим это, читая state.tsv из подставного init.
prep_state() {
    printf '# z2k autocircular state\n# key\thost\tstrategy\tts\tmode\n' > "$SB/state.tsv"
    printf 'rkn_tcp%scloudflareclient.com|4%s7%s1%sauto\n' "$TAB" "$TAB" "$TAB" "$TAB" >> "$SB/state.tsv"
    cp "$SB/state.tsv" "$SB/state2.tsv"
    rm -f "$SB/ready" "$SB"/restarted.*
}

# --- третье плечо держит -----------------------------------------------------
prep_state
mk_env 3
cat > "$SB/init.sh" <<INNER
#!/bin/sh
a=\$(awk -F'\t' '\$1=="rkn_tcp" && \$2=="cloudflareclient.com|4" {print \$3}' "$SB/state.tsv")
echo "\$a" > "$SB/arm"
[ "\$a" = "3" ] && touch "$SB/ready"
exit 0
INNER
chmod +x "$SB/init.sh"
out=$(sh -c ". '$SB/env.sh'; warp_masque_tune" 2>&1); rc=$?
assert_eq "подбор нашёл рабочее плечо" "0" "$rc"
assert_eq "остановился на третьем"     "3" "$(awk -F'\t' '$1=="rkn_tcp" && $2=="cloudflareclient.com|4" {print $3}' "$SB/state.tsv")"
assert_eq "закреплено как ручное"      "manual" "$(awk -F'\t' '$1=="rkn_tcp" && $2=="cloudflareclient.com|4" {print $5}' "$SB/state.tsv")"
assert_eq "запасной файл тоже обновлён" "3" "$(awk -F'\t' '$1=="rkn_tcp" && $2=="cloudflareclient.com|4" {print $3}' "$SB/state2.tsv")"

# --- ни одно не держит: возвращаем как было ---------------------------------
prep_state
cat > "$SB/init.sh" <<'INNER'
#!/bin/sh
exit 0
INNER
chmod +x "$SB/init.sh"
out=$(sh -c ". '$SB/env.sh'; warp_masque_tune" 2>&1); rc=$?
assert_eq "неудача возвращает 1" "1" "$rc"
# Врать ротатору про «ручной выбор», который ничего не дал, значит запретить ему
# искать самому.
assert_eq "прежнее плечо возвращено" "7" "$(awk -F'\t' '$1=="rkn_tcp" && $2=="cloudflareclient.com|4" {print $3}' "$SB/state.tsv")"

# --- подключение к enable ----------------------------------------------------
assert_eq "подбор запускается из enable" "1" "$(grep -c 'warp_masque_tune && warp_pbr_up' "$W")"
assert_eq "и переживает обрыв сессии"    "1" "$(grep -c "trap '' HUP" "$W")"
# Маршрут ставится только по ДОКАЗАННОЙ готовности — иначе игровой ipset уедет
# в чёрную дыру.
assert_eq "маршрут только после успеха"  "1" "$(grep -c 'warp_masque_tune && warp_pbr_up' "$W")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
