#!/bin/sh
# tests/test_au_converge_inherited_ref.sh — сходимость не качает с тега, который
# остался в окружении от прошлой переустановки.
#
# ЧТО СЛУЧИЛОСЬ. au_apply_reinstall экспортирует Z2K_AU_TARGET_REF, а переустановка
# перезапускает планировщик прямо из своего окружения. Дальше каждый ночной
# прогон рождается от планировщика и получает эту переменную по наследству.
# au_apply_converge её не сбрасывал, и au_repo_base строила адрес по
# унаследованному тегу. Замер на роутере 25.09.2026: у z2k-scheduler.sh и lighttpd
# в /proc/<pid>/environ стоит Z2K_AU_TARGET_REF=p-84.18 (ночная переустановка
# 15.09), все четыре источника отдают файлы p-84.18 байт в байт, суммы ждутся от
# новой версии — отказ и откат девять ночей подряд.
#
# Проверяем ПОВЕДЕНИЕМ: подкладываем «наследство» в окружение и смотрим, с какого
# адреса сходимость пошла бы качать.
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d) || exit 1; trap 'rm -rf "$SB"' EXIT
Z2K_AU_SOURCE_ONLY=1; export Z2K_AU_SOURCE_ONLY
# shellcheck disable=SC1091
. "$ROOT/lib/utils.sh" 2>/dev/null
# shellcheck disable=SC1091
. "$ROOT/lib/auto_update.sh" 2>/dev/null
Z2K_AU_TMP_DIR="$SB/tmp"; mkdir -p "$Z2K_AU_TMP_DIR"
ZAPRET2_DIR="$SB/zd"; mkdir -p "$ZAPRET2_DIR/lua"
_log="$SB/log"
au_log() { printf '%s\n' "$*" >> "$_log"; }

# Один расходящийся файл — чтобы прогон дошёл до доставки.
printf 'старое\n' > "$ZAPRET2_DIR/lua/a.lua"
printf 'новое\n'  > "$SB/new.lua"
_sha=$(z2k_sha256_file "$SB/new.lua")

# Доставку не исполняем: запоминаем, откуда пошли бы качать, и отказываем —
# дальше функция только откатывается, это нам и нужно.
au_snapshot_for_patch() { return 0; }
au_rollback_patch() { return 0; }
au_converge_apply() { au_repo_base > "$SB/base"; return 1; }

manifest() {   # manifest <строка истории>
    cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<EOF
{
  "current": "p-85.10",
  "history": [
    $1
  ],
  "install_map": {
    "files/lua/a.lua": ["$ZAPRET2_DIR/lua/a.lua"]
  },
  "files_sha256": {
    "files/lua/a.lua": "$_sha"
  }
}
EOF
}

# Наследство от переустановки 15.09.
Z2K_AU_TARGET_REF=p-84.18; export Z2K_AU_TARGET_REF

# Сходимость ведёт себя так же, как на чистом окружении: качает из
# Z2K_AU_REPO_RAW. Это же переопределение держит песочницу
# scripts/rehearse_update.sh — адрес с тегом мимо него ушёл бы на GitHub.
for _entry in \
    '{"v": "p-85.10", "type": "patch", "ts": "2026-09-23T15:26:49Z", "ref": "p-85.10", "changed_files": []}' \
    '{"v": "p-85.10", "type": "patch", "ts": "2026-09-23T15:26:49Z", "changed_files": []}'
do
    Z2K_AU_TARGET_REF=p-84.18; export Z2K_AU_TARGET_REF
    manifest "$_entry"
    case "$_entry" in *'"ref"'*) _what="ref в манифесте есть" ;; *) _what="ref в манифесте нет" ;; esac
    rm -f "$SB/base"
    au_apply_converge p-85.10 >/dev/null 2>&1
    assert_eq "$_what: качаем из Z2K_AU_REPO_RAW, а не с унаследованного p-84.18" \
        "$Z2K_AU_REPO_RAW" "$(cat "$SB/base" 2>/dev/null)"
done

printf '\nPASSED: %s, FAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
