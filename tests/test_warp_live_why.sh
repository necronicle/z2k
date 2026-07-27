#!/bin/sh
# tests/test_warp_live_why.sh
#
# "Режим включён, но туннель ещё не поднялся" was printed for SIX different causes and
# they were indistinguishable — to the user and to us. Four separate root causes have
# already been fixed under that one sentence (subnet collision with the Keenetic SSTP
# pool, registration blocked by DPI, link never raised, the address overridden instead
# of taken from session.conf), and every new report still arrived looking exactly like
# the previous ones, so each one restarted from "send me the log".
#
# The screenshot that prompted this: a router on r-67, enable took 00:12:56 -> 00:13:16,
# i.e. 20 seconds. The enable path spends up to 35 s waiting for an address and a raised
# link, then probes 8 s, waits 3 s, probes 8 s again. Twenty seconds cannot contain the
# 35 s wait, so on THAT router the interface had an address and was up immediately and
# it was the PROBE that failed — a different cause from every one fixed so far, and
# nothing in the message said so.
#
# So the verdict now names the check that failed. Every branch below is a distinct,
# actionable cause: no device, no address, link down, engine dead, probe timed out,
# empty response, and reached-Cloudflare-but-not-WARP (which means the interface works
# and the MASQUE session does not — usually a dead registration).
#
# The one thing that must NOT change: a box without curl is never called dead. That
# would turn missing tooling into a restart storm against a healthy tunnel.
#
# POSIX sh, no router: ip/curl/pidof are stubs.

HERE=$(cd "$(dirname "$0")/.." && pwd)
WARPSH="${Z2K_WARPSH_UNDER_TEST:-$HERE/files/z2k-warp.sh}"
ACTIONS="$HERE/webpanel/cgi/actions.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wwhy.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

for f in "$WARPSH" "$ACTIONS"; do
    [ -f "$f" ] || { printf '[FAIL] missing %s\n' "$f"; exit 1; }
done

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*\\{?[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}

FN="$TMP/fn.sh"
{ grep -m1 "^WARP_ENGINE_LOG=" "$WARPSH"; extract_fn warp_engine_tail "$WARPSH"; echo; extract_fn warp_engine_connected "$WARPSH"; echo; extract_fn warp_explain_dead "$WARPSH"; echo; extract_fn warp_tunnel_live "$WARPSH"; } > "$FN"
grep -q '^warp_tunnel_live()' "$FN" && ok "extracted warp_tunnel_live()" \
                                   || no "extracted warp_tunnel_live()" "a definition" "none"

BIN="$TMP/bin"; mkdir -p "$BIN"
# ip stub driven by fixture files: presence, address, UP are set per case.
cat > "$BIN/ip" <<EOF
#!/bin/sh
case "\$*" in
    *"link show"*)
        [ -f "$TMP/dev" ] || exit 1
        if [ -f "$TMP/up" ]; then echo "9: opkgtun0: <POINTOPOINT,UP,LOWER_UP> mtu 1280"
        else echo "9: opkgtun0: <POINTOPOINT,MULTICAST,NOARP> mtu 1280"; fi ;;
    *"addr show"*)
        [ -f "$TMP/addr" ] || exit 0
        echo "9: opkgtun0    inet 172.16.0.2/32 scope global opkgtun0" ;;
esac
exit 0
EOF
# curl stub: exit code from $TMP/curl_rc, body from $TMP/curl_body.
cat > "$BIN/curl" <<EOF
#!/bin/sh
cat "$TMP/curl_body" 2>/dev/null
exit \$(cat "$TMP/curl_rc" 2>/dev/null || echo 0)
EOF
chmod +x "$BIN/ip" "$BIN/curl"

# run  -> echoes "rc=<n> why=<text>"
run() {
    cat > "$TMP/r.sh" <<EOF
WARP_IFACE=opkgtun0
WARP_PROBE_URL="https://1.1.1.1/cdn-cgi/trace"
WARP_PROBE_TIMEOUT=8
WARP_ENGINE_LOG="${WARP_ENGINE_LOG:-/nonexistent}"
WARP_LIVE_STAMP="$TMP/live.stamp"
warp_live_record() { echo "\$1" > "$TMP/recorded"; }
warp_usque_running() { [ -f "$TMP/engine" ]; }
_warp_now() { echo 1000; }
. "$FN"
warp_tunnel_live; rc=\$?
printf 'rc=%s\n' "\$rc"
printf 'why=%s\n' "\$WARP_LIVE_WHY"
EOF
    rm -f "$TMP/recorded"
    WARP_ENGINE_LOG="$WARP_ENGINE_LOG" PATH="$BIN:$PATH" sh "$TMP/r.sh" 2>&1
}
rcof()  { printf '%s\n' "$1" | sed -n 's/^rc=//p'; }
whyof() { printf '%s\n' "$1" | sed -n 's/^why=//p'; }
recorded() { cat "$TMP/recorded" 2>/dev/null; }

