#!/bin/sh
# tests/test_webpanel_autopilot.sh — проверка PR 4:
#   * live /status -> объект autopilot из z2k-gv-policy.dat + observed + gvsub;
#   * невалидные/отсутствующие/искажённые файлы не роняют JSON;
#   * tri-state оверрайды gv-preflight / yt-quic-off / quic-off (auto|1|off|0);
#   * yt-autopilot (auto|1|0) принудительно включает Z2K_GV_SERVER_REPLY2=1;
#   * генератор config_official.sh и сохранение флагов при регенерации;
#   * при наличии бинарника nfqws2 — реальный --dry-run со всеми режимами.

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected '%s', got '%s'\n" "$1" "$2" "$3"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf "[SKIP] %s (%s)\n" "$1" "$2"; }

assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}
assert_contains() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *)      fail "$1" "contains '$2'" "$3" ;;
    esac
}
assert_not_contains() {
    case "$3" in
        *"$2"*) fail "$1" "not contains '$2'" "found '$2'" ;;
        *)      pass "$1" ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

command -v python3 >/dev/null 2>&1 || {
    skip "test_webpanel_autopilot" "нет python3"
    printf "\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
    exit 0
}

if command -v dash >/dev/null 2>&1; then SH_UT="dash"; else SH_UT="sh"; fi

SB="$(mktemp -d)"
JOB_IDS=""
cleanup() {
    for _j in $JOB_IDS; do
        rm -f "/tmp/z2k-job-$_j.log" "/tmp/z2k-job-$_j.pid" "/tmp/z2k-job-$_j.exit"
    done
    rm -rf "$SB"
}
trap cleanup EXIT

ZAPRET2_DIR="$SB/opt/zapret2";                  export ZAPRET2_DIR
CONFIG_FILE="$ZAPRET2_DIR/config";              export CONFIG_FILE
LISTS_DIR="$ZAPRET2_DIR/lists";                 export LISTS_DIR
WHITELIST_FILE="$LISTS_DIR/whitelist.txt";      export WHITELIST_FILE
CUSTOM_STRAT_DIR="$LISTS_DIR/custom-strategies"; export CUSTOM_STRAT_DIR
WARP_LISTS_DIR="$LISTS_DIR/warp";               export WARP_LISTS_DIR
STATE_FILE="$ZAPRET2_DIR/state.tsv";            export STATE_FILE
INIT_SCRIPT="$SB/S99-stub";                     export INIT_SCRIPT
Z2K_GV_POLICY_FILE="$SB/z2k-gv-policy.dat";     export Z2K_GV_POLICY_FILE
Z2K_GV_OBSERVED_FILE="$SB/z2k-gv-observed.tsv"; export Z2K_GV_OBSERVED_FILE
Z2K_GVSUB_STATUS_FILE="$SB/z2k-gvsub.json";     export Z2K_GVSUB_STATUS_FILE
Z2K_GVSUB_IPS="$SB/z2k-gv-ips.txt";             export Z2K_GVSUB_IPS

mkdir -p "$ZAPRET2_DIR/extra_strats/TCP/YT" \
         "$ZAPRET2_DIR/extra_strats/TCP/YT_GV" \
         "$ZAPRET2_DIR/extra_strats/TCP/RKN" \
         "$ZAPRET2_DIR/extra_strats/UDP/YT" \
         "$ZAPRET2_DIR/extra_strats/UDP/Discord" \
         "$LISTS_DIR" "$CUSTOM_STRAT_DIR" "$ZAPRET2_DIR/lib" "$ZAPRET2_DIR/lua"

cp "$SCRIPT_DIR/lib/config_official.sh" "$ZAPRET2_DIR/lib/config_official.sh"
cp "$SCRIPT_DIR/lib/utils.sh" "$ZAPRET2_DIR/lib/utils.sh"
cp "$SCRIPT_DIR/files/lua/z2k-gv-autopilot.lua" "$ZAPRET2_DIR/lua/"
cp "$SCRIPT_DIR/files/lua/z2k-preflight.lua" "$ZAPRET2_DIR/lua/"
cp "$SCRIPT_DIR/files/lua/z2k-quic-reject.lua" "$ZAPRET2_DIR/lua/" 2>/dev/null || :

