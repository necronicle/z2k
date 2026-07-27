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
# Exported once: the probe-behaviour cases below run in a child shell that writes its
# trace under $TMP. Passing it as a command prefix instead trips SC2097/2098 in CI.
export TMP

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
    *"сессия к Cloudflare установлена, но трафик внутри туннеля не проходит"*)
        ok "the verdict distinguishes 'session up, no traffic' from 'never came up'" ;;
    *)  no "the verdict distinguishes 'session up, no traffic' from 'never came up'" "the wording" "absent" ;;
esac
# ...and it must NOT name a culprit. The old wording blamed the provider, derived from a
# marker that means nothing, and that verdict was sent to a user.
case "$enable_fn3" in
    *"режет провайдер"*) no "the verdict does not blame the provider" "no blame" "still blames" ;;
    *) ok "the verdict does not blame the provider" ;;
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

# --- 9j. "Tunnel established" is not evidence of anything --------------------
# usque prints it unconditionally BEFORE it dials (cmd/nativetun.go). Treating it as a live
# session is what made enable skip endpoint variants, burn a re-registration and blame the
# provider. Only the HTTP 200 on CONNECT-IP counts.
mk_log '2026/07/27 10:00:00 UTC Tunnel established, you may now set up routing and DNS'
case "$(conn)" in *rc=1*) ok "'Tunnel established' alone is NOT treated as connected" ;;
    *) no "'Tunnel established' alone is NOT treated as connected" "rc=1" "$(conn)" ;; esac
# A non-200 from Cloudflare is a failure we were not detecting at all.
mk_log '2026/07/27 10:00:00 UTC Connected to MASQUE server' \
       '2026/07/27 10:01:00 UTC Tunnel connection failed: 403'
case "$(conn)" in *rc=1*) ok "'Tunnel connection failed' is recognised as a failure" ;;
    *) no "'Tunnel connection failed' is recognised as a failure" "rc=1" "$(conn)" ;; esac
rm -f "$TMP/engine.log"

# --- 9k. a pinned endpoint variant cannot become permanent ------------------
# THE field bug: the init prefers session.alt.conf forever, and clearing it used to be
# reachable only from the final failure branch of enable. Reproduced on a live router — the
# engine kept starting against 188.114.98.1 across restarts, which is "restarting does not
# help" exactly.
exp=$(extract_fn warp_variant_expire "$WARPSH")
[ -n "$exp" ] && ok "there is a variant-expiry path at all" \
              || no "there is a variant-expiry path at all" "warp_variant_expire" "absent"
case "$exp" in
    *'warp_live_cached'*) ok "a variant that IS delivering is kept" ;;
    *) no "a variant that IS delivering is kept" "the liveness check" "absent" ;;
esac
case "$exp" in
    *WARP_VARIANT_TTL*) ok "expiry is time-bounded, not immediate (no race with enable)" ;;
    *) no "expiry is time-bounded, not immediate" "a TTL" "absent" ;;
esac
sh_fn=$(extract_fn warp_selfheal "$WARPSH")
case "$sh_fn" in
    *warp_variant_expire*) ok "selfheal runs the expiry (the toggle is not the only path)" ;;
    *) no "selfheal runs the expiry" "the call" "absent" ;;
esac
rr2=$(extract_fn warp_reregister_guarded "$WARPSH")
case "$rr2" in
    *warp_variant_clear*) ok "re-registration drops the pin first" ;;
    *) no "re-registration drops the pin first" "warp_variant_clear" "absent" ;;
esac
# Order matters: clearing after registering would leave the engine on the old key.
c_ln=$(printf '%s\n' "$rr2" | grep -n 'warp_variant_clear' | head -1 | cut -d: -f1)
g_ln=$(printf '%s\n' "$rr2" | grep -n 'register --accept-tos' | head -1 | cut -d: -f1)
if [ -n "$c_ln" ] && [ -n "$g_ln" ] && [ "$c_ln" -lt "$g_ln" ]; then
    ok "the pin is dropped BEFORE registering ($c_ln < $g_ln)"
else
    no "the pin is dropped BEFORE registering" "clear first" "$c_ln/$g_ln"
fi

# --- 9l. the guessed endpoints are gone -------------------------------------
# Measured: 188.114.x answer our SNI with alert 40 and no certificate, and with the correct
# SNI present a different public key that usque's pinning rejects. They are WireGuard-range
# addresses; upstream says h2 endpoints must be read off the official client.
eps=$(grep -m1 '^WARP_ENDPOINTS=' "$WARPSH")
case "$eps" in
    *188.114.*) no "no guessed WireGuard-range addresses among the candidates" "none" "$eps" ;;
    *) ok "no guessed WireGuard-range addresses among the candidates" ;;