reset_all() { rm -f "$TMP/dev" "$TMP/addr" "$TMP/up" "$TMP/engine" "$TMP/curl_body" "$TMP/curl_rc"; }

# --- 1. no device -----------------------------------------------------------
reset_all
out=$(run)
[ "$(rcof "$out")" = 1 ] && ok "no device -> not live" || no "no device -> not live" 1 "$(rcof "$out")"
case "$(whyof "$out")" in *"не существует"*) ok "no device: reason names the missing interface" ;;
    *) no "no device: reason names the missing interface" "не существует" "$(whyof "$out")" ;; esac

# --- 2. device, no address --------------------------------------------------
reset_all; : > "$TMP/dev"; : > "$TMP/up"
out=$(run)
[ "$(rcof "$out")" = 1 ] && ok "no address -> not live" || no "no address -> not live" 1 "$(rcof "$out")"
case "$(whyof "$out")" in *"нет IPv4-адреса"*) ok "no address: reason says the address is missing" ;;
    *) no "no address: reason says the address is missing" "нет IPv4-адреса" "$(whyof "$out")" ;; esac

# --- 3. address, link not UP ------------------------------------------------
reset_all; : > "$TMP/dev"; : > "$TMP/addr"
out=$(run)
case "$(whyof "$out")" in *"линк"*"не поднят"*) ok "link down: reason says the link is not up" ;;
    *) no "link down: reason says the link is not up" "линк не поднят" "$(whyof "$out")" ;; esac

# --- 4. all up, engine dead -------------------------------------------------
reset_all; : > "$TMP/dev"; : > "$TMP/addr"; : > "$TMP/up"
out=$(run)
case "$(whyof "$out")" in *"usque не запущен"*) ok "engine dead: reason says the engine is not running" ;;
    *) no "engine dead: reason says the engine is not running" "usque не запущен" "$(whyof "$out")" ;; esac

# --- 5. THE SCREENSHOT CASE: everything up, probe times out -----------------
reset_all; : > "$TMP/dev"; : > "$TMP/addr"; : > "$TMP/up"; : > "$TMP/engine"
echo 28 > "$TMP/curl_rc"; : > "$TMP/curl_body"
out=$(run)
[ "$(rcof "$out")" = 1 ] && ok "probe timeout -> not live" || no "probe timeout -> not live" 1 "$(rcof "$out")"
case "$(whyof "$out")" in *"curl rc=28"*) ok "probe timeout: reason carries the curl exit code" ;;
    *) no "probe timeout: reason carries the curl exit code" "curl rc=28" "$(whyof "$out")" ;; esac
# and it must NOT be blamed on the address or the link, which were fine
case "$(whyof "$out")" in *"адрес"*|*"линк"*) no "probe timeout: does not misblame address/link" "no such words" "$(whyof "$out")" ;;
    *) ok "probe timeout: does not misblame address/link" ;; esac

# --- 6. probe succeeds at the socket level but returns nothing --------------
reset_all; : > "$TMP/dev"; : > "$TMP/addr"; : > "$TMP/up"; : > "$TMP/engine"
echo 0 > "$TMP/curl_rc"; : > "$TMP/curl_body"
out=$(run)
case "$(whyof "$out")" in *"пустой ответ"*) ok "empty body: reason says the response was empty" ;;
    *) no "empty body: reason says the response was empty" "пустой ответ" "$(whyof "$out")" ;; esac

# --- 7. reached Cloudflare, but warp=off ------------------------------------
# The interface works and the MASQUE session does not — a completely different fix
# from every other branch, and previously indistinguishable from all of them.
reset_all; : > "$TMP/dev"; : > "$TMP/addr"; : > "$TMP/up"; : > "$TMP/engine"
echo 0 > "$TMP/curl_rc"
printf 'fl=123abc\nip=1.2.3.4\nwarp=off\n' > "$TMP/curl_body"
out=$(run)
[ "$(rcof "$out")" = 1 ] && ok "warp=off -> not live" || no "warp=off -> not live" 1 "$(rcof "$out")"
case "$(whyof "$out")" in *"WARP не активен"*) ok "warp=off: reason distinguishes it from an unreachable probe" ;;
    *) no "warp=off: reason distinguishes it from an unreachable probe" "WARP не активен" "$(whyof "$out")" ;; esac
