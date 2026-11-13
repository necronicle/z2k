#!/bin/sh
# Real config generation and updater flag backup, isolated from /opt.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
. "$ROOT/lib/utils.sh" 2>/dev/null
. "$ROOT/lib/config_official.sh"
. "$ROOT/lib/auto_update.sh"
print_info() { :; }; print_success() { :; }; print_warning() { :; }
au_log() { :; }
failed=0
check() {
    if [ "$2" = "$3" ]; then echo "[PASS] $1"; else
        echo "[FAIL] $1: expected '$2', got '$3'"; failed=$((failed+1))
    fi
}
router() {
    ZAPRET2_DIR="$TMP/$1"; export ZAPRET2_DIR
    mkdir -p "$ZAPRET2_DIR/lists" "$ZAPRET2_DIR/extra_strats"
}
regen() { create_official_config "$ZAPRET2_DIR/config" > "$TMP/generate.log" 2>&1 || { cat "$TMP/generate.log"; exit 1; }; }
# Every previously shipped switch is exercised at both explicit values.
registry=$(z2k_toggle_defaults 2>/dev/null || true)
router missing
printf '# old config without flags\n' > "$ZAPRET2_DIR/config"
regen
# Audited defaults of the source release, independent of the new registry.
legacy_pairs='ENABLED:0 DISABLE_CUSTOM:0 DISABLE_IPV6:0 POLICY_EXCLUDE:0 GAME_WARP_ENABLED:0 TG_PROXY_USER_DISABLED:0
Z2K_CATEGORY_YOUTUBE:1 Z2K_CATEGORY_RKN:1 Z2K_CATEGORY_DISCORD_VOICE:1
Z2K_CIRCULAR_RESET:1 Z2K_DISCORD_UPDATE_TLS_TIMEOUT:1 Z2K_INJECT_TLS_MODS:0
Z2K_PADENCAP:1 Z2K_NFQWS2_TEMPLATES:1 Z2K_DYNAMIC_TTL:1 Z2K_INSTA_DNS:1
Z2K_REDIRECTOR_DNS:1 Z2K_SNI_STALL:1 Z2K_GV_SERVER_REPLY2:1
Z2K_QUIC_OFF:0 Z2K_YT_QUIC_OFF:0 Z2K_PPE_DEOFFLOAD_QUIC:1 Z2K_PANEL_AUTH:0
Z2K_AUTO_UPDATE_ENABLED:1 Z2K_AUTOHOSTLIST:0 Z2K_WARP_WDTT:0 Z2K_REFACTOR_PHASE3:0'
for pair in $legacy_pairs; do
    key=${pair%:*}; want=${pair#*:}
    check "missing key freezes old default $key" "$want" "$(safe_config_read "$key" "$ZAPRET2_DIR/config" missing)"
done
for want in 0 1; do
    router "explicit$want"
    printf 'Z2K_GV_SERVER_REPLY2=%s\nZ2K_DYNAMIC_TTL=%s\nZ2K_UDP_MISC=%s\nZ2K_REFACTOR_PHASE3=%s\n' "$want" "$want" "$want" "$want" > "$ZAPRET2_DIR/config"
    if [ -n "$registry" ]; then
        printf '%s\n' "$registry" | while read -r key def off; do
            printf '%s=%s\n' "$key" "$want"
        done > "$ZAPRET2_DIR/config"
    fi
    printf 'Z2K_UDP_MISC=%s\n' "$want" >> "$ZAPRET2_DIR/config"
    regen
    ! grep -q 'key=udp_misc\|--filter-udp=590-600' "$ZAPRET2_DIR/config"
    for key in $(printf '%s\n' "$registry" | awk '{print $1}') Z2K_GV_SERVER_REPLY2 Z2K_DYNAMIC_TTL Z2K_REFACTOR_PHASE3; do
        check "explicit $key=$want" "$want" "$(safe_config_read "$key" "$ZAPRET2_DIR/config" missing)"
    done
    cp "$ZAPRET2_DIR/config" "$TMP/before"
    regen
    if cmp -s "$TMP/before" "$ZAPRET2_DIR/config"; then echo '[PASS] repeat unchanged'; else check repeat identical changed; fi
done
for key in Z2K_GV_PREFLIGHT Z2K_GV_SERVER_REPLY; do
    router "$key"
    printf '%s=0\n' "$key" > "$ZAPRET2_DIR/config"
    regen
    check "rename preserves $key=0" 0 "$(safe_config_read Z2K_GV_SERVER_REPLY2 "$ZAPRET2_DIR/config" missing)"
done
router fresh-base
regen
for pair in $legacy_pairs; do
    key=${pair%:*}; want=${pair#*:}
    case "$key" in ENABLED|DISABLE_CUSTOM) want=1 ;; DISABLE_IPV6) continue ;; esac
    check "fresh default $key" "$want" "$(safe_config_read "$key" "$ZAPRET2_DIR/config" missing)"