echo "youtube.com" > "$ZAPRET2_DIR/extra_strats/TCP/YT/List.txt"
echo "googlevideo.com" > "$ZAPRET2_DIR/extra_strats/TCP/YT_GV/List.txt"
echo "youtube.com" > "$ZAPRET2_DIR/extra_strats/UDP/YT/List.txt"
echo "rutracker.org" > "$ZAPRET2_DIR/extra_strats/TCP/RKN/List.txt"
echo "discord.com" > "$ZAPRET2_DIR/extra_strats/UDP/Discord/List.txt"
echo "whitelisted.example.com" > "$WHITELIST_FILE"
printf '%s\n' '--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1' \
    > "$ZAPRET2_DIR/extra_strats/TCP/RKN/Strategy.txt"
printf '%s\n' '--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=yt_tcp --lua-desync=fake:strategy=1' \
    > "$ZAPRET2_DIR/extra_strats/TCP/YT/Strategy.txt"
printf '%s\n' '--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=gv_tcp --lua-desync=fake:strategy=1' \
    > "$ZAPRET2_DIR/extra_strats/TCP/YT_GV/Strategy.txt"
printf '%s\n' '--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=5:key=quic --lua-desync=fake:strategy=1' \
    > "$ZAPRET2_DIR/extra_strats/UDP/YT/Strategy.txt"

printf '#!/bin/sh\necho restart >> "%s"\nexit 0\n' "$SB/restarts" > "$INIT_SCRIPT"
chmod +x "$INIT_SCRIPT"

STUBDIR="$SB/cgi"
mkdir -p "$STUBDIR"
cp "$SCRIPT_DIR/webpanel/cgi/api.sh" "$SCRIPT_DIR/webpanel/cgi/auth.sh" \
   "$SCRIPT_DIR/webpanel/cgi/actions.sh" "$STUBDIR/"
cat >> "$STUBDIR/actions.sh" <<'STUB'
is_running() { return 0; }
is_installed() { return 0; }
tunnel_pid() { return 1; }
STUB

cgi_stub() {
    _m="$1"; _p="$2"; _q="${3:-}"; _b="${4:-}"
    if [ -n "$_b" ]; then
        _cl=$(wc -c < "$_b" | tr -d ' ')
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="$_cl" \
            "$SH_UT" "$STUBDIR/api.sh" < "$_b" 2>/dev/null
    else
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH=0 \
            "$SH_UT" "$STUBDIR/api.sh" < /dev/null 2>/dev/null
    fi
}
cgi_body()   { awk 'blank{print} /^\r?$/{blank=1}'; }
cgi_status() { tr -d '\r' | awk 'NR==1{print; exit}'; }
json_ok_p()  { printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 && echo 1 || echo 0; }
jget() {
    printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = eval(sys.argv[1], {"d": d})
if v is None: print("null")
elif v is True: print("true")
elif v is False: print("false")
else: print(v)
' "$2" 2>/dev/null
}
job_wait() {
    _w=0
    while [ "$_w" -lt 20 ]; do
        [ -f "/tmp/z2k-job-$1.exit" ] && return 0
        _w=$((_w + 1)); sleep 1
    done
    return 1
}

printf '\n--- 1. /status без policy.dat и при свежем конфиге ---\n'
printf 'ENABLED=1\nZ2K_YT_AUTOPILOT=auto\nZ2K_GV_SERVER_REPLY2=1\nZ2K_YT_QUIC_OFF=0\nZ2K_QUIC_OFF=0\n' > "$CONFIG_FILE"
rm -f "$Z2K_GV_POLICY_FILE" "$Z2K_GV_OBSERVED_FILE" "$Z2K_GVSUB_STATUS_FILE"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "empty policy: valid JSON"              "1"     "$(json_ok_p "$OUT")"
assert_eq "empty policy: policy_present=false"    "false" "$(jget "$OUT" 'd["autopilot"]["policy_present"]')"
assert_eq "empty policy: gvsub_present=false"     "false" "$(jget "$OUT" 'd["autopilot"]["gvsub_present"]')"
assert_eq "empty policy: safety_fuse_ok=false"    "false" "$(jget "$OUT" 'd["autopilot"]["safety_fuse_ok"]')"
assert_eq "empty policy: observed_count=0"        "0"     "$(jget "$OUT" 'd["autopilot"]["observed_count"]')"
assert_eq "empty policy: toggles.yt_autopilot"    "auto"  "$(jget "$OUT" 'd["toggles"]["yt_autopilot"]')"
assert_eq "empty policy: toggles.gv_preflight"    "auto"  "$(jget "$OUT" 'd["toggles"]["gv_preflight"]')"
assert_eq "empty policy: toggles.yt_quic_off"     "auto"  "$(jget "$OUT" 'd["toggles"]["yt_quic_off"]')"
assert_eq "empty policy: toggles.quic_off"        "auto"  "$(jget "$OUT" 'd["toggles"]["quic_off"]')"