case "$(whyof "$out")" in *"warp=off"*) ok "warp=off: the actual answer is quoted back" ;;
    *) no "warp=off: the actual answer is quoted back" "warp=off" "$(whyof "$out")" ;; esac

# --- 8. healthy: warp=on ----------------------------------------------------
reset_all; : > "$TMP/dev"; : > "$TMP/addr"; : > "$TMP/up"; : > "$TMP/engine"
echo 0 > "$TMP/curl_rc"
printf 'fl=123abc\nip=1.2.3.4\nwarp=on\n' > "$TMP/curl_body"
out=$(run)
[ "$(rcof "$out")" = 0 ] && ok "warp=on -> live (INVARIANT)" || no "warp=on -> live (INVARIANT)" 0 "$(rcof "$out")"
[ -z "$(whyof "$out")" ] && ok "a live tunnel carries no reason" || no "a live tunnel carries no reason" "" "$(whyof "$out")"
[ "$(recorded)" = 1 ] && ok "a live verdict is recorded as 1" || no "a live verdict is recorded as 1" 1 "$(recorded)"

# --- 9. INVARIANT: no curl must never mean "dead" ---------------------------
# Missing tooling proves nothing, and calling it dead would restart a healthy tunnel
# in a loop.
reset_all; : > "$TMP/dev"; : > "$TMP/addr"; : > "$TMP/up"; : > "$TMP/engine"
# Shadowing `command` is how curl is made invisible: emptying PATH would also take
# away the shell itself (the first version of this case did exactly that and reported
# "sh: command not found" as a failure).
out=$(PATH="$BIN:$PATH" sh -c '
WARP_IFACE=opkgtun0; WARP_PROBE_TIMEOUT=8
command() { return 1; }
warp_live_record() { :; }
warp_usque_running() { true; }
. '"$FN"'
warp_tunnel_live; echo "rc=$?"' 2>&1)
case "$out" in *"rc=0"*) ok "no curl -> never reported dead (INVARIANT)" ;;
    *) no "no curl -> never reported dead (INVARIANT)" "rc=0" "$out" ;; esac

# --- 9b. the engine's own last line is surfaced -----------------------------
# Our checks stop at "device is fine, data does not flow". WHY is known only to usque,
# which says so plainly in the log we already capture. Not printing it meant this class
# of report still needed one more round trip to the user — the exact thing this whole
# change exists to remove.
mk_log() { printf '%s\n' "$@" > "$TMP/engine.log"; }
tail_of() { PATH="$BIN:$PATH" sh -c "WARP_ENGINE_LOG='$TMP/engine.log'; . '$FN'; warp_engine_tail"; }

mk_log '[z2k-warp] enable' \
       '2026/07/27 06:36:52 UTC Connected to MASQUE server' \
       '[z2k-warp] попытка 1 не удалась: что-то'
[ "$(tail_of)" = "2026/07/27 06:36:52 UTC Connected to MASQUE server" ] \
    && ok "engine tail skips our own [z2k-warp] lines" \
    || no "engine tail skips our own [z2k-warp] lines" "the engine line" "$(tail_of)"

# The multicast noise repeats constantly and would bury every useful line.
mk_log '2026/07/27 06:47:30 UTC Tunnel idle. Waiting for outbound activity before reconnecting...' \
       '2026/07/27 06:47:31 UTC dropping proxied packet (76 bytes) that cannot be proxied: connect-ip: datagram Hop Limit too small: 1' \
       '2026/07/27 06:47:32 UTC dropping proxied packet (76 bytes) that cannot be proxied: connect-ip: datagram Hop Limit too small: 1'
case "$(tail_of)" in
    *"Tunnel idle"*) ok "engine tail skips the Hop Limit noise" ;;
    *) no "engine tail skips the Hop Limit noise" "Tunnel idle" "$(tail_of)" ;;
esac

rm -f "$TMP/engine.log"
[ -z "$(tail_of)" ] && ok "no log -> empty tail, not an error" \
                    || no "no log -> empty tail, not an error" "" "$(tail_of)"

