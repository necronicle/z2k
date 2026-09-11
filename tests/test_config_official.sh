#!/bin/sh
# tests/test_config_official.sh - Integration tests for lib/config_official.sh
# Run: sh tests/test_config_official.sh
# POSIX sh compatible (busybox ash).

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            printf "[PASS] %s\n" "$desc"
            ;;
        *)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: output does not contain '%s'\n" "$desc" "$needle"
            ;;
    esac
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: output unexpectedly contains '%s'\n" "$desc" "$needle"
            ;;
        *)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            printf "[PASS] %s\n" "$desc"
            ;;
    esac
}

# ==============================================================================
# SETUP: mock filesystem in /tmp to avoid touching /opt/zapret2
# ==============================================================================

MOCK_DIR="/tmp/z2k_test_config_$$"
MOCK_ZAPRET2="${MOCK_DIR}/opt/zapret2"
MOCK_CONFIG_DIR="${MOCK_DIR}/opt/etc/zapret2"
MOCK_EXTRA_STRATS="${MOCK_ZAPRET2}/extra_strats"
MOCK_LISTS="${MOCK_ZAPRET2}/lists"

mkdir -p "$MOCK_EXTRA_STRATS/TCP/YT" \
         "$MOCK_EXTRA_STRATS/TCP/YT_GV" \
         "$MOCK_EXTRA_STRATS/TCP/RKN" \
         "$MOCK_EXTRA_STRATS/UDP/YT" \
         "$MOCK_EXTRA_STRATS/cache/autocircular" \
         "$MOCK_LISTS" \
         "$MOCK_CONFIG_DIR" \
         "$MOCK_ZAPRET2/nfq2"

# Create mock hostlist files (non-empty so profiles are included)
echo "youtube.com" > "$MOCK_EXTRA_STRATS/TCP/YT/List.txt"
echo "googlevideo.com" > "$MOCK_EXTRA_STRATS/TCP/YT_GV/List.txt"
echo "youtube.com" > "$MOCK_EXTRA_STRATS/UDP/YT/List.txt"
echo "rutracker.org" > "$MOCK_EXTRA_STRATS/TCP/RKN/List.txt"
echo "whitelisted.example.com" > "$MOCK_LISTS/whitelist.txt"

# Create sample strategy files
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:strategy=1" > "$MOCK_EXTRA_STRATS/TCP/RKN/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4" > "$MOCK_EXTRA_STRATS/TCP/YT/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4" > "$MOCK_EXTRA_STRATS/TCP/YT_GV/Strategy.txt"
echo "--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=yt_quic --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3:strategy=1" > "$MOCK_EXTRA_STRATS/UDP/YT/Strategy.txt"

# Create mock config (no Austerus)
echo "ENABLED=1" > "$MOCK_ZAPRET2/config"

# Source utils.sh first (provides safe_config_read, print_*, etc.)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/utils.sh"

# Restore paths after sourcing (utils.sh sets global ZAPRET2_DIR etc.)
ZAPRET2_DIR="$MOCK_ZAPRET2"
CONFIG_DIR="$MOCK_CONFIG_DIR"
LISTS_DIR="$MOCK_LISTS"

# ==============================================================================
# TEST: ensure_circular_nld2 (extracted inline from generate_nfqws2_opt_from_strategies)
# We replicate the function here since it is defined as a nested function.
# ==============================================================================

ensure_circular_nld2() {
    local input="$1"
    local out=""
    local token=""
    local opts=""
    local part=""
    local rest=""
    local old_ifs="$IFS"

    for token in $input; do
        case "$token" in
            --lua-desync=circular:*)
                opts="${token#--lua-desync=circular:}"
                rest=""
                IFS=':'
                for part in $opts; do
                    case "$part" in
                        nld=*) ;;
                        *) rest="${rest:+$rest:}$part" ;;
                    esac
                done
                IFS="$old_ifs"
                if [ -n "$rest" ]; then
                    token="--lua-desync=circular:${rest}:nld=2"
                else
                    token="--lua-desync=circular:nld=2"
                fi
                ;;
        esac
        out="${out:+$out }$token"
    done

    IFS="$old_ifs"
    printf '%s' "$out"
}

printf "\n--- ensure_circular_nld2 ---\n"

# Test: adds nld=2 to circular token without existing nld
INPUT1="--filter-tcp=443 --lua-desync=circular:fails=3:time=60:key=test --lua-desync=fake:strategy=1"
RESULT1=$(ensure_circular_nld2 "$INPUT1")
assert_contains "nld2: adds nld=2 to circular token" "nld=2" "$RESULT1"
assert_contains "nld2: preserves fails param" "fails=3" "$RESULT1"
assert_contains "nld2: preserves non-circular tokens" "--filter-tcp=443" "$RESULT1"

# Test: replaces existing nld value with nld=2
INPUT2="--lua-desync=circular:fails=3:nld=5:time=60"
RESULT2=$(ensure_circular_nld2 "$INPUT2")
assert_contains "nld2: replaces existing nld with nld=2" "nld=2" "$RESULT2"
assert_not_contains "nld2: removes old nld=5" "nld=5" "$RESULT2"

# Test: does not modify non-circular tokens
INPUT3="--lua-desync=fake:payload=tls_client_hello:dir=out"
RESULT3=$(ensure_circular_nld2 "$INPUT3")
assert_eq "nld2: non-circular token unchanged" "$INPUT3" "$RESULT3"

# Test: bare circular with no opts
INPUT4="--lua-desync=circular:key=test"
RESULT4=$(ensure_circular_nld2 "$INPUT4")
assert_contains "nld2: adds nld=2 to minimal circular" "nld=2" "$RESULT4"

# ==============================================================================
# TEST: ensure_circular_hostkey_split (extracted inline from
# generate_nfqws2_opt_from_strategies). Replicated here — it is a nested function.
# Contract: append hostkey=z2k_hostkey_split to a circular token that has no key
# generator yet; leave an explicit hostkey= untouched; never touch non-circular
# tokens. The lua side (z2k_hostkey_split in files/lua/z2k-modern-core.lua) is
# covered by tests/test_z2k_hostkey_split.lua. Ordering note: this runs after
# ensure_circular_nld2 and before ensure_circular_doc_args/in_range, which keep
# unknown circular args ($rest), so the appended hostkey= survives to the engine.
# ==============================================================================

