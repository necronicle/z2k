#!/bin/sh
# Настоящие converge/скачивание/раскладка/refresh-binaries; только транспорт
# заменён file://-источником. Ветка сдвигается ПОСЛЕ загрузки манифеста и
# первого запроса файла. Унаследованный ref не должен пережить выбор цели.
# Переменные настроек читаются подключаемым кодом апдейтера.
# shellcheck disable=SC2034
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM

# Каждый сценарий изолирует окружение и перечитанные функции подоболочкой.
run_case() (
    mode="$1"
    Z2K_AU_SOURCE_ONLY=1; export Z2K_AU_SOURCE_ONLY
    # shellcheck source=/dev/null
    . "$ROOT/lib/utils.sh" 2>/dev/null
    # shellcheck source=/dev/null
    . "$ROOT/lib/auto_update.sh" 2>/dev/null
    ZAPRET2_DIR="$SB/$mode/zd"
    Z2K_AU_TMP_DIR="$SB/$mode/tmp"
    Z2K_AU_SBIN="$SB/$mode/sbin"
    Z2K_AU_INSTALLED_TAG_FILE="$ZAPRET2_DIR/.z2k-installed-tag"
    Z2K_AU_LOG_FILE="$SB/$mode/au.log"
    Z2K_AU_REPO_RAW=https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced
    Z2K_AU_FILE_TRIES=2
    repo="$SB/$mode/repo"
    requests="$SB/$mode/requests"
    mkdir -p "$ZAPRET2_DIR/lib" "$Z2K_AU_TMP_DIR" "$Z2K_AU_SBIN"
    for ref in p-85.10 p-84.18 z2k-enhanced; do
        mkdir -p "$repo/$ref/files/lua" "$repo/$ref/lib" \
            "$repo/$ref/webpanel/www" "$repo/$ref/tools/builds"
        printf 'release a\n' > "$repo/$ref/files/lua/a.lua"
        printf 'release b\n' > "$repo/$ref/files/lua/b.lua"
        printf 'release panel\n' > "$repo/$ref/webpanel/www/index.html"
        printf 'release binary\n' > "$repo/$ref/tools/builds/z2k-detect-linux-amd64"
        cp "$ROOT/lib/auto_update.sh" "$repo/$ref/lib/auto_update.sh"
    done
    printf 'inherited old a\n' > "$repo/p-84.18/files/lua/a.lua"
    printf 'old a\n' > "$ZAPRET2_DIR/a.lua"
    printf 'old b\n' > "$ZAPRET2_DIR/b.lua"
    printf 'old panel\n' > "$ZAPRET2_DIR/index.html"
    mkdir -p "$ZAPRET2_DIR/state"
    printf '2\n' > "$ZAPRET2_DIR/state/au-delivery-fails"
    # Только зависимости от платформы/сервисов; шаг и его загрузчик настоящие.
    : > "$ZAPRET2_DIR/lib/config_official.sh"
    get_arch() { echo test-amd64; }
    map_arch_to_bin_arch() { echo linux-x86_64; }
    au_snapshot_for_patch() { return 0; }
    au_rollback_patch() { : > "$SB/$mode/rollback"; }
    au_health_check() { return 0; }
    au_log() { printf '%s\n' "$*" >> "$Z2K_AU_LOG_FILE"; }
    sleep() { :; }

    ref_field=', "ref": "p-85.10"'
    case "$mode" in missing) ref_field='' ;; empty) ref_field=', "ref": ""' ;; esac
    cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<MANIFEST
{
  "current": "p-85.10",
  "history": [
    {"v": "p-84.18", "ref": "p-84.18"},
    {"v": "p-85.10"$ref_field}
  ],
  "install_map": {
    "files/lua/a.lua": ["$ZAPRET2_DIR/a.lua"],
    "files/lua/b.lua": ["$ZAPRET2_DIR/b.lua"],
    "webpanel/www/index.html": ["$ZAPRET2_DIR/index.html"],
    "lib/auto_update.sh": ["$ZAPRET2_DIR/lib/auto_update.sh"]
  },
  "files_sha256": {
    "files/lua/a.lua": "$(z2k_sha256_file "$repo/p-85.10/files/lua/a.lua")",
    "files/lua/b.lua": "$(z2k_sha256_file "$repo/p-85.10/files/lua/b.lua")",
    "webpanel/www/index.html": "$(z2k_sha256_file "$repo/p-85.10/webpanel/www/index.html")",
    "lib/auto_update.sh": "$(z2k_sha256_file "$repo/p-85.10/lib/auto_update.sh")",
    "tools/builds/z2k-detect-linux-amd64": "$(z2k_sha256_file "$repo/p-85.10/tools/builds/z2k-detect-linux-amd64")"
  }
}
MANIFEST
    if [ "$mode" = corrupt ]; then
        printf 'wrong tag payload\n' > "$repo/p-85.10/files/lua/b.lua"
        # Проверяем именно отказ 1, не эскалацию из-за прежнего счётчика 2.
        printf '0\n' > "$ZAPRET2_DIR/state/au-delivery-fails"
    fi

    # Граница транспорта: настоящий curl читает локальные файлы, проверка
    # эталона — та же _z2k_verify_fetched из utils.sh. Наружу запросов нет.
    # au_repo_base и обе функции au_download_repo_file* НЕ подменяются.
    z2k_fetch() {
        local url="$1" dest="$2" rel count
        printf '%s\n' "$url" >> "$requests"
        # Проверяет и export, а не только переменную в текущей оболочке.
        sh -c 'printf "%s\n" "$Z2K_AU_TARGET_REF"' >> "$SB/$mode/exported-ref"
        count=$(awk 'END {print NR}' "$requests")
        case "$url" in
            https://raw.githubusercontent.com/necronicle/z2k/*)
                rel=${url#https://raw.githubusercontent.com/necronicle/z2k/}
                rel=${rel%%\?*} ;;
            *) return 1 ;;
        esac
        # Уже полученный манифест остаётся прежним. Ветка сдвигается во
        # время первой доставки, тег продолжает отдавать прежние байты.
        if [ "$count" -eq 1 ]; then
            case "$mode" in tagged|retry|corrupt)
                for path in files/lua/a.lua files/lua/b.lua webpanel/www/index.html \
                    tools/builds/z2k-detect-linux-amd64; do
                    printf 'next release\n' > "$repo/z2k-enhanced/$path"
                done ;;
            esac
        fi
        if [ "$mode" = retry ] && [ "$rel" = p-85.10/files/lua/a.lua ]; then
            count=$(grep -c '/files/lua/a.lua' "$requests")
            # Первая попытка + её обход кэша падают. На повторе голый URL
            # отдаёт чужие байты; обход кэша должен сохранить целевой тег.
            [ "$count" -le 2 ] && return 1
            if [ "$count" -eq 3 ]; then
                rel=z2k-enhanced/files/lua/a.lua
            fi
        fi
        command curl -fsSL "file://$repo/$rel" -o "$dest" || return 1
        _z2k_verify_fetched "$dest" "$url"
    }
    Z2K_AU_TARGET_REF=p-84.18; export Z2K_AU_TARGET_REF
    rc=0
    au_apply_converge p-85.10 refresh-binaries > "$SB/$mode/output" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$SB/$mode/rc"
)