# ...and it reaches the reason the user reads.
reset_all; : > "$TMP/dev"; : > "$TMP/addr"; : > "$TMP/up"; : > "$TMP/engine"
echo 28 > "$TMP/curl_rc"; : > "$TMP/curl_body"
mk_log '2026/07/27 06:36:52 UTC Establishing MASQUE connection to 162.159.198.2:443'
out=$(WARP_ENGINE_LOG="$TMP/engine.log" run)
case "$(whyof "$out")" in
    *"движок: "*"Establishing MASQUE"*) ok "the reason carries the engine's last line" ;;
    *) no "the reason carries the engine's last line" "движок: ...Establishing MASQUE" "$(whyof "$out")" ;;
esac
rm -f "$TMP/engine.log"
out=$(WARP_ENGINE_LOG="$TMP/engine.log" run)
case "$(whyof "$out")" in
    *"движок:"*) no "no engine log -> no dangling 'движок:'" "no suffix" "$(whyof "$out")" ;;
    *) ok "no engine log -> no dangling 'движок:'" ;;
esac

# --- 9c. endpoint variants: only on failure, never on the original config ---
# The constraint that shaped this: it must be impossible for a router whose tunnel works
# to be affected. Nothing here runs unless the tunnel has already failed, no state file
# exists by default, and the ORIGINAL session.conf is only ever read — it holds the device
# key, and rewriting it would cost the registration rather than merely a session.
apply_fn=$(extract_fn warp_variant_apply "$WARPSH")
case "$apply_fn" in
    *'> "$WARP_ALT_CONF.tmp"'*) ok "the variant is written to a COPY, not to session.conf" ;;
    *) no "the variant is written to a COPY, not to session.conf" "a .tmp copy" "absent" ;;
esac
# grep, not a case list: the first glob swallowed the others (SC2221/2222), so the
# sed -i check never actually ran — a dead assertion pretending to guard the one file
# whose corruption costs a user their registration.
if printf '%s\n' "$apply_fn" | grep -qE '>>?[[:space:]]*"\$USQUE_SESSION"|sed +-i[^&|]*\$USQUE_SESSION|tee[^&|]*\$USQUE_SESSION'; then
    no "the original session.conf is never written" "read-only" "written"
else
    ok "the original session.conf is never written"
fi
# A mangled copy must be discarded, not handed to usque.
case "$apply_fn" in
    *'private_key'*) ok "the copy is validated before use (key still present)" ;;
    *) no "the copy is validated before use (key still present)" "a validation" "absent" ;;
esac
# Rotation is gated on the reason: with "no address" the endpoint is not the suspect.
enable_fn2=$(extract_fn warp_enable "$WARPSH")
case "$enable_fn2" in
    *'*"проба через"*|*"WARP не активен"*'*) ok "variants are tried only for a dead data path" ;;
    *) no "variants are tried only for a dead data path" "the reason gate" "absent" ;;
esac
# ...and only after the engine restart has already been spent.
k_ln=$(printf '%s\n' "$enable_fn2" | grep -n 'kicked=1' | head -1 | cut -d: -f1)
v_ln=$(printf '%s\n' "$enable_fn2" | grep -n 'warp_variant_apply' | head -1 | cut -d: -f1)
if [ -n "$k_ln" ] && [ -n "$v_ln" ] && [ "$k_ln" -lt "$v_ln" ]; then
    ok "the engine restart is tried before any variant ($k_ln < $v_ln)"
else
    no "the engine restart is tried before any variant" "restart first" "$k_ln/$v_ln"
fi
# A failed run must not leave the router pinned to a variant that did not work either.
case "$enable_fn2" in
    *warp_variant_clear*) ok "a final failure restores the stock endpoint" ;;
    *) no "a final failure restores the stock endpoint" "warp_variant_clear" "absent" ;;
esac
# The init must fall back to the stock config when no variant file exists — that is what
# keeps every working router byte-identical.
init_launch=$(grep -A3 'nativetun \\' "$HERE/files/init.d/S51z2k-warp" | head -6)
case "$init_launch" in
    *'--config "$_cfg"'*) ok "the init launches with the selected config" ;;
    *) no "the init launches with the selected config" '--config "$_cfg"' "$init_launch" ;;
esac
grep -q '_cfg="$SESSION"' "$HERE/files/init.d/S51z2k-warp" \
    && ok "the init defaults to the original session.conf" \
    || no "the init defaults to the original session.conf" 'default to $SESSION' "absent"
