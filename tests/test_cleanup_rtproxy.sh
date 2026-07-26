#!/bin/sh
# tests/test_cleanup_rtproxy.sh
#
# z2k_cleanup.sh must undo the RuTracker proxy completely.
#
# It had sections for :1443, :1444, :1446 and PPE but NONE for rt-proxy, and the
# consequence is worse than leftover clutter: the rutracker domains stay pinned in
# the router's own config to the sentinel 10.171.171.171 while nothing listens on
# :1445 any more, so rutracker is dead FOREVER and nothing on the box explains why.
# People run this script precisely when something is already broken, so it must not
# add a breakage of its own.
#
# Asserted behaviourally: mock iptables/ndmc/conntrack record their argv, the real
# section is executed against them, and the test checks the commands that were
# actually issued — including the LD_LIBRARY_PATH= prefix, without which ndmc dies
# with "Cli::Main: failed to initialize" (measured on KeenOS 5.01.C.1.0-0) and the
# pins silently survive.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=${Z2K_CLEANUP_UNDER_TEST:-"$HERE/z2k_cleanup.sh"}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/clrtp.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$SRC" ] || { printf '[FAIL] not found: %s\n' "$SRC"; exit 1; }

# Pull just the rt-proxy section out, between its banner and the next one.
sed -n '/^# 5a-rt\./,/^# 5b\./p' "$SRC" | sed '$d' > "$TMP/section.sh"
if [ ! -s "$TMP/section.sh" ]; then
    no "the rt-proxy cleanup section exists" "a section" "none"
    printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
    exit 1
fi
ok "the rt-proxy cleanup section exists"

BIN="$TMP/bin"; mkdir -p "$BIN"
# iptables: records argv; -C succeeds ONCE per distinct rule so the while-loops
# delete exactly once and terminate (a mock that always succeeds would hang).
cat > "$BIN/iptables" <<EOF
#!/bin/sh
printf 'iptables %s\n' "\$*" >> "$TMP/cmd.log"
for a in "\$@"; do case "\$a" in -C) key=\$(printf '%s' "\$*" | tr -d ' /');
    if [ -f "$TMP/seen.\$key" ]; then exit 1; fi; : > "$TMP/seen.\$key"; exit 0 ;; esac; done
exit 0
EOF
cat > "$BIN/ndmc" <<EOF
#!/bin/sh
printf 'ndmc LLP=[%s] %s\n' "\${LD_LIBRARY_PATH-UNSET}" "\$*" >> "$TMP/cmd.log"
exit 0
EOF
cat > "$BIN/conntrack" <<EOF
#!/bin/sh
printf 'conntrack %s\n' "\$*" >> "$TMP/cmd.log"
exit 0
EOF
chmod +x "$BIN/iptables" "$BIN/ndmc" "$BIN/conntrack"

: > "$TMP/cmd.log"
cat > "$TMP/run.sh" <<EOF
log_info() { :; }
log_skip() { :; }
LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib
export LD_LIBRARY_PATH
. "$TMP/section.sh"
EOF
PATH="$BIN:$PATH" sh "$TMP/run.sh" >/dev/null 2>&1

grepc() { grep -c "$1" "$TMP/cmd.log" 2>/dev/null || true; }

# --- the NAT redirect to the proxy port -------------------------------------
n=$(grepc 'iptables .*-D PREROUTING -d 10.171.171.171 -p tcp --dport 443 -j REDIRECT --to-port 1445')
[ "${n:-0}" -ge 1 ] && ok "removes the PREROUTING REDIRECT to :1445" \
                    || no "removes the PREROUTING REDIRECT to :1445" ">=1" "${n:-0}"
n=$(grepc 'iptables .*-D OUTPUT -d 10.171.171.171 -p tcp --dport 443 -j REDIRECT --to-port 1445')
[ "${n:-0}" -ge 1 ] && ok "removes the OUTPUT REDIRECT to :1445" \
                    || no "removes the OUTPUT REDIRECT to :1445" ">=1" "${n:-0}"

# --- the PPE de-offload rule, installed separately from the REDIRECT --------
n=$(grepc 'iptables .*-t mangle -D PREROUTING -d 10.171.171.171 .*-j PPE')
[ "${n:-0}" -ge 1 ] && ok "removes the sentinel PPE de-offload rule" \
                    || no "removes the sentinel PPE de-offload rule" ">=1" "${n:-0}"

# --- conntrack for the sentinel ---------------------------------------------
n=$(grepc 'conntrack .*-d 10.171.171.171')
[ "${n:-0}" -ge 1 ] && ok "flushes conntrack for the sentinel" \
                    || no "flushes conntrack for the sentinel" ">=1" "${n:-0}"

# --- THE pins: all seven domains, and every ndmc call must be unpoisoned ----
missing=""
for d in rutracker.org www.rutracker.org rutracker.cc static.rutracker.cc \
         api.rutracker.cc rep.rutracker.cc rutracker.wiki; do
    grep -q "no ip host $d 10.171.171.171" "$TMP/cmd.log" 2>/dev/null || missing="$missing $d"
done
[ -z "$missing" ] && ok "unpins all seven rutracker domains" \
                  || no "unpins all seven rutracker domains" "all" "missing:$missing"

leaked=$(grepc 'ndmc LLP=\[/opt'); leaked=${leaked:-0}
[ "$leaked" = 0 ] && ok "every ndmc call clears LD_LIBRARY_PATH" \
                  || no "every ndmc call clears LD_LIBRARY_PATH" 0 "$leaked"

n=$(grepc 'ndmc .*system configuration save')
[ "${n:-0}" -ge 1 ] && ok "persists the unpin to the router config" \
                    || no "persists the unpin to the router config" ">=1" "${n:-0}"

# --- the loops must terminate ------------------------------------------------
# A `while iptables -C ...; do iptables -D ...; done` against a mock that always
# succeeds would spin forever. Bound the evidence: a sane run issues few commands.
total=$(wc -l < "$TMP/cmd.log" | tr -d ' ')
[ "${total:-0}" -lt 200 ] && ok "the delete loops terminate (${total} commands issued)" \
                          || no "the delete loops terminate" "<200 commands" "$total"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