done
# New-version declaration; the immutable bootstrap deliberately has no entry.
if command -v z2k_toggle_defaults >/dev/null 2>&1; then
    eval "$(sed -n '/^z2k_toggle_defaults() {/,/^}/p' "$ROOT/lib/config_official.sh" | sed '1s/z2k_toggle_defaults/z2k_test_old_defaults/')"
    z2k_toggle_defaults() { z2k_test_old_defaults; echo 'Z2K_TEST_NEXT 1 0'; echo 'Z2K_TEST_DISABLED 0 1'; }
    router missing
    regen
    check 'next toggle disabled on existing install' 0 "$(safe_config_read Z2K_TEST_NEXT "$ZAPRET2_DIR/config" missing)"
    check 'next inverse toggle disabled on existing install' 1 "$(safe_config_read Z2K_TEST_DISABLED "$ZAPRET2_DIR/config" missing)"
    router bootstrap-next
    printf '# old version without ledger\n' > "$ZAPRET2_DIR/config"
    regen
    check 'new toggle off even without prior ledger' 0 "$(safe_config_read Z2K_TEST_NEXT "$ZAPRET2_DIR/config" missing)"
    cp "$ZAPRET2_DIR/config" "$TMP/new-before"; regen
    cmp -s "$TMP/new-before" "$ZAPRET2_DIR/config" || check 'repeat new toggle' identical changed
    router fresh
    regen
    check 'fresh keeps next toggle current default' 1 "$(safe_config_read Z2K_TEST_NEXT "$ZAPRET2_DIR/config" missing)"
else
    check 'next toggle migration mechanism' present absent
fi
# Bootstrap must read the effective OLD default, even if current fallback differs.
router old-source
mkdir -p "$ZAPRET2_DIR/lib"
printf 'old=$(safe_config_read "Z2K_DYNAMIC_TTL" "$cfg" "0")\n' > "$ZAPRET2_DIR/lib/config_official.sh"
printf '# old config\n' > "$ZAPRET2_DIR/config"
regen
check 'old source default wins over current default' 0 "$(safe_config_read Z2K_DYNAMIC_TTL "$ZAPRET2_DIR/config" missing)"
router old-external-source
mkdir -p "$ZAPRET2_DIR/lib"
printf '# old generator without auto-update preservation\n' > "$ZAPRET2_DIR/lib/config_official.sh"
printf 'x=$(read_flag "Z2K_AUTO_UPDATE_ENABLED" "$cfg" "1")\n' > "$ZAPRET2_DIR/lib/auto_update.sh"
printf '# old config\n' > "$ZAPRET2_DIR/config"
regen
check 'old consumer outside generator supplies effective default' 1 "$(safe_config_read Z2K_AUTO_UPDATE_ENABLED "$ZAPRET2_DIR/config" missing)"