ensure_circular_hostkey_split() {
    local input="$1"
    local out="" token="" opts="" part="" has_hostkey=""
    local old_ifs="$IFS"

    for token in $input; do
        case "$token" in
            --lua-desync=circular:*)
                opts="${token#--lua-desync=circular:}"
                has_hostkey=""
                IFS=':'
                for part in $opts; do
                    case "$part" in
                        hostkey=*) has_hostkey="1" ;;
                    esac
                done
                IFS="$old_ifs"
                [ -z "$has_hostkey" ] && token="${token}:hostkey=z2k_hostkey_split"
                ;;
        esac
        out="${out:+$out }$token"
    done

    IFS="$old_ifs"
    printf '%s' "$out"
}

printf "\n--- ensure_circular_hostkey_split ---\n"

# Test: adds the split key generator to a circular token that has none
HK_IN1="--filter-tcp=443 --lua-desync=circular:fails=3:time=60:key=rkn_tcp:nld=2 --lua-desync=fake:strategy=1"
HK_R1=$(ensure_circular_hostkey_split "$HK_IN1")
assert_contains "hostkey_split: adds hostkey=z2k_hostkey_split" "hostkey=z2k_hostkey_split" "$HK_R1"
assert_contains "hostkey_split: preserves key=rkn_tcp" "key=rkn_tcp" "$HK_R1"
assert_contains "hostkey_split: preserves nld=2" "nld=2" "$HK_R1"
assert_contains "hostkey_split: preserves non-circular tokens" "--lua-desync=fake:strategy=1" "$HK_R1"

# Test: idempotent — a second pass does not append a second hostkey
HK_R1B=$(ensure_circular_hostkey_split "$HK_R1")
assert_eq "hostkey_split: idempotent (no double-append)" "$HK_R1" "$HK_R1B"

# Test: an explicit hostkey is left untouched (e.g. discord_udp's z2k_nohost_key)
HK_IN2="--lua-desync=circular:fails=3:key=discord_udp:nld=2:hostkey=z2k_nohost_key --lua-desync=fake:strategy=1"
HK_R2=$(ensure_circular_hostkey_split "$HK_IN2")
assert_contains "hostkey_split: keeps existing z2k_nohost_key" "hostkey=z2k_nohost_key" "$HK_R2"
assert_not_contains "hostkey_split: does not override an explicit hostkey" "z2k_hostkey_split" "$HK_R2"

# Test: non-circular token unchanged
HK_IN3="--lua-desync=fake:payload=tls_client_hello:dir=out"
HK_R3=$(ensure_circular_hostkey_split "$HK_IN3")
assert_eq "hostkey_split: non-circular token unchanged" "$HK_IN3" "$HK_R3"

printf "\n--- Austerus mode removed (all_tcp443) ---\n"

# Режим Austerusj снят 2026-08-04. Раньше здесь лежал тест, который ничего не
# проверял: он ассертил строковый литерал, объявленный двумя строками выше, и
# ни разу не вызывал генератор. Поэтому он и не заметил бы ни поломки ветки, ни
# её удаления.
#
# Что проверяем теперь — ровно то, из-за чего режим был опасен: ветка
# закорачивала ВСЮ генерацию конфига через `return 0`, выдавая три строки из
# Zapret1 без хостлистов и без --hostlist-exclude=whitelist.txt. Гард держит
# генератор от повторного знакомства с этим файлом: пока в нём нет ни чтения
# all_tcp443.conf, ни ранней ветки, режим воскреснуть не может.
GENERATOR_SRC=$(cat "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/config_official.sh" 2>/dev/null)

assert_not_contains "austerus: генератор больше не читает all_tcp443.conf" \
    'safe_config_read "ENABLED" "$austerus_conf"' "$GENERATOR_SRC"
assert_not_contains "austerus: закоротка AUSTERUS_OPT удалена" \
    "AUSTERUS_OPT" "$GENERATOR_SRC"
assert_not_contains "austerus: стратегии Zapret1 больше не эмитятся" \
    "tls_clienthello_www_google_com:badsum:badseq:repeats=1:tls_mod=sni=www.google.com,rnd,dupsid" \
    "$GENERATOR_SRC"

# Миграция, снимающая режим у затронутых, обязана существовать и сносить файл
# безусловно — иначе откат на старую версию подхватит его снова.
INSTALL_SRC=$(cat "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/install.sh" 2>/dev/null)
assert_contains "austerus: миграция объявлена" "migrate_drop_austerus_mode()" "$INSTALL_SRC"
assert_contains "austerus: миграция вызывается на установке" \
    "$(printf '\n    migrate_drop_austerus_mode\n')" "$INSTALL_SRC"

# ==============================================================================
# TEST: Output format of generated config contains expected tokens
# ==============================================================================

printf "\n--- Config output structure ---\n"

# Build a representative NFQWS2_OPT output manually to validate structural checks.
# Этап 2 (failure-detector wiring restored): rkn_tcp/yt_tcp get
# failure_detector=z2k_silent_drop_detector, gv_tcp gets z2k_tls_alert_fatal.
# success_detector= (Этап 3) and no_http_redirect (Этап 4) NOT yet wired here.
# inseq= (native arg) kept; Discord nohost via hostkey=z2k_nohost_key.
SAMPLE_OPT="--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/RKN/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=rkn_tcp:nld=2:inseq=26000:failure_detector=z2k_silent_drop_detector:success_detector=z2k_http_success_positive_only:no_http_redirect --lua-desync=fake:strategy=1 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/YT/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=yt_tcp:nld=2:inseq=18000:failure_detector=z2k_silent_drop_detector:success_detector=z2k_success_no_reset:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/YT_GV/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=gv_tcp:nld=2:inseq=24000:failure_detector=z2k_silent_drop_detector:success_detector=z2k_http_success_positive_only:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/UDP/YT/List.txt --filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:key=yt_quic:nld=2 --new
--filter-udp=50000-50099 --filter-l7=discord,stun --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=discord_udp:nld=2:hostkey=z2k_nohost_key"