for mode in tagged retry missing empty corrupt; do
    run_case "$mode" || exit 1
    zd="$SB/$mode/zd"
    rc=$(cat "$SB/$mode/rc")
    if [ "$mode" = corrupt ]; then
        assert_eq 'чужие байты по тегу: доставка отклонена' 1 "$rc"
        assert_eq 'при отказе не разложен даже первый файл' 'old a' "$(cat "$zd/a.lua")"
        assert_eq 'отказ доставки увеличил счётчик' 1 "$(cat "$zd/state/au-delivery-fails")"
        assert_eq 'при отказе версия не записана' '' "$(cat "$zd/.z2k-installed-tag" 2>/dev/null)"
        continue
    fi
    assert_eq "$mode: доставка прошла" 0 "$rc"
    assert_eq "$mode: файл a целевого релиза" 'release a' "$(cat "$zd/a.lua")"
    assert_eq "$mode: файл b целевого релиза" 'release b' "$(cat "$zd/b.lua")"
    assert_eq "$mode: панель целевого релиза" 'release panel' "$(cat "$zd/index.html")"
    assert_eq "$mode: refresh-binaries в перечитанном коде" 'release binary' \
        "$(cat "$SB/$mode/sbin/z2k-detect" 2>/dev/null)"
    assert_eq "$mode: шаги действительно прошли через перечитывание" 1 \
        "$(grep -c 'шаги исполняет доставленный код' "$SB/$mode/au.log")"
    assert_eq "$mode: версия записана после доставки и шагов" p-85.10 "$(cat "$zd/.z2k-installed-tag" 2>/dev/null)"
    assert_eq "$mode: счётчик неудач обнулён" 0 "$(cat "$zd/state/au-delivery-fails")"
    expected_ref=p-85.10
    case "$mode" in missing|empty) expected_ref=z2k-enhanced ;; esac
    assert_eq "$mode: все URL используют целевой ref, включая бинарник" 0 \
        "$(grep -cv "^https://raw.githubusercontent.com/necronicle/z2k/$expected_ref/" "$SB/$mode/requests")"
    env_ref=$expected_ref
    case "$mode" in missing|empty) env_ref='' ;; esac
    assert_eq "$mode: экспортируется новый ref, старый отброшен" "$env_ref" \
        "$(sort -u "$SB/$mode/exported-ref")"
    if [ "$expected_ref" = p-85.10 ]; then
        assert_eq "$mode: ветка действительно сдвинулась во время доставки" 'next release' \
            "$(cat "$SB/$mode/repo/z2k-enhanced/files/lua/b.lua")"
    fi
    if [ "$mode" = retry ]; then
        assert_eq 'две попытки файла a с обходом кэша' 4 \
            "$(grep -c '/files/lua/a.lua' "$SB/$mode/requests")"
        assert_eq 'обход кэша сохранил целевой тег' 2 \
            "$(grep -c '/p-85.10/files/lua/a.lua?z2kcb=' "$SB/$mode/requests")"
    fi
done
printf '\nPASSED: %s, FAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
