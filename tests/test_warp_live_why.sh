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
{ extract_fn warp_explain_dead "$WARPSH"; echo; extract_fn warp_tunnel_live "$WARPSH"; } > "$FN"
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
    PATH="$BIN:$PATH" sh "$TMP/r.sh" 2>&1
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
