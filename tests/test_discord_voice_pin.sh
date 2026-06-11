#!/bin/sh
# tests/test_discord_voice_pin.sh — unit test for z2k-discord-voice-pin.sh
# (Flowseal-mirror Discord-voice ndmc ip host pinning).
#
# Stubs ndmc (a running-config file backs the "show"/"ip host"/"no ip host"
# verbs), curl (health-check code), conntrack. Paths point at a sandbox via the
# Z2K_DVP_* env overrides. The script is sourced in a subshell so its exit
# doesn't kill the test and the stub functions shadow the real commands.

SCRIPT="files/z2k-discord-voice-pin.sh"
[ -f "$SCRIPT" ] || SCRIPT="./files/z2k-discord-voice-pin.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

RC="$TMP/runconfig"; : > "$RC"
CFG="$TMP/config";    : > "$CFG"
LST="$TMP/list"
LOGF="$TMP/log"

# Flowseal-format list: 3 finland nodes -> one CF edge.
printf '%s\n' \
  '104.25.158.178 finland10000.discord.media' \
  '104.25.158.178 finland10001.discord.media' \
  '104.25.158.178 finland10002.discord.media' > "$LST"

count_pins() { grep -cE '^ip host finland[0-9]+\.discord\.media' "$RC" 2>/dev/null; }

# run <health_code> [list_path]  — execute the script with stubs + sandbox env.
run() {
    _hc="$1"; _lst="${2:-$LST}"
    (
        ndmc() {
            _c="$2"
            case "$_c" in
                "show running-config") cat "$RC" 2>/dev/null ;;
                "ip host "*)    echo "ip host ${_c#ip host }" >> "$RC" ;;
                "no ip host "*) _t="ip host ${_c#no ip host }"
                                grep -vxF "$_t" "$RC" 2>/dev/null > "$RC.t"
                                mv -f "$RC.t" "$RC" 2>/dev/null ;;
                *) : ;;
            esac
        }
        curl() { printf '%s' "$_hc"; }
        conntrack() { :; }
        export Z2K_DVP_CONFIG="$CFG" Z2K_DVP_LIST="$_lst" Z2K_DVP_LOG="$LOGF"
        . "$SCRIPT"
    )
}

# 1. apply: enabled + reachable edge -> all 3 finland nodes pinned.
: > "$RC"; : > "$CFG"
run 403
[ "$(count_pins)" = "3" ] && ok "apply: 3 finland pins added" || bad "apply: expected 3, got $(count_pins)"
grep -qxF 'ip host finland10001.discord.media 104.25.158.178' "$RC" \
    && ok "apply: pin maps host -> CF edge" || bad "apply: wrong pin content"

# 2. idempotent: re-run with the same desired state -> no change.
run 403
[ "$(count_pins)" = "3" ] && ok "idempotent: still 3 after re-run" || bad "idempotent: got $(count_pins)"

# 3. disable: Z2K_DISCORD_VOICE_PIN=0 -> strip all pins.
echo 'Z2K_DISCORD_VOICE_PIN=0' > "$CFG"
run 403
[ "$(count_pins)" = "0" ] && ok "disable: pins removed on flag=0" || bad "disable: got $(count_pins)"

# 4. health-check fail: dead edge (empty code) -> remove pins, never keep a
#    dead-IP pin (re-enable first, seed pins, then fail the health-check).
: > "$CFG"; : > "$RC"; run 403
[ "$(count_pins)" = "3" ] || bad "health-fail setup: expected 3, got $(count_pins)"
run ""
[ "$(count_pins)" = "0" ] && ok "health-fail: pins removed (no dead-IP pin)" || bad "health-fail: got $(count_pins)"

# 5. IP rotation: edge changed in the list -> repin all to the new IP.
: > "$RC"; : > "$CFG"; run 403
printf '%s\n' '188.114.96.7 finland10000.discord.media' \
              '188.114.96.7 finland10001.discord.media' \
              '188.114.96.7 finland10002.discord.media' > "$TMP/list2"
run 403 "$TMP/list2"
[ "$(grep -c '188.114.96.7' "$RC")" = "3" ] && [ "$(grep -c '104.25.158.178' "$RC")" = "0" ] \
    && ok "rotation: all pins moved to new edge" || bad "rotation: $(grep -c '188.114.96.7' "$RC") new / $(grep -c '104.25.158.178' "$RC") old"

# 6. missing list -> no-op (don't touch anything).
: > "$RC"; : > "$CFG"
run 403 "$TMP/does-not-exist"
[ "$(count_pins)" = "0" ] && ok "missing-list: no pins applied" || bad "missing-list: got $(count_pins)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
