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
# Утверждения — по ВЫВОДУ движка, а не по файлам: песочница живёт внутри него и
# исчезает вместе с ним, а «сходимость» сильнее любой проверки двух файлов —
# она сверяет каждый файл манифеста.
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

# Пара деревьев В ВИДЕ РЕПОЗИТОРИЯ: prev — предыдущий релиз, cand — кандидат.
#
# Адреса в install_map АБСОЛЮТНЫЕ, и часть их лежит вне /opt/zapret2 — так и в
# настоящем манифесте: S99zapret2 живёт в /opt/etc/init.d. Движок обязан
# переписать их под свой корень; фикстура нарочно содержит обе разновидности,
# потому что на настоящем масштабе первая же репетиция об это и споткнулась.
#
# Запись истории обязана начинаться с {"v": — именно этот вид ищет
# au_entry_steps, и фикстура с "version" молча дала бы ноль шагов.
mk_fixture() {
    _p="$1"; _c="$2"
    mkdir -p "$_p/files/lua" "$_p/files/etc" "$_p/files/init.d" \
             "$_c/files/lua" "$_c/files/etc" "$_c/files/init.d"
    printf 'старое\n'      > "$_p/files/lua/a.lua"
    printf 'то же\n'       > "$_p/files/lua/b.lua"
    printf 'старый init\n' > "$_p/files/init.d/S99zapret2.new"
    printf 'новое\n'       > "$_c/files/lua/a.lua"
    cp "$_p/files/lua/b.lua" "$_c/files/lua/b.lua"
    printf 'добавлен\n'    > "$_c/files/lua/c.lua"
    printf 'новый init\n'  > "$_c/files/init.d/S99zapret2.new"
    cp "$ROOT/files/etc/z2k-update-pub.pem" "$_p/files/etc/z2k-update-pub.pem"
    cp "$ROOT/files/etc/z2k-update-pub.pem" "$_c/files/etc/z2k-update-pub.pem"
    cat > "$_c/UPDATES.json" <<EOF
{
  "current": "p-2",
  "install_map": {
  "files/lua/a.lua": ["/opt/zapret2/lua/a.lua"],
  "files/lua/b.lua": ["/opt/zapret2/lua/b.lua"],
  "files/lua/c.lua": ["/opt/zapret2/lua/c.lua"],
  "files/init.d/S99zapret2.new": ["/opt/etc/init.d/S99zapret2"],
  "files/etc/z2k-update-pub.pem": ["/opt/zapret2/etc/z2k-update-pub.pem"]
  },
  "files_sha256": {
  "files/lua/a.lua": "$(z2k_sha "$_c/files/lua/a.lua")",
  "files/lua/b.lua": "$(z2k_sha "$_c/files/lua/b.lua")",
  "files/lua/c.lua": "$(z2k_sha "$_c/files/lua/c.lua")",
  "files/init.d/S99zapret2.new": "$(z2k_sha "$_c/files/init.d/S99zapret2.new")",
  "files/etc/z2k-update-pub.pem": "$(z2k_sha "$_c/files/etc/z2k-update-pub.pem")"
  },
  "history": [
{"v": "p-2", "type": "patch", "ref": "HEAD", "steps": ["restart-service"], "changed_files": []},
{"v": "p-1", "type": "patch", "ref": "HEAD", "changed_files": []}
  ]
}
EOF
}

# ── Успешный проход ──────────────────────────────────────────────────────────
mk_fixture "$SB/prev" "$SB/cand"
# --updater candidate: постоянный тест отвечает на «не сломали ли мы код», и
# гонять он обязан НАШ апдейтер. Релизный гейт берёт старый — см. шапку движка.
out=$(sh "$ENGINE" --prev "$SB/prev" --candidate "$SB/cand" \
      --from p-1 --to p-2 --updater candidate 2>&1)
rc=$?
assert_eq "успешный проход возвращает ноль" "0" "$rc"
assert_eq "прогон дожил под set -e"   "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] прогон')"
assert_eq "сходимость подтверждена"   "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] сходимость')"
assert_eq "снимок непустой"           "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] снимок')"
assert_eq "шаги те и в том порядке"   "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] шаги')"
assert_eq "отметка версии сдвинулась" "1" "$(printf '%s\n' "$out" | grep -c '^\[OK\] отметка версии')"
assert_eq "время между строками напечатано" "1" "$(printf '%s\n' "$out" | grep -c 'самая длинная пауза')"
assert_eq "ни одного нарушенного утверждения" "0" "$(printf '%s\n' "$out" | grep -c '^\[FAIL\]')"

# ── Обрыв посреди доставки ───────────────────────────────────────────────────
#
# Обрыв — не «а вдруг»: ровно так выглядит потеря связи, и именно в этом окне
# дерево наполовину новое. Откат обязан вернуть его ПОБАЙТНО, а отметка версии
# остаться старой — иначе роутер считает себя обновлённым, не будучи им.
out2=$(sh "$ENGINE" --prev "$SB/prev" --candidate "$SB/cand" \
       --from p-1 --to p-2 --updater candidate --interrupt-after 1 2>&1)
rc2=$?
assert_eq "обрыв: утверждения выполнены"   "0" "$rc2"
assert_eq "обрыв распознан как провал"     "1" "$(printf '%s\n' "$out2" | grep -c '^\[OK\] обрыв распознан')"
assert_eq "дерево вернулось как было"      "1" "$(printf '%s\n' "$out2" | grep -c '^\[OK\] откат')"
assert_eq "отметка версии осталась старой" "1" "$(printf '%s\n' "$out2" | grep -c '^\[OK\] отметка версии не сдвинулась')"

# ── Гейт в release.sh ────────────────────────────────────────────────────────
#
# Окно единственное: кандидат уже существует (манифест собран и подписан), а
# номер ещё не сожжён (коммита и тега нет). Переиздавать вышедший номер нельзя,
# поэтому дешевле не выпустить, чем выпустить и откатывать.
R="$ROOT/scripts/release.sh"
assert_eq "гейт зовёт движок" "1" "$(grep -c 'rehearse_update.sh' "$R")"
assert_eq "гейт стоит ДО коммита" "1" \
    "$(awk '/rehearse_update.sh/ && !r {r=NR} /^git commit -q -m "release:/ {c=NR} END {print (r>0 && c>0 && r<c) ? 1 : 0}' "$R")"
assert_eq "и ПОСЛЕ подписи манифеста" "1" \
    "$(awk '/подпись сверена с опубликованным/ {p=NR} /rehearse_update.sh/ && !r {r=NR} END {print (p>0 && r>p) ? 1 : 0}' "$R")"
assert_eq "провал останавливает релиз" "1" "$(grep -c 'репетиция провалена' "$R")"
assert_eq "обход есть и он громкий" "1" \
    "$(awk '/Z2K_REHEARSAL_SKIP/ {n++} END {print (n>0) ? 1 : 0}' "$R")"
# Предыдущий релиз берётся из того, что release.sh уже вычислил, а не заново:
# два способа определить одно и то же разъедутся.
assert_eq "предыдущий релиз не изобретается заново" "1" \
    "$(awk '/rehearse_update.sh/ {f=1} f && /--from "\$CUR"/ {print 1; exit} END {if (!f) print 0}' "$R")"
# Гейт релиза обязан гонять СТАРЫЙ апдейтер: на роутере обновление выполняет
# тот, что уже лежит на диске, а новый начинает работать со следующего раза.
assert_eq "гейт не навязывает свой апдейтер" "0" \
    "$(awk '/rehearse_update.sh/ {f=1} f && /--updater candidate/ {n++} END {print n+0}' "$R")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