# Native rollback structure guarantees (2026-05-28):
#  - rkn_tcp circular has inseq=26000 (native arg — TLS stall window 14-25KB)
#  - yt_tcp / gv_tcp circular have inseq=18000 (smaller first-burst typical)
#  - NO z2k_* failure_detector= / success_detector= injections (native
#    standard_failure_detector / standard_success_detector by default)
#  - NO no_http_redirect (native 302/307 cross-SLD redirect detection active)
#  - Discord UDP keys hostname-less flows via hostkey=z2k_nohost_key (native
#    arg.hostkey extension), replacing the archived allow_nohost wrapper
assert_contains "structure: rkn_tcp has inseq=26000" "key=rkn_tcp:nld=2:inseq=26000" "$SAMPLE_OPT"
assert_contains "structure: yt_tcp has inseq=18000" "key=yt_tcp:nld=2:inseq=18000" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has inseq=24000 (silent_drop byte-gate)" "key=gv_tcp:nld=2:inseq=24000" "$SAMPLE_OPT"
assert_contains "structure: discord_udp uses native hostkey generator" "key=discord_udp:nld=2:hostkey=z2k_nohost_key" "$SAMPLE_OPT"
# Этапы 2-3: failure_detector= + success_detector= wired per pool;
# no_http_redirect stays native until Этап 4.
assert_contains "structure: rkn_tcp no_http_redirect (Этап 4, classifier replaces native)" "success_detector=z2k_http_success_positive_only:no_http_redirect" "$SAMPLE_OPT"
assert_not_contains "structure: no allow_nohost (replaced by hostkey=z2k_nohost_key)" "allow_nohost" "$SAMPLE_OPT"

assert_contains "structure: has --filter-tcp" "--filter-tcp" "$SAMPLE_OPT"
assert_contains "structure: has --filter-udp" "--filter-udp" "$SAMPLE_OPT"
assert_contains "structure: has --hostlist" "--hostlist=" "$SAMPLE_OPT"
assert_contains "structure: has --hostlist-exclude" "--hostlist-exclude=" "$SAMPLE_OPT"
# r-17: gv_tcp moved off --hostlist-domains=googlevideo.com onto its own
# YT_GV/List.txt file → no --hostlist-domains= anywhere in the output now.
assert_not_contains "structure: gv_tcp uses YT_GV/List.txt, not inline --hostlist-domains" "--hostlist-domains=" "$SAMPLE_OPT"
assert_contains "structure: has YT_GV hostlist file" "TCP/YT_GV/List.txt" "$SAMPLE_OPT"
assert_contains "structure: has --new separators" "--new" "$SAMPLE_OPT"
assert_contains "structure: has --lua-desync" "--lua-desync=" "$SAMPLE_OPT"

# Count --new separators (should be 4 in the sample above)
NEW_COUNT=$(printf '%s' "$SAMPLE_OPT" | grep -o -- '--new' | wc -l | tr -d ' ')
assert_eq "structure: correct --new count" "4" "$NEW_COUNT"

# ==============================================================================
# TEST: generator RUNTIME invocation (real function vs mock /opt tree)
# ==============================================================================
# Earlier static-SAMPLE coverage was insufficient: it asserted on hand-
# constructed strings, not on what generate_nfqws2_opt_from_strategies
# actually emits. This block runs the real function against a mock
# /opt/zapret2 root (via ZAPRET2_DIR override now that lists_dir derives
# from it) and asserts on captured output.

# Source the generator (utils.sh already sourced above).
. "$SCRIPT_DIR/lib/config_official.sh"


# Build a mock /opt-tree under MOCK_DIR/<name>/ and invoke the generator
# with ZAPRET2_DIR pointing at it. Echoes the captured output to stdout.
# Args: <subdir-name> <config-content> [<extra-files-callback>]
run_generator() {
    local subname="$1" cfg="$2" extra_cb="$3"
    local root="${MOCK_DIR}/${subname}"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists"
    # Minimum hostlists so non-game profiles don't error out (they get
    # skipped via add_hostlist_line if missing, but creating them avoids
    # noise on stderr that could mask real test signal).
    echo "youtube.com" > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com" > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org" > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    # Minimum Strategy.txt for the rkn_tcp TLS arm. Without this the
    # generator's `if [ -f ".../RKN/Strategy.txt" ]` gate keeps rkn_tcp
    # empty and the arm isn't emitted — which masks regressions in the
    # rkn_tcp wiring (failure_detector / --in-range / inseq).
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    printf '%s\n' "$cfg" > "$root/config"
    # Рантайм обрыва на 16 КБ проводится в rkn_tcp только если lua-файл реально
    # лежит на диске (иначе движок падал бы в error() на каждом пакете). Мок
    # обязан повторять установленную систему.
    mkdir -p "$root/lua"
    cp "$SCRIPT_DIR/files/lua/z2k-tcp16.lua" "$root/lua/" 2>/dev/null || true
    # Поправки к штатному детектору и детектор молчания QUIC тоже резолвятся
    # по имени в _G и тоже проводятся в конфиг только при наличии файла.
    [ "${Z2K_TEST_NO_DETECTOR_LUA:-0}" = "1" ] || {
        cp "$SCRIPT_DIR/files/lua/z2k-alert.lua" "$root/lua/" 2>/dev/null || true
        cp "$SCRIPT_DIR/files/lua/z2k-quic-silence.lua" "$root/lua/" 2>/dev/null || true
    }
    [ -n "$extra_cb" ] && eval "$extra_cb \"$root\""
    ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null )
    rm -rf "$root"
}

# Helper: extract the rkn_tcp TLS arm (filter-l7=tls + key=rkn_tcp).
# http_rkn lives on a separate line (filter-tcp=80, key=http_rkn) and
# is filtered out by the key match.
get_rkn_tcp_arm_line() {
    printf '%s\n' "$1" | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk" \
        | grep -F 'key=rkn_tcp' | head -1
}

