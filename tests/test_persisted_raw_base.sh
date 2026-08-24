#!/bin/sh
# tests/test_persisted_raw_base.sh — база обновления списков не должна застывать
# на теге релиза.
#
# ЧТО СЛУЧИЛОСЬ. Обновление на время своей работы пинит GITHUB_RAW на
# НЕИЗМЕНЯЕМЫЙ тег релиза, чтобы все файлы приехали из одного среза. Этот пин
# утекал в конфиг: create_official_config записывал Z2K_GITHUB_RAW из текущего
# окружения, и роутер, переустановившийся на r-79.7, потом ВЕЧНО тянул списки
# доменов из тега r-79.7. Ветка уезжала, у него списки замирали, и ни в одном
# логе это не выглядело ошибкой. Найдено на роутере владельца прямой сверкой
# конфига до и после перегенерации.
#
# С переходом на адресные обновления переустановки стали редкими — то есть пин
# жил бы ещё дольше.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Логика среза пина проверяется как есть — тем же case, что в генераторе.
pick() {
    _r="$1"
    case "$_r" in
        */necronicle/z2k/z2k-enhanced|*/necronicle/z2k/z2k-staging) ;;
        */necronicle/z2k/*)
            _r="${Z2K_RELEASE_BRANCH:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}" ;;
    esac
    printf '%s' "$_r"
}
B=https://raw.githubusercontent.com/necronicle/z2k

assert_eq "тег релиза срезается до ветки"     "$B/z2k-enhanced" "$(pick "$B/r-79.7")"
assert_eq "дотнутый тег тоже"                 "$B/z2k-enhanced" "$(pick "$B/p-79.10")"
assert_eq "хеш коммита тоже"                  "$B/z2k-enhanced" "$(pick "$B/1756a43")"
assert_eq "рабочая ветка сохраняется"         "$B/z2k-enhanced" "$(pick "$B/z2k-enhanced")"
assert_eq "staging сохраняется (тестовые сборки)" "$B/z2k-staging" "$(pick "$B/z2k-staging")"
# Зеркало или форк — не наш случай, не трогаем: человек знает, что делает.
assert_eq "чужая база не трогается" "https://example.invalid/mirror" "$(pick "https://example.invalid/mirror")"

# Контракт генератора: он обязан писать срезанное значение, а не сырое окружение.
G="$ROOT/lib/config_official.sh"
if grep -q '_z2k_persist_raw' "$G"; then
    ok "генератор пишет отдельно вычисленную базу"
else
    no "генератор пишет отдельно вычисленную базу" "_z2k_persist_raw" "не найдено — пин снова утечёт"
fi
if grep -q 'Z2K_GITHUB_RAW="\${_z2k_persist_raw}"' "$G"; then
    ok "в конфиг идёт именно она"
else
    no "в конфиг идёт именно она" 'Z2K_GITHUB_RAW="${_z2k_persist_raw}"' "не найдено"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
