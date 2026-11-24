#!/bin/sh
# tests/test_z2k_gv_autopilot.sh — сквозной тест автопилота YouTube (PR 3):
# Lua-логика, проводка в config_official.sh / S99zapret2.new / валидаторе / очистке.
# POSIX sh.

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-ap-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
nhas() { ! has "$1" "$2"; }

# 1. Lua-часть
if lua "$ROOT/tests/test_z2k_gv_autopilot.lua"; then
    ok "test_z2k_gv_autopilot.lua"
else
    bad "test_z2k_gv_autopilot.lua"
fi

# 2. Генератор конфига и тумблеры Z2K_YT_AUTOPILOT
make_root() {
    _r="$TMP/$1"
    mkdir -p "$_r/lua" "$_r/lists" "$_r/extra_strats/TCP/YT" "$_r/extra_strats/TCP/YT_GV" \
        "$_r/extra_strats/TCP/RKN" "$_r/extra_strats/UDP/YT" "$_r/state"
    cp "$ROOT/files/lua/z2k-gv-autopilot.lua" "$_r/lua/"
    cp "$ROOT/files/lua/z2k-preflight.lua" "$_r/lua/"
    cp "$ROOT/files/lua/z2k-quic-reject.lua" "$_r/lua/"
    cp "$ROOT/files/lua/z2k-alert.lua" "$_r/lua/"
    cp "$ROOT/files/lua/z2k-quic-silence.lua" "$_r/lua/"
    printf 'youtube.com\ngvt1.com\n' > "$_r/extra_strats/TCP/YT/List.txt"
    printf 'googlevideo.com\n' > "$_r/extra_strats/TCP/YT_GV/List.txt"
    printf 'rutracker.org\n' > "$_r/extra_strats/TCP/RKN/List.txt"
    printf 'youtube.com\ngooglevideo.com\ngvt1.com\n' > "$_r/extra_strats/UDP/YT/List.txt"
    printf 'ok.ru\n' > "$_r/lists/whitelist.txt"
    printf '142.250.74.1\n' > "$_r/tmp-ips"
    printf '%s' "$_r"
}

run_gen() {
    _gr="$1"
    (
        set +eu
        ZAPRET2_DIR="$_gr"; export ZAPRET2_DIR
        Z2K_GVSUB_IPS="$_gr/tmp-ips"; export Z2K_GVSUB_IPS
        # shellcheck disable=SC1091
        . "$ROOT/lib/utils.sh" >/dev/null 2>&1
        # shellcheck disable=SC1091
        . "$ROOT/lib/config_official.sh" >/dev/null 2>&1
        print_info() { :; }
        print_success() { :; }
        print_warning() { :; }
        print_error() { echo "ERR: $*" >&2; }
        create_official_config "$_gr/config" >/dev/null 2>&1
    ) || return 1
    cat "$_gr/config"
}

extract_opt() {
    # shellcheck disable=SC1090
    CFG_EXTRACT_PATH="$1" sh -c 'NFQWS2_OPT=""; . "$CFG_EXTRACT_PATH" >/dev/null 2>&1 || :; printf "%s" "$NFQWS2_OPT"'
}

R1=$(make_root fresh)
CFG1=$(run_gen "$R1")
OPT1=$(extract_opt "$R1/config")
if has 'Z2K_YT_AUTOPILOT=auto' "$CFG1"; then ok "fresh config emits Z2K_YT_AUTOPILOT=auto"; else bad "missing Z2K_YT_AUTOPILOT=auto"; fi
if has 'NFQWS2_TCP_PKT_OUT="45"' "$CFG1"; then ok "config emits NFQWS2_TCP_PKT_OUT=45"; else bad "missing NFQWS2_TCP_PKT_OUT=45"; fi
if has '--lua-desync=z2k_autopilot_tcp_fastfail --in-range=a --out-range=a --payload=all --lua-desync=z2k_preflight:' "$OPT1"; then
    ok "gv_tcp order: fastfail -> preflight"
else
    bad "gv_tcp fastfail/preflight order broken"
fi
if has '--lua-desync=z2k_preflight:pos=none:pieces=1:keepts:sni=www.google.com:timeout=4:v6 --lua-desync=z2k_autopilot_stall_guard' "$OPT1"; then
    ok "gv_tcp order: preflight -> stall_guard"
else
    bad "gv_tcp preflight/stall_guard order broken"
fi
if has '--lua-desync=z2k_autopilot_observe' "$OPT1"; then
    ok "yt_tcp has z2k_autopilot_observe"