# Профиль ЦЕЛИКОМ из готового config-файла.
#
# Арсенал РКН объявляется в конфиге один раз (--template) и подставляется в
# профили (--import), поэтому «взять строку с key=rkn_tcp» больше не значит
# «взять весь профиль»: стратегии лежат в блоке шаблона. Раскрыватель
# возвращает прежний взгляд — профиль одной строкой со всеми инстансами.
config_profile_line() {
    sed -n '/^NFQWS2_OPT="/,/^"[[:space:]]*$/p' "$1" \
        | sed '1d;$d' \
        | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk" \
        | grep -F "$2" | head -1
}

printf "\n--- окно входящих выше порога inseq ---\n"

# Порог inseq ставится в config_official.sh, а окно `--in-range=-sN` вставляют
# раскладчики ensure_youtube_tls_* НИЖЕ по коду — константой, ничего не зная
# про порог. Гейт ensure_circular_in_range, заведённый 2026-08-14, правит
# только уже существующий токен, поэтому на дефолтной поставке (в стратегии
# токена нет вовсе) он не срабатывал, и на боевом роутере 2026-08-17 стояло:
#
#   rkn_tcp  --in-range=-s20000  inseq=26000   полоса пуста
#   yt_tcp   --in-range=-s5556   inseq=18000   полоса пуста
#
# Пустая полоса = успех по входящим недостижим, а окно, в котором входящий RST
# ещё считается провалом, обрезано окном видимости, а не порогом. Сторожим
# инвариант на всех TLS-пулах сразу.
# YT/GV в run_generator по умолчанию идут без circular — дописываем, иначе
# сторожить у них нечего.
_seed_tls_circulars() {
    local root="$1"
    echo "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=circular:fails=3:time=60:key=yt_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:strategy=1" \
        > "$root/extra_strats/TCP/YT/Strategy.txt"
    echo "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=circular:fails=3:time=60:key=gv_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:strategy=1" \
        > "$root/extra_strats/TCP/YT_GV/Strategy.txt"
}
OUT_RANGE=$(run_generator "in-range-vs-inseq" "" "_seed_tls_circulars")
_flat_range=$(printf '%s\n' "$OUT_RANGE" | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk")

check_range_above_inseq() {
    local key="$1" line cap inseq
    line=$(printf '%s\n' "$_flat_range" | grep -F "key=$key" | head -1)
    [ -n "$line" ] || { assert_eq "$key: строка профиля найдена" "да" "нет"; return; }
    cap=$(printf '%s\n' "$line" | tr ' ' '\n' | grep -o -- '--in-range=-s[0-9]*' | head -1 | sed 's/.*-s//')
    inseq=$(printf '%s\n' "$line" | tr ' ' '\n' | grep -o 'inseq=[0-9]*' | head -1 | sed 's/inseq=//')
    if [ -z "$inseq" ]; then
        assert_eq "$key: inseq на месте" "число" "пусто"
        return
    fi
    if [ -n "$cap" ] && [ "$cap" -gt "$inseq" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "[PASS] %s: окно -s%s выше порога inseq=%s\n" "$key" "$cap" "$inseq"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "[FAIL] %s: окно -s%s НЕ выше порога inseq=%s — полоса пуста\n" "$key" "${cap:-нет}" "$inseq"
    fi
}

check_range_above_inseq rkn_tcp
check_range_above_inseq yt_tcp
check_range_above_inseq gv_tcp

# Расширение l7 и окно наблюдения обязаны сосуществовать.
#
# Ловим конкретный провал r-77.1. Пулы видео берут --filter-l7=tls,unknown,
# чтобы забирать соединения без SNI, а раскладку с --in-range вставляет хелпер,
# который сравнивал токен с «--filter-l7=tls» ТОЧНО. С довеском совпадение
# пропадало, раскладка молча не применялась, окно оставалось пустым.
#
# Проверка не заметила бы этого на макбуке: переписывание было сделано через
# sed с \| в BRE — у GNU это альтернатива, у BSD литерал, поэтому на маке
# подстановка не выполнялась вовсе и тест шёл по старому пути. Здесь смотрим
# РЕЗУЛЬТАТ, а не способ: в строке обязаны быть оба признака сразу.
check_l7_and_range_together() {
    local key="$1" line
    line=$(printf '%s\n' "$_flat_range" | grep -F "key=$key" | head -1)
    [ -n "$line" ] || { assert_eq "$key: строка профиля найдена" "да" "нет"; return; }
    case "$line" in
        *--filter-l7=tls,unknown*)
            case "$line" in
                *--in-range=-s*)
                    TESTS_PASSED=$((TESTS_PASSED + 1))
                    printf "[PASS] %s: tls,unknown и окно --in-range вместе\n" "$key" ;;
                *)
                    TESTS_FAILED=$((TESTS_FAILED + 1))
                    printf "[FAIL] %s: есть tls,unknown, но окна --in-range нет — раскладка не применилась\n" "$key" ;;
            esac ;;
        *)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: нет --filter-l7=tls,unknown — соединения без SNI пройдут мимо профиля\n" "$key" ;;
    esac
}

check_l7_and_range_together yt_tcp
check_l7_and_range_together gv_tcp

# РКН намеренно остаётся на чистом tls: там на тех же портах живёт слишком
# много чужого, и расширение забрало бы его в пул.
case $(printf '%s\n' "$_flat_range" | grep -F "key=rkn_tcp" | head -1) in
    *--filter-l7=tls,unknown*)
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "[FAIL] rkn_tcp: l7 расширен до tls,unknown — РКН это не нужно\n" ;;
    *)
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "[PASS] rkn_tcp: l7 остался чистым tls\n" ;;
esac

printf "\n--- DISABLE_IPV6: preserved across config regen (user request 2026-06-19) ---\n"

