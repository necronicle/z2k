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
  *"-t mangle -S FORWARD"*)   echo "-A FORWARD -o br+ -p udp -m udp --sport 53 -m conntrack --ctstate ESTABLISHED -m string --string \"googlevideo\" --algo bm --to 65535 --icase -j NFQUEUE --queue-num 210 --queue-bypass" ;;
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
has "-t mangle -D OUTPUT" "$SWL" && has "--queue-num 210 --queue-bypass" "$SWL" \
    && ok "удаление снимает очередь ответов DNS в OUTPUT" || bad "очередь ответов DNS в OUTPUT остаётся после удаления"
has "-t mangle -D FORWARD" "$SWL" && has "--ctstate ESTABLISHED" "$SWL" \
    && ok "удаление снимает очередь ответов DNS в FORWARD" || bad "очередь ответов DNS в FORWARD остаётся после удаления"
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
      z2k_gvsub_ensure_observed_owner() { :; }
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

# --- 10. Очередь DNS в mangle OUTPUT и mangle FORWARD (--ctstate ESTABLISHED) --
{
    fn z2k_gvsub_enabled
    fn z2k_gvsub_dns_rule
    fn z2k_gvsub_legacy_purge
    fn z2k_gvsub_fw_start
    fn z2k_gvsub_fw_stop
} > "$TMP/fw-fns.sh"

cat > "$TMP/mock_ipt.py" <<'PY'
import json, os, sys
from pathlib import Path
fam = sys.argv[1]
args = sys.argv[2:]
st_path = Path(os.environ["FW_STATE"])
log_path = Path(os.environ["FW_CALLS"])
with log_path.open("a") as lf:
    lf.write(fam + " " + " ".join(args) + "\n")
st = json.loads(st_path.read_text()) if st_path.exists() else {}
if len(args) < 4 or args[0] != "-t":
    sys.exit(2)
table, op, chain = args[1], args[2], args[3]
key = f"{fam}/{table}/{chain}"
cur = st.get(key, [])
if op == "-C":
    spec = " ".join(args[4:])
    sys.exit(0 if spec in cur else 1)
if op == "-I":
    spec = " ".join(args[5:])
    st[key] = [spec] + cur
    st_path.write_text(json.dumps(st))
    sys.exit(0)
if op == "-D":
    spec = " ".join(args[4:])
    if spec not in cur:
        sys.exit(1)
    cur.remove(spec)
    st[key] = cur
    st_path.write_text(json.dumps(st))
    sys.exit(0)
if op in ("-F", "-X"):
    st.pop(key, None)
    st_path.write_text(json.dumps(st))
    sys.exit(0)
sys.exit(2)
PY

run_fw_case() (
    . "$TMP/fw-fns.sh"
    printf '#!/bin/sh\necho gvsub\n' > "$TMP/gvbin"
    chmod +x "$TMP/gvbin"
    Z2K_GVSUB_BIN="$TMP/gvbin"
    Z2K_GVSUB_QUEUE=210
    Z2K_GVSUB_CHAIN=Z2K_GVSUB
    Z2K_GVSUB_PID="$TMP/no.pid"
    Z2K_GV_SERVER_REPLY2=1
    FWTYPE=iptables
    DISABLE_IPV6="$1"
    FW_STATE="$TMP/fw-$2.json"
    FW_CALLS="$TMP/fw-$2.calls"
    MOD_LOG="$TMP/fw-$2.mods"
    export FW_STATE FW_CALLS
    rm -f "$FW_STATE" "$FW_CALLS" "$MOD_LOG"
    [ -z "${3:-}" ] || printf '%s' "$3" > "$FW_STATE"
    iptablesw()  { python3 "$TMP/mock_ipt.py" iptablesw "$@"; }
    ip6tablesw() { python3 "$TMP/mock_ipt.py" ip6tablesw "$@"; }
    z2k_insmod_fw() { printf '%s\n' "$1" >> "$MOD_LOG"; }
    eval "$4"
)

# Вызов без $5 совместим со старой сигнатурой (OUTPUT без conntrack), а $5=FORWARD
# ограничивает выходной интерфейс локальными мостами (-o br+) и проверяет ESTABLISHED.
OUT_RULE=$(. "$TMP/fw-fns.sh"; Z2K_GVSUB_QUEUE=210; echo_cmd() { printf '%s' "$*"; }; z2k_gvsub_dns_rule echo_cmd -I video)
FWD_RULE=$(. "$TMP/fw-fns.sh"; Z2K_GVSUB_QUEUE=210; echo_cmd() { printf '%s' "$*"; }; z2k_gvsub_dns_rule echo_cmd -I video current FORWARD)
[ "$OUT_RULE" = "-t mangle -I OUTPUT 1 ! -o lo -p udp --sport 53 -m string --algo bm --icase --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass" ] \
    && ok "z2k_gvsub_dns_rule по умолчанию ставит правило в OUTPUT без conntrack" \
    || bad "неожиданное правило OUTPUT: '$OUT_RULE'"