# Changing the NEW version default must not change an old effective value.
router default-change
printf '# old config\n' > "$ZAPRET2_DIR/config"
regen
cp "$ZAPRET2_DIR/config" "$TMP/default-before"
z2k_toggle_defaults() { z2k_test_old_defaults | sed 's/^Z2K_DYNAMIC_TTL 1 0$/Z2K_DYNAMIC_TTL 0 0/'; echo 'Z2K_TEST_NEXT 1 0'; echo 'Z2K_TEST_DISABLED 0 1'; }
regen
check 'new version default 0 keeps existing effective 1' 1 "$(safe_config_read Z2K_DYNAMIC_TTL "$ZAPRET2_DIR/config" missing)"
z2k_toggle_defaults() { z2k_test_old_defaults; echo 'Z2K_TEST_NEXT 1 0'; echo 'Z2K_TEST_DISABLED 0 1'; }
# Ledger contains old VERSION defaults, not the user's previous selection.
router removed-key
printf 'Z2K_DYNAMIC_TTL=0\n' > "$ZAPRET2_DIR/config"
regen
printf '# key removed, old runtime fallback is 1\n' > "$ZAPRET2_DIR/config"
regen
check 'removed key uses old runtime default, not last selection' 1 "$(safe_config_read Z2K_DYNAMIC_TTL "$ZAPRET2_DIR/config" missing)"
# A patch with zero regeneration steps must freeze newly delivered switches
# before a consumer/restart. Execute the real delivered step runner.
router zero-step
printf '# existing install\n' > "$ZAPRET2_DIR/config"
regen
mkdir -p "$ZAPRET2_DIR/lib"
cp "$ROOT/lib/config_official.sh" "$ROOT/lib/utils.sh" "$ZAPRET2_DIR/lib/"
{
    printf '\nz2k_toggle_defaults() { cat <<'"'"'NEXT_REGISTRY'"'"'\n'
    printf '%s\n' "$registry"
    printf 'Z2K_TEST_DELIVERED 1 0\nNEXT_REGISTRY\n}\n'
} >> "$ZAPRET2_DIR/lib/config_official.sh"
au_run_steps
check 'zero-step patch freezes delivered new toggle' 0 "$(safe_config_read Z2K_TEST_DELIVERED "$ZAPRET2_DIR/config" missing)"
# First patch can replace the old module before regen; source tag disambiguates
# historical aliases from stale, already ineffective pre-policy leftovers.
for scenario in 'p-87.20:none:0' 'p-87.21:none:0' 'p-87.23:none:0' \
                'p-87.23:Z2K_GV_PREFLIGHT=0:0' 'p-87.23:Z2K_GV_PREFLIGHT=1:1' \
                'p-87.26:Z2K_GV_SERVER_REPLY=0:0' 'p-87.26:Z2K_GV_PREFLIGHT=0:1' \
                'p-87.26:none:1' 'p-87.33:Z2K_GV_PREFLIGHT=0:1' \
                'p-87.33:Z2K_GV_SERVER_REPLY=0:1'; do
    tag=${scenario%%:*}; tail=${scenario#*:}; line=${tail%:*}; want=${tail##*:}
    router "tag-$tag-$line"
    mkdir -p "$ZAPRET2_DIR/lib"
    cp "$ROOT/lib/config_official.sh" "$ZAPRET2_DIR/lib/"
    printf '%s\n' "$tag" > "$ZAPRET2_DIR/.z2k-installed-tag"
    printf '# old config\n' > "$ZAPRET2_DIR/config"
    [ "$line" = none ] || printf '%s\n' "$line" >> "$ZAPRET2_DIR/config"
    regen
    check "source release $tag ($line) preserves effective preflight" "$want" "$(safe_config_read Z2K_GV_SERVER_REPLY2 "$ZAPRET2_DIR/config" missing)"
done
# A future boolean exposed by the UI must join the migration registry.
grep -hE 'read_flag "[A-Z0-9_]+" .* "[01]"' "$ROOT"/webpanel/cgi/*.sh \
    | sed -n 's/.*read_flag "\([A-Z0-9_]*\)".*/\1/p' | sort -u > "$TMP/ui-bools"
while IFS= read -r key; do
    if printf '%s\n' "$registry" | grep -q "^$key "; then
        check "UI switch registered $key" yes yes
    else
        check "UI switch registered $key" yes no
    fi
done < "$TMP/ui-bools"
# Backup must retain non-Z2K switches too.
router backup
printf 'GAME_WARP_ENABLED=1\nENABLED=0\nDISABLE_CUSTOM=0\n' > "$ZAPRET2_DIR/config"
au_save_feature_flags "$TMP/flags"
check 'backup keeps WARP' 1 "$(safe_config_read GAME_WARP_ENABLED "$TMP/flags" missing)"
printf 'Z2K_DYNAMIC_TTL=1\n' > "$ZAPRET2_DIR/config"
au_reapply_feature_flags "$TMP/flags"
check 'reapply restores absent WARP key' 1 "$(safe_config_read GAME_WARP_ENABLED "$ZAPRET2_DIR/config" missing)"
check 'reapply preserves service off' 0 "$(safe_config_read ENABLED "$ZAPRET2_DIR/config" missing)"
check 'reapply restores explicit custom scripts on' 0 "$(safe_config_read DISABLE_CUSTOM "$ZAPRET2_DIR/config" missing)"
[ "$failed" = 0 ]