# A non-numeric port file must never reach the command line.
pline=$(grep -A4 '_p=$(cat "$WARP_DIR/port"' "$HERE/files/init.d/S51z2k-warp")
case "$pline" in
    *'*[!0-9]*'*) ok "a non-numeric port is rejected" ;;
    *) no "a non-numeric port is rejected" "a digit guard" "$pline" ;;
esac

# --- 9d. our own log lines are not attributed to the engine -----------------
# The init prefixes its lines with a DATE and then [z2k-warp], so anchoring the filter at
# the start of the line let them through — a field log reported OUR "address applied via
# iproute2" line as if the engine had said it.
mk_log '2026/07/27 10:46:28 UTC Connected to MASQUE server' \
       'Mon Jul 27 13:41:33 MSK 2026 [z2k-warp] 172.16.0.2 is on opkgtun0 via iproute2'
case "$(tail_of)" in
    *"[z2k-warp]"*) no "our own dated log lines are not shown as the engine's" "engine only" "$(tail_of)" ;;
    *"Connected to MASQUE server"*) ok "our own dated log lines are not shown as the engine's" ;;
    *) no "our own dated log lines are not shown as the engine's" "the engine line" "$(tail_of)" ;;
esac

# --- 9e. session state decides whether rotating the endpoint makes sense ----
conn() { PATH="$BIN:$PATH" sh -c "WARP_ENGINE_LOG='$TMP/engine.log'; . '$FN'; warp_engine_connected; echo rc=\$?"; }
mk_log '2026/07/27 10:46:28 UTC Connected to MASQUE server'
case "$(conn)" in *rc=0*) ok "a connected session is recognised" ;;
    *) no "a connected session is recognised" "rc=0" "$(conn)" ;; esac
mk_log '2026/07/27 10:47:20 UTC Failed to connect tunnel: connect-ip: failed to send request'
case "$(conn)" in *rc=1*) ok "a failed connect is recognised" ;;
    *) no "a failed connect is recognised" "rc=1" "$(conn)" ;; esac
# The LAST marker wins: a success from an hour ago must not mask a current failure.
mk_log '2026/07/27 10:46:28 UTC Connected to MASQUE server' \
       '2026/07/27 10:47:20 UTC Failed to connect tunnel: connect-ip: failed to send request'
case "$(conn)" in *rc=1*) ok "a stale success does not mask a later failure" ;;
    *) no "a stale success does not mask a later failure" "rc=1" "$(conn)" ;; esac
mk_log '2026/07/27 10:47:20 UTC Failed to connect tunnel: x' \
       '2026/07/27 10:48:00 UTC Connected to MASQUE server'
case "$(conn)" in *rc=0*) ok "a later success wins over an earlier failure" ;;
    *) no "a later success wins over an earlier failure" "rc=0" "$(conn)" ;; esac
rm -f "$TMP/engine.log"
case "$(conn)" in *rc=1*) ok "no log -> not considered connected" ;;
    *) no "no log -> not considered connected" "rc=1" "$(conn)" ;; esac

# ...and the enable path uses it, both to skip pointless rotation and to say what is
# actually wrong. Rotating away from a working handshake produced "tls: handshake failure"
# on the alternatives in the field — strictly worse than doing nothing.
enable_fn3=$(extract_fn warp_enable "$WARPSH")
case "$enable_fn3" in
    *'if warp_engine_connected; then'*) ok "rotation is skipped when the session does establish" ;;
    *) no "rotation is skipped when the session does establish" "the guard" "absent" ;;
esac
case "$enable_fn3" in
    *"УСТАНАВЛИВАЕТСЯ, но трафик внутри него не проходит"*)
        ok "the verdict distinguishes 'filtered inside' from 'never came up'" ;;
    *)  no "the verdict distinguishes 'filtered inside' from 'never came up'" "the wording" "absent" ;;
esac
gc_ln=$(printf '%s\n' "$enable_fn3" | grep -n 'warp_engine_connected' | head -1 | cut -d: -f1)
rot_ln=$(printf '%s\n' "$enable_fn3" | grep -n 'vidx=\$((vidx + 1))' | head -1 | cut -d: -f1)
if [ -n "$gc_ln" ] && [ -n "$rot_ln" ] && [ "$gc_ln" -lt "$rot_ln" ]; then
    ok "the session check runs before any rotation ($gc_ln < $rot_ln)"
else
    no "the session check runs before any rotation" "check first" "$gc_ln/$rot_ln"
fi

