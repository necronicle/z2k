#!/bin/sh
# tests/test_update_stale_mirror_cachebust.sh — свежеопубликованный релиз обязан
# доехать СРАЗУ, а не после того, как истекут кэши зеркал.
#
# ЧТО СЛУЧИЛОСЬ. Публикация двигает релизную ветку, но raw/jsdelivr/gh-proxy ещё
# несколько минут отдают до-релизные байты. Пара манифест+подпись от этого уже
# защищена (au_repair_torn_pair перезапрашивает её мимо кэша), а файлы — не были.
# Получалось гарантированное окно: манифест свежий, файл старый, sha не сходится,
# роутер откатывает релиз целиком и повторяет только через сутки. Перебор зеркал
# тут бесполезен — причина у всех одна, и она не в зеркале.
#
# Отсюда правило: промах по ожидаемому sha — это ещё не отказ. Пока эталон
# известен, тот же адрес обязан быть перезапрошен с уникальным параметром: для
# кэша это другой объект, и он идёт за ним к первоисточнику.
#
# Проверяем ПОВЕДЕНИЕМ, а не наличием строчки: зеркало отдаёт несвежее на голый
# адрес и верное — на адрес с параметром.
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
HERE=$(cd "$(dirname "$0")/.." && pwd)

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

if command -v sha256sum >/dev/null 2>&1; then _sha() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then _sha() { shasum -a 256 "$1" | awk '{print $1}'; }
else printf '[SKIP] нечем считать sha256\n'; exit 0
fi

printf 'СВЕЖЕЕ содержимое релиза\n' > "$TMP/good"
printf 'ДО-РЕЛИЗНОЕ содержимое из кэша\n' > "$TMP/stale"
GOOD_SHA=$(_sha "$TMP/good")

# Берём НАСТОЯЩУЮ функцию из дерева, а не её пересказ.
eval "$(sed -n '/^au_download_repo_file() {/,/^}/p' "$HERE/lib/auto_update.sh")"

au_log() { printf 'LOG %s\n' "$*" >> "$TMP/log"; }
au_repo_base() { printf 'https://example.invalid/z2k/branch'; }
z2k_sha256_file() { _sha "$1"; }

# Модель зеркала: голый адрес отдаёт кэш, адрес с z2kcb — первоисточник.
# Ожидаемый sha уважаем так же, как настоящий z2k_fetch: чужие байты = отказ.
Z2K_STALE_ALSO=0
z2k_fetch() {
    _u="$1"; _o="$2"
    case "$_u" in
        *z2kcb=*) [ "$Z2K_STALE_ALSO" = "1" ] && cp "$TMP/stale" "$_o" || cp "$TMP/good" "$_o" ;;
        *)        cp "$TMP/stale" "$_o" ;;
    esac
    if [ -n "$Z2K_FETCH_SHA256" ] && [ "$(_sha "$_o")" != "$Z2K_FETCH_SHA256" ]; then
        rm -f "$_o"; return 1
    fi
    return 0
}

# --- 1. несвежее зеркало не должно ронять обновление --------------------------
rc=0
au_download_repo_file "files/S99zapret2.new" "$TMP/out" "$GOOD_SHA" || rc=$?
if [ "$rc" = "0" ]; then ok "несвежее зеркало не роняет доставку"
else no "несвежее зеркало не роняет доставку" "0" "$rc"; fi
if [ -f "$TMP/out" ] && [ "$(_sha "$TMP/out")" = "$GOOD_SHA" ]; then
    ok "доставлены байты релиза, а не кэша"
else
    no "доставлены байты релиза, а не кэша" "$GOOD_SHA" "$( [ -f "$TMP/out" ] && _sha "$TMP/out" || echo нет-файла)"
fi
if grep -q 'мимо кэша' "$TMP/log" 2>/dev/null; then
    ok "перезапрос мимо кэша виден в журнале"
else
    no "перезапрос мимо кэша виден в журнале" "строка есть" "тишина"
fi

# --- 2. и при этом чужие байты по-прежнему не принимаются ---------------------
# Если несвежее отдаёт и первоисточник — это не «ну и ладно», это отказ.
rm -f "$TMP/out" "$TMP/log"
Z2K_STALE_ALSO=1
rc=0
au_download_repo_file "files/S99zapret2.new" "$TMP/out" "$GOOD_SHA" || rc=$?
if [ "$rc" != "0" ]; then ok "если несвежее везде — отказ, а не тихая раскладка"
else no "если несвежее везде — отказ" "не 0" "0"; fi
if [ ! -f "$TMP/out" ] || [ "$(_sha "$TMP/out")" != "$(_sha "$TMP/stale")" ]; then
    ok "чужие байты не остаются на диске"
else
    no "чужие байты не остаются на диске" "файла нет" "лежит кэш"
fi

# --- 3. без эталона лишних кругов не делаем -----------------------------------
# Перезапрос доказывает что-то только против известного sha. Без него это просто
# лишний обход зеркал, а на этих коробках он не бесплатный.
rm -f "$TMP/out" "$TMP/log"
Z2K_STALE_ALSO=0
au_download_repo_file "files/S99zapret2.new" "$TMP/out" >/dev/null 2>&1
if ! grep -q 'мимо кэша' "$TMP/log" 2>/dev/null; then
    ok "без ожидаемого sha перезапрос не делается"
else
    no "без ожидаемого sha перезапрос не делается" "тишина" "полез мимо кэша"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
