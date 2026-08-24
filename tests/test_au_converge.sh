#!/bin/sh
# tests/test_au_converge.sh — обновление сходится к манифесту, а не применяет дельту.
#
# Следствия, которые здесь проверяются:
#   - доставляется РОВНО недостающее (совпавшее по sha не качается);
#   - повторный прогон не делает ничего (идемпотентность);
#   - файл, потерянный три релиза назад, восстанавливается сам — не потому что
#     мы это предусмотрели, а потому что он не совпал по sha;
#   - при битой сумме цель не портится: сначала качаем и проверяем ВСЁ, только
#     потом раскладываем.
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
au_log() { :; }

sha() { z2k_sha256_file "$1"; }
mkdir -p "$SB/zd/lua" "$SB/repo/files/lua"
printf 'старое\n' > "$SB/zd/lua/a.lua"
printf 'новое\n'  > "$SB/repo/files/lua/a.lua"
printf 'то же\n'  > "$SB/zd/lua/b.lua"
cp "$SB/zd/lua/b.lua" "$SB/repo/files/lua/b.lua"
printf 'потерян\n' > "$SB/repo/files/lua/c.lua"    # на диске отсутствует вовсе

cat > "$SB/manifest.json" <<EOF
{
  "install_map": {
    "files/lua/a.lua": ["$SB/zd/lua/a.lua"],
    "files/lua/b.lua": ["$SB/zd/lua/b.lua"],
    "files/lua/c.lua": ["$SB/zd/lua/c.lua"]
  },
  "files_sha256": {
    "files/lua/a.lua": "$(sha "$SB/repo/files/lua/a.lua")",
    "files/lua/b.lua": "$(sha "$SB/repo/files/lua/b.lua")",
    "files/lua/c.lua": "$(sha "$SB/repo/files/lua/c.lua")"
  },
  "current": "p-1"
}
EOF

assert_eq "манифест с картой опознан" "0" "$(au_manifest_has_install_map "$SB/manifest.json"; echo $?)"
assert_eq "цель читается из карты" "$SB/zd/lua/a.lua" "$(au_manifest_install_targets "$SB/manifest.json" files/lua/a.lua)"

plan=$(au_converge_plan "$SB/manifest.json" | sort | tr '\n' ' ')
assert_eq "в план попали только расходящиеся" "files/lua/a.lua files/lua/c.lua " "$plan"

# Доставка: качалку подменяем локальным репозиторием.
au_download_repo_file() { cp "$SB/repo/$1" "$2" 2>/dev/null; }
au_converge_plan "$SB/manifest.json" > "$SB/plan.txt"
assert_eq "доставка прошла" "0" "$(au_converge_apply "$SB/manifest.json" "$SB/plan.txt"; echo $?)"
assert_eq "изменённый файл обновлён" "новое" "$(cat "$SB/zd/lua/a.lua")"
assert_eq "потерянный файл восстановлен" "потерян" "$(cat "$SB/zd/lua/c.lua")"
assert_eq "совпадавший файл не тронут" "то же" "$(cat "$SB/zd/lua/b.lua")"

assert_eq "повторный прогон: делать нечего" "" "$(au_converge_plan "$SB/manifest.json" | tr '\n' ' ')"

# Битая сумма: НИЧЕГО не раскладывается — ни этот файл, ни соседний по плану.
printf 'подделка\n' > "$SB/repo/files/lua/a.lua"
printf 'старое\n'   > "$SB/zd/lua/a.lua"
printf 'тоже старое\n' > "$SB/zd/lua/c.lua"
printf 'files/lua/a.lua\nfiles/lua/c.lua\n' > "$SB/plan2.txt"
assert_eq "sha не сошлась — отказ" "1" "$(au_converge_apply "$SB/manifest.json" "$SB/plan2.txt"; echo $?)"
assert_eq "цель не испорчена" "старое" "$(cat "$SB/zd/lua/a.lua")"
assert_eq "соседний файл тоже не тронут — раскладка после проверки ВСЕГО" \
    "тоже старое" "$(cat "$SB/zd/lua/c.lua")"

# Две цели у одного файла (списки: files/lists/ + lists/).
mkdir -p "$SB/zd/files/lists" "$SB/zd/lists" "$SB/repo/files/lists"
printf 'список\n' > "$SB/repo/files/lists/t.txt"
cat > "$SB/m2.json" <<EOF
{"install_map": {"files/lists/t.txt": ["$SB/zd/files/lists/t.txt", "$SB/zd/lists/t.txt"]},
 "files_sha256": {"files/lists/t.txt": "$(sha "$SB/repo/files/lists/t.txt")"},
 "current": "p-1"}
EOF
printf 'files/lists/t.txt\n' > "$SB/plan3.txt"
au_converge_apply "$SB/m2.json" "$SB/plan3.txt" >/dev/null
assert_eq "обе цели заполнены" "список|список" \
    "$(cat "$SB/zd/files/lists/t.txt" 2>/dev/null)|$(cat "$SB/zd/lists/t.txt" 2>/dev/null)"

# Обрыв загрузки — отказ, дерево не тронуто.
au_download_repo_file() { return 1; }
printf 'цел\n' > "$SB/zd/lua/a.lua"
printf 'files/lua/a.lua\n' > "$SB/plan4.txt"
assert_eq "обрыв загрузки — отказ" "1" "$(au_converge_apply "$SB/manifest.json" "$SB/plan4.txt"; echo $?)"
assert_eq "после обрыва цель цела" "цел" "$(cat "$SB/zd/lua/a.lua")"

# ── ХОД РАБОТЫ ───────────────────────────────────────────────────────────────
#
# Владелец роутера прочитал обычное обновление как поломку: журнал печатал
# «расходится файлов — 10» и молчал всё время скачивания. Молчание в журнале
# неотличимо от зависания, поэтому строка на каждый файл — часть работы, а не
# оформление, и уходить она не должна.
_log="$SB/progress.log"
au_log() { printf '%s\n' "$*" >> "$_log"; }
: > "$_log"
au_download_repo_file() { cp "$SB/repo/$1" "$2" 2>/dev/null; }
mkdir -p "$SB/repo/files/lua" "$SB/zd/lua"
printf 'p1\n' > "$SB/repo/files/lua/p1.lua"
printf 'p2\n' > "$SB/repo/files/lua/p2.lua"
cat > "$SB/m3.json" <<EOF
{
  "install_map": {
    "files/lua/p1.lua": ["$SB/zd/lua/p1.lua"],
    "files/lua/p2.lua": ["$SB/zd/lua/p2.lua"]
  },
  "files_sha256": {
    "files/lua/p1.lua": "$(sha "$SB/repo/files/lua/p1.lua")",
    "files/lua/p2.lua": "$(sha "$SB/repo/files/lua/p2.lua")"
  }
}
EOF
printf 'files/lua/p1.lua\nfiles/lua/p2.lua\n' > "$SB/plan5.txt"
assert_eq "оба файла доставлены" "0" "$(au_converge_apply "$SB/m3.json" "$SB/plan5.txt" >/dev/null 2>&1; echo $?)"
assert_eq "виден ход: строка на каждый файл" "2" "$(grep -c 'качаю' "$_log")"
assert_eq "видно, сколько осталось"          "1" "$(grep -c '\[2/2\]' "$_log")"
assert_eq "видно, что качается прямо сейчас" "1" "$(grep -c '\[1/2\] качаю files/lua/p1.lua' "$_log")"
au_log() { :; }

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
