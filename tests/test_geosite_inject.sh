#!/bin/sh
# Exercise the real geosite Google filter, publication and offline migration.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GEO="$ROOT/files/z2k-geosite.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }
log() { :; }
ZAPRET2_DIR="$TMP/router"
EXTRA="$ZAPRET2_DIR/extra_strats"
TMP_DIR="$TMP/work"
ETAG_DIR="$TMP/etag"
mkdir -p "$EXTRA/TCP/RKN" "$EXTRA/TCP/YT" "$EXTRA/TCP/YT_GV" "$EXTRA/UDP/YT" "$ZAPRET2_DIR/lists" "$TMP_DIR" "$ETAG_DIR"
for fn in filter_google_domains clean_google_domains apply_new_list inject_yt_login_domains fetch_all; do
    body=$(awk -v fn="$fn" '$0 == fn "() {" { on=1 } on { print } on && /^}/ { exit }' "$GEO")
    eval "$body"
done
eval "$(sed -n '/^YT_LOGIN_DOMAINS=/p' "$GEO")"
cat > "$TMP/input" <<'EOF'
google.com
www.google.com
accounts.google.com
translate.google.com
video.google.com
stream.meet.google.com
meet.google.com
googlevideo.com
oauth2.googleapis.com
evilgoogle.com
google.com.example.org
# google.com is a comment
chatgpt.com
api.chatgpt.com
claude.ai
assets.claude.ai
gemini.google.com
github.com
api.github.com
cloudflareclient.com
api.cloudflareclient.com
cloudflare-dns.com
cloudflare-dns.com.example.org
github.com.example.org
notchatgpt.com
EOF
printf 'WWW.GOOGLE.COM\r\nwww.google.com.\n' >> "$TMP/input"
cat > "$TMP/expected" <<'EOF'
meet.google.com
googlevideo.com
oauth2.googleapis.com
evilgoogle.com
google.com.example.org
# google.com is a comment
cloudflare-dns.com.example.org
github.com.example.org
notchatgpt.com
EOF
filter_google_domains "$TMP/input" > "$TMP/output"
cmp -s "$TMP/expected" "$TMP/output" && ok 'suffix boundaries, Meet, case, CRLF and separate Google domains' || bad 'domain filter'
for f in "$EXTRA/TCP/RKN/List.txt" "$EXTRA/TCP/YT/List.txt" "$EXTRA/TCP/YT_GV/List.txt" "$EXTRA/UDP/YT/List.txt" "$ZAPRET2_DIR/lists/extra-domains.txt" "$ZAPRET2_DIR/lists/autohostlist-domains.txt"; do
    cp "$TMP/input" "$f"
done
for f in whitelist.txt sni_wl_candidates.txt; do cp "$TMP/input" "$ZAPRET2_DIR/lists/$f"; done
ZAPRET2_DIR="$ZAPRET2_DIR" sh "$GEO" clean-google >/dev/null 2>&1 || bad 'offline command exit'
for f in "$EXTRA"/*/*/List.txt "$ZAPRET2_DIR/lists/extra-domains.txt" "$ZAPRET2_DIR/lists/autohostlist-domains.txt"; do
    cmp -s "$TMP/expected" "$f" && ok "offline cleanup: ${f#"$ZAPRET2_DIR"/}" || bad "offline cleanup: $f"
done
for f in whitelist.txt sni_wl_candidates.txt; do
    cmp -s "$TMP/input" "$ZAPRET2_DIR/lists/$f" && ok "untouched: $f" || bad "untouched: $f"
done
clean_google_domains && cmp -s "$TMP/expected" "$EXTRA/TCP/RKN/List.txt" && ok 'cleanup is idempotent' || bad 'idempotence'
inject_yt_login_domains
filter_google_domains "$EXTRA/TCP/YT/List.txt" > "$TMP/output"
if cmp -s "$TMP/output" "$EXTRA/TCP/YT/List.txt" && grep -qxF accounts.youtube.com "$TMP/output" && grep -qxF oauth2.googleapis.com "$TMP/output"; then
    ok 'login injection preserves YouTube endpoints without Google accounts'
else bad 'login injection'; fi
# Publication must filter before the atomic rename, even if every input entry
# is removed. Intentional filtering is not upstream truncation.
printf 'domain:google.com\nfull:www.google.com\n' > "$TMP/upstream"
if apply_new_list "$TMP/upstream" "$TMP/published" youtube.txt && [ ! -s "$TMP/published" ]; then
    ok 'publication removes all prohibited entries without shrink-guard rejection'
else bad 'publication all-Google'; fi
printf 'domain:accounts.google.com\ndomain:meet.google.com\ndomain:googlevideo.com\n' > "$TMP/upstream"
if apply_new_list "$TMP/upstream" "$TMP/published" youtube.txt && grep -qxF meet.google.com "$TMP/published" && ! grep -qxF accounts.google.com "$TMP/published"; then
    ok 'fresh normalized publication keeps Meet and removes accounts'
else bad 'publication normalization'; fi
# Network boundary only is mocked: run the actual fetch_all orchestration.
ensure_deps() { :; }
_z2k_rkn_fp_gate() { :; }
pick_rkn_asset() { echo ru-blocked.txt; }
fetch_asset() { return "$FETCH_RC"; }
subtract_googlevideo_from_yt() { :; }
subtract_yt_from_rkn() { :; }
subtract_false_positive_from_rkn() { :; }
purge_stale_google_state() { :; }
purge_stale_instagram_state() { :; }
for FETCH_RC in 0 1; do
    cp "$TMP/input" "$EXTRA/TCP/RKN/List.txt"
    fetch_all; rc=$?
    if [ "$rc" -eq "$FETCH_RC" ] && cmp -s "$TMP/expected" "$EXTRA/TCP/RKN/List.txt"; then
        ok "fetch without new bodies still cleans old lists (network rc=$FETCH_RC)"
    else bad "fetch cleanup rc=$FETCH_RC"; fi
done
# Real init entrypoint must clean before starting the daemon, including the
# direct start_daemons command. Check its ordering with a stubbed spawn only.
ZAPRET_BASE="$ZAPRET2_DIR"
cp "$GEO" "$ZAPRET_BASE/z2k-geosite.sh"
eval "$(sed -n '/^start_daemons()/,/^}/p' "$ROOT/files/S99zapret2.new")"
z2k_daemon_fail_reset() { :; }
ensure_autocircular_files() { :; }
_z2k_retire_cf_extra_state() { :; }
ensure_autohostlist_files() { :; }
custom_runner() { :; }
repair_autocircular_files_after_daemon_start() { :; }
z2k_daemon_fail_count() { echo 0; }
standard_mode_daemons() {
    cmp -s "$TMP/expected" "$EXTRA/TCP/RKN/List.txt" && touch "$TMP/spawn-clean"
}
cp "$TMP/input" "$EXTRA/TCP/RKN/List.txt"
start_daemons >/dev/null 2>&1
[ -f "$TMP/spawn-clean" ] && ok 'init cleans before spawning daemon' || bad 'init cleanup ordering'
for f in "$ROOT"/files/lists/extra_strats/*/*/List.txt; do
    # RKN is a bundled fallback, not a patch-delivered list. Its existing
    # entries are filtered by clean-google before the daemon starts.
    [ "$f" = "$ROOT/files/lists/extra_strats/TCP/RKN/List.txt" ] && continue
    filter_google_domains "$f" > "$TMP/output"
    cmp -s "$f" "$TMP/output" && ok "shipped list clean: ${f#"$ROOT"/}" || bad "shipped list: $f"
done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
