#!/bin/sh
# tests/test_au_cleanup_step.sh — шаг обновления cleanup-ip-hosts обязан
# ДЕЙСТВИТЕЛЬНО снимать записи, а не сообщать, что пропустил.
#
# Повод: жалоба 31.08.2026 — «[au] cleanup-ip-hosts: функция недоступна,
# пропускаю». Шаг не работал ни у кого и никогда: функция жила в install.sh, а
# апдейтер его не подключает. Код возврата у пропуска НОЛЬ, поэтому обновление
# шло дальше, и снаружи всё выглядело исправным.
#
# Поэтому здесь не проверяется ни код возврата, ни расположение функции —
# запускается сам шаг с подставным ndmc, и смотрится, что записи сняты.
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/lib" "$SB/bin" "$SB/state"
cp "$DIR/lib/utils.sh" "$SB/lib/utils.sh"
cp "$DIR/lib/auto_update.sh" "$SB/lib/auto_update.sh"
# Генератор конфига апдейтер подключает по тому же пути; для этого шага он не
# нужен, но без файла au_gen_libs_source не найдёт каталог.
printf '#!/bin/sh\ncreate_official_config() { return 0; }\n' > "$SB/lib/config_official.sh"

# Подставной ndmc: показывает записи и пишет полученные команды в журнал.
cat > "$SB/bin/ndmc" <<'NDMC'
#!/bin/sh
case "$2" in
  "show running-config")
    echo 'ip host raw.githubusercontent.com 185.199.108.133'
    echo 'ip host raw.githubusercontent.com 185.199.109.133'
    echo 'ip host cdn.jsdelivr.net 104.16.85.20'
    echo 'ip host gh-proxy.com 172.67.1.1'
    echo 'ip host www.instagram.com 157.240.1.1'
    echo 'ip host example.com 9.9.9.9'
    ;;
  "system configuration save") ;;
  *) echo "$2" >> "$NDMC_LOG" ;;
esac
exit 0
NDMC
chmod +x "$SB/bin/ndmc"
: > "$SB/ndmc.log"

OUT=$(cd "$SB" && PATH="$SB/bin:$PATH" NDMC_LOG="$SB/ndmc.log" ZAPRET2_DIR="$SB" \
      sh -c '. ./lib/auto_update.sh >/dev/null 2>&1; au_step_cleanup_ip_hosts' 2>&1)

case "$OUT" in
    *"функция недоступна"*) bad "шаг снова сообщает «функция недоступна» и ничего не делает" ;;
    *)                      ok  "шаг нашёл свою функцию" ;;
esac

# Наши записи — сняты.
missed=""
for h in raw.githubusercontent.com cdn.jsdelivr.net gh-proxy.com; do
    grep -q "^no ip host $h " "$SB/ndmc.log" || missed="$missed $h"
done
if [ -z "$missed" ]; then
    ok "записи github и зеркал сняты"
else
    bad "не сняты:$missed"
fi

# Обе записи одного домена, а не только первая.
n=$(grep -c '^no ip host raw.githubusercontent.com ' "$SB/ndmc.log" 2>/dev/null || echo 0)
if [ "$n" = "2" ]; then
    ok "сняты все адреса домена, а не первый попавшийся"
else
    bad "снято $n записей raw.githubusercontent.com, ожидалось 2"
fi

# Чужого не трогаем: instagram — рабочий пин обхода, example.com не наш вовсе.
if grep -qE '^no ip host (www\.instagram\.com|example\.com) ' "$SB/ndmc.log"; then
    bad "шаг снёс чужие записи: $(grep -E '^no ip host (www\.instagram\.com|example\.com) ' "$SB/ndmc.log" | head -2 | tr '\n' ' ')"
else
    ok "чужие записи не тронуты"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