printf '\n--- 2. /status с заполненным z2k-gv-policy.dat, observed и gvsub.json ---\n'
cat > "$Z2K_GV_POLICY_FILE" <<'POL'
type=header	version=1	updated=1790001234	usable_v4=2	usable_v6=1	baseline_rtt_ms=26	ggc_rtt_ms=5	global_quic_blocked=1	preflight_sni=www.google.com	resyn_delay_ms=110	preflight_giveup_ms=950	ggc_stall_guard_ms=1400
type=prefix	addr=178.219.240.0/24	kind=isp	verdict=good_ggc	quic_ok=1	rtt_ms=5
type=prefix	addr=142.250.74.0/24	kind=google	verdict=bad_bypassable	quic_ok=0	rtt_ms=34
type=ip	addr=178.219.240.10	kind=isp	verdict=good_ggc	quic_ok=1	rtt_ms=5
type=ip	addr=178.219.240.11	kind=isp	verdict=dead_l3	quic_ok=0	rtt_ms=0
type=ip	addr=142.250.74.10	kind=google	verdict=good_direct	quic_ok=1	rtt_ms=28
type=ip	addr=142.250.74.11	kind=google	verdict=bad_bypassable	quic_ok=0	rtt_ms=34
type=ip	addr=142.250.74.12	kind=google	verdict=bad_unbypassable	quic_ok=0	rtt_ms=40
type=ip	addr=142.250.74.13	kind=google	verdict=dead_ggc	quic_ok=0	rtt_ms=0
type=ip	addr=172.217.20.14	kind=play	verdict=good_direct	quic_ok=1	rtt_ms=29
POL
printf '178.219.240.10\trr1.googlevideo.com\n142.250.74.10\trr2.googlevideo.com\n# comment\n\n172.217.20.14\tgvt1.com\n' > "$Z2K_GV_OBSERVED_FILE"
printf '{"updated":1790001234}\n' > "$Z2K_GVSUB_STATUS_FILE"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "full policy: valid JSON"           "1"              "$(json_ok_p "$OUT")"
assert_eq "full policy: policy_present"       "true"           "$(jget "$OUT" 'd["autopilot"]["policy_present"]')"
assert_eq "full policy: gvsub_present"        "true"           "$(jget "$OUT" 'd["autopilot"]["gvsub_present"]')"
assert_eq "full policy: updated"              "1790001234"     "$(jget "$OUT" 'd["autopilot"]["updated"]')"
assert_eq "full policy: stale=false"          "false"          "$(jget "$OUT" 'd["autopilot"]["stale"]')"
assert_eq "full policy: usable_v4"            "2"              "$(jget "$OUT" 'd["autopilot"]["usable_v4"]')"
assert_eq "full policy: usable_v6"            "1"              "$(jget "$OUT" 'd["autopilot"]["usable_v6"]')"
assert_eq "full policy: baseline_rtt_ms"      "26"             "$(jget "$OUT" 'd["autopilot"]["baseline_rtt_ms"]')"
assert_eq "full policy: ggc_rtt_ms"           "5"              "$(jget "$OUT" 'd["autopilot"]["ggc_rtt_ms"]')"
assert_eq "full policy: global_quic_blocked"  "true"           "$(jget "$OUT" 'd["autopilot"]["global_quic_blocked"]')"
assert_eq "full policy: preflight_sni"        "www.google.com" "$(jget "$OUT" 'd["autopilot"]["preflight_sni"]')"
assert_eq "full policy: resyn_delay_ms"       "110"            "$(jget "$OUT" 'd["autopilot"]["resyn_delay_ms"]')"
assert_eq "full policy: preflight_giveup_ms"  "950"            "$(jget "$OUT" 'd["autopilot"]["preflight_giveup_ms"]')"
assert_eq "full policy: ggc_stall_guard_ms"   "1400"           "$(jget "$OUT" 'd["autopilot"]["ggc_stall_guard_ms"]')"
assert_eq "full policy: safety_fuse_ok"       "true"           "$(jget "$OUT" 'd["autopilot"]["safety_fuse_ok"]')"
assert_eq "full policy: observed_count"       "3"              "$(jget "$OUT" 'd["autopilot"]["observed_count"]')"
assert_eq "full policy: prefixes_total"       "2"              "$(jget "$OUT" 'd["autopilot"]["prefixes_total"]')"
assert_eq "full policy: ips_total"            "7"              "$(jget "$OUT" 'd["autopilot"]["ips_total"]')"
assert_eq "full policy: isp_good"             "1"              "$(jget "$OUT" 'd["autopilot"]["isp_good"]')"
assert_eq "full policy: isp_dead"             "1"              "$(jget "$OUT" 'd["autopilot"]["isp_dead"]')"
assert_eq "full policy: google_good"          "1"              "$(jget "$OUT" 'd["autopilot"]["google_good"]')"
assert_eq "full policy: google_bypassable"    "1"              "$(jget "$OUT" 'd["autopilot"]["google_bypassable"]')"
assert_eq "full policy: google_unbypassable"  "1"              "$(jget "$OUT" 'd["autopilot"]["google_unbypassable"]')"
assert_eq "full policy: google_dead"          "1"              "$(jget "$OUT" 'd["autopilot"]["google_dead"]')"
assert_eq "full policy: quic_ok_count"        "3"              "$(jget "$OUT" 'd["autopilot"]["quic_ok_count"]')"
assert_eq "full policy: play_count"           "1"              "$(jget "$OUT" 'd["autopilot"]["play_count"]')"