else
    bad "yt_tcp missing z2k_autopilot_observe"
fi
if has '--lua-desync=z2k_autopilot_quic' "$OPT1"; then
    ok "quic has z2k_autopilot_quic"
else
    bad "quic missing z2k_autopilot_quic"
fi

# Валидатор принимает сгенерированный NFQWS2_OPT с новыми действиями
VAL_OUT=$(NFQWS2_OPT="" ZAPRET2_DIR="$R1" sh "$ROOT/files/z2k-config-validator.sh" "$R1/config" 2>&1 || true)
if nhas 'Неизвестное lua-desync действие' "$VAL_OUT"; then
    ok "config-validator accepts all z2k_autopilot_* actions"
else
    bad "config-validator rejected autopilot actions: $VAL_OUT"
fi

# Z2K_YT_AUTOPILOT=0 отключает автопилот и переживает регенерацию
R0=$(make_root opt0)
printf 'ENABLED=1\nZ2K_YT_AUTOPILOT=0\n' > "$R0/config"
CFG0=$(run_gen "$R0")
OPT0=$(extract_opt "$R0/config")
if has 'Z2K_YT_AUTOPILOT=0' "$CFG0"; then ok "Z2K_YT_AUTOPILOT=0 preserved across regen"; else bad "Z2K_YT_AUTOPILOT=0 lost"; fi
if nhas 'z2k_autopilot_' "$OPT0"; then ok "Z2K_YT_AUTOPILOT=0 removes z2k_autopilot_* actions"; else bad "z2k_autopilot_* leaked when Z2K_YT_AUTOPILOT=0"; fi
if has 'z2k_preflight:pos=none:pieces=1:keepts:sni=www.google.com:timeout=4:v6:autopilot=0' "$OPT0"; then
    ok "Z2K_YT_AUTOPILOT=0 sets :autopilot=0 on preflight"
else
    bad "missing :autopilot=0 on preflight"
fi

# Z2K_YT_AUTOPILOT=1 переживает регенерацию и даёт gvsub без REPLY2
R1EX=$(make_root opt1)
printf 'ENABLED=1\nZ2K_YT_AUTOPILOT=1\n' > "$R1EX/config"
CFG1EX=$(run_gen "$R1EX")
if has 'Z2K_YT_AUTOPILOT=1' "$CFG1EX"; then ok "Z2K_YT_AUTOPILOT=1 preserved across regen"; else bad "Z2K_YT_AUTOPILOT=1 lost"; fi

# Z2K_YT_QUIC_OFF=1 сохраняет z2k_quic_reject и передаёт :yt=0 в z2k_autopilot_quic
RQ=$(make_root yqoff)
printf 'ENABLED=1\nZ2K_YT_QUIC_OFF=1\n' > "$RQ/config"
run_gen "$RQ" >/dev/null
OPTQ=$(extract_opt "$RQ/config")
if has '--lua-desync=z2k_quic_reject' "$OPTQ" && has '--lua-desync=z2k_autopilot_quic:yt=0' "$OPTQ"; then
    ok "Z2K_YT_QUIC_OFF=1 keeps z2k_quic_reject and sets :yt=0"
else
    bad "Z2K_YT_QUIC_OFF=1 wiring wrong"
fi

# Z2K_QUIC_OFF=1 ставит безусловный z2k_quic_reject без z2k_autopilot_quic
RQA=$(make_root qoff)
printf 'ENABLED=1\nZ2K_QUIC_OFF=1\n' > "$RQA/config"
run_gen "$RQA" >/dev/null
OPTQA=$(extract_opt "$RQA/config")
if has '--lua-desync=z2k_quic_reject' "$OPTQA" && nhas 'z2k_autopilot_quic' "$OPTQA"; then
    ok "Z2K_QUIC_OFF=1 keeps z2k_quic_reject and skips z2k_autopilot_quic"
else
    bad "Z2K_QUIC_OFF=1 wiring wrong"
fi

# Phase 3 (google_tls): подключает fastfail + stall_guard, без z2k_preflight
RP3=$(make_root p3)
printf 'ENABLED=1\nZ2K_REFACTOR_PHASE3=1\nZ2K_GV_SERVER_REPLY2=0\n' > "$RP3/config"
run_gen "$RP3" >/dev/null
OPTP3=$(extract_opt "$RP3/config")
if has 'key=google_tls' "$OPTP3" && has 'z2k_autopilot_tcp_fastfail' "$OPTP3" \
   && has 'z2k_autopilot_stall_guard' "$OPTP3" && nhas 'z2k_preflight' "$OPTP3"; then
    ok "Phase 3 google_tls includes autopilot TCP guards without preflight"