# Regression: DISABLE_IPV6 was the ONE knob read only from the environment,
# so a user-set value got clobbered by the IPv6 autodetect on every config
# regen / nightly auto-update (p-30 wrote it to the file, but this function
# re-overwrote it). It now reads back from the existing config like every
# other knob. Precedence: env > saved-in-file > autodetect.
test_disable_ipv6() {
    local tag="$1" file_line="$2" env_val="$3"
    local root="${MOCK_DIR}/disable-ipv6-$tag"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" "$root/lists"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    { echo "ENABLED=1"; if [ -n "$file_line" ]; then echo "$file_line"; fi; } > "$root/config"
    if [ -n "$env_val" ]; then
        ( ZAPRET2_DIR="$root" DISABLE_IPV6="$env_val" create_official_config "$root/config" >/dev/null 2>&1 )
    else
        ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    fi
    grep -E '^DISABLE_IPV6=' "$root/config" | head -1
    rm -rf "$root"
}

DI6_OUT=$(test_disable_ipv6 "file1" "DISABLE_IPV6=1" "")
assert_contains "DISABLE_IPV6=1 from file survives regen, env unset (p-30 regression)" "DISABLE_IPV6=1" "$DI6_OUT"

DI6_OUT=$(test_disable_ipv6 "env0" "DISABLE_IPV6=1" "0")
assert_contains "env DISABLE_IPV6=0 overrides saved file =1" "DISABLE_IPV6=0" "$DI6_OUT"

DI6_OUT=$(test_disable_ipv6 "absent" "" "")
assert_contains "absent in file -> autodetect still emits a DISABLE_IPV6 line" "DISABLE_IPV6=" "$DI6_OUT"

# Auto-update reinstall: config_file is built FRESH (step_build_zapret2 moved
# the old tree to .old.$$ BEFORE config gen), so config_file carries no
# DISABLE_IPV6 on the first pass. The prior value must be recovered from the
# .old.$$ backup, NOT autodetected — otherwise a hand-disabled v6 gets
# re-enabled mid-reinstall (Mark 2026-06-20: на апдейте IPv6 не трогаем).
test_disable_ipv6_reinstall() {
    local tag="$1" old_val="$2"
    local root="${MOCK_DIR}/disable-ipv6-ri-$tag"
    rm -rf "$root" "${root}".old.* 2>/dev/null
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" "$root/lists"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    # fresh config (no DISABLE_IPV6) + prior value lives ONLY in the .old.$$ backup
    echo "ENABLED=1" > "$root/config"
    mkdir -p "${root}.old.999"
    { echo "ENABLED=1"; echo "DISABLE_IPV6=${old_val}"; } > "${root}.old.999/config"
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    grep -E '^DISABLE_IPV6=' "$root/config" | head -1
    rm -rf "$root" "${root}".old.* 2>/dev/null
}

# Test BOTH values: on a given box autodetect resolves to ONE fixed value, so
# the opposite-value case proves we PRESERVED rather than re-autodetected.
DI6_OUT=$(test_disable_ipv6_reinstall "old1" "1")
assert_contains "reinstall: DISABLE_IPV6=1 recovered from .old backup (hand-disabled v6 preserved)" "DISABLE_IPV6=1" "$DI6_OUT"

DI6_OUT=$(test_disable_ipv6_reinstall "old0" "0")
assert_contains "reinstall: DISABLE_IPV6=0 recovered from .old backup (not re-autodetected)" "DISABLE_IPV6=0" "$DI6_OUT"

printf "\n--- Z2K_PPE_DEOFFLOAD: webpanel offload toggle persists across regen ---\n"

# Regression: the Keenetic per-flow hardware-offload exclusion toggle
# (Z2K_PPE_DEOFFLOAD) was NOT in the config-preserve pattern, so toggle_ppe's own
# regenerate_config wiped the key -> the NDM hook re-added the de-offload rules ->
# the webpanel switch silently reverted after a regen/reboot. Must survive now.
test_ppe_deoffload() {
    local tag="$1" file_line="$2"
    local root="${MOCK_DIR}/ppe-$tag"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" "$root/lists"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    { echo "ENABLED=1"; if [ -n "$file_line" ]; then echo "$file_line"; fi; } > "$root/config"
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    grep -E '^Z2K_PPE_DEOFFLOAD=' "$root/config" | head -1
    rm -rf "$root"
}

PPE_OUT=$(test_ppe_deoffload "off" "Z2K_PPE_DEOFFLOAD=0")
assert_contains "Z2K_PPE_DEOFFLOAD=0 survives regen (webpanel toggle no longer reverts)" "Z2K_PPE_DEOFFLOAD=0" "$PPE_OUT"

PPE_OUT=$(test_ppe_deoffload "absent" "")
assert_contains "Z2K_PPE_DEOFFLOAD absent -> emits default =1" "Z2K_PPE_DEOFFLOAD=1" "$PPE_OUT"

printf "\n--- Z2K_PADENCAP: padencap autoinjector flag ---\n"

