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

# --- 10. Транзитный DNS (Smart TV / телефоны): mangle OUTPUT + FORWARD --------
{
    fn z2k_gvsub_enabled
    fn z2k_gvsub_dns_rule
    fn z2k_gvsub_legacy_purge
    fn z2k_gvsub_fw_stop
    fn z2k_gvsub_fw_start
} > "$TMP/fw_fns.sh"

mkdir -p "$TMP/fwstate"
cat > "$TMP/fw_mock.py" <<'PYMOCK'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

p = Path(os.environ["FW_STATE"])
st = json.loads(p.read_text()) if p.exists() else {}
fam = sys.argv[1]
args = sys.argv[2:]
if len(args) < 4 or args[0] != "-t":
    sys.exit(2)
table, op, chain = args[1], args[2], args[3]
key = f"{fam}/{table}/{chain}"
rules = st.setdefault(key, [])
if op == "-C":
    spec = " ".join(args[4:])
    sys.exit(0 if spec in rules else 1)
elif op == "-I":
    spec = " ".join(args[5:])
    rules.insert(0, spec)
elif op == "-D":
    spec = " ".join(args[4:])
    if spec not in rules:
        sys.exit(1)
    rules.remove(spec)
elif op in ("-F", "-X"):
    st.pop(key, None)
p.write_text(json.dumps(st))
PYMOCK
chmod +x "$TMP/fw_mock.py"

FW_STATE="$TMP/fwstate/state.json"
export FW_STATE
(
    . "$TMP/fw_fns.sh"
    printf '#!/bin/sh\necho gvsub\n' > "$TMP/gvbin"
    chmod +x "$TMP/gvbin"
    Z2K_GVSUB_BIN="$TMP/gvbin"
    Z2K_GVSUB_QUEUE=210
    Z2K_GVSUB_CHAIN=Z2K_GVSUB
    Z2K_GVSUB_PID="$TMP/no.pid"
    Z2K_GV_SERVER_REPLY2=1
    FWTYPE=iptables
    DISABLE_IPV6=0
    z2k_insmod_fw() { :; }
    iptablesw()  { python3 "$TMP/fw_mock.py" iptablesw  "$@"; }
    ip6tablesw() { python3 "$TMP/fw_mock.py" ip6tablesw "$@"; }
    # Старая форма без --icase в FORWARD должна очищаться при старте.
    python3 - "$FW_STATE" <<'PYSEED'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "iptablesw/mangle/FORWARD": [
        "! -o lo -p udp --sport 53 -m string --algo bm --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass"
    ]
}))
PYSEED
    z2k_gvsub_fw_start
    z2k_gvsub_fw_start
)
python3 - "$FW_STATE" <<'PYCHK1'
import json, sys
from pathlib import Path
st = json.loads(Path(sys.argv[1]).read_text())
for fam in ("iptablesw", "ip6tablesw"):
    for ch in ("OUTPUT", "FORWARD"):
        rules = st.get(f"{fam}/mangle/{ch}", [])
        assert len(rules) == 3, f"{fam}/mangle/{ch}: {rules}"
        assert all("--icase" in r and "--queue-num 210 --queue-bypass" in r for r in rules), rules
PYCHK1
[ "$?" -eq 0 ] && ok "fw_start идемпотентно ставит 3 правила очереди 210 в OUTPUT и FORWARD (IPv4/IPv6)" \
    || bad "fw_start не обеспечил по 3 актуальных правила в OUTPUT и FORWARD"

(
    . "$TMP/fw_fns.sh"
    Z2K_GVSUB_QUEUE=210
    Z2K_GVSUB_CHAIN=Z2K_GVSUB
    DISABLE_IPV6=0
    iptablesw()  { python3 "$TMP/fw_mock.py" iptablesw  "$@"; }
    ip6tablesw() { python3 "$TMP/fw_mock.py" ip6tablesw "$@"; }
    z2k_gvsub_fw_stop
)
python3 - "$FW_STATE" <<'PYCHK2'
import json, sys
from pathlib import Path
st = json.loads(Path(sys.argv[1]).read_text())
for fam in ("iptablesw", "ip6tablesw"):
    for ch in ("OUTPUT", "FORWARD"):
        rules = st.get(f"{fam}/mangle/{ch}", [])
        assert rules == [], f"остались правила в {fam}/mangle/{ch}: {rules}"
