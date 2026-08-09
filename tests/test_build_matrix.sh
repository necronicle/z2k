#!/bin/sh
# tests/test_build_matrix.sh — арки и флаги описаны в одном месте, и всё
# остальное с ним сходится.
#
# ЧТО СЛУЧИЛОСЬ. Матрица была переписана от руки в трёх местах: Makefile каждого
# модуля, кросс-сборка CI и сверка бинарников. Они разошлись: CI собирал
# mtproxy-client/arm с GOARM=5, а Makefile выпускал GOARM=7 — то есть
# ARM-бинарник Телеграм-клиента не проверялся ни одним прогоном ни разу.
# Комментарий в CI при этом уверенно утверждал обратное, и читающий его человек
# получал ложное чувство покрытия.
#
# build-matrix.tsv объявлен источником правды. Здесь сверяются три вещи:
# Makefile'ы, содержимое builds/ и то, что CI читает именно этот файл.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
M="$ROOT/build-matrix.tsv"
[ -f "$M" ] || { printf '[FAIL] нет %s\n' "$M"; exit 1; }

ROWS=$(mktemp) || exit 1
trap 'rm -f "$ROWS"' EXIT
grep -v '^#' "$M" | grep '	' > "$ROWS"

_n=$(wc -l < "$ROWS" | tr -d ' ')
if [ "$_n" -ge 30 ]; then ok "матрица непустая ($_n строк)"
else no "матрица непустая" "минимум 30" "$_n"; fi

# --- 1. Каждый модуль с go.mod есть в матрице ---------------------------------
_miss=0
for _g in "$ROOT"/*/go.mod; do
    [ -f "$_g" ] || continue
    _mod=$(basename "$(dirname "$_g")")
    grep -q "^${_mod}	" "$ROWS" || { printf '[FAIL] модуля %s нет в матрице\n' "$_mod"; _miss=$((_miss+1)); }
done
[ "$_miss" = "0" ] && ok "все модули с go.mod присутствуют" || FAIL=$((FAIL + _miss))

# --- 2. Makefile сходится с матрицей по флагам --------------------------------
#
# Сверяем ровно то, что разошлось в поле: доп. переменные у конкретной арки.
_bad=0
while IFS='	' read -r _mod _pkg _bdir _prefix _arch _sfx _extra; do
    [ -n "$_mod" ] || continue
    [ "$_bdir" = "-" ] && continue          # vps-relay: per-arch целей нет
    _mk="$ROOT/$_mod/Makefile"
    [ -f "$_mk" ] || { printf '[FAIL] нет %s\n' "$_mk"; _bad=$((_bad+1)); continue; }
    _line=$(grep -E "GOARCH=${_arch}([^0-9a-z]|$)" "$_mk" | head -1)
    if [ -z "$_line" ]; then
        printf '[FAIL] %s: в Makefile нет цели под GOARCH=%s\n' "$_mod" "$_arch"
        _bad=$((_bad+1)); continue
    fi
    if [ "$_extra" != "-" ]; then
        _key=${_extra%%=*}; _val=${_extra#*=}
        _got=$(printf '%s' "$_line" | sed -n "s/.*${_key}=\([A-Za-z0-9]*\).*/\1/p")
        if [ "$_got" != "$_val" ]; then
            printf '[FAIL] %s/%s: матрица %s=%s, Makefile %s=%s\n' \
                "$_mod" "$_arch" "$_key" "$_val" "$_key" "${_got:-нет}"
            _bad=$((_bad+1))
        fi
    elif printf '%s' "$_line" | grep -qE 'GOARM=|GOMIPS=|GOMIPS64='; then
        printf '[FAIL] %s/%s: в Makefile есть флаг, которого нет в матрице\n' "$_mod" "$_arch"
        _bad=$((_bad+1))
    fi
    # Имя выходного файла — тоже часть контракта: установщик ищет по нему.
    # Пишут его двумя способами: явным суффиксом в строке сборки
    # (mtproxy-client, rt-proxy) или через имя цели $@ из списка арок
    # (z2k-detect, z2k-verify). Принимаем оба, но требуем, чтобы имя вообще
    # встречалось в Makefile — иначе выпускается файл, которого никто не ждёт.
    if ! grep -qE -- "(-linux-${_sfx}([^0-9a-z]|$)|(^|[[:space:]])linux-${_sfx}([[:space:]]|$))" "$_mk"; then
        printf '[FAIL] %s/%s: в Makefile нет имени linux-%s\n' "$_mod" "$_arch" "$_sfx"
        _bad=$((_bad+1))
    fi
done < "$ROWS"
[ "$_bad" = "0" ] && ok "Makefile'ы сходятся с матрицей по флагам и именам файлов" || FAIL=$((FAIL + _bad))

# --- 3. Всё, что лежит в builds/, объявлено в матрице -------------------------
#
# Обратная сторона: файл, которого нет в матрице, никем не собирается и не
# сверяется — он просто лежит и едет людям.
_orph=0
for _d in "$ROOT"/*/builds; do
    [ -d "$_d" ] || continue
    _rel="$(basename "$(dirname "$_d")")/builds"
    for _f in "$_d"/*-linux-*; do
        [ -f "$_f" ] || continue
        _b=$(basename "$_f"); _p=${_b%-linux-*}; _s=${_b##*-linux-}
        if ! awk -F'	' -v d="$_rel" -v p="$_p" -v s="$_s" \
               '$3==d && $4==p && $6==s {found=1} END{exit !found}' "$ROWS"; then
            printf '[FAIL] %s/%s лежит в дереве, но в матрице его нет\n' "$_rel" "$_b"
            _orph=$((_orph+1))
        fi
    done
done
[ "$_orph" = "0" ] && ok "в builds/ нет бинарников вне матрицы" || FAIL=$((FAIL + _orph))

# --- 4. Обратное: каждая строка матрицы имеет файл ----------------------------
_gone=0
while IFS='	' read -r _mod _pkg _bdir _prefix _arch _sfx _extra; do
    [ -n "$_mod" ] || continue
    [ "$_bdir" = "-" ] && continue
    [ -f "$ROOT/$_bdir/$_prefix-linux-$_sfx" ] || {
        printf '[FAIL] матрица объявляет %s/%s-linux-%s, а файла нет\n' "$_bdir" "$_prefix" "$_sfx"
        _gone=$((_gone+1)); }
done < "$ROWS"
[ "$_gone" = "0" ] && ok "каждая строка матрицы имеет отгружаемый файл" || FAIL=$((FAIL + _gone))

# --- 5. CI читает матрицу, а не свой список -----------------------------------
CI="$ROOT/.github/workflows/ci.yml"
if grep -q 'build-matrix.tsv' "$CI"; then
    ok "CI читает build-matrix.tsv"
else
    no "CI читает build-matrix.tsv" "ссылка на файл" "у CI собственный список"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