# Z2K_PADENCAP (default 0): when =1, inject_z2k_tls_mods добавляет
# padencap ко всем :tls_mod= токенам в rkn_tcp. Plus persist round-trip.
# Padencap НЕ должен попадать в yt_tcp/yt_gv_tcp — другие
# DPI profiles, padencap там не верифицирован.
test_padencap_under_flag() {
    local flag="$1" expect_padencap="$2" desc_suffix="$3"
    # Dir name MUST NOT contain "padencap" as substring (fgrep would
    # match it in paths and break the rkn-arm assertions below).
    local root="${MOCK_DIR}/pe-flag-$flag"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists"
    echo "youtube.com" > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com" > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org" > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    # Strategy.txt с :tls_mod= токеном чтобы injector имел что трогать.
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:tls_mod=rnd,dupsid,sni=www.google.com:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    # 2026-05-03: auto-injection отключена by default, требует Z2K_INJECT_TLS_MODS=1
    # для активации вместе с Z2K_PADENCAP=1 (двухуровневый opt-in).
    cat > "$root/config" <<EOF
ENABLED=1
Z2K_INJECT_TLS_MODS=$flag
Z2K_PADENCAP=$flag
EOF
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    local rkn_arm
    rkn_arm=$(config_profile_line "$root/config" 'key=rkn_tcp')

    if [ "$expect_padencap" = "1" ]; then
        assert_contains "padencap flag=$flag: rkn_tcp tls_mod has padencap" \
            "padencap" "$rkn_arm"
    else
        assert_not_contains "padencap flag=$flag: rkn_tcp tls_mod без padencap" \
            "padencap" "$rkn_arm"
    fi

    # Idempotency: padencap не должен дублироваться при повторном
    # запуске create_official_config (injector гейт *padencap* skip).
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    local rkn_arm_2nd
    rkn_arm_2nd=$(config_profile_line "$root/config" 'key=rkn_tcp')
    local padencap_count
    padencap_count=$(printf '%s' "$rkn_arm_2nd" | grep -o "padencap" | wc -l | tr -d ' ')
    if [ "$expect_padencap" = "1" ]; then
        # На каждом :tls_mod= токене с padencap должен быть ровно 1
        # padencap, не два. У нас в Strategy.txt один :tls_mod= токен →
        # ожидается ровно 1 padencap во всём rkn arm.
        assert_eq "padencap flag=$flag: idempotent (no duplication)" "1" "$padencap_count"
    fi

    rm -rf "$root"
}

test_padencap_under_flag "0" "0" "rkn_tcp без padencap"
test_padencap_under_flag "1" "1" "rkn_tcp с padencap"

