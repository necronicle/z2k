#!/bin/sh
# tests/test_shell_syntax_ash.sh — каждый поставляемый скрипт обязан
# разбираться оболочкой роутера.
#
# Повод: 31.08.2026 z2k-tcp16-probe.sh уехал в релиз с синтаксической ошибкой и
# падал на роутере первой же строкой. На маке `sh -n` его пропускает — там bash
# в режиме sh, а на Keenetic busybox ash, и он строже. Ошибка нашлась только
# штатным запуском на железе, то есть после выпуска.
#
# dash — ближайший к ash разборщик, доступный в CI. Проверка стоит секунды и
# закрывает весь класс «у меня работало».
# POSIX sh.

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

SH=""
for c in dash ash busybox; do
    command -v "$c" >/dev/null 2>&1 || continue
    case "$c" in
        busybox) busybox sh -c 'true' >/dev/null 2>&1 && SH="busybox sh" ;;
        *)       SH="$c" ;;
    esac
    [ -n "$SH" ] && break
done
[ -n "$SH" ] || { echo "[SKIP] нет dash/ash/busybox — проверить нечем"; exit 0; }

bad_files=""
n=0
for f in "$DIR"/files/*.sh "$DIR"/lib/*.sh "$DIR"/webpanel/cgi/*.sh; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    # shellcheck disable=SC2086
    $SH -n "$f" 2>/dev/null || bad_files="$bad_files $(basename "$f")"
done

if [ -z "$bad_files" ]; then
    ok "все $n поставляемых скриптов разбираются оболочкой $SH"
else
    bad "не разбираются оболочкой роутера:$bad_files"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
