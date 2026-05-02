#!/bin/sh
# tests/test_install_completeness.sh
#
# End-to-end install pipeline integrity:
#   1) Каждый --lua-init reference в S99zapret2.new должен либо
#      downloaded by z2k.sh download_init_script(), либо whitelisted
#      как provided-by-fork-tarball (zapret-lib / zapret-antidpi /
#      zapret-auto / locked).
#   2) Каждый blob=NAME (non-hex) reference в strats_new2.txt /
#      lib/config_official.sh должен либо registered в S99zapret2.new
#      через --blob=NAME:@path, либо builtin (fake_default_*),
#      либо lua-defined через tls_mod() в одном из подгружаемых файлов.
#
# Runs at z2k repo root (script supports both bare path and tests/dir).

set -e

cd "$(dirname "$0")/.." || exit 1

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "[PASS] %s\n" "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "[FAIL] %s: expected '%s', got '%s'\n" "$desc" "$expected" "$actual"
    fi
}

printf "\n--- install completeness: lua-init coverage ---\n"

# 1) Collect lua files referenced via --lua-init in S99zapret2.new.
S99=files/S99zapret2.new

# Extract VAR="$ZAPRET_BASE/lua/X.lua" pairs, then check each with
# --lua-init=@$VAR or --lua-init=@$VAR appears.
LUA_INIT_REFS=$(awk -F'"' '
    /^[A-Z_0-9]+="\$ZAPRET_BASE\/lua\// {
        var=$0; sub(/=.*/,"",var)
        path=$2; sub(/^\$ZAPRET_BASE\//,"",path)
        ref[var]=path
    }
    END { for (v in ref) print v" "ref[v] }
' "$S99")

# Filter to only those actually used in --lua-init=@$VAR
USED_INITS=""
echo "$LUA_INIT_REFS" | while IFS=' ' read -r var path; do
    [ -z "$var" ] && continue
    if grep -q "\-\-lua-init=@\$$var" "$S99"; then
        printf "%s\n" "$path"
    fi
done > /tmp/test_install_inits.txt

# Also handle inline LUA_LIB / LUA_ANTIDPI (which are LUAOPT="--lua-init=@$LUA_LIB ...")
for inline_var in LUA_LIB LUA_ANTIDPI; do
    path=$(awk -F'"' "/^${inline_var}=\"\\\$ZAPRET_BASE\\/lua\\//{p=\$2; sub(/^\\\$ZAPRET_BASE\\//,\"\",p); print p; exit}" "$S99")
    [ -n "$path" ] && printf "%s\n" "$path" >> /tmp/test_install_inits.txt
done

LUA_USED=$(sort -u /tmp/test_install_inits.txt | tr '\n' ' ')

# 2) Collect downloaded files in z2k.sh (space-separated for substring match)
LUA_DOWNLOADED=$(grep -oE '\$\{GITHUB_RAW\}/files/lua/[a-zA-Z_0-9-]+\.lua' z2k.sh \
    | sed 's|.*files/||' | sort -u | tr '\n' ' ')

# 3) Whitelist of files provided by fork release tarball (extracted by
#    z2k_fetch'нный openwrt-embedded.tar.gz, not z2k.sh download_init_script):
TARBALL_WHITELIST="lua/zapret-lib.lua lua/zapret-antidpi.lua lua/zapret-auto.lua lua/locked.lua"

# 4) Diff
MISSING=""
for f in $LUA_USED; do
    case " $LUA_DOWNLOADED $TARBALL_WHITELIST " in
        *" $f "*) ;;
        *) MISSING="$MISSING $f" ;;
    esac
done
MISSING=$(printf "%s" "$MISSING" | xargs -n1 2>/dev/null | sort -u | xargs)
assert_eq "every --lua-init reference is downloaded or tarball-shipped" "" "$MISSING"

# 5) Inverse: downloaded but not referenced (waste / dead download)
EXTRA=""
for f in $LUA_DOWNLOADED; do
    case " $LUA_USED " in
        *" $f "*) ;;
        *) EXTRA="$EXTRA $f" ;;
    esac
done
EXTRA=$(printf "%s" "$EXTRA" | xargs -n1 2>/dev/null | sort -u | xargs)
assert_eq "no orphan downloads (downloaded but never lua-init'd)" "" "$EXTRA"

printf "\n--- install completeness: blob coverage ---\n"

# Collect every blob=NAME / seqovl_pattern=NAME reference (non-hex) from
# operational config sources.
BLOB_REFS=$( (cat lib/config_official.sh strats_new2.txt 2>/dev/null) \
    | grep -oE '\b(blob|seqovl_pattern)=[a-zA-Z_][a-zA-Z_0-9]*' \
    | cut -d= -f2 \
    | sort -u | tr '\n' ' ')

# Loaded by S99 via --blob=NAME:@path
LOADED_BLOBS=$(grep -oE '\-\-blob=[a-zA-Z_0-9]+:@' "$S99" \
    | sed 's/^--blob=//;s/:@$//' | sort -u | tr '\n' ' ')

# nfqws2 builtins
BUILTIN_BLOBS="fake_default_tls fake_default_http fake_default_quic all"

# lua-defined globals (via tls_mod() in any --lua-init'd file)
LUA_DEFINED=""
for f in $LUA_USED; do
    p="files/$f"
    [ -f "$p" ] || continue
    LUA_DEFINED="$LUA_DEFINED $(grep -oE '^[a-z_][a-zA-Z_0-9]*[[:space:]]*=[[:space:]]*tls_mod\(' "$p" \
        | sed 's/[[:space:]]*=.*//' | tr '\n' ' ')"
done

GHOST=""
for n in $BLOB_REFS; do
    case " $LOADED_BLOBS $BUILTIN_BLOBS $LUA_DEFINED " in
        *" $n "*) ;;
        *) GHOST="$GHOST $n" ;;
    esac
done
GHOST=$(printf "%s" "$GHOST" | xargs -n1 2>/dev/null | sort -u | xargs)
assert_eq "every blob= reference is registered or lua-defined" "" "$GHOST"

# Cleanup
rm -f /tmp/test_install_inits.txt

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