[ "$FWD_RULE" = "-t mangle -I FORWARD 1 -o br+ -p udp --sport 53 -m conntrack --ctstate ESTABLISHED -m string --algo bm --icase --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass" ] \
    && ok "z2k_gvsub_dns_rule для FORWARD ограничивает -o br+ и включает -m conntrack --ctstate ESTABLISHED" \
    || bad "неожиданное правило FORWARD: '$FWD_RULE'"

# Предзаполним устаревшие формы без --icase, проверим старт, идемпотентность
# повторного старта и полную очистку на стопе.
SEED='{"iptablesw/mangle/OUTPUT":["! -o lo -p udp --sport 53 -m string --algo bm --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass"],"iptablesw/mangle/FORWARD":["-o br+ -p udp --sport 53 -m conntrack --ctstate ESTABLISHED -m string --algo bm --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass"]}'
run_fw_case 0 dual "$SEED" '
    z2k_gvsub_fw_start
    cp "$FW_STATE" "$FW_STATE.after1"
    : > "$FW_CALLS"
    z2k_gvsub_fw_start
    cp "$FW_STATE" "$FW_STATE.after2"
    cp "$FW_CALLS" "$FW_CALLS.second"
    z2k_gvsub_fw_stop
'
if python3 - "$TMP/fw-dual.json.after1" "$TMP/fw-dual.json.after2" "$TMP/fw-dual.calls.second" "$TMP/fw-dual.json" <<'PYCHECK'
import json, sys
from pathlib import Path
s1 = json.loads(Path(sys.argv[1]).read_text())
s2 = json.loads(Path(sys.argv[2]).read_text())
second_calls = Path(sys.argv[3]).read_text().splitlines()
stopped = json.loads(Path(sys.argv[4]).read_text())
assert s1 == s2, f"повторный start_fw изменил состояние: {s1} != {s2}"
assert not any(" -I " in c for c in second_calls), f"повторный start_fw вставлял дубли: {second_calls}"
assert not any("-t nat -I" in c or "DNAT" in c or "443" in c for c in second_calls), second_calls
for fam in ("iptablesw", "ip6tablesw"):
    out_rules = s1.get(f"{fam}/mangle/OUTPUT", [])
    fwd_rules = s1.get(f"{fam}/mangle/FORWARD", [])
    assert len(out_rules) == 3, (fam, out_rules)
    assert len(fwd_rules) == 3, (fam, fwd_rules)
    assert all(r.startswith("! -o lo ") and "conntrack" not in r and "--icase" in r for r in out_rules), out_rules
    assert all(r.startswith("-o br+ ") and "! -o lo" not in r and "--sport 53 -m conntrack --ctstate ESTABLISHED -m string" in r and "--icase" in r for r in fwd_rules), fwd_rules
    assert not stopped.get(f"{fam}/mangle/OUTPUT"), stopped
    assert not stopped.get(f"{fam}/mangle/FORWARD"), stopped
PYCHECK
then
    ok "start/stop gvsub идемпотентно ведёт OUTPUT и FORWARD в обоих семействах и чистит старые формы"
else
    bad "ошибка жизненного цикла правил OUTPUT/FORWARD в start/stop"
fi

# При DISABLE_IPV6=1 правила ставятся в iptablesw (OUTPUT+FORWARD), а ip6tablesw пропускается;
# при отсутствии string/conntrack в /proc/net/ip_tables_matches подгружаются xt_string и xt_conntrack.
run_fw_case 1 v4only "" '
    grep() { [ "$2" != string ] && [ "$2" != conntrack ]; }
    z2k_gvsub_fw_start
'
if python3 - "$TMP/fw-v4only.json" "$TMP/fw-v4only.mods" <<'PYV4'
import json, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())
mods = Path(sys.argv[2]).read_text().splitlines()
assert len(s.get("iptablesw/mangle/OUTPUT", [])) == 3, s
assert len(s.get("iptablesw/mangle/FORWARD", [])) == 3, s
assert "ip6tablesw/mangle/OUTPUT" not in s and "ip6tablesw/mangle/FORWARD" not in s, s
assert "xt_string" in mods and "xt_conntrack" in mods, mods
PYV4
then
    ok "DISABLE_IPV6=1 пропускает ip6tablesw, а start подгружает xt_string и xt_conntrack"
else
    bad "DISABLE_IPV6=1 или подгрузка xt_conntrack сработали неверно"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
