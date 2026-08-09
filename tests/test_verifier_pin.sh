#!/bin/sh
# tests/test_verifier_pin.sh — дайджесты проверяльщика в z2k.sh совпадают со
# сборкой.
#
# ПОЧЕМУ БЕЗ ЭТОГО ГЕЙТА ПРОВЕРЯЛЬЩИК НЕЛЬЗЯ ВЫПУСКАТЬ. Рассинхрон здесь даёт
# отказ ОДНОВРЕМЕННО У ВСЕГО ПАРКА: z2k.sh не примет проверяльщик, не совпавший
# с пином, а без проверяльщика роутер с защёлкнутым храповиком отвергает
# манифест. То есть одна забытая пересборка = обновления встали у всех сразу.
#
# Класс проблемы в проекте уже реализовывался: `make all` без
# Z2K_TUNNEL_SECRET проходил молча и зелено, а на роутерах ложился Telegram.
# Здесь то же самое, только громче.
#
# Гейт сравнивает пины с СОБРАННЫМИ бинарниками в z2k-verify/builds/. Сборка
# воспроизводима (-trimpath -buildvcs=false), поэтому одинаковый исходник с тем
# же тулчейном обязан давать байт в байт тот же файл.
#
# POSIX sh.

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
Z2K="$ROOT/z2k.sh"
BUILDS="$ROOT/z2k-verify/builds"

[ -f "$Z2K" ] || { printf '[FAIL] нет %s\n' "$Z2K"; exit 1; }

_sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else return 1; fi
}

# --- 1. Таблица пинов на месте и непустая -------------------------------------
pins=$(sed -n 's/^        \(linux-[a-z0-9]*\)) *printf \([0-9a-f]\{64\}\) *;;.*/\1 \2/p' "$Z2K")
n=$(printf '%s\n' "$pins" | grep -c 'linux-')
if [ "$n" -ge 9 ]; then
    ok "в z2k.sh запинены дайджесты всех 9 арок ($n)"
else
    no "в z2k.sh запинены дайджесты всех 9 арок" "9" "$n"
fi

# --- 2. Пин совпадает со сборкой ----------------------------------------------
if [ ! -d "$BUILDS" ]; then
    SKIP=$((SKIP+1))
    printf '[SKIP] сверка пинов со сборкой (нет %s — соберите: cd z2k-verify && make all)\n' "$BUILDS"
else
    _mismatch=0 _checked=0
    printf '%s\n' "$pins" | while read -r arch want; do
        [ -n "$arch" ] || continue
        f="$BUILDS/z2k-verify-$arch"
        if [ ! -s "$f" ]; then
            printf '[FAIL] нет сборки для %s — пин не с чем сверить\n' "$arch"
            echo x >> "$HERE/.pinfail.$$"
            continue
        fi
        got=$(_sha "$f")
        if [ "$got" != "$want" ]; then
            printf '[FAIL] %s: пин %s, сборка %s\n' "$arch" "$want" "$got"
            echo x >> "$HERE/.pinfail.$$"
        fi
    done
    if [ -f "$HERE/.pinfail.$$" ]; then
        _mismatch=$(wc -l < "$HERE/.pinfail.$$" | tr -d ' ')
        rm -f "$HERE/.pinfail.$$"
        FAIL=$((FAIL + _mismatch))
        printf '[FAIL] пины разошлись со сборкой у %s арок — обновите таблицу в z2k.sh\n' "$_mismatch"
    else
        ok "все пины совпадают со сборкой"
    fi
    _checked=0
    for _b in "$BUILDS"/z2k-verify-linux-*; do
        [ -f "$_b" ] && _checked=$((_checked + 1))
    done
    if [ "$_checked" -ge 9 ]; then
        ok "собраны все 9 арок ($_checked)"
    else
        no "собраны все 9 арок" "9" "$_checked"
    fi
fi

# --- 3. В бинарнике нет ничего изменчивого ------------------------------------
#
# Контракт: ни ключа, ни версии — всё аргументами. Иначе ротация ключа требовала
# бы пересборки девяти арок и десятков мегабайт в историю git, который бинарники
# не дельтит.
MAIN="$ROOT/z2k-verify/cmd/z2k-verify/main.go"
if [ -f "$MAIN" ]; then
    if grep -qE 'BEGIN PUBLIC KEY|MCowBQYDK2Vw' "$MAIN"; then
        no "в проверяльщике не вшит публичный ключ" "нет ключа в исходнике" "ключ найден"
    else
        ok "в проверяльщике не вшит публичный ключ"
    fi
    if grep -qE '^var (version|Version) ' "$MAIN"; then
        no "в проверяльщике не вшита версия" "нет версии" "версия найдена"
    else
        ok "в проверяльщике не вшита версия"
    fi
else
    no "исходник проверяльщика на месте" "$MAIN" "нет"
fi

# --- 4. ARM собирается с GOARM=5 ----------------------------------------------
#
# У mtproxy-client стоит 7. Разнобой опаснее, чем кажется: собранный под ARMv7
# бинарник на ARMv5 без VFP падает с illegal instruction, а это при защёлкнутом
# храповике означает «обновления встали» на всей этой части парка.
MK="$ROOT/z2k-verify/Makefile"
if [ -f "$MK" ] && grep -q 'GOARCH=arm GOARM=5' "$MK"; then
    ok "ARM собирается с GOARM=5"
else
    no "ARM собирается с GOARM=5" "GOARM=5" "не найдено в Makefile"
fi

# --- 5. Сборка воспроизводима --------------------------------------------------
if [ -f "$MK" ] && grep -q -- '-trimpath' "$MK" && grep -q -- '-buildvcs=false' "$MK"; then
    ok "сборка воспроизводима (-trimpath, -buildvcs=false)"
else
    no "сборка воспроизводима" "-trimpath и -buildvcs=false" "не найдено"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
