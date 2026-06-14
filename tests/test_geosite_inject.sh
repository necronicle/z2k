#!/bin/sh
# tests/test_geosite_inject.sh — unit test for z2k-geosite.sh inject_yt_video_domains
# (r-56.2: route video.google.com through the googlevideo profiles).
#
# z2k-geosite.sh runs `case "$cmd" in fetch) fetch_all` at the bottom with no
# sourced-guard, so we can't source it. Instead extract the const + function
# text from the source and eval it — this exercises the REAL function body.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GEOSITE="$SCRIPT_DIR/files/z2k-geosite.sh"
[ -f "$GEOSITE" ] || { echo "FAIL: $GEOSITE not found"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Sandbox that the real function writes into.
EXTRA="$TMP/extra_strats"
mkdir -p "$EXTRA/TCP/YT_GV" "$EXTRA/TCP/YT" "$EXTRA/UDP/YT"
log() { :; }  # function calls log() — stub it

# Pull the const + function verbatim from the shipped script.
eval "$(grep -E '^YT_VIDEO_DOMAINS=' "$GEOSITE")"
eval "$(sed -n '/^inject_yt_video_domains() {/,/^}/p' "$GEOSITE")"

[ "$YT_VIDEO_DOMAINS" = "video.google.com" ] \
    && ok "const: YT_VIDEO_DOMAINS = video.google.com" \
    || bad "const: YT_VIDEO_DOMAINS unexpected ('$YT_VIDEO_DOMAINS')"

# Seed lists as they look at runtime: YT_GV + UDP/YT carry googlevideo; YT (yt_tcp)
# has googlevideo stripped and must NOT receive the video domain.
printf 'googlevideo.com\n' > "$EXTRA/TCP/YT_GV/List.txt"
printf 'youtube.com\ngooglevideo.com\nytimg.com\n' > "$EXTRA/UDP/YT/List.txt"
printf 'youtube.com\nytimg.com\n' > "$EXTRA/TCP/YT/List.txt"

inject_yt_video_domains

grep -qxF 'video.google.com' "$EXTRA/TCP/YT_GV/List.txt" \
    && ok "inject: video.google.com added to TCP/YT_GV/List.txt" \
    || bad "inject: missing from TCP/YT_GV/List.txt"
grep -qxF 'video.google.com' "$EXTRA/UDP/YT/List.txt" \
    && ok "inject: video.google.com added to UDP/YT/List.txt" \
    || bad "inject: missing from UDP/YT/List.txt"
grep -qxF 'video.google.com' "$EXTRA/TCP/YT/List.txt" \
    && bad "inject: video.google.com WRONGLY added to TCP/YT (yt_tcp)" \
    || ok "inject: TCP/YT (yt_tcp) left untouched — only googlevideo lists"

# Idempotent: second run adds no duplicate.
inject_yt_video_domains
n=$(grep -cxF 'video.google.com' "$EXTRA/UDP/YT/List.txt")
[ "$n" = "1" ] && ok "idempotent: no duplicate after re-run" || bad "idempotent: got $n copies"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