printf '\n--- 3. Битые поля, Safety Fuse=false, stale=1 и экранирование preflight_sni ---\n'
printf 'type=header\tupdated=0099\tstale=1\tusable_v4=0\tusable_v6=0\tbaseline_rtt_ms=abc\tggc_rtt_ms=99999999999999999999\tglobal_quic_blocked=no\tpreflight_sni=bad"sni\\x\tresyn_delay_ms=0150\n' > "$Z2K_GV_POLICY_FILE"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "malformed policy: valid JSON"       "1"         "$(json_ok_p "$OUT")"
assert_eq "malformed policy: safety_fuse=false" "false"    "$(jget "$OUT" 'd["autopilot"]["safety_fuse_ok"]')"
assert_eq "malformed policy: stale=true"       "true"      "$(jget "$OUT" 'd["autopilot"]["stale"]')"
assert_eq "malformed policy: updated 0099->99" "99"        "$(jget "$OUT" 'd["autopilot"]["updated"]')"
assert_eq "malformed policy: bad int -> 0"     "0"         "$(jget "$OUT" 'd["autopilot"]["baseline_rtt_ms"]')"
assert_eq "malformed policy: huge int -> 0"    "0"         "$(jget "$OUT" 'd["autopilot"]["ggc_rtt_ms"]')"
assert_eq "malformed policy: escaped sni"      'bad"sni\x' "$(jget "$OUT" 'd["autopilot"]["preflight_sni"]')"

printf '\n--- 4. POST /toggle/yt-autopilot и tri-state оверрайды ---\n'
BODYF="$SB/body.txt"
printf 'value=invalid\n' > "$BODYF"
for ep in /toggle/yt-autopilot /toggle/gv-preflight /toggle/yt-quic-off /toggle/quic-off; do
    RAW=$(cgi_stub POST "$ep" "" "$BODYF")
    assert_contains "$ep rejects bogus -> 400" "Status: 400" "$(printf '%s\n' "$RAW" | cgi_status)"
