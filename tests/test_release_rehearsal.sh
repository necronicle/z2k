#!/bin/sh
# tests/test_release_rehearsal.sh — репетиция обновления в песочнице.
#
# ЗАЧЕМ. Переработка обновлений приехала с тремя дефектами, и каждый нашёл живой
# человек, а не мы:
#
#   `cmd; rc=$?` под чужим set -e   — терминал умирал молча на проверке конфига
#   снимок для отката брал 0 файлов — 42 секунды тишины, откатывать нечего
#   счётчик поставлен не на тот участок — «висит» осталось на месте
#
# Юнит-тесты были зелёные, CI зелёный. Обновление как ПРОЦЕСС — от старой
# версии до новой, со снимком, шагами и откатом — не проверялось ни разу
# целиком. Здесь оно проверяется целиком, в песочнице, без железа.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENGINE="$ROOT/scripts/rehearse_update.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM

for need in python3 curl dash; do
    command -v "$need" >/dev/null 2>&1 || { printf 'SKIP: нет %s\n' "$need"; exit 0; }
done

z2k_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

# Пара деревьев: base — «как установлено сейчас», cand — что раздаётся.
# Запись истории обязана начинаться с {"v": — именно этот вид ищет
# au_entry_steps, и фикстура с "version" молча дала бы ноль шагов.
mk_fixture() {
    _b="$1"; _c="$2"
    mkdir -p "$_b/zd/lua" "$_b/zd/etc" "$_c/files/lua" "$_c/files/etc"
    printf 'старое\n'   > "$_b/zd/lua/a.lua"
    printf 'то же\n'    > "$_b/zd/lua/b.lua"
    printf 'новое\n'    > "$_c/files/lua/a.lua"
    cp "$_b/zd/lua/b.lua" "$_c/files/lua/b.lua"
    printf 'добавлен\n' > "$_c/files/lua/c.lua"
    cp "$ROOT/files/etc/z2k-update-pub.pem" "$_b/zd/etc/z2k-update-pub.pem"
    cp "$ROOT/files/etc/z2k-update-pub.pem" "$_c/files/etc/z2k-update-pub.pem"
    printf 'p-1\n' > "$_b/zd/.z2k-installed-tag"
    cat > "$_c/UPDATES.json" <<EOF
{
  "current": "p-2",
  "install_map": {
  "files/lua/a.lua": ["$_b/zd/lua/a.lua"],
  "files/lua/b.lua": ["$_b/zd/lua/b.lua"],
  "files/lua/c.lua": ["$_b/zd/lua/c.lua"]
  },
  "files_sha256": {
  "files/lua/a.lua": "$(z2k_sha "$_c/files/lua/a.lua")",
  "files/lua/b.lua": "$(z2k_sha "$_c/files/lua/b.lua")",
  "files/lua/c.lua": "$(z2k_sha "$_c/files/lua/c.lua")"
  },
  "history": [
{"v": "p-2", "type": "patch", "ref": "HEAD", "steps": ["restart-service"], "changed_files": []},
{"v": "p-1", "type": "patch", "ref": "HEAD", "changed_files": []}
  ]
}
EOF
}

# ── Успешный проход ──────────────────────────────────────────────────────────
mk_fixture "$SB/base" "$SB/cand"
out=$(sh "$ENGINE" --base "$SB/base/zd" --candidate "$SB/cand" --from p-1 --to p-2 2>&1)
rc=$?
assert_eq "успешный проход возвращает ноль" "0" "$rc"
assert_eq "прогон дожил под set -e"   "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] прогон')"
assert_eq "сходимость подтверждена"   "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] сходимость')"
assert_eq "снимок непустой"           "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] снимок')"
assert_eq "шаги те и в том порядке"   "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] шаги')"
assert_eq "отметка версии сдвинулась" "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] отметка версии')"
assert_eq "время между строками напечатано" "1" "$(printf '%s\n' "$out" | grep -c 'самая длинная пауза')"

# Доставка обязана была реально произойти, а не «сойтись» на пустом плане.
assert_eq "изменившийся файл обновлён" "новое"    "$(cat "$SB/base/zd/lua/a.lua" | tr -d '\n')"
assert_eq "отсутствовавший привезён"   "добавлен" "$(cat "$SB/base/zd/lua/c.lua" 2>/dev/null | tr -d '\n')"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
