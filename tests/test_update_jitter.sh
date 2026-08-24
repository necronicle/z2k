#!/bin/sh
# tests/test_update_jitter.sh — ночные задачи расходятся по времени, а не бьют
# в одну минуту всем флотом.
#
# ЧТО СЛУЧИЛОСЬ. Разброс ночного обновления (0..90 мин) считался через `cksum`,
# которого на Entware НЕТ. Строка «не посчиталось — значит ноль» превращала
# сбой в «ноль у всех»: каждый роутер обновлялся ровно в 02:00:00. В логе
# владельца это видно дословно — fire в 02:00:20, done в 02:00:22, две секунды
# вместо сорока шести минут, которые дал бы его hostname.
#
# Поэтому здесь проверяется не только «джиттер считается», но и главное:
# ЛЮБОЙ запасной путь даёт РАЗНОЕ время на разных роутерах. Тихий сбой,
# собирающий флот в одну минуту, — это тот же баг под другим именем.
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT

# shellcheck disable=SC1091
. "$ROOT/lib/utils.sh" 2>/dev/null

# --- 1. значение в диапазоне ---
j=$(z2k_host_jitter 5400)
case "$j" in
    ''|*[!0-9]*) no "джиттер — число" "число" "[$j]" ;;
    *) if [ "$j" -ge 0 ] && [ "$j" -lt 5400 ]; then ok "джиттер в диапазоне 0..5399 ($j)"
       else no "джиттер в диапазоне" "0..5399" "$j"; fi ;;
esac

# --- 2. стабилен на одном хосте (роутер не должен «плавать» ночь от ночи) ---
assert_eq "джиттер стабилен между вызовами" "$j" "$(z2k_host_jitter 5400)"

# --- 3. разный на разных хостах ---
mkdir -p "$SB/bin"
mk_host() { printf '#!/bin/sh\necho %s\n' "$1" > "$SB/bin/hostname"; chmod +x "$SB/bin/hostname"; }
mk_host Keenetic-0235; a=$(PATH="$SB/bin:$PATH" z2k_host_jitter 5400)
mk_host Keenetic-9981; b=$(PATH="$SB/bin:$PATH" z2k_host_jitter 5400)
mk_host Keenetic-4417; c=$(PATH="$SB/bin:$PATH" z2k_host_jitter 5400)
if [ "$a" != "$b" ] || [ "$b" != "$c" ]; then ok "разные хосты — разное время ($a/$b/$c)"
else no "разные хосты — разное время" "различаются" "$a/$b/$c"; fi

# --- 4. БЕЗ md5sum и sha256sum: запасной путь НЕ обязан быть детерминированным,
#        но обязан быть РАЗНЫМ, а не нулём у всех ---
cat > "$SB/bin/md5sum" <<'EOF'
#!/bin/sh
exit 127
EOF
cp "$SB/bin/md5sum" "$SB/bin/sha256sum"
cp "$SB/bin/md5sum" "$SB/bin/cksum"
chmod +x "$SB/bin/md5sum" "$SB/bin/sha256sum" "$SB/bin/cksum"
zeros=0; vals=""
i=0
while [ "$i" -lt 6 ]; do
    v=$(PATH="$SB/bin:$PATH" sh -c ". '$ROOT/lib/utils.sh' 2>/dev/null; z2k_host_jitter 5400")
    vals="$vals $v"
    [ "$v" = "0" ] && zeros=$((zeros+1))
    i=$((i+1))
done
assert_eq "без хешей: не ноль у всех" "0" "$zeros"
uniq_n=$(printf '%s\n' $vals | sort -u | wc -l | tr -d ' ')
if [ "$uniq_n" -gt 1 ]; then ok "без хешей: значения расходятся ($vals )"
else no "без хешей: значения расходятся" ">1 различных" "$vals"; fi

# --- 5. контракт: cksum больше не используется, «пусто → 0» не вернулось ---
# Запрещён ВЫЗОВ, а не упоминание: почему cksum здесь нельзя — ценный
# комментарий, и он должен пережить этот тест. Комментарии срезаем.
for f in files/z2k-auto-update.sh files/z2k-update-lists.sh files/z2k-stats-upload.sh; do
    assert_eq "$(basename $f): не зовёт отсутствующий cksum" "0" \
        "$(sed 's/#.*//' "$ROOT/$f" | grep -cE '(\||^|;|\$\()[[:space:]]*cksum([[:space:]]|$)')"
done
assert_eq "auto-update: нет тихого «пусто → 0»" "0" "$(grep -c 'JITTER=0' "$ROOT/files/z2k-auto-update.sh")"

# --- 6. ночные задачи флота расходятся: разброс есть у всех трёх ---
for f in files/z2k-auto-update.sh files/z2k-update-lists.sh files/z2k-stats-upload.sh; do
    assert_eq "$(basename $f): разброс применяется" "yes" \
        "$(grep -q 'z2k_host_jitter' "$ROOT/$f" && echo yes || echo no)"
done

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