# --- 9f. re-registration: fenced, and never loses the old key ---------------
# Upstream #73 (the same "tls: handshake failure" we saw) says a NEWLY GENERATED config
# works, so this is worth trying — but it burns the device key, and losing a registration
# to a guess is worse than the problem. Hence: keep the old one aside first, restore it if
# the new one changes nothing, and only run at all when the session DOES establish and
# still carries nothing (upstream #31 shows rotating addresses in that state does nothing).
rr=$(extract_fn warp_reregister_guarded "$WARPSH")
case "$rr" in
    *'cp -f "$USQUE_SESSION" "$USQUE_SESSION.prev"'*) ok "the old registration is copied aside first" ;;
    *) no "the old registration is copied aside first" "a backup" "absent" ;;
esac
# The backup must be taken BEFORE register runs, or there is nothing to go back to.
bk=$(printf '%s\n' "$rr" | grep -n 'session.conf.prev\|USQUE_SESSION.prev' | head -1 | cut -d: -f1)
rg=$(printf '%s\n' "$rr" | grep -n 'register --accept-tos' | head -1 | cut -d: -f1)
if [ -n "$bk" ] && [ -n "$rg" ] && [ "$bk" -lt "$rg" ]; then
    ok "the backup is taken before registering ($bk < $rg)"
else
    no "the backup is taken before registering" "backup first" "$bk/$rg"
fi
case "$rr" in
    *'private_key'*) ok "a truncated or key-less new config is rejected" ;;
    *) no "a truncated or key-less new config is rejected" "a validation" "absent" ;;
esac
case "$rr" in
    *_warp_cooldown_ok*) ok "re-registration respects the enrollment cooldown" ;;
    *) no "re-registration respects the enrollment cooldown" "the cooldown" "absent" ;;
esac
rb=$(extract_fn warp_reregister_rollback "$WARPSH")
case "$rb" in
    *'cp -f "$USQUE_SESSION.prev" "$USQUE_SESSION"'*) ok "a rollback restores the previous registration" ;;
    *) no "a rollback restores the previous registration" "the restore" "absent" ;;
esac
enable_fn4=$(extract_fn warp_enable "$WARPSH")
case "$enable_fn4" in
    *'reregged=1'*) ok "re-registration is attempted at most once per enable" ;;
    *) no "re-registration is attempted at most once per enable" "the once-guard" "absent" ;;
esac
case "$enable_fn4" in
    *warp_reregister_rollback*) ok "a final failure rolls the registration back" ;;
    *) no "a final failure rolls the registration back" "the rollback call" "absent" ;;
esac
# It must be reached ONLY through the connected branch: re-registering a tunnel that never
# connects burns a key for nothing.
conn_ln=$(printf '%s\n' "$enable_fn4" | grep -n 'if warp_engine_connected; then' | head -1 | cut -d: -f1)
rr_ln=$(printf '%s\n' "$enable_fn4" | grep -n 'warp_reregister_guarded' | head -1 | cut -d: -f1)
if [ -n "$conn_ln" ] && [ -n "$rr_ln" ] && [ "$conn_ln" -lt "$rr_ln" ]; then
    ok "re-registration only runs when the session establishes ($conn_ln < $rr_ln)"
else
    no "re-registration only runs when the session establishes" "gated" "$conn_ln/$rr_ln"
fi
# A success must drop the kept-aside copy, or it would be restored on some later run.
case "$enable_fn4" in
    *'rm -f "$USQUE_SESSION.prev"'*) ok "success discards the kept-aside registration" ;;
    *) no "success discards the kept-aside registration" "the cleanup" "absent" ;;
esac

# --- 9g. re-registration, BEHAVIOURALLY: the old key always comes back ------
# The checks above are structural. This one runs the function against a real file with a
# stubbed `usque register`, because "the backup is restored" is the property that decides
# whether a guess costs a user their registration. The first version of this check stubbed
# the wrong argument ($3 is "--config", the path is $4), so nothing was ever written and
# all of it passed while testing nothing.
RRW="$TMP/rr"; mkdir -p "$RRW/bin"
printf '{\n  "private_key": "ORIGINAL-KEY",\n  "endpoint_h2_v4": "162.159.198.2"\n}\n' > "$RRW/session.conf"
rr_orig=$(md5of() { :; }; cksum < "$RRW/session.conf")
{
    echo '_wlog() { :; }'
    echo 'warp_usque_restart() { return 0; }'
    echo '_warp_cooldown_ok() { [ -z "$RR_COOLDOWN_BLOCK" ]; }'
    extract_fn warp_reregister_guarded  "$WARPSH"
    extract_fn warp_reregister_rollback "$WARPSH"
} > "$RRW/fns.sh"
rr_drive() { sh -c ". '$RRW/fns.sh'; USQUE_BIN='$RRW/bin/usque'; USQUE_SESSION='$RRW/session.conf'; WARP_REG_STAMP='$RRW/st'; WARP_REG_COOLDOWN=0; $1" 2>&1; }
rr_same() { [ "$rr_orig" = "$(cksum < "$RRW/session.conf")" ]; }

