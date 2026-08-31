#!/bin/sh
# tests/test_ip_hosts_cleanup_once.sh — чистка записей ip host обязана пройти
# РОВНО ОДИН РАЗ.
#
# Записи тянутся с 23.04.2026: их писал снятый четвёртый слой скачивания, по
# постоянной записи на каждую неудачную попытку. Убрать унаследованное надо, но
# повторять это по расписанию нельзя — чистка правит и сохраняет конфигурацию
# роутера, и делать это у человека за спиной каждый день незачем.
#
# Берётся НАСТОЯЩИЙ блок из планировщика и исполняется дважды с подставными
# ndmc и run_task. Структурная проверка здесь бесполезна: ломается не текст, а
# поведение — что уже случалось (шаг обновления молча пропускался у всех).
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHED="$DIR/files/z2k-scheduler.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/lib" "$SB/bin" "$SB/state"
cp "$DIR/lib/utils.sh" "$SB/lib/utils.sh"

cat > "$SB/bin/ndmc" <<'NDMC'
#!/bin/sh
case "$2" in
  "show running-config")
    [ -f "$STATE/removed" ] || {
      echo 'ip host raw.githubusercontent.com 185.199.108.133'
      echo 'ip host gh-proxy.com 172.67.1.1'
    }
    echo 'ip host example.org 9.9.9.9'
    ;;
  "system configuration save") ;;
  "no ip host raw.githubusercontent.com 185.199.108.133"|"no ip host gh-proxy.com 172.67.1.1")
    echo "$2" >> "$STATE/log"; : > "$STATE/removed" ;;
  *) echo "$2" >> "$STATE/log" ;;
esac
exit 0
NDMC
chmod +x "$SB/bin/ndmc"
: > "$SB/log"

# Настоящий блок из планировщика: от заголовка до конца условия.
BLOCK=$(awk '/^# Записи ip host от прежних версий/,/^fi$/' "$SCHED")
[ -n "$BLOCK" ] || { bad "не нашёл блок чистки в планировщике"; echo; echo "PASSED: $PASS"; echo "FAILED: $FAIL"; exit 1; }

run_block() {
    ( cd "$SB" && PATH="$SB/bin:$PATH" STATE="$SB" ZAPRET2_DIR="$SB" \
        sh -c "run_task() { shift 1; \"\$@\"; }; $BLOCK" >/dev/null 2>&1 )
}

# --- первый прогон: чистит и ставит отметку ---------------------------------
run_block
n=$(grep -c '^no ip host' "$SB/log" 2>/dev/null || echo 0)
[ "$n" -ge 2 ] && ok "первый прогон снял наши записи ($n)" \
               || bad "первый прогон не снял записи (снято $n)"
grep -q 'example.org' "$SB/log" 2>/dev/null \
    && bad "снята чужая запись example.org" \
    || ok "чужие записи не тронуты"
[ -f "$SB/state/ip-hosts-cleanup.done" ] && ok "отметка поставлена" \
                                         || bad "отметки нет — чистка повторится"

# --- второй прогон: не делает ничего ----------------------------------------
before=$(wc -l < "$SB/log" 2>/dev/null | tr -d ' ')
rm -f "$SB/removed"            # мусор снова «появился»
run_block
after=$(wc -l < "$SB/log" 2>/dev/null | tr -d ' ')
[ "$before" = "$after" ] && ok "второй прогон не делает ничего — чистка ровно одна" \
                         || bad "чистка выполнилась повторно ($before -> $after строк)"

# --- отметки нет — чистка снова возможна (не заперли себя навсегда) ---------
rm -f "$SB/state/ip-hosts-cleanup.done"
run_block
after2=$(wc -l < "$SB/log" 2>/dev/null | tr -d ' ')
[ "$after2" -gt "$after" ] && ok "без отметки чистка выполняется снова" \
                           || bad "без отметки чистка не запускается — починить руками нельзя"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
