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
{ grep -m1 "^WARP_ENGINE_LOG=" "$WARPSH"; extract_fn warp_engine_tail "$WARPSH"; echo; extract_fn warp_explain_dead "$WARPSH"; echo; extract_fn warp_tunnel_live "$WARPSH"; } > "$FN"
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
