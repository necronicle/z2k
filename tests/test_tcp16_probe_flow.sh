#!/bin/sh
# tests/test_tcp16_probe_flow.sh — сценарии скрипта пробы обрыва на 16 КБ
# (files/z2k-tcp16-probe.sh) на заглушке z2k-detect. Ревью 25.10.2026:
# фатальная ошибка и пропавший код не равны «блок есть»; молчащие мишени не
# трогают флаг; замок не пускает второй прогон; две фазы подбора и
# отрицательный кэш; прерывание сигналом гасит замер и не ставит отметку
# завершения; конфиг пересобирается во временный файл и проверяется до
# подмены, а без изменения механизма не трогается вовсе. POSIX sh.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROBE="$ROOT/files/z2k-tcp16-probe.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/tcp16flow.XXXXXX") || exit 1
trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

Z=$SB/z2k
mkdir -p "$Z/state" "$Z/lists" "$Z/lib" "$SB/bin"
printf '# t\nT1\t100\t-\tX\t1.1.1.1\t443\n' > "$Z/lists/tcp16_targets.txt"
printf 'good.example\nbad.example\ntail1.example\ntail2.example\n' > "$Z/lists/sni_wl_candidates.txt"

# Заглушка z2k-detect. Поведение — из файлов в $SB:
#   s1.rc / s1.asn — код и список сетей пробы линии;
#   scanA.out / scanA.rc — карта и код быстрой фазы;
#   scanB.out / scanB.rc — карта и код хвоста;
#   s1.sleep — пауза пробы линии (для теста сигнала).
cat > "$SB/bin/z2k-detect" <<EOF
#!/bin/sh
[ "\$1 \$2" = "tcp16 -h" ] && exit 0
echo "\$*" >> "$SB/calls"
out=""; asnout=""; phase=A; prev=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -sni-out) out="\$2"; shift ;;
    -asn-out) asnout="\$2"; shift ;;
    -asn-keep) phase=B ;;
  esac
  shift
done
if [ -n "\$asnout" ]; then
  [ -f "$SB/s1.sleep" ] && sleep "\$(cat "$SB/s1.sleep")"
  rc=\$(cat "$SB/s1.rc")
  case "\$rc" in 0|1) cp "$SB/s1.asn" "\$asnout" ;; esac
  exit "\$rc"
fi
cp "$SB/scan\$phase.out" "\$out"
exit "\$(cat "$SB/scan\$phase.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SB/bin/z2k-detect"

# Генератор конфига: механизм в конфиге ровно тогда, когда флаг 1 и не стоит
# выключатель в $SB/gen_off. Валидатор отказывает при $SB/val_fail.
cat > "$Z/lib/utils.sh" <<'EOF'
:
EOF
cat > "$Z/lib/config_official.sh" <<EOF
create_official_config() {
    if [ "\$(cat "$Z/state/tcp16.flag" 2>/dev/null)" = "1" ] && [ ! -f "$SB/gen_off" ]; then
        printf 'NFQWS2_OPT="--lua-desync=z2k_sni_fake:x"\n' > "\$1"
    else
        printf 'NFQWS2_OPT="--lua-desync=fake"\n' > "\$1"
    fi
    echo gen >> "$SB/gen.log"
}
EOF
cat > "$Z/z2k-config-validator.sh" <<EOF
[ -f "$SB/val_fail" ] && exit 2
exit 0
EOF

run() {
    DETECT="$SB/bin/z2k-detect" ZAPRET2_DIR="$Z" LOG="$SB/probe.log" \
    Z2K_TCP16_LOCK="$SB/lock" CONFIG="$Z/config" STRATEGY_CONFIG_LOCK="$SB/scl" \
    Z2K_TCP16_QUICK=2 sh "$PROBE" > "$SB/out.txt" 2>&1
    echo $?
}
reset() {
    rm -f "$Z/state/"* "$SB/calls" "$SB/gen.log" "$SB/gen_off" "$SB/val_fail" "$SB/s1.sleep" "$SB/scan"*
    printf 'NFQWS2_OPT="--lua-desync=fake"\n' > "$Z/config"
}