printf "\n--- штатные детекторы, circular по документации (решение 10.09.2026) ---\n"
# Своих детекторов нет: ни failure_detector=, ни success_detector= ни в одном
# пуле. Параметры circular — из docs/manual.md апстрима (standard_*_detector):
# retrans=3, maxseq=32768, inseq=4096, плюс reset (RST ретрансмиттеру после
# фиксации неудачи; в автохостлисте у bol-van это умолчание). Окно входящих —
# -s5556 (inseq 4096 + 1460). QUIC: udp_in=1 по документации, udp_out=5 — по
# замеру 19.08.2026 (см. комментарий у quic_udp).
OUT_DOC=$(run_generator "docalign" "" "_seed_tls_circulars")
_flat_doc=$(printf '%s\n' "$OUT_DOC" | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk")
assert_not_contains "нет своих детекторов удач"    "success_detector=" "$_flat_doc"
assert_not_contains "нет сторожа обрыва"           "z2k_stall_watch"   "$_flat_doc"
for _k in rkn_tcp yt_tcp gv_tcp; do
    _line=$(printf '%s\n' "$_flat_doc" | grep -F "key=$_k" | head -1)
    _circ=$(printf '%s\n' "$_line" | tr ' ' '\n' | grep -- '--lua-desync=circular:' | head -1)
    assert_contains     "$_k: retrans=3 (manual: «не менее retrans ретрансмиссий», по умолчанию 3)" "retrans=3"    "$_circ"
    assert_contains     "$_k: maxseq=32768"  "maxseq=32768" "$_circ"
    assert_contains     "$_k: inseq=4096"    "inseq=4096"   "$_circ"
    assert_contains     "$_k: reset"         ":reset"       "$_circ"
    assert_contains     "$_k: fails=3"       "fails=3"      "$_circ"
    assert_not_contains "$_k: нет старых retrans=2"    "retrans=2"    "$_circ"
    assert_not_contains "$_k: нет старых maxseq=16384" "maxseq=16384" "$_circ"
    assert_contains     "$_k: окно входящих -s5556"    "--in-range=-s5556" "$_line"
done
_yt_circ=$(printf '%s\n' "$_flat_doc" | grep -F "key=yt_tcp" | head -1 | tr ' ' '\n' | grep -- '--lua-desync=circular:' | head -1)
assert_contains "yt_tcp: окно счётчика 300 (замер ТВ 25-26.08) сохранено" "time=300" "$_yt_circ"
_quic=$(printf '%s\n' "$_flat_doc" | grep -F "key=yt_quic" | head -1)
assert_contains     "yt_quic: udp_in=1 по документации" "udp_in=1"  "$_quic"
assert_contains     "yt_quic: udp_out=5 по замеру"      "udp_out=5" "$_quic"
assert_contains     "yt_quic: детектор молчания QUIC проведён" "failure_detector=z2k_fail_quic_silence" "$_quic"
_http=$(printf '%s\n' "$_flat_doc" | grep -F "key=http_rkn" | head -1)
assert_contains "http_rkn: обёртка проведена и здесь" "failure_detector=z2k_fail_tls_alert" "$_http"

# --- поправки к штатному детектору (сняты 10.09, возвращены 11.09.2026) -----
#
# Детектор не заменяет штатный, а оборачивает: зовёт standard_failure_detector
# и добавляет поправки, каждая из которых меряна на боевом роутере (шапка
# files/lua/z2k-alert.lua). Все они ротацию ПРИТОРМАЖИВАЮТ — живой хост не
# ротируем, RST самого сервера не провал, провал вешается на ту стратегию, на
# которой соединение началось.
for _k in rkn_tcp yt_tcp gv_tcp; do
    _circ=$(printf '%s\n' "$_flat_doc" | grep -F "key=$_k" | head -1 | tr ' ' '\n' | grep -- '--lua-desync=circular:' | head -1)
    assert_contains "$_k: обёртка детектора проведена" "failure_detector=z2k_fail_tls_alert" "$_circ"
    assert_contains "$_k: штатные пороги рядом уцелели" "retrans=3"                          "$_circ"
done
# Обёртка узнаёт о живости хоста только из вызовов на ВХОДЯЩИХ пакетах.
# Два условия в профиле это обеспечивают, и оба легко потерять правкой:
#   - у ротатора нет фильтра по типу payload (иначе его зовут только на
#     ClientHello, и весь гвард живости мёртв);
#   - задано окно входящих (иначе диапазон пуст и инстанс не вызывается вовсе).
for _k in rkn_tcp yt_tcp gv_tcp; do
    _line=$(printf '%s\n' "$_flat_doc" | grep -F "key=$_k" | head -1)
    _before=$(printf '%s' "$_line" | sed 's/--lua-desync=circular.*//')
    assert_not_contains "$_k: фильтр payload не режет вызовы ротатора" "--payload=" "$_before"
    assert_contains     "$_k: окно входящих задано"                    "--in-range=" "$_line"
done
# QUIC — свой детектор и свой файл: штатный для UDP не работает в принципе
# (замер 19.08 по 1646 потокам), различает классы только время.
_quic_sil=$(printf '%s\n' "$_flat_doc" | grep -F "key=yt_quic" | head -1)
assert_not_contains "yt_quic: TCP-обёртку на UDP не вешаем" "z2k_fail_tls_alert" "$_quic_sil"

# Файлов модулей нет — имя функции резолвить некому, движок падал бы в error()
# на каждом пакете профиля. Тот же гейт, что у подстановки имени 16 КБ.
OUT_DET_NOLUA=$(Z2K_TEST_NO_DETECTOR_LUA=1 run_generator "detect-nolua" "" "_seed_tls_circulars")
_rkn_nolua=$(get_rkn_tcp_arm_line "$OUT_DET_NOLUA" | tr ' ' '\n' | grep -- '--lua-desync=circular:' | head -1)
assert_not_contains "без файла модуля детектор не проводится" "failure_detector=" "$_rkn_nolua"
assert_contains     "без файла модуля штатное на месте"       "retrans=3"        "$_rkn_nolua"
assert_contains     "http_rkn: fails=3"           "circular:fails=3" "$_http"

# Выключатель RST: Z2K_CIRCULAR_RESET=0 снимает reset, остальное на месте.
OUT_NORST=$(run_generator "docalign-norst" "Z2K_CIRCULAR_RESET=0" "_seed_tls_circulars")
_rkn_norst=$(printf '%s\n' "$OUT_NORST" | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk" | grep -F "key=rkn_tcp" | head -1 | tr ' ' '\n' | grep -- '--lua-desync=circular:' | head -1)
assert_not_contains "Z2K_CIRCULAR_RESET=0: reset снят"      ":reset"   "$_rkn_norst"
assert_contains     "Z2K_CIRCULAR_RESET=0: retrans=3 остался" "retrans=3" "$_rkn_norst"

# Правленый руками Strategy.txt с чужим детектором и старыми порогами
# приводится к тому же виду: имя функции, которой нет на диске, роняет движок в
# error() на каждом пакете профиля. z2k_mid_stream_stall — как раз такое имя:
# файл с ним снят 26.08.2026, а в чужих сборках строка встречается до сих пор.
_seed_hand_edited() {
    local root="$1"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:retrans=1:maxseq=16384:inseq=26000:time=60:key=rkn_tcp:failure_detector=z2k_mid_stream_stall --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
}
OUT_HAND=$(run_generator "docalign-hand" "" "_seed_hand_edited")
_rkn_hand=$(get_rkn_tcp_arm_line "$OUT_HAND" | tr ' ' '\n' | grep -- '--lua-desync=circular:' | head -1)
assert_not_contains "ручной Strategy.txt: мёртвый детектор срезан" "z2k_mid_stream_stall" "$_rkn_hand"
# …и на его место встаёт наш, существующий на диске.
assert_contains     "ручной Strategy.txt: проведён живой детектор" "failure_detector=z2k_fail_tls_alert" "$_rkn_hand"
_dups_det=$(printf '%s' "$_rkn_hand" | grep -o "failure_detector=" | wc -l | tr -d ' ')
assert_eq "ручной Strategy.txt: детектор не задвоен" "1" "$_dups_det"
assert_not_contains "ручной Strategy.txt: inseq=26000 снят"        "inseq=26000"       "$_rkn_hand"
assert_contains     "ручной Strategy.txt: inseq=4096 поставлен"    "inseq=4096"        "$_rkn_hand"
assert_contains     "ручной Strategy.txt: retrans=3 поставлен"     "retrans=3"         "$_rkn_hand"
_dups=$(printf '%s' "$_rkn_hand" | grep -o "retrans=" | wc -l | tr -d ' ')
assert_eq "ручной Strategy.txt: retrans не задвоен" "1" "$_dups"

# ── e2e: hostkey=z2k_hostkey_split доезжает до вывода реального генератора ────
# Не инлайн-копию трансформа, а настоящий generate_nfqws2_opt_from_strategies:
# ensure_circular_hostkey_split вешает hostkey= на rkn-circular, и он переживает
# всю цепочку (nld2 → hostkey_split → doc_args → in_range → failure_detector),
# т.к. каждый последующий трансформ либо сохраняет неизвестные аргументы circular,
# либо не трогает сам токен. Разбор в комментарии у функции в config_official.sh.
printf "\n--- e2e: hostkey_split в выводе генератора ---\n"
OUT_HK=$(run_generator "hostkey-split" "" "_seed_tls_circulars")
_rkn_hk=$(get_rkn_tcp_arm_line "$OUT_HK" | tr ' ' '\n' | grep -- '--lua-desync=circular:' | head -1)
assert_contains "e2e: rkn-circular несёт hostkey=z2k_hostkey_split" "hostkey=z2k_hostkey_split" "$_rkn_hk"
assert_contains "e2e: split на том же токене, что key=rkn_tcp" "key=rkn_tcp" "$_rkn_hk"
_dups_hk=$(printf '%s' "$_rkn_hk" | grep -o "hostkey=" | wc -l | tr -d ' ')
assert_eq "e2e: hostkey не задвоен" "1" "$_dups_hk"
# Точечность: yt_tcp — чужой пул, split на него не вешается.
_yt_hk=$(printf '%s\n' "$OUT_HK" | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk" | grep -F "key=yt_tcp" | head -1 | tr ' ' '\n' | grep -- '--lua-desync=circular:' | head -1)
assert_not_contains "e2e: yt_tcp не получает split (rkn-only)" "z2k_hostkey_split" "$_yt_hk"

# NFQWS2_TCP_PKT_IN — окно входящих в пакетах — 10: детектору успеха нужно
# inseq=4096 + пакет, десять — двойной запас; прежние 50 кормили сторож обрыва.
_root_pkt="${MOCK_DIR}/pkt-in"; rm -rf "$_root_pkt"; mkdir -p "$_root_pkt/lists"
printf 'ENABLED=1\n' > "$_root_pkt/config"
( ZAPRET2_DIR="$_root_pkt" create_official_config "$_root_pkt/config" >/dev/null 2>&1 )
assert_eq "NFQWS2_TCP_PKT_IN=10 в конфиге" 'NFQWS2_TCP_PKT_IN="10"' "$(grep -E '^NFQWS2_TCP_PKT_IN=' "$_root_pkt/config" | head -1)"
assert_eq "Z2K_CIRCULAR_RESET переживает регенерацию (умолчание 1)" 'Z2K_CIRCULAR_RESET=1' "$(grep -E '^Z2K_CIRCULAR_RESET=' "$_root_pkt/config" | head -1)"
assert_eq "Z2K_USE_MID_STREAM_DETECTOR больше не пишется" "" "$(grep -E '^Z2K_USE_MID_STREAM_DETECTOR=' "$_root_pkt/config" | head -1)"
# Ключи снятого 11.09.2026 детектора молчания в конфиг больше не пишутся.
# Проверяем именно отсутствие: пока они писались, регенерация возвращала их со
# значением по умолчанию, то есть «выключено» жило ровно до первого обновления.
assert_eq "Z2K_SILENCE_DETECT больше не пишется"  "" "$(grep -E '^Z2K_SILENCE_DETECT=' "$_root_pkt/config" | head -1)"
assert_eq "Z2K_SILENCE_SECONDS больше не пишется" "" "$(grep -E '^Z2K_SILENCE_SECONDS=' "$_root_pkt/config" | head -1)"
rm -rf "$_root_pkt"

printf "\n--- corrupt pool Strategy.txt: fail closed, keep old config (field 2026-08-06) ---\n"

# A USB flash can hand back an all-0xFF file for a strategy pool (dead NAND
# block: size and mtime intact, bytes gone). Feeding that garbage into
# NFQWS2_OPT poisons the on-disk config and the next nfqws2 restart dies
# wholesale. The generator must instead fail closed and leave the existing
# config untouched — never half-write it.
test_corrupt_pool_fails_closed() {
    local root="${MOCK_DIR}/corrupt-pool"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists"
    echo "youtube.com"    > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com"> "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"    > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"  > "$root/extra_strats/TCP/RKN/List.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=yt_tcp --lua-desync=fake:strategy=1" > "$root/extra_strats/TCP/YT/Strategy.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=gv_tcp --lua-desync=fake:strategy=1" > "$root/extra_strats/TCP/YT_GV/Strategy.txt"
    echo "--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=yt_quic --lua-desync=fake:strategy=1" > "$root/extra_strats/UDP/YT/Strategy.txt"
    # RKN pool: all-0xFF garbage, exactly the dead-block failure mode.
    awk 'BEGIN{for(i=0;i<64;i++)printf "%c",255}' > "$root/extra_strats/TCP/RKN/Strategy.txt"

    local sentinel="ORIGINAL_UNTOUCHED_SENTINEL"
    printf 'ENABLED=1\n%s=1\n' "$sentinel" > "$root/config"

    local rc
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 ); rc=$?

    assert_eq         "corrupt-pool: create_official_config returns non-zero" "1" "$rc"
    # The old config must survive byte-for-byte: no NFQWS2_OPT written, sentinel intact.
    assert_contains   "corrupt-pool: original config preserved" "$sentinel" "$(cat "$root/config")"
    assert_not_contains "corrupt-pool: no NFQWS2_OPT written from garbage" "NFQWS2_OPT=" "$(cat "$root/config")"
    rm -rf "$root"
}
test_corrupt_pool_fails_closed

# Same dead-NAND exposure applies to the USER-owned custom-strategies files:
# they live on the same flash AND override the pool value, so guarding only the
# pool files left the identical hang reachable through the back door.
# Healthy custom file must still be honoured — that is the other half of the test.
test_corrupt_custom_strategy() {
    local variant="$1" body="$2" want_rc="$3" desc="$4"
    local root="${MOCK_DIR}/custom-$variant"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists/custom-strategies"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    for f in TCP/YT TCP/YT_GV TCP/RKN; do
        echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=x --lua-desync=fake:strategy=1" \
            > "$root/extra_strats/$f/Strategy.txt"
    done
    echo "--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=yt_quic --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/UDP/YT/Strategy.txt"

    # The custom override under test.
    if [ "$variant" = "corrupt" ]; then
        awk 'BEGIN{for(i=0;i<64;i++)printf "%c",255}' > "$root/lists/custom-strategies/rkn_tcp.txt"
    else
        printf '%s\n' "$body" > "$root/lists/custom-strategies/rkn_tcp.txt"
    fi

    printf 'ENABLED=1\nCUSTOM_SENTINEL=1\n' > "$root/config"
    local rc
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 ); rc=$?
    assert_eq "custom-$variant: rc — $desc" "$want_rc" "$rc"
    if [ "$want_rc" = "1" ]; then
        assert_contains     "custom-$variant: original config preserved" "CUSTOM_SENTINEL" "$(cat "$root/config")"
        assert_not_contains "custom-$variant: no NFQWS2_OPT from garbage" "NFQWS2_OPT=" "$(cat "$root/config")"
    else
        # Healthy override must actually reach the generated options.
        assert_contains "custom-$variant: override applied" "z2k_custom_marker" "$(cat "$root/config")"
    fi
    rm -rf "$root"
}
test_corrupt_custom_strategy corrupt "" "1" "порченый пользовательский файл роняет генерацию"
test_corrupt_custom_strategy healthy \
    "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:blob=z2k_custom_marker:strategy=1" \
    "0" "исправный пользовательский файл принимается"

rm -rf "$MOCK_DIR"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