done

# Disable yt-autopilot -> 0
printf 'value=0\n' > "$BODYF"
OUT=$(cgi_stub POST /toggle/yt-autopilot "" "$BODYF" | cgi_body)
assert_eq "yt-autopilot=0 ok" "true" "$(jget "$OUT" 'd["ok"]')"
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
OPT=$(ZAPRET2_DIR="$ZAPRET2_DIR" sh -c 'NFQWS2_OPT=""; . "$0" >/dev/null 2>&1 || :; printf "%s" "$NFQWS2_OPT"' "$CONFIG_FILE")
assert_not_contains "yt-autopilot=0 strips z2k_autopilot_*" "z2k_autopilot_" "$OPT"
assert_contains "yt-autopilot=0 sets :autopilot=0 on preflight" ":autopilot=0" "$OPT"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "status yt_autopilot=0" "0" "$(jget "$OUT" 'd["toggles"]["yt_autopilot"]')"
assert_eq "status yt_quic_off=off when ap=0 & val=0" "off" "$(jget "$OUT" 'd["toggles"]["yt_quic_off"]')"
assert_eq "status gv_preflight=1 when ap=0 & sr2=1 & mode=auto" "1" "$(jget "$OUT" 'd["toggles"]["gv_preflight"]')"
assert_eq "status gvsub_enabled=true when sr2=1" "true" "$(jget "$OUT" 'd["autopilot"]["gvsub_enabled"]')"

# Z2K_YT_QUIC_OFF=auto with yt_autopilot=0 must also report effective off consistently
printf 'value=auto\n' > "$BODYF"
OUT=$(cgi_stub POST /toggle/yt-quic-off "" "$BODYF" | cgi_body)
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "status yt_quic_off=off when ap=0 & val=auto" "off" "$(jget "$OUT" 'd["toggles"]["yt_quic_off"]')"

# Simulate legacy Z2K_GV_SERVER_REPLY2=0 while yt_autopilot=auto -> status exposes gvsub_enabled=false;
# then re-enable yt-autopilot=auto -> must force Z2K_GV_SERVER_REPLY2=1 and gvsub_enabled=true!
sed -i 's/^Z2K_YT_AUTOPILOT=.*/Z2K_YT_AUTOPILOT=auto/' "$CONFIG_FILE"
sed -i 's/^Z2K_GV_SERVER_REPLY2=.*/Z2K_GV_SERVER_REPLY2=0/' "$CONFIG_FILE"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "status gvsub_enabled=false when legacy sr2=0" "false" "$(jget "$OUT" 'd["autopilot"]["gvsub_enabled"]')"
printf 'value=auto\n' > "$BODYF"
OUT=$(cgi_stub POST /toggle/yt-autopilot "" "$BODYF" | cgi_body)
assert_eq "yt-autopilot=auto ok" "true" "$(jget "$OUT" 'd["ok"]')"
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
SR2=$(awk -F= '/^Z2K_GV_SERVER_REPLY2=/{v=$2} END{print v}' "$CONFIG_FILE")
assert_eq "yt-autopilot=auto enforces Z2K_GV_SERVER_REPLY2=1" "1" "$SR2"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "status gvsub_enabled=true restored" "true" "$(jget "$OUT" 'd["autopilot"]["gvsub_enabled"]')"
OPT=$(ZAPRET2_DIR="$ZAPRET2_DIR" sh -c 'NFQWS2_OPT=""; . "$0" >/dev/null 2>&1 || :; printf "%s" "$NFQWS2_OPT"' "$CONFIG_FILE")
assert_contains "yt-autopilot=auto restores z2k_autopilot_quic" "z2k_autopilot_quic" "$OPT"