esac
case "$eps" in
    *162.159.198.2*) ok "the documented endpoint is what remains" ;;
    *) no "the documented endpoint is what remains" "162.159.198.2" "$eps" ;;
esac
# The rewrite must be anchored on the endpoint line, or it can corrupt unrelated fields.
ap2=$(extract_fn warp_variant_apply "$WARPSH")
case "$ap2" in
    *'endpoint_h2_v4'*) ok "the endpoint rewrite is anchored on its own key" ;;
    *) no "the endpoint rewrite is anchored on its own key" "the anchor" "absent" ;;
esac

# --- 9m. the data path: MTU, NAT, PBR ---------------------------------------
# Everything here protects the FORWARDED path — the one users actually use, and the one our
# probe has never tested. The probe binds to the device and sources from the tunnel address;
# a LAN client's packet is forwarded, needs NAT and needs to be marked. All three could be
# broken while the probe stayed green, which is how "the panel says it works" and "the whole
# internet is down" were both true for the same router.

# MTU: usque reads the TUN with a buffer of exactly its own MTU and truncates silently;
# h2 mode has no PMTU discovery. Measured live: 1500 -> probe times out, 1280 -> warp=on.
mtu_fn=$(extract_fn warp_mtu_ensure "$WARPSH")
[ -n "$mtu_fn" ] && ok "there is an MTU invariant at all" \
                 || no "there is an MTU invariant at all" "warp_mtu_ensure" "absent"
case "$mtu_fn" in
    *'-le "$WARP_MTU"'*) ok "the invariant is an upper bound, not an equality" ;;
    *) no "the invariant is an upper bound, not an equality" "a <= check" "$mtu_fn" ;;
esac
case "$(extract_fn warp_pbr_up "$WARPSH")" in
    *warp_mtu_ensure*) ok "MTU is asserted before routing is applied" ;;
    *) no "MTU is asserted before routing is applied" "the call" "absent" ;;
esac
case "$(extract_fn warp_selfheal "$WARPSH")" in
    *warp_mtu_ensure*) ok "MTU is re-asserted on every selfheal tick" ;;
    *) no "MTU is re-asserted on every selfheal tick" "the call" "absent" ;;
esac
# The init must set it the moment the device appears, not wait for NDM (a 40 s window), and
# the iproute2 fallback must set it too — it used to set only the address.
S51M="$HERE/files/init.d/S51z2k-warp"
n=$(grep -c 'ip link set dev "$ifc" mtu "$MTU"' "$S51M")
[ "${n:-0}" -ge 2 ] && ok "the init sets MTU both on device appearance and in the fallback ($n)" \
                    || no "the init sets MTU in both places" ">=2" "$n"

# NAT: verified, not assumed. Dropping our MASQUERADE because "NDM does it" is only safe
# when NDM's rule actually exists — and it does not when `ip global` was never applied,
# which is precisely the state the fallback leaves behind.
np=$(extract_fn warp_nat_present "$WARPSH")
[ -n "$np" ] && ok "NDM's NAT is checked at runtime" || no "NDM's NAT is checked at runtime" "warp_nat_present" "absent"
purge=$(extract_fn warp_purge_legacy_nat "$WARPSH")
case "$purge" in
    *'! warp_nat_present'*) ok "the legacy purge refuses to run when NDM has no NAT" ;;
    *) no "the legacy purge refuses to run when NDM has no NAT" "the guard" "absent" ;;
esac
case "$(extract_fn warp_pbr_up "$WARPSH")" in
    *warp_nat_ensure*) ok "bringing routing up guarantees NAT exists" ;;
    *) no "bringing routing up guarantees NAT exists" "warp_nat_ensure" "absent" ;;
esac

# PBR: explicit pref (Keenetic's own rules sit at 100-4096) and an explicit mask
# (--set-mark clobbers the whole word, wiping Keenetic's own marks).
pbr=$(extract_fn warp_pbr_up "$WARPSH")
case "$pbr" in
    *'pref "$WARP_RULE_PREF"'*) ok "the ip rule has an explicit preference" ;;
    *) no "the ip rule has an explicit preference" "pref" "absent" ;;
esac
case "$pbr" in
    *'--set-xmark'*) ok "the mark is set with a mask (--set-xmark)" ;;
    *) no "the mark is set with a mask (--set-xmark)" "--set-xmark" "absent" ;;
esac
# Non-comment lines only — the comment explaining WHY --set-mark is wrong contains it.
# (Third time today that a grep matched my own explanation; the pattern is the lesson.)
pbr_code=$(printf '%s\n' "$pbr" | grep -v '^[[:space:]]*#')
case "$pbr_code" in
    *'--set-mark '*) no "the clobbering --set-mark form is gone from the add path" "absent" "still there" ;;
    *) ok "the clobbering --set-mark form is gone from the add path" ;;
