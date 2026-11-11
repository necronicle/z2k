#!/bin/sh
# Run actual shipped builders; catches reintroduction from upstream/learned lists.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mode=${1:-all}
if [ "$mode" = all ] || [ "$mode" = shipped ]; then
    if grep -Rni gvt1 "$ROOT/files/lists"; then echo '[FAIL] shipped gvt1'; exit 1; fi
fi
if [ "$mode" = all ] || [ "$mode" = build ]; then
    eval "$(sed -n '/^filter_google_domains() {/,/^}/p' "$ROOT/files/z2k-geosite.sh")"
    eval "$(sed -n '/^apply_new_list() {/,/^}/p' "$ROOT/files/z2k-geosite.sh")"
    TMP_DIR=$TMP/work; mkdir -p "$TMP_DIR"
    log() { :; }
    { i=1; while [ "$i" -le 100 ]; do echo "domain:keep$i.example"; i=$((i+1)); done
      printf 'domain:gvt1.com\nfull:rr.gvt1.com\ndomain:RR.GVT1.COM.\ndomain:notgvt1.com\ndomain:gvt1.com.example\n'
    } > "$TMP/upstream"
    apply_new_list "$TMP/upstream" "$TMP/List.txt" youtube.txt
    if grep -iE '(^|\.)gvt1\.com\.?$' "$TMP/List.txt"; then echo '[FAIL] upstream gvt1 survived'; exit 1; fi
    grep -qx notgvt1.com "$TMP/List.txt"
    grep -qx gvt1.com.example "$TMP/List.txt"
fi
if [ "$mode" = all ] || [ "$mode" = offline ]; then
    for f in extra_strats/TCP/RKN/List.txt extra_strats/TCP/YT/List.txt extra_strats/UDP/YT/List.txt extra_strats/TCP/YT_GV/List.txt extra_strats/TCP/YT/List.txt.shipped files/lists/extra_strats/TCP/YT/List.txt lists/extra_strats/TCP/YT/List.txt lists/autohostlist-domains.txt ipset/zapret-hosts-auto.txt; do
        mkdir -p "$TMP/install/$(dirname "$f")"
        printf 'gvt1.com\nRR.GVT1.COM.\nkeep.example\n' > "$TMP/install/$f"
    done
    printf 'gvt1.com\n' > "$TMP/install/lists/extra-domains.txt"
    cp "$TMP/install/lists/extra-domains.txt" "$TMP/user-original"
    ZAPRET2_DIR=$TMP/install sh "$ROOT/files/z2k-geosite.sh" clean-google
    for f in "$TMP/install/extra_strats"/*/*/List.txt "$TMP/install/extra_strats/TCP/YT/List.txt.shipped" "$TMP/install/files/lists/extra_strats/TCP/YT/List.txt" "$TMP/install/lists/extra_strats/TCP/YT/List.txt" "$TMP/install/lists/autohostlist-domains.txt" "$TMP/install/ipset/zapret-hosts-auto.txt"; do
        printf 'keep.example\n' > "$TMP/expected"
        cmp "$TMP/expected" "$f"
    done
    cmp "$TMP/user-original" "$TMP/install/lists/extra-domains.txt"
fi
if [ "$mode" = all ] || [ "$mode" = auto ]; then
    eval "$(sed -n '/^normalize_autohost_domains()/,/^}/p' "$ROOT/files/S99zapret2.new")"
    printf 'gvt1.com\n*.rr.gvt1.com\nhttps://RR.GVT1.COM/path\nkeep.example\n' | normalize_autohost_domains > "$TMP/auto"
    printf 'keep.example\n' > "$TMP/expected"
    cmp "$TMP/expected" "$TMP/auto"
fi
echo "[PASS] gvt1 lists ($mode)"