else
    bad "Phase 3 wiring wrong"
fi

# 2a. Дополнительные edge-case Lua-тесты (TLS 1.2, TCP FIN/RST, gfe observe, /24 prefix, giveup cleanup)
if lua "$ROOT/tests/test_z2k_gv_autopilot_edge.lua"; then
    ok "test_z2k_gv_autopilot_edge.lua"
else
    bad "test_z2k_gv_autopilot_edge.lua failed"
fi

# 2b. Кастомная QUIC-стратегия без --in-range=a не утекает --in-range=x в circular
RCQ=$(make_root custom_quic)
mkdir -p "$RCQ/lists/custom-strategies"
printf '%s\n' '--lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=5:key=quic:nld=2 --lua-desync=fake:payload=quic_initial:repeats=2' \
    > "$RCQ/lists/custom-strategies/quic.txt"
run_gen "$RCQ" >/dev/null
OPTCQ=$(extract_opt "$RCQ/config")
if has '--payload=quic_initial --lua-desync=z2k_autopilot_quic --in-range=a --out-range=a --payload=all --lua-desync=circular' "$OPTCQ"; then
    ok "custom QUIC restores --in-range=a --out-range=a --payload=all before circular"
else
    bad "custom QUIC leaked --in-range=x or omitted --payload=all"
fi

# 2c. Phase 3 имеет --payload=all перед fastfail/stall_guard
if has '--in-range=a --out-range=a --payload=all --lua-desync=z2k_autopilot_tcp_fastfail --lua-desync=z2k_autopilot_stall_guard' "$OPTP3"; then
    ok "Phase 3 emits --payload=all before autopilot TCP guards"
else
    bad "Phase 3 missing --payload=all before autopilot TCP guards"
fi

# 2d. Z2K_GV_SERVER_REPLY2=0 + Z2K_YT_AUTOPILOT=1: --payload=all в gv_tcp, S99 не включает gvsub без Z2K_GV_SERVER_REPLY2=1
RSR0=$(make_root sr0_ap1)
printf 'ENABLED=1\nZ2K_GV_SERVER_REPLY2=0\nZ2K_YT_AUTOPILOT=1\n' > "$RSR0/config"
run_gen "$RSR0" >/dev/null
OPTSR0=$(extract_opt "$RSR0/config")
if has '--in-range=a --out-range=a --payload=all --lua-desync=z2k_autopilot_tcp_fastfail --lua-desync=z2k_autopilot_stall_guard' "$OPTSR0" \
   && nhas 'z2k_preflight' "$OPTSR0"; then
    ok "Z2K_GV_SERVER_REPLY2=0 + Z2K_YT_AUTOPILOT=1 emits --payload=all without preflight"
else
    bad "Z2K_GV_SERVER_REPLY2=0 + Z2K_YT_AUTOPILOT=1 wiring wrong"
fi
if grep -qE '^    \[ "\$\{Z2K_GV_SERVER_REPLY2:-1\}" = "1" \] \|\| return 1$' "$ROOT/files/S99zapret2.new"; then
    ok "S99 z2k_gvsub_enabled stays gated on Z2K_GV_SERVER_REPLY2 (no DNS blackhole)"
else
    bad "S99 z2k_gvsub_enabled has mismatched Z2K_YT_AUTOPILOT gate"
fi

# 2e. z2k_preflight_v6_gate сохраняет fastfail и stall_guard при удалении :v6
V6_OUT=$(ROOT_PATH="$ROOT" sh -c '
    NFQWS2_OPT="--in-range=a --out-range=a --payload=all --lua-desync=z2k_autopilot_tcp_fastfail --in-range=a --out-range=a --payload=all --lua-desync=z2k_preflight:pos=none:pieces=1:keepts:sni=www.google.com:timeout=4:v6 --lua-desync=z2k_autopilot_stall_guard"
    DISABLE_IPV6=1
    eval "$(awk "/^z2k_preflight_v6_gate\(\)/,/^}/" "$ROOT_PATH/files/S99zapret2.new")"
    z2k_preflight_v6_gate >/dev/null
    printf "%s" "$NFQWS2_OPT"