esac
# ...but the DOWN path must still know the old form, or legacy rules become unremovable.
down=$(extract_fn warp_pbr_down "$WARPSH")
case "$down" in
    *'--set-mark '*) ok "the teardown still removes legacy --set-mark rules" ;;
    *) no "the teardown still removes legacy --set-mark rules" "the legacy form" "absent" ;;
esac
pref=$(sed -n 's/^WARP_RULE_PREF="${WARP_RULE_PREF:-\([0-9]*\)}".*/\1/p' "$WARPSH" | head -1)
[ -n "$pref" ] && [ "$pref" -lt 100 ] \
    && ok "our rule is consulted before Keenetic's policy rules (pref $pref < 100)" \
    || no "our rule is consulted before Keenetic's policy rules" "<100" "${pref:-unset}"

# --- 9n. engine hygiene: keepalive, -S, and a stop that stops ---------------
# `-k` is a NO-OP in --http2 (it only reaches the QUIC config), so nothing kept the session
# alive. Cloudflare drops an idle MASQUE session and then makes the wake-up take 10-20 s —
# longer than any probe we run, so an idle tunnel reads as broken and gets "repaired" by a
# restart that idles it again.
S51H="$HERE/files/init.d/S51z2k-warp"
grep -q 'KEEPALIVE_SECS' "$S51H" && ok "there is a keepalive of our own" \
                                 || no "there is a keepalive of our own" "KEEPALIVE_SECS" "absent"
ks=$(sed -n 's/^KEEPALIVE_SECS="${KEEPALIVE_SECS:-\([0-9]*\)}".*/\1/p' "$S51H" | head -1)
[ -n "$ks" ] && [ "$ks" -lt 300 ] \
    && ok "the keepalive fits inside Cloudflare's ~5 min idle drop (${ks}s)" \
    || no "the keepalive fits inside the idle window" "<300" "${ks:-unset}"
# curl, not ping: ICMP through the tunnel is dropped (measured on the router, 100% loss).
grep -q 'curl -4 --interface "$ifc" -s -m 5 -o /dev/null "$KEEPALIVE_URL"' "$S51H" \
    && ok "the keepalive uses a path that actually works through the tunnel" \
    || no "the keepalive uses a path that actually works" "curl through the interface" "absent"
# Short sleep steps: a long `sleep` is a separate child and survives its parent.
grep -q 'sleep 5' "$S51H" && ok "the keepalive sleeps in short steps (no orphaned sleep)" \
                          || no "the keepalive sleeps in short steps" "sleep 5" "absent"
grep -q -- '-S \\' "$S51H" && ok "IPv6 inside the tunnel is disabled (-S)" \
                          || no "IPv6 inside the tunnel is disabled (-S)" "-S" "absent"
# The launch must appear exactly once — an earlier edit of mine left a truncated copy of the
# command whose trailing backslash swallowed the following comment, so the engine started
# WITHOUT --http2 and in the foreground. dash -n was perfectly happy with it.
n=$(grep -c '"\$BIN" nativetun' "$S51H")
[ "$n" = 1 ] && ok "the engine is launched exactly once ($n)" \
             || no "the engine is launched exactly once" 1 "$n"
# A stop must take everything the supervisor spawned with it.
grep -q 'kill "$child" "$keeper" "$ndmjob"' "$S51H" \
    && ok "the TERM trap kills the daemon, the keepalive and the NDM job" \
    || no "the TERM trap kills all spawned jobs" "all three" "absent"

# --- 9o. our own handshake is excluded from the bypass ----------------------
# The MASQUE session is plain TLS to a Cloudflare address and z2k desyncs TLS. It survived
# only because our fronting SNI happens to be in the shipped whitelist — so a user editing
# that whitelist would start desyncing our own tunnel with no way to know why. The engine's
# NFQUEUE rules all carry `! --match-set nozapret dst`, so the address belongs in that set.
noz=$(extract_fn warp_endpoint_nozapret "$WARPSH")
[ -n "$noz" ] && ok "there is an endpoint exclusion at all" \
              || no "there is an endpoint exclusion at all" "warp_endpoint_nozapret" "absent"
case "$noz" in
    *nozapret*) ok "it uses the engine's own exclusion set, not a new rule" ;;
    *) no "it uses the engine's own exclusion set" "nozapret" "absent" ;;
esac
case "$noz" in
    *'ipset test nozapret'*) ok "it is idempotent (tests before adding)" ;;
    *) no "it is idempotent" "an ipset test" "absent" ;;