PYCHK2
[ "$?" -eq 0 ] && ok "fw_stop снимает все правила очереди 210 и из OUTPUT, и из FORWARD" \
    || bad "fw_stop оставил правила в OUTPUT или FORWARD"

# --- 11. Диагностика z2k-diag.sh: print_gvsub и print_health ------------------
DIAG="$ROOT/files/z2k-diag.sh"
awk '/^print_gvsub\(\)/{p=1} p{print} p&&/^}/{exit}' "$DIAG" > "$TMP/diag_gvsub.sh"
awk '/^print_health\(\)/{p=1} p{print} p&&/^}/{exit}' "$DIAG" > "$TMP/diag_health.sh"

mkdir -p "$TMP/droot/lua" "$TMP/droot/extra_strats/TCP/RKN" "$TMP/dbin"
: > "$TMP/droot/lua/z2k-preflight.lua"
awk 'BEGIN{for(i=1;i<=1005;i++) print "d"i".example.com"}' > "$TMP/droot/extra_strats/TCP/RKN/List.txt"
printf '0.0.0.0/32\n::/128\n74.125.110.70\n2a00:1450:4001::9\n' > "$TMP/gv-ips-diag.txt"
printf '#!/bin/sh\necho gvsub\n' > "$TMP/dbin/gvsub-bin"
chmod +x "$TMP/dbin/gvsub-bin"

cat > "$TMP/dbin/iptables" <<'STUB'
#!/bin/sh
emit3() {
    echo "-A $1 ! -o lo -p udp -m udp --sport 53 -m string --string \"googlevideo\" --algo bm --icase -j NFQUEUE --queue-num 210 --queue-bypass"
    echo "-A $1 ! -o lo -p udp -m udp --sport 53 -m string --hex-string \"|016307796f757475626503636f6d00|\" --algo bm --icase -j NFQUEUE --queue-num 210 --queue-bypass"
    echo "-A $1 ! -o lo -p udp -m udp --sport 53 -m string --hex-string \"|046776743103636f6d00|\" --algo bm --icase -j NFQUEUE --queue-num 210 --queue-bypass"
}
case "$*" in
    *"-t mangle -S OUTPUT"*)  emit3 OUTPUT ;;
    *"-t mangle -S FORWARD"*)
        case "${MOCK_FWD_MODE:-3}" in
            0) ;;
            1) echo "-A FORWARD ! -o lo -p udp -m udp --sport 53 -m string --string \"googlevideo\" --algo bm --icase -j NFQUEUE --queue-num 210 --queue-bypass" ;;
            *) emit3 FORWARD ;;
        esac
        ;;
esac
exit 0
STUB
cp "$TMP/dbin/iptables" "$TMP/dbin/ip6tables"
cat > "$TMP/dbin/ip" <<'STUB'
#!/bin/sh
case "$*" in
    "-6 route show default") [ "${MOCK_V6_LEAK:-0}" = 1 ] && echo "default via fe80::1 dev eth3 metric 1024" ;;
    "-6 -o addr show scope global") [ "${MOCK_V6_LEAK:-0}" = 1 ] && echo "2: br0    inet6 2a00:1450:4001::1/64 scope global" ;;
esac
exit 0
STUB
chmod +x "$TMP/dbin/iptables" "$TMP/dbin/ip6tables" "$TMP/dbin/ip"

printf '%s\n' "$$" > "$TMP/live.pid"
GVSUB_OUT=$(
    PATH="$TMP/dbin:$PATH"
    ZAPRET2_DIR="$TMP/droot"
    Z2K_GVSUB_PID="$TMP/live.pid"
    Z2K_GVSUB_IPS="$TMP/gv-ips-diag.txt"
    Z2K_GVSUB_STATUS="$TMP/none.json"
    Z2K_GVSUB_LOG="$TMP/none.log"
    printf 'DISABLE_IPV6=0\n' > "$TMP/droot/config"
    . "$TMP/diag_gvsub.sh"
    print_gvsub
)
has "адресов видео     : 2 " "$GVSUB_OUT" && has "-A FORWARD" "$GVSUB_OUT" \
    && ok "print_gvsub показывает число накопленных IP (без sentinels) и очередь в FORWARD" \
    || bad "print_gvsub не показал число IP или FORWARD: $GVSUB_OUT"