# gv-preflight tri-state: off keeps Z2K_GV_SERVER_REPLY2=1 (gvsub alive), removes z2k_preflight,
# and STILL emits --ipset with z2k_autopilot_tcp_fastfail + stall_guard
printf 'value=off\n' > "$BODYF"
OUT=$(cgi_stub POST /toggle/gv-preflight "" "$BODYF" | cgi_body)
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
OPT=$(ZAPRET2_DIR="$ZAPRET2_DIR" sh -c 'NFQWS2_OPT=""; . "$0" >/dev/null 2>&1 || :; printf "%s" "$NFQWS2_OPT"' "$CONFIG_FILE")
SR2=$(awk -F= '/^Z2K_GV_SERVER_REPLY2=/{v=$2} END{print v}' "$CONFIG_FILE")
assert_eq "gv-preflight=off keeps Z2K_GV_SERVER_REPLY2=1" "1" "$SR2"
assert_not_contains "gv-preflight=off removes z2k_preflight" "z2k_preflight" "$OPT"
assert_contains "gv-preflight=off keeps fastfail" "z2k_autopilot_tcp_fastfail" "$OPT"
assert_contains "gv-preflight=off keeps --ipset for fastfail" "--ipset=$Z2K_GVSUB_IPS" "$OPT"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "status gv_preflight=off" "off" "$(jget "$OUT" 'd["toggles"]["gv_preflight"]')"

# gv-preflight=1 forces :autopilot=0 alongside fastfail
printf 'value=1\n' > "$BODYF"
OUT=$(cgi_stub POST /toggle/gv-preflight "" "$BODYF" | cgi_body)
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
OPT=$(ZAPRET2_DIR="$ZAPRET2_DIR" sh -c 'NFQWS2_OPT=""; . "$0" >/dev/null 2>&1 || :; printf "%s" "$NFQWS2_OPT"' "$CONFIG_FILE")
assert_contains "gv-preflight=1 emits :autopilot=0" "z2k_preflight:pos=none:pieces=1:keepts:sni=www.google.com:timeout=4:v6:autopilot=0" "$OPT"
assert_contains "gv-preflight=1 keeps stall_guard" "z2k_autopilot_stall_guard" "$OPT"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "status gv_preflight=1" "1" "$(jget "$OUT" 'd["toggles"]["gv_preflight"]')"

# yt-quic-off=off and quic-off=off pass :yt=0 and :global=0 without unconditional reject
printf 'value=off\n' > "$BODYF"
OUT=$(cgi_stub POST /toggle/yt-quic-off "" "$BODYF" | cgi_body)
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
OUT=$(cgi_stub POST /toggle/quic-off "" "$BODYF" | cgi_body)
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
OPT=$(ZAPRET2_DIR="$ZAPRET2_DIR" sh -c 'NFQWS2_OPT=""; . "$0" >/dev/null 2>&1 || :; printf "%s" "$NFQWS2_OPT"' "$CONFIG_FILE")
assert_contains "yt-quic-off=off + quic-off=off -> :yt=0:global=0" "z2k_autopilot_quic:yt=0:global=0" "$OPT"
assert_not_contains "yt/quic off emits no z2k_quic_reject" "z2k_quic_reject" "$OPT"
OUT=$(cgi_stub GET /status "" | cgi_body)
assert_eq "status yt_quic_off=off" "off" "$(jget "$OUT" 'd["toggles"]["yt_quic_off"]')"
assert_eq "status quic_off=off"    "off" "$(jget "$OUT" 'd["toggles"]["quic_off"]')"

# Regen preservation check
( export ZAPRET2_DIR; . "$ZAPRET2_DIR/lib/utils.sh"; . "$ZAPRET2_DIR/lib/config_official.sh"; create_official_config "$CONFIG_FILE" >/dev/null 2>&1 )
assert_eq "regen keeps Z2K_GV_PREFLIGHT_MODE=1" "1"   "$(grep -E '^Z2K_GV_PREFLIGHT_MODE=' "$CONFIG_FILE" | tail -n 1 | cut -d= -f2)"
assert_eq "regen keeps Z2K_YT_QUIC_OFF=off"     "off" "$(grep -E '^Z2K_YT_QUIC_OFF=' "$CONFIG_FILE" | tail -n 1 | cut -d= -f2)"
assert_eq "regen keeps Z2K_QUIC_OFF=off"        "off" "$(grep -E '^Z2K_QUIC_OFF=' "$CONFIG_FILE" | tail -n 1 | cut -d= -f2)"

