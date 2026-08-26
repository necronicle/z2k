#!/bin/sh
# tests/test_manifest_install_map.sh — манифест описывает целевое состояние целиком.
#
# install_map едет данными, чтобы роутер не знал ни одного шаблона путей и не
# опаздывал на релиз. Отсюда контракт: карта обязана покрывать ВСЕ деливеряблы,
# а не только изменившиеся, иначе сходимость к манифесту неполна и файл,
# потерянный три релиза назад, не восстановится.
#
# Проверяется ГЕНЕРАТОР в песочнице, а не UPDATES.json в дереве: между релизами
# манифест не меняется вообще — карту и подпись пересобирает release.sh одним
# шагом (см. tests/test_manifest_signature.sh, пункт 4).
PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
sk() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
report() { printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"; [ "$FAIL" -eq 0 ]; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { sk "контракт install_map" "нет python3"; report; exit $?; }

TMP=$(mktemp -d) || { sk "контракт install_map" "нет mktemp"; report; exit $?; }
trap 'rm -rf "$TMP"' EXIT
if ! git -C "$ROOT" clone -q --no-hardlinks --local . "$TMP/clone" 2>/dev/null; then
    sk "контракт install_map" "клонирование недоступно"; report; exit $?
fi
# Клон несёт закоммиченное состояние; накладываем рабочее дерево, включая новые
# файлы, — иначе тест сторожит вчерашний генератор.
for f in $(git -C "$ROOT" diff --name-only HEAD 2>/dev/null; git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null); do
    [ -f "$ROOT/$f" ] || continue
    mkdir -p "$TMP/clone/$(dirname "$f")"
    cp -f "$ROOT/$f" "$TMP/clone/$f"
done
cd "$TMP/clone" || { sk "контракт install_map" "клон недоступен"; report; exit $?; }
sh scripts/gen_file_hashes.sh >/dev/null 2>&1 || { no "генератор отработал" "успех" "ошибка"; report; exit $?; }
ok "генератор отработал"

OUT=$(python3 - UPDATES.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
sha, imap = d.get('files_sha256', {}), d.get('install_map', {})
print("HAS", 1 if imap else 0)
# верифай-онли бинарники цели не имеют: она зависит от арки роутера
missing = [f for f in sha if f not in imap and '/builds/' not in f]
print("MISSING", len(missing), " ".join(missing[:5]))
extra = [f for f in imap if f not in sha]
print("EXTRA", len(extra), " ".join(extra[:5]))
bad = [f for f, t in imap.items() if not isinstance(t, list) or not t
       or not all(isinstance(x, str) and x.startswith('/') for x in t)]
print("BAD", len(bad), " ".join(bad[:5]))
print("N", len(imap))
PY
)
assert_eq "install_map есть"                 "HAS 1"     "$(printf '%s\n' "$OUT" | grep '^HAS')"
assert_eq "у каждого деливерабла есть цель"  "MISSING 0" "$(printf '%s\n' "$OUT" | grep '^MISSING' | cut -d' ' -f1-2)"
assert_eq "нет целей без контрольной суммы"  "EXTRA 0"   "$(printf '%s\n' "$OUT" | grep '^EXTRA' | cut -d' ' -f1-2)"
assert_eq "все значения — непустые списки абсолютных путей" "BAD 0" "$(printf '%s\n' "$OUT" | grep '^BAD' | cut -d' ' -f1-2)"
_n=$(printf '%s\n' "$OUT" | grep '^N' | cut -d' ' -f2)
if [ "${_n:-0}" -gt 100 ]; then ok "карта покрывает всё дерево ($_n целей)"
else no "карта покрывает всё дерево" ">100 целей" "$_n"; fi

# Апдейтер читает карту своим sed'ом, а не python'ом: расхождение здесь —
# это доставка мимо цели на живом роутере.
rd() { sh -c "Z2K_AU_SOURCE_ONLY=1 . ./lib/auto_update.sh 2>/dev/null
au_manifest_install_targets ./UPDATES.json '$1' | tr '\n' '|'"; }
# Файл для этой проверки должен просто существовать в дереве; z2k-detectors.lua,
# стоявший здесь раньше, удалён 26.08.2026 как недостижимый.
assert_eq "апдейтер читает ту же цель"          "/opt/zapret2/lua/z2k-alert.lua|" "$(rd files/lua/z2k-alert.lua)"
assert_eq "апдейтер видит цель вне ZAPRET2_DIR" "/opt/etc/init.d/S51z2k-warp|"        "$(rd files/init.d/S51z2k-warp)"
assert_eq "апдейтер видит обе цели списка"      "/opt/zapret2/files/lists/telegram_ips.txt|/opt/zapret2/lists/telegram_ips.txt|" \
    "$(rd files/lists/telegram_ips.txt)"
assert_eq "у бинарника цели нет"                ""                                    "$(rd z2k-warpd/builds/z2k-warpd-linux-arm64)"
assert_eq "карта опознаётся"                    "0" "$(sh -c 'Z2K_AU_SOURCE_ONLY=1 . ./lib/auto_update.sh 2>/dev/null; au_manifest_has_install_map ./UPDATES.json; echo $?')"

# Генератор идемпотентен: второй прогон не меняет ни байта.
cp UPDATES.json "$TMP/pass1.json"
sh scripts/gen_file_hashes.sh >/dev/null 2>&1
if cmp -s "$TMP/pass1.json" UPDATES.json; then ok "второй прогон ничего не меняет"
else no "второй прогон ничего не меняет" "идентично" "разошлось"; fi

report