')
if has 'z2k_autopilot_tcp_fastfail' "$V6_OUT" && has 'z2k_autopilot_stall_guard' "$V6_OUT" \
   && has 'z2k_preflight:pos=none:pieces=1:keepts:sni=www.google.com:timeout=4' "$V6_OUT" \
   && nhas ':v6' "$V6_OUT"; then
    ok "z2k_preflight_v6_gate strips :v6 cleanly without breaking autopilot steps"
else
    bad "z2k_preflight_v6_gate corrupted NFQWS2_OPT ($V6_OUT)"
fi

# 3. Порядок загрузки в S99zapret2.new, NAT masquerade и уборка
L_AP=$(grep -n 'LUA_Z2K_GV_AUTOPILOT=' "$ROOT/files/S99zapret2.new" | head -1 | cut -d: -f1)
L_PF=$(grep -n 'LUA_Z2K_PREFLIGHT=' "$ROOT/files/S99zapret2.new" | head -1 | cut -d: -f1)
L_QR=$(grep -n 'LUA_Z2K_QUIC_REJECT=' "$ROOT/files/S99zapret2.new" | head -1 | cut -d: -f1)
if [ -n "$L_AP" ] && [ -n "$L_PF" ] && [ -n "$L_QR" ] && [ "$L_AP" -lt "$L_PF" ] && [ "$L_AP" -lt "$L_QR" ]; then
    ok "S99 loads z2k-gv-autopilot.lua before preflight and quic-reject"
else
    bad "S99 lua load order wrong ($L_AP / $L_PF / $L_QR)"
fi
if grep -q 'z2k_autopilot_stall_guard' "$ROOT/files/S99zapret2.new"; then
    ok "S99 NAT masquerade covers stall_guard"
else
    bad "S99 NAT masquerade missing stall_guard"
fi
if grep -q 'z2k-gv-policy.dat' "$ROOT/z2k_cleanup.sh" && grep -q 'z2k-gv-observed.tsv' "$ROOT/z2k_cleanup.sh"; then
    ok "z2k_cleanup.sh cleans policy.dat and observed.tsv"
else
    bad "z2k_cleanup.sh missing policy/observed cleanup"
fi
if grep -q 'z2k-gv-policy.dat' "$ROOT/lib/install.sh" && grep -q 'z2k-gv-observed.tsv' "$ROOT/lib/install.sh"; then
    ok "lib/install.sh _z2k_sweep_our_rules cleans policy.dat and observed.tsv"
else
    bad "lib/install.sh missing policy/observed cleanup"
fi
if awk '/^start_daemons\(\)/,/^}/' "$ROOT/files/S99zapret2.new" | awk '/z2k_gvsub_ensure_observed_owner/{o=NR} /standard_mode_daemons/{s=NR} END{exit (o && s && o < s) ? 0 : 1}'; then
    ok "S99 start_daemons fixes observed.tsv owner before standard_mode_daemons"
else
    bad "S99 start_daemons does not fix observed.tsv owner before daemon start"
fi
if ROOT_PATH="$ROOT" sh -c '
    eval "$(awk "/^z2k_gvsub_ensure_observed_owner\(\)/,/^}/" "$ROOT_PATH/files/S99zapret2.new")"
    d=$(mktemp -d); trap "rm -rf \"\$d\"" EXIT
    printf "x\n" > "$d/obs"
    chown() { echo "CHOWN:$1:$2" >> "$d/log"; }
    chmod() { echo "CHMOD:$1:$2" >> "$d/log"; }
    Z2K_GVSUB_OBSERVED="$d/obs" WS_USER=nobody z2k_gvsub_ensure_observed_owner
    grep -q "CHOWN:nobody:$d/obs" "$d/log" && grep -q "CHMOD:644:$d/obs" "$d/log" || exit 1
    printf "y\n" > "$d/real"
    if ln -s "$d/real" "$d/sym" 2>/dev/null && [ -L "$d/sym" ]; then
        Z2K_GVSUB_OBSERVED="$d/sym" WS_USER=nobody z2k_gvsub_ensure_observed_owner
        ! grep -q "$d/sym" "$d/log" || exit 1
    fi
'; then
    ok "z2k_gvsub_ensure_observed_owner updates regular file and skips symlink"
else
    bad "z2k_gvsub_ensure_observed_owner symlink/chown behavior broken"
fi
if grep -q 'files/lua/z2k-gv-autopilot.lua' "$ROOT/z2k.sh"; then
    ok "z2k.sh downloads files/lua/z2k-gv-autopilot.lua"
else
    bad "z2k.sh missing z2k-gv-autopilot.lua download"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