# Switch back to auto
printf 'value=auto\n' > "$BODYF"
for ep in /toggle/gv-preflight /toggle/yt-quic-off /toggle/quic-off; do
    OUT=$(cgi_stub POST "$ep" "" "$BODYF" | cgi_body)
    JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
done
OPT=$(ZAPRET2_DIR="$ZAPRET2_DIR" sh -c 'NFQWS2_OPT=""; . "$0" >/dev/null 2>&1 || :; printf "%s" "$NFQWS2_OPT"' "$CONFIG_FILE")
assert_not_contains "auto restores z2k_autopilot_quic without :yt=0" "z2k_autopilot_quic:yt=0" "$OPT"
assert_not_contains "auto restores preflight without :autopilot=0" ":autopilot=0" "$OPT"

printf '\n--- 5. Реальный nfqws2 --dry-run (если бинарник есть) ---\n'
NFQ_BIN=""
for _cand in "${Z2K_NFQWS2_BIN:-}" /root/zapret2-z2k-fork/nfq2/nfqws2 /opt/zapret2/nfq2/nfqws2; do
    [ -n "$_cand" ] && [ -x "$_cand" ] && { NFQ_BIN="$_cand"; break; }
done
if [ -n "$NFQ_BIN" ] && [ -d /root/zapret2-z2k-fork/lua ]; then
    cp "$SCRIPT_DIR"/files/lua/*.lua "$ZAPRET2_DIR/lua/" 2>/dev/null || :
    cp /root/zapret2-z2k-fork/lua/zapret-lib.lua \
       /root/zapret2-z2k-fork/lua/zapret-antidpi.lua \
       /root/zapret2-z2k-fork/lua/zapret-auto.lua \
       "$ZAPRET2_DIR/lua/"
    chmod -R a+rX "$SB"
    printf 'value=off\n' > "$BODYF"
    OUT=$(cgi_stub POST /toggle/yt-quic-off "" "$BODYF" | cgi_body); JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
    OUT=$(cgi_stub POST /toggle/quic-off "" "$BODYF" | cgi_body); JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
    printf 'value=1\n' > "$BODYF"
    OUT=$(cgi_stub POST /toggle/gv-preflight "" "$BODYF" | cgi_body); JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"; job_wait "$JOB"
    OPT_DRY=$(ZAPRET2_DIR="$ZAPRET2_DIR" sh -c 'NFQWS2_OPT=""; . "$0" >/dev/null 2>&1 || :; printf "%s" "$NFQWS2_OPT"' "$CONFIG_FILE")
    assert_contains "generated opt has :yt=0:global=0 and :autopilot=0" ":yt=0:global=0" "$OPT_DRY"
    if "$NFQ_BIN" --dry-run --qnum=299 \
        --lua-init="@${ZAPRET2_DIR}/lua/zapret-lib.lua" \
        --lua-init="@${ZAPRET2_DIR}/lua/zapret-antidpi.lua" \
        --lua-init="@${ZAPRET2_DIR}/lua/zapret-auto.lua" \
        --lua-init="@${ZAPRET2_DIR}/lua/z2k-gv-autopilot.lua" \
        --lua-init="@${ZAPRET2_DIR}/lua/z2k-preflight.lua" \
        --filter-tcp=443 --in-range=a --out-range=a --payload=all \
        --lua-desync=z2k_autopilot_tcp_fastfail \
        --lua-desync=z2k_preflight:pos=none:pieces=1:keepts:sni=www.google.com:timeout=4:autopilot=0 \
        --lua-desync=z2k_autopilot_stall_guard \
        --new \
        --filter-udp=443 --in-range=x --out-range=a --payload=quic_initial \
        --lua-desync=z2k_autopilot_quic:yt=0:global=0 \
        >/dev/null 2>&1; then
        pass "nfqws2 --dry-run accepts autopilot :yt=0:global=0 & preflight :autopilot=0"
    else
        fail "nfqws2 --dry-run autopilot args" "exit 0" "non-zero"
    fi
else
    skip "nfqws2 --dry-run проверка флагов" "нет бинарника nfqws2 или zapret-lib"
fi

printf "\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
[ "$TESTS_FAILED" -eq 0 ]