# A new config with no key must be rejected and the old one put back.
printf '#!/bin/sh\n[ "$1" = register ] && { printf broken > "$4"; exit 0; }\nexit 1\n' > "$RRW/bin/usque"
chmod +x "$RRW/bin/usque"
out=$(rr_drive 'warp_reregister_guarded; echo "rc=$?"')
case "$out" in *rc=1*) ok "a key-less new registration is refused" ;;
    *) no "a key-less new registration is refused" "rc=1" "$out" ;; esac
rr_same && ok "...and the original registration is untouched" \
         || no "...and the original registration is untouched" "unchanged" "changed"
[ -f "$RRW/session.conf.prev" ] && no "...and no backup is left behind" "removed" "present" \
                                || ok "...and no backup is left behind"

# A valid new config is applied — and rolled back byte for byte when it does not help.
printf '#!/bin/sh\n[ "$1" = register ] && { printf "{\\"private_key\\": \\"NEW-KEY\\"}" > "$4"; exit 0; }\nexit 1\n' > "$RRW/bin/usque"
out=$(rr_drive 'warp_reregister_guarded; echo "rc=$?"')
case "$out" in *rc=0*) ok "a valid new registration is accepted" ;;
    *) no "a valid new registration is accepted" "rc=0" "$out" ;; esac
grep -q NEW-KEY "$RRW/session.conf" && ok "...and actually replaces the config" \
                                    || no "...and actually replaces the config" "NEW-KEY" "$(cat "$RRW/session.conf")"
rr_drive 'warp_reregister_rollback' >/dev/null
rr_same && ok "rollback restores the previous registration byte for byte" \
         || no "rollback restores the previous registration byte for byte" "the original" "$(cat "$RRW/session.conf")"
[ -f "$RRW/session.conf.prev" ] && no "rollback clears the backup" "removed" "present" \
                                || ok "rollback clears the backup"

# Under cooldown nothing may be touched at all — that guard is what stops a blocked
# router burning a device key on every attempt.
out=$(sh -c ". '$RRW/fns.sh'; RR_COOLDOWN_BLOCK=1; USQUE_BIN='$RRW/bin/usque'; USQUE_SESSION='$RRW/session.conf'; warp_reregister_guarded; echo rc=\$?" 2>&1)
case "$out" in *rc=1*) ok "the cooldown blocks re-registration" ;;
    *) no "the cooldown blocks re-registration" "rc=1" "$out" ;; esac
rr_same && ok "...without touching the config" || no "...without touching the config" "unchanged" "changed"

# --- 9h. the enable probe is patient; selfheal's is not ---------------------
# Upstream #49: after idle, Cloudflare makes new requests take 10-20 s. An 8 s ceiling
# cannot span that, so a waking tunnel reads as dead — the shape of every field log
# (session "Connected", probe times out, restarts make it worse by re-idling it).
# The widening must apply to ENABLE ONLY: selfheal runs the same probe every tick and
# blocking the scheduler for 20 s a time would be a new fault.
grep -q '^WARP_ENABLE_PROBE_TIMEOUT=' "$WARPSH" \
    && ok "the enable path has its own probe timeout" \
    || no "the enable path has its own probe timeout" "WARP_ENABLE_PROBE_TIMEOUT" "absent"
gt=$(sed -n 's/^WARP_PROBE_TIMEOUT="${WARP_PROBE_TIMEOUT:-\([0-9]*\)}".*/\1/p' "$WARPSH" | head -1)
et=$(sed -n 's/^WARP_ENABLE_PROBE_TIMEOUT="${WARP_ENABLE_PROBE_TIMEOUT:-\([0-9]*\)}".*/\1/p' "$WARPSH" | head -1)
[ -n "$gt" ] && [ -n "$et" ] && [ "$et" -gt "$gt" ] \
    && ok "enable waits longer than the per-tick probe ($et > $gt)" \
    || no "enable waits longer than the per-tick probe" "enable > global" "$et/$gt"