run_health() {
    (
        PATH="$TMP/dbin:$PATH"
        export MOCK_FWD_MODE="${2:-3}" MOCK_V6_LEAK="${3:-0}"
        ZAPRET2_DIR="$TMP/droot"
        Z2K_GVSUB_BIN="$TMP/dbin/gvsub-bin"
        Z2K_GVSUB_PID="$4"
        printf '%s\n' "$1" > "$TMP/droot/config"
        mount() { echo "tmpfs on /opt type tmpfs (rw)"; }
        bitmap_port_ok() { echo yes; }
        pgrep() { echo 4242; }
        nfqueue_counts() { echo "2 4 1"; }
        df() { printf 'Filesystem 1K-blocks Used Available Use%%\n/dev/sda1 100000 1000 90000 1%%\n'; }
        nfqws_strategy_counts() { echo "10 3 0"; }
        nfqws_reasm_state() { echo off; }
        nfqws_first_packets_state() { echo 0; }
        clock_skew_vs_relay() { echo 0; }
        tg_user_disabled() { return 0; }
        . "$TMP/diag_health.sh"
        print_health
    )
}

H_OK=$(run_health "DISABLE_IPV6=0" 3 1 "$TMP/live.pid")
if ! has "DISABLE_IPV6=1" "$H_OK" && ! has "gvsub" "$H_OK" && ! has "очереди DNS YouTube" "$H_OK"; then
    ok "print_health молчит по YouTube/gvsub, когда IPv6 включён в z2k, gvsub работает и все 3/3 правила стоят"
else
    bad "ложное срабатывание print_health: $H_OK"
fi

H_NFT=$(run_health "$(printf 'DISABLE_IPV6=0\nFWTYPE=nftables')" 0 0 "$TMP/dead.pid")
if ! has "gvsub" "$H_NFT" && ! has "очереди DNS YouTube" "$H_NFT"; then
    ok "print_health не требует iptables-службу gvsub на стендах с FWTYPE=nftables"
else
    bad "ложное срабатывание print_health при FWTYPE=nftables: $H_NFT"
fi

H_V6=$(run_health "DISABLE_IPV6=1" 3 1 "$TMP/live.pid")
has "DISABLE_IPV6=1 в конфиге z2k, но на роутере активен глобальный IPv6" "$H_V6" \
    && ok "print_health ловит утечку YouTube по глобальному IPv6 при DISABLE_IPV6=1" \
    || bad "print_health не поймал утечку по IPv6: $H_V6"

H_DOWN=$(run_health "DISABLE_IPV6=0" 3 0 "$TMP/dead.pid")
has "служба DNS-наблюдения YouTube (z2k-detect gvsub) не запущена" "$H_DOWN" \
    && ok "print_health ловит остановленную службу gvsub" \
    || bad "print_health не поймал остановленный gvsub: $H_DOWN"

H_NOFWD=$(run_health "DISABLE_IPV6=0" 0 0 "$TMP/live.pid")
has "правила очереди DNS YouTube (210) неполные (OUTPUT=3/3, FORWARD=0/3)" "$H_NOFWD" \
    && ok "print_health ловит отсутствие правил очереди 210 в mangle FORWARD" \
    || bad "print_health не поймал отсутствие правил в FORWARD: $H_NOFWD"

H_PARTFWD=$(run_health "DISABLE_IPV6=0" 1 0 "$TMP/live.pid")
has "правила очереди DNS YouTube (210) неполные (OUTPUT=3/3, FORWARD=1/3)" "$H_PARTFWD" \
    && ok "print_health ловит частичную потерю правил очереди 210 (1/3) в mangle FORWARD" \
    || bad "print_health не поймал частичную потерю правил в FORWARD: $H_PARTFWD"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