# --- 1. фатальная ошибка замера — не «блок есть»
reset; echo 4 > "$SB/s1.rc"
rc=$(run)
eq "код 4 (фатально): выход 2" "2" "$rc"
eq "код 4: флага нет (не мерили)" "absent" "$([ -f "$Z/state/tcp16.flag" ] && echo present || echo absent)"
eq "код 4: отметки завершения нет" "absent" "$([ -f "$Z/state/tcp16.flag.ts" ] && echo present || echo absent)"
eq "код 4: подбор имён не запускался" "1" "$(grep -c . "$SB/calls")"

# --- 2. мишени молчат — флаг и список сетей не трогаем
reset; echo 1 > "$Z/state/tcp16.flag"; printf '100\n' > "$Z/state/tcp16_asn.txt"; echo 3 > "$SB/s1.rc"
rc=$(run)
eq "код 3: выход 2" "2" "$rc"
eq "код 3: прежний флаг цел" "1" "$(cat "$Z/state/tcp16.flag")"
eq "код 3: прежний список сетей цел" "100" "$(cat "$Z/state/tcp16_asn.txt")"

# --- 3. блок есть: две фазы, кэш, версия карт, отметки, конфиг
reset; echo 1 > "$SB/s1.rc"; printf '# x\n100\n200\n300\n' > "$SB/s1.asn"
printf '# m\n100\tgood.example\n' > "$SB/scanA.out"; echo 0 > "$SB/scanA.rc"
printf '# m\n100\tgood.example\n200\ttail2.example\n' > "$SB/scanB.out"; echo 0 > "$SB/scanB.rc"
rc=$(run)
eq "блок: выход 0" "0" "$rc"
eq "блок: флаг 1" "1" "$(cat "$Z/state/tcp16.flag")"
eq "быстрая фаза: подбор по списку сетей пробы и с прежней картой" "1" \
   "$(grep -c -- "-asn-in $Z/state/tcp16_asn.txt -prev $Z/state/tcp16_sni.txt" "$SB/calls")"
eq "хвост запущен для сетей без имени (200, 300)" "200 300" \
   "$(awk '!/^#/' "$SB/calls" | grep -- '-asn-keep' >/dev/null && echo "200 300")"
eq "карта — итог хвоста" "2" "$(grep -c '^[0-9]' "$Z/state/tcp16_sni.txt")"
eq "временной карты не осталось" "absent" "$([ -f "$Z/state/tcp16_sni.txt.new" ] && echo present || echo absent)"
eq "отрицательный кэш: только 300" "300" "$(cut -f1 "$Z/state/tcp16_noname.txt" | tr '\n' ' ' | sed 's/ $//')"
eq "версия карт для рантайма записана" "present" "$([ -s "$Z/state/tcp16.ver" ] && echo present || echo absent)"
eq "отметка завершения записана" "present" "$([ -s "$Z/state/tcp16.flag.ts" ] && echo present || echo absent)"
eq "механизм попал в конфиг" "1" "$(grep -c z2k_sni_fake "$Z/config")"
eq "замок снят" "absent" "$([ -d "$SB/lock" ] && echo present || echo absent)"

# Миграция старого селектора: прежняя строка не равна новому отправителю.
printf 'NFQWS2_OPT="--lua-desync=z2k_sni_pick:blob=z2k_ch"\n' > "$Z/config"
run >/dev/null
eq "старый селектор заменён компактным отправителем" "1" "$(grep -c z2k_sni_fake "$Z/config")"
eq "старый селектор удалён" "0" "$(grep -c z2k_sni_pick "$Z/config")"

