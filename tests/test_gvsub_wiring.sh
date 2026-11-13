#!/bin/sh
# tests/test_gvsub_wiring.sh — обвязка службы подмены плохих адресов googlevideo
# (z2k-detect gvsub) и пробы на IPv6.
#
# Звенья в разных файлах, каждое ломает механизм молча: цепочки первыми в
# PREROUTING (иначе движок обрабатывает соединение ПОСЛЕ переадресации и его
# пакеты уходят с адресом из локальной сети — стенд 09.11.2026), очередь для
# ответов DNS с --queue-bypass (без службы DNS обязан работать), SIGHUP службе
# после перестройки таблиц Keenetic, порядок остановки, ключ в генераторе,
# тумблер в панели. Код исполняется с подставными iptables, а не ищется grep'ом.
# POSIX sh (busybox ash).

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
S99="$ROOT/files/S99zapret2.new"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

TMP="${TMPDIR:-/tmp}/z2k-gvsub-wiring.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

fn() { awk -v f="$1" '$0 == f "()" || $0 == f "() {" {p=1} p{print} p&&/^}/{exit}' "$S99"; }
body() { fn "$1" | tr '\n' ' '; }

# DNS lifecycle and retired-key matrix execute the real init functions.
sh "$ROOT/tests/test_play_serverhello.sh" || exit 1

# --- 7. Доставка бинарника ------------------------------------------------------------
STEPS=$(sh -c ". '$ROOT/lib/release_map.sh' 2>/dev/null
    z2k_steps_for z2k-detect/builds/z2k-detect-linux-arm64 | tr '\n' ' '")
has "refresh-binaries" "$STEPS" && ok "новый z2k-detect доставляется обновлением" || bad "сборка z2k-detect не доставляется: '$STEPS'"

# --- 8. Удаление z2k снимает службу и её правила -------------------------------
SW=$(awk '/^_z2k_sweep_our_rules\(\)/{p=1} p{print} p&&/^}/{exit}' "$ROOT/lib/install.sh")
FE=$(awk '/^_z2k_foreign_engine\(\)/{p=1} p{print} p&&/^}/{exit}' "$ROOT/lib/install.sh")
mkdir -p "$TMP/sw"
cat > "$TMP/sw/iptables" <<'STUB'
#!/bin/sh
case "$*" in
  *"-t filter -S FORWARD"*) echo "-A FORWARD -j Z2K_GVSUB_Q" ;;
  *"-t nat -S PREROUTING"*)   echo "-A PREROUTING -j Z2K_GVSUB" ;;
  *"-t mangle -S OUTPUT"*)    echo "-A OUTPUT -p udp -m udp --sport 53 -m string --string \"googlevideo\" --algo bm --to 65535 -j NFQUEUE --queue-num 210 --queue-bypass" ;;
  *" -S "*) ;;
  *) echo "${0##*/} $*" >> "$SWLOG" ;;
esac
exit 0
STUB
cp "$TMP/sw/iptables" "$TMP/sw/ip6tables"; chmod +x "$TMP/sw/iptables" "$TMP/sw/ip6tables"
SWLOG="$TMP/swlog"; : > "$SWLOG"
( PATH="$TMP/sw:$PATH"; export SWLOG; pidof() { return 1; }; eval "$FE"; eval "$SW"
  ZAPRET2_DIR="$TMP/none" _z2k_sweep_our_rules )
SWL=$(cat "$SWLOG")
has "-t nat -D PREROUTING -j Z2K_GVSUB" "$SWL" && ok "удаление снимает крючок цепочки подмены" || bad "крючок Z2K_GVSUB остаётся после удаления"
has "--queue-num 210 --queue-bypass" "$SWL" && ok "удаление снимает очередь ответов DNS" || bad "очередь ответов DNS остаётся после удаления"
has "-t nat -X Z2K_GVSUB" "$SWL" && ok "удаление удаляет сами цепочки" || bad "цепочки Z2K_GVSUB остаются"
grep -q 'z2k-gvsub.pid' "$ROOT/z2k_cleanup.sh" && grep -q 'X Z2K_GVSUB' "$ROOT/z2k_cleanup.sh" \
    && ok "отдельный скрипт удаления тоже снимает службу и цепочки" || bad "z2k_cleanup.sh не знает о службе подмены"

# 10.11.2026: проверяем оба пути удаления, чтобы REJECT не оставался без службы.
check_quic_cleanup() {
    for cmd in '-D FORWARD -j Z2K_GVSUB_Q' '-F Z2K_GVSUB_Q' '-X Z2K_GVSUB_Q'; do
        for fam in iptables ip6tables; do
            has "$fam -w -t filter $cmd" "$1" && ok "$2 $fam: $cmd" || bad "$2 $fam: нет $cmd"
        done
    done
}
: > "$SWLOG"
( PATH="$TMP/sw:$PATH"; export SWLOG; pidof() { return 1; }; eval "$FE"; eval "$SW"
  ZAPRET2_DIR="$TMP/none" _z2k_sweep_our_rules )
check_quic_cleanup "$(cat "$SWLOG")" install
CLEAN=$(awk '/^for fw_tool in iptables ip6tables; do/{p=1} p{print} p&&/^done$/{exit}' "$ROOT/z2k_cleanup.sh")
: > "$SWLOG"
( PATH="$TMP/sw:$PATH"; export SWLOG; log_info() { :; }; eval "$CLEAN" )
check_quic_cleanup "$(cat "$SWLOG")" cleanup

# --- 9. Реальный запуск функции init: путь whitelist доходит отдельным аргументом.
fn z2k_gvsub_start > "$TMP/start.sh"
cat > "$TMP/capture" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$GVSUB_ARGS"
STUB
chmod +x "$TMP/capture"
for root in default "$TMP/custom root"; do
    ( . "$TMP/start.sh"
      z2k_gvsub_enabled() { return 0; }
      z2k_gvsub_stop() { :; }
      Z2K_GVSUB_BIN="$TMP/capture"
      Z2K_GVSUB_QUEUE=210
      Z2K_GVSUB_LOG="$TMP/start.log"
      Z2K_GVSUB_STATUS="$TMP/status"
      Z2K_GVSUB_PID="$TMP/start.pid"
      Z2K_GVSUB_IPS="$TMP/ips"
      DISABLE_IPV6=0
      GVSUB_ARGS="$TMP/args"; export GVSUB_ARGS
      if [ "$root" = default ]; then unset ZAPRET2_DIR; else ZAPRET2_DIR="$root"; fi
      z2k_gvsub_start >/dev/null
      wait "$(cat "$Z2K_GVSUB_PID")" )
    want="$root/lists/whitelist.txt"
    [ "$root" != default ] || want=/opt/zapret2/lists/whitelist.txt
    got=$(awk 'p {print; exit} $0 == "-whitelist" {p=1}' "$TMP/args")
    [ "$got" = "$want" ] && ok "start gvsub передаёт -whitelist: $root" \
        || bad "start gvsub: whitelist '$got', нужен '$want'"
done

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