[ "$gt" = 8 ] && ok "the per-tick probe timeout is unchanged ($gt s)" \
              || no "the per-tick probe timeout is unchanged" 8 "$gt"
[ "$et" -ge 15 ] && ok "the enable probe spans the documented 10-20 s wake window ($et s)" \
                 || no "the enable probe spans the documented 10-20 s wake window" ">=15" "$et"
enable_fn5=$(extract_fn warp_enable "$WARPSH")
case "$enable_fn5" in
    *'WARP_PROBE_TIMEOUT="$WARP_ENABLE_PROBE_TIMEOUT"'*) ok "enable actually applies its own timeout" ;;
    *) no "enable actually applies its own timeout" "the assignment" "absent" ;;
esac
# Two probes at the widened timeout plus the gaps must still leave room for the
# escalation ladder inside the budget.
bud=$(sed -n 's/^WARP_ENABLE_BUDGET="${WARP_ENABLE_BUDGET:-\([0-9]*\)}".*/\1/p' "$WARPSH" | head -1)
rw=$(sed -n 's/^WARP_ENABLE_RETRY_WAIT="${WARP_ENABLE_RETRY_WAIT:-\([0-9]*\)}".*/\1/p' "$WARPSH" | head -1)
per=$(( et * 2 + rw + 3 ))
if [ "$bud" -ge $(( per * 2 )) ]; then
    ok "the budget still fits at least two full attempts (${per}s each of ${bud}s)"
else
    no "the budget still fits at least two full attempts" ">=$(( per * 2 ))" "$bud"
fi

# --- 9i. the engine is told to reconnect on its own -------------------------
# Parking in "Tunnel idle. Waiting for outbound activity" is the state Cloudflare
# penalises on wake, so do not park there.
S51W="$HERE/files/init.d/S51z2k-warp"
grep -q -- '--always-reconnect' "$S51W" \
    && ok "the engine is launched with --always-reconnect" \
    || no "the engine is launched with --always-reconnect" "the flag" "absent"
grep -q -- '-r "$RECONNECT_DELAY"' "$S51W" \
    && ok "the reconnect delay is passed explicitly" \
    || no "the reconnect delay is passed explicitly" "-r" "absent"
rd=$(sed -n 's/^RECONNECT_DELAY="${RECONNECT_DELAY:-\([0-9]*\)s}".*/\1/p' "$S51W" | head -1)
[ -n "$rd" ] && [ "$rd" -ge 5 ] \
    && ok "the reconnect delay is not the 1 s default (${rd}s) — no storm on a blocked ISP" \
    || no "the reconnect delay is not the 1 s default" ">=5s" "${rd:-unset}"

# --- 10. the caller actually prints the reason ------------------------------
enable_fn=$(extract_fn warp_enable "$WARPSH")
case "$enable_fn" in *'причина:'*) ok "warp_enable prints the reason line" ;;
    *) no "warp_enable prints the reason line" 'причина:' "absent" ;; esac
# ...and it must end in a verdict, never in "come back later".
case "$enable_fn" in
    *"НЕ поднялся"*) ok "warp_enable ends with a definitive no, not 'check later'" ;;
    *) no "warp_enable ends with a definitive no, not 'check later'" "НЕ поднялся" "absent" ;;
esac
# Non-comment lines only: the comment explaining WHY that sentence is gone contains it.
enable_code=$(printf '%s\n' "$enable_fn" | grep -v '^[[:space:]]*#')
case "$enable_code" in
    *"через минуту"*) no "warp_enable no longer defers to the user" "absent" "still defers" ;;
    *) ok "warp_enable no longer defers to the user" ;;
esac
# The diagnosis must NOT live inside the verdict function — selfheal calls that one every
# tick and a momentary pidof miss must never read as "dead".
live_fn=$(extract_fn warp_tunnel_live "$WARPSH")
case "$live_fn" in
    *warp_usque_running*) no "the verdict does not depend on the engine check" "absent" "present" ;;
    *) ok "the verdict does not depend on the engine check" ;;
esac
# ...and the webpanel no longer guesses next to it.
# Non-comment lines only — the commit that removed the guess mentions it in a comment,
# and matching that would make this assertion permanently red.
if grep -v '^[[:space:]]*#' "$ACTIONS" | grep -q 'регистрация/сеть'; then
    no "the panel stopped guessing '(регистрация/сеть)'" "absent" "still there"
else
    ok "the panel stopped guessing '(регистрация/сеть)'"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