esac
# The address must come from the config actually in use, or we would exclude the wrong one.
case "$noz" in
    *'[ -s "$WARP_ALT_CONF" ] && cfg="$WARP_ALT_CONF"'*) ok "it reads the config the engine is really using" ;;
    *) no "it reads the config the engine is really using" "the alt-config check" "absent" ;;
esac
case "$(extract_fn warp_pbr_up "$WARPSH")" in
    *warp_endpoint_nozapret*) ok "the exclusion is applied when routing comes up" ;;
    *) no "the exclusion is applied when routing comes up" "the call" "absent" ;;
esac
case "$(extract_fn warp_selfheal "$WARPSH")" in
    *warp_endpoint_nozapret*) ok "the exclusion is re-applied every tick (the set is the engine's)" ;;
    *) no "the exclusion is re-applied every tick" "the call" "absent" ;;
esac

# --- 9p. the probe escalates instead of being uniformly slow ----------------
# Upstream #49: after idle, Cloudflare makes new requests take 10-20 s. An 8 s ceiling
# cannot span that. Raising it for EVERY probe would block the scheduler 20 s a tick, so the
# longer ceiling is paid only after two ordinary failures — never on a healthy router.
cat > "$TMP/retry.sh" <<'EOF'
WARP_PROBE_RETRY_WAIT=0
WARP_PROBE_TIMEOUT=8
WARP_PROBE_SLOW_TIMEOUT=20
WARP_PROBE_ESCALATE=1
warp_tunnel_live() { echo "$WARP_PROBE_TIMEOUT" >> "$TMP/probes"; return 1; }
EOF
extract_fn warp_tunnel_live_retry "$WARPSH" >> "$TMP/retry.sh"
echo 'warp_tunnel_live_retry; echo "rc=$?"; echo "after=$WARP_PROBE_TIMEOUT"' >> "$TMP/retry.sh"
: > "$TMP/probes"
out=$(sh "$TMP/retry.sh" 2>&1)
seq=$(tr '\n' ' ' < "$TMP/probes")
[ "$seq" = "8 8 20 " ] && ok "probes escalate 8 -> 8 -> 20 ($seq)" \
                       || no "probes escalate 8 -> 8 -> 20" "8 8 20" "$seq"
case "$out" in *"after=8"*) ok "the widened timeout is restored afterwards" ;;
    *) no "the widened timeout is restored afterwards" "after=8" "$out" ;; esac
case "$out" in *rc=1*) ok "all three failing means not live" ;;
    *) no "all three failing means not live" "rc=1" "$out" ;; esac
# A tunnel that answers on the first probe must cost exactly one probe.
cat > "$TMP/retry1.sh" <<'EOF'
WARP_PROBE_RETRY_WAIT=0
WARP_PROBE_TIMEOUT=8
WARP_PROBE_SLOW_TIMEOUT=20
warp_tunnel_live() { echo "$WARP_PROBE_TIMEOUT" >> "$TMP/probes1"; return 0; }
EOF
extract_fn warp_tunnel_live_retry "$WARPSH" >> "$TMP/retry1.sh"
echo 'warp_tunnel_live_retry; echo "rc=$?"' >> "$TMP/retry1.sh"
: > "$TMP/probes1"
out=$(sh "$TMP/retry1.sh" 2>&1)
n=$(grep -c . "$TMP/probes1")
[ "$n" = 1 ] && ok "a healthy tunnel still costs exactly one probe ($n)" \
             || no "a healthy tunnel still costs exactly one probe" 1 "$n"
# And WITHOUT the opt-in the retry must stop at two — selfheal runs this every tick and a
# down tunnel would otherwise eat 36 s of every 60 s.
cat > "$TMP/retry2.sh" <<'EOF'
WARP_PROBE_RETRY_WAIT=0
WARP_PROBE_TIMEOUT=8
WARP_PROBE_SLOW_TIMEOUT=20
WARP_PROBE_ESCALATE=0
warp_tunnel_live() { echo x >> "$TMP/probes2"; return 1; }
EOF
extract_fn warp_tunnel_live_retry "$WARPSH" >> "$TMP/retry2.sh"
echo 'warp_tunnel_live_retry' >> "$TMP/retry2.sh"
: > "$TMP/probes2"
sh "$TMP/retry2.sh" >/dev/null 2>&1
n2=$(grep -c . "$TMP/probes2")
[ "$n2" = 2 ] && ok "without the opt-in it still stops at two probes ($n2)" \
              || no "without the opt-in it still stops at two probes" 2 "$n2"
case "$(extract_fn warp_enable "$WARPSH")" in
    *'WARP_PROBE_ESCALATE=1'*) ok "only enable opts into the slow third probe" ;;
    *) no "only enable opts into the slow third probe" "the opt-in" "absent" ;;
esac

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