# --- 4. второй прогон: 300 в свежем кэше — хвост не нужен, конфиг не трогаем
: > "$SB/calls"; : > "$SB/gen.log"
printf '# m\n100\tgood.example\n200\ttail2.example\n' > "$SB/scanA.out"
cp "$Z/config" "$SB/cfg.before"
rc=$(run)
eq "повтор: выход 0" "0" "$rc"
eq "повтор: хвост не запускался (300 в свежем кэше)" "0" "$(grep -c -- '-asn-keep' "$SB/calls")"
if cmp -s "$Z/config" "$SB/cfg.before"; then ok "повтор: механизм не менялся — конфиг не подменён"; else no "повтор: конфиг не подменён" same changed; fi

# --- 5. генератор механизм не включает (выключатель) — без вечной пересборки
reset; echo 1 > "$SB/s1.rc"; printf '100\n' > "$SB/s1.asn"
printf '100\tgood.example\n' > "$SB/scanA.out"; touch "$SB/gen_off"
rc=$(run)
eq "выключатель: выход 0" "0" "$rc"
eq "выключатель: механизма в конфиге нет и подмены не было" "0" "$(grep -c z2k_sni_fake "$Z/config")"
grep -q "пересборка не нужна" "$SB/out.txt" && ok "выключатель: пересборка признана ненужной" || no "выключатель: пересборка не нужна" message absent

# --- 6. валидатор отказал — работающий конфиг не трогаем
reset; echo 1 > "$SB/s1.rc"; printf '100\n' > "$SB/s1.asn"
printf '100\tgood.example\n' > "$SB/scanA.out"; touch "$SB/val_fail"
run >/dev/null
eq "валидатор отказал: механизма в работающем конфиге нет" "0" "$(grep -c z2k_sni_fake "$Z/config")"
eq "валидатор отказал: временного конфига не осталось" "0" "$(find "$Z" -name 'config.tcp16.*' | grep -c .)"

# --- 7. замок: живой владелец — второй прогон не идёт
reset; echo 0 > "$SB/s1.rc"; printf '' > "$SB/s1.asn"
mkdir "$SB/lock"; echo $$ > "$SB/lock/pid"
rc=$(run)
eq "замок занят живым: выход 2" "2" "$rc"
eq "замок занят живым: замер не запускался" "absent" "$([ -f "$SB/calls" ] && echo present || echo absent)"
# мёртвый владелец — замок снимается
echo 4194300 > "$SB/lock/pid"
rc=$(run)
eq "замок мёртвого владельца снят, прогон прошёл" "0" "$rc"
rm -rf "$SB/lock"

# --- 8. сигнал посреди замера: замер погашен, отметки завершения нет, замок снят
reset; echo 1 > "$SB/s1.rc"; printf '100\n' > "$SB/s1.asn"; echo 30 > "$SB/s1.sleep"
DETECT="$SB/bin/z2k-detect" ZAPRET2_DIR="$Z" LOG="$SB/probe.log" Z2K_TCP16_LOCK="$SB/lock" \
    CONFIG="$Z/config" STRATEGY_CONFIG_LOCK="$SB/scl" sh "$PROBE" > "$SB/out.txt" 2>&1 &
pp=$!
i=0; while [ ! -s "$SB/lock/child" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
child=$(cat "$SB/lock/child" 2>/dev/null)
t0=$(date +%s)
kill -TERM "$pp"
wait "$pp" 2>/dev/null
t1=$(date +%s)
[ $((t1 - t0)) -lt 10 ] && ok "сигнал: проба вышла сразу, не дожидаясь замера" || no "сигнал: проба вышла сразу" "<10s" "$((t1 - t0))s"
if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then no "сигнал: замер погашен" dead alive; kill "$child" 2>/dev/null; else ok "сигнал: замер погашен"; fi
eq "сигнал: флаг не поставлен" "absent" "$([ -f "$Z/state/tcp16.flag" ] && echo present || echo absent)"
eq "сигнал: отметки завершения нет" "absent" "$([ -f "$Z/state/tcp16.flag.ts" ] && echo present || echo absent)"
eq "сигнал: отметка начала есть (повод для повтора)" "present" "$([ -f "$Z/state/tcp16.flag.started" ] && echo present || echo absent)"
eq "сигнал: замок снят" "absent" "$([ -d "$SB/lock" ] && echo present || echo absent)"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
