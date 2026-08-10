#!/bin/sh
# scripts/ci_local.sh — весь CI одной командой, ДО push.
#
# push в z2k-enhanced — это деплой: CI на GitHub прогоняется уже ПОСЛЕ того,
# как файлы стали доступны роутерам. Единственное место, где красный тест
# успевает остановить релиз, — локальная машина. Этот скрипт зеркалит джобы
# .github/workflows/ci.yml (shellcheck, dash-синтаксис, дайджест-гейт,
# тест-сьют, luacheck, go-модули, мутационное тестирование) так, чтобы
# «прогнать полный CI локально» не требовало помнить семь команд.
#
# Отличия от CI — только вынужденные, и каждое объявляется вслух в выводе:
#   - версии shellcheck/luacheck локально другие (CI-раннер остаётся судьёй);
#   - go test идёт без -race и НЕ прод-тулчейном: тестовые бинарники старых
#     тулчейнов не запускаются на свежем macOS (dyld: missing LC_UUID) — это
#     несовместимость тулчейна с ОС, не код. Тесты гоняются новейшим
#     доступным go; vet и все сборки остаются на прод-1.25.12. В CI (linux)
#     всё, включая -race, идёт на 1.25.12;
#   - дайджест-гейт пропускается, если UPDATES.json/index.html уже изменены
#     в рабочем дереве: gen_file_hashes.sh правит их на месте, и прогон
#     поверх незакоммиченной работы затёр бы её.
#
# Инструмент не найден → шаг ПРОПУСКАЕТСЯ С ПРЕДУПРЕЖДЕНИЕМ, а не падает:
# как в tests/run_all.sh. Пропуск ≠ зелёный, список пропусков в итоге.
#
# Выход: 0 = всё прогнанное зелёное. Не 0 = есть красное, push делать нельзя.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

FAILED=""
SKIPPED=""

step()   { printf '\n━━━ %s ━━━\n' "$1"; }
passed() { printf '[OK]   %s\n' "$1"; }
failed() { printf '[FAIL] %s\n' "$1"; FAILED="$FAILED|$1"; }
skipped() { printf '[SKIP] %s — %s\n' "$1" "$2"; SKIPPED="$SKIPPED|$1"; }

# --- Тулчейн Go: прод собирается СТРОГО go1.25.12. Не 1.26.x — там golang/go#77730
# (рантайм неверно распознаёт отсутствие futex_time64 на MIPS), не 1.22.12 — она
# снята с поддержки. Валидировать другим тулчейном можно, но об этом надо знать.
if [ -x "$HOME/go/bin/go1.25.12" ]; then
    GO="$HOME/go/bin/go1.25.12"
elif command -v go >/dev/null 2>&1; then
    GO=go
    printf 'ВНИМАНИЕ: go1.25.12 не найден, использую %s — прод собирается 1.25.12\n' "$(go version)"
else
    GO=""
fi

# Каким go ЗАПУСКАТЬ тестовые бинарники (см. шапку про dyld на macOS).
GO_TEST="$GO"
if [ "$(uname)" = "Darwin" ] && command -v go >/dev/null 2>&1; then
    GO_TEST=go
fi

# ---------------------------------------------------------------------------
step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --version | sed -n 's/^version:/  локальный shellcheck /p'
    printf '  (версии кодов расходятся между релизами — судья всё равно CI-раннер)\n'
    # Тот же набор файлов и исключений, что в ci.yml — маски менять ТОЛЬКО
    # синхронно с ним.
    if { find . -name '*.sh' \( -path './z2k.sh' -o -path './z2k_cleanup.sh' -o -path './lib/*.sh' -o -path './files/*.sh' -o -path './tests/*.sh' -o -path './scripts/*.sh' -o -path './webpanel/cgi/*.sh' \); \
         find ./files/init.d -type f -name 'S*'; \
         find ./files -maxdepth 1 -type f -name 'S*'; } \
         | xargs shellcheck --severity=warning --exclude=SC1007,SC1090,SC1091,SC3043,SC3040,SC2034,SC2148,SC2154; then
        passed "shellcheck"
    else
        failed "shellcheck"
    fi
else
    skipped "shellcheck" "не установлен (brew install shellcheck)"
fi

# ---------------------------------------------------------------------------
step "синтаксис шелла (dash -n, прокси BusyBox ash)"
if command -v dash >/dev/null 2>&1; then
    rc=0
    # heredoc, а не `for f in $(find ...)`: цикл остаётся в текущем шелле
    # (rc не теряется в subshell), и старые shellcheck не ворчат SC2044.
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if ! dash -n "$f" 2>/tmp/z2k_synerr.$$; then
            printf 'SYNTAX ERROR in %s:\n' "$f"; cat /tmp/z2k_synerr.$$; rc=1
        fi
    done <<Z2KFILES
$(find ./files ./lib ./webpanel/cgi -type f \( -name '*.sh' -o -name 'S*' \) 2>/dev/null)
./z2k.sh
./z2k_cleanup.sh
Z2KFILES
    rm -f /tmp/z2k_synerr.$$
    [ "$rc" -eq 0 ] && passed "dash -n" || failed "dash -n"
else
    skipped "dash -n" "dash не установлен"
fi

# ---------------------------------------------------------------------------
step "манифест (не тронут между релизами / подписан на релизе)"
# Зеркалит гейт из ci.yml. Между релизами манифест не меняется вообще: карту и
# подпись пересобирает только release.sh. Разойдись эти два места — локальный
# прогон говорил бы «зелено» там, где CI краснеет, и наоборот.
# Ссылку освежаем сами и читаем ИМЕННО принесённое.
#
# Настоящий CI всегда видит актуальный z2k-enhanced, а локально remote-tracking
# ссылка свежа ровно настолько, насколько давно делали fetch — на устаревшей
# прогон уходит в ветку «это релизный коммит» и краснеет там, где всё в
# порядке (сразу двумя проверками: картой сумм и тест-сьютом). Красное по
# причине «давно не фетчил» хуже бесполезного: оно учит не верить прогону.
#
# Читаем FETCH_HEAD, а не refs/remotes/origin/...: `git fetch origin <branch>`
# обновляет remote-tracking ссылку не во всякой конфигурации, а FETCH_HEAD
# пишется всегда. Best-effort: офлайн — откат на remote-tracking, что было.
if git fetch -q origin z2k-enhanced 2>/dev/null; then
    _pubref=FETCH_HEAD
else
    _pubref=origin/z2k-enhanced
fi
_pub=$(git show "$_pubref:UPDATES.json" 2>/dev/null \
       | sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
_cur=$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' UPDATES.json | head -1)
if [ -z "$_pub" ]; then
    skipped "манифест" "нет origin/z2k-enhanced — сверять не с чем (git fetch origin)"
elif [ "$_pub" = "$_cur" ]; then
    if git diff --quiet "$_pubref" HEAD -- UPDATES.json UPDATES.json.sig 2>/dev/null \
       && git diff --quiet -- UPDATES.json UPDATES.json.sig 2>/dev/null; then
        passed "манифест не тронут (рабочий коммит, current=$_cur)"
    else
        printf 'Манифест правлен вне релиза. Карту и подпись пересобирает только\n'
        printf 'scripts/release.sh — верните файлы: git checkout -- UPDATES.json UPDATES.json.sig\n'
        failed "манифест"
    fi
else
    _ok=1
    # ПРОВЕРКА НЕ ИМЕЕТ ПРАВА ПОРТИТЬ ТО, ЧТО ПРОВЕРЯЕТ.
    #
    # gen_file_hashes.sh переписывает UPDATES.json на месте, и раньше он
    # вызывался прямо так. Достаточно было иметь незакоммиченную правку
    # доставляемого файла на релизном коммите — и прогон, сообщив «files_sha256
    # не описывает дерево», сам вписывал в манифест новые суммы и оставлял его
    # изменённым. Дальше по цепочке ломалась подпись (она считалась от прежних
    # байт), и следующий же прогон краснел ещё и на ней — уже по своей вине.
    # Ровно та авария, о которой предупреждает шапка tests/test_release_tooling.sh.
    #
    # Снимок до, сверка после, безусловное восстановление.
    _snap=$(mktemp) || _snap=""
    if [ -n "$_snap" ]; then
        cp UPDATES.json "$_snap"
        if sh scripts/gen_file_hashes.sh >/dev/null 2>&1 && cmp -s UPDATES.json "$_snap"; then :; else
            printf 'files_sha256 не описывает дерево — пересоберите релиз.\n'; _ok=0
        fi
        cp "$_snap" UPDATES.json
        rm -f "$_snap"
    else
        printf 'не создать временный файл — карту не сверить.\n'; _ok=0
    fi
    if [ -s UPDATES.json.sig ] && command -v openssl >/dev/null 2>&1; then
        _o=$(for c in /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
                 command -v "$c" >/dev/null 2>&1 || continue
                 "$c" pkeyutl -help 2>&1 | grep -q -- '-rawin' && { printf '%s' "$c"; break; }
             done)
        if [ -n "$_o" ]; then
            "$_o" pkeyutl -verify -rawin -pubin -inkey files/etc/z2k-update-pub.pem \
                -in UPDATES.json -sigfile UPDATES.json.sig >/dev/null 2>&1 \
                || { printf 'Подпись манифеста не сходится с опубликованным ключом.\n'; _ok=0; }
        fi
    else
        printf 'Релиз без подписи — его отвергнет каждый роутер с защёлкнутым храповиком.\n'; _ok=0
    fi
    if [ "$_ok" = "1" ]; then
        passed "релизный коммит: карта описывает дерево, подпись сходится ($_pub -> $_cur)"
    else
        failed "манифест"
    fi
fi

# ---------------------------------------------------------------------------
step "тест-сьют (tests/run_all.sh)"
if sh tests/run_all.sh; then
    passed "тест-сьют"
else
    failed "тест-сьют"
fi

# ---------------------------------------------------------------------------
step "luacheck"
if command -v luacheck >/dev/null 2>&1; then
    if luacheck files/lua/*.lua --codes -q; then
        passed "luacheck"
    else
        # ВАЖНО: luacheck выходит с кодом 1 и на warnings — в CI это красный.
        failed "luacheck"
    fi
else
    skipped "luacheck" "не установлен (brew install luacheck)"
fi

LUA_BIN=""
for c in lua5.3 lua5.4 lua; do
    if command -v "$c" >/dev/null 2>&1; then LUA_BIN=$c; break; fi
done
if [ -n "$LUA_BIN" ]; then
    if "$LUA_BIN" tests/test_http_classifier.lua; then
        passed "lua unit tests ($LUA_BIN)"
    else
        failed "lua unit tests ($LUA_BIN)"
    fi
else
    skipped "lua unit tests" "lua не установлен"
fi

# ---------------------------------------------------------------------------
step "go-модули (gofmt, vet, test, кросс-компиляция)"
if [ -n "$GO" ]; then
    # Модули и цели — ИЗ build-matrix.tsv, единственного источника правды (см.
    # шапку самого файла). Раньше список модулей и целей для каждого был
    # продублирован здесь руками и разошёлся с ci.yml в двух местах разом:
    # z2k-verify не проверялся ЛОКАЛЬНО НИ РАЗУ с момента появления (цикл
    # `for m in mtproxy-client rt-proxy vps-relay z2k-detect` о нём не знал),
    # а arm-цели mtproxy-client/rt-proxy держали свой GOARM отдельной case-веткой,
    # которая могла разойтись с Makefile'ами ровно так же, как уже расходилась
    # в CI (см. комментарий build-matrix.tsv про GOARM=5 vs GOARM=7).
    _modules=$(awk -F'\t' '!/^#/ && NF>1 {print $1}' build-matrix.tsv | sort -u)
    for m in $_modules; do
        printf -- '--- %s ---\n' "$m"
        unfmt=$(cd "$m" && gofmt -l .)
        if [ -n "$unfmt" ]; then
            printf 'не отформатировано gofmt:\n%s\n' "$unfmt"
            failed "$m gofmt"
        else
            passed "$m gofmt"
        fi
        if (cd "$m" && "$GO" vet ./...); then passed "$m vet"; else failed "$m vet"; fi
        # Без -race и тулчейном GO_TEST: см. шапку. В CI (linux) race включён.
        if (cd "$m" && "$GO_TEST" test -count=1 ./...); then passed "$m test"; else failed "$m test"; fi

        xrc=0
        while IFS="$(printf '\t')" read -r mod pkg bdir prefix goarch sfx extra; do
            case "$mod" in ''|\#*) continue ;; esac
            [ "$mod" = "$m" ] || continue
            [ "$extra" = "-" ] && extra=""
            # shellcheck disable=SC2086 # $extra — набор присваиваний окружения
            if ! (cd "$m" && env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" $extra \
                    "$GO" build -trimpath -ldflags="-s -w" -o /dev/null "$pkg"); then
                printf 'сломана сборка linux/%s%s\n' "$goarch" "${extra:+ ($extra)}"; xrc=1
            fi
        done < build-matrix.tsv
        [ "$xrc" -eq 0 ] && passed "$m кросс-компиляция" || failed "$m кросс-компиляция"
    done
else
    skipped "go-модули" "go не установлен"
fi

# ---------------------------------------------------------------------------
step "мутационное тестирование"
if [ -n "$GO" ]; then
    if GO="$GO" sh tests/mutation.sh; then
        passed "мутанты"
    else
        failed "мутанты"
    fi
else
    skipped "мутанты" "go не установлен"
fi

# ---------------------------------------------------------------------------
step "actionlint (workflows)"
# SHELLCHECK_OPTS обязателен и здесь: actionlint без него гоняет встроенный
# ShellCheck на info-уровне (см. тот же комментарий в ci.yml, job
# "Workflow lint"), и без этой переменной локальный прогон красный там, где
# реальный CI зелёный — то самое расхождение "локально строже, чем судья",
# которое эта же переменная там и лечит. Найдено на практике: SC2094 (info)
# на двух местах в jsdelivr-purge.yml завалил ci_local.sh, хотя реальный CI
# эти же строки принял бы молча.
export SHELLCHECK_OPTS="--severity=warning"
if command -v actionlint >/dev/null 2>&1; then
    if actionlint; then passed "actionlint"; else failed "actionlint"; fi
elif [ -x "$HOME/go/bin/actionlint" ]; then
    if "$HOME/go/bin/actionlint"; then passed "actionlint"; else failed "actionlint"; fi
else
    skipped "actionlint" "не установлен (go install github.com/rhysd/actionlint/cmd/actionlint@latest)"
fi

# ---------------------------------------------------------------------------
printf '\n━━━ ИТОГ ━━━\n'
if [ -n "$SKIPPED" ]; then
    printf 'Пропущено (не зелёное, а непроверенное):%s\n' "$(printf '%s' "$SKIPPED" | tr '|' '\n  ')"
fi
if [ -n "$FAILED" ]; then
    printf 'КРАСНОЕ:%s\n' "$(printf '%s' "$FAILED" | tr '|' '\n  ')"
    printf '\nPush с этим делать нельзя.\n'
    exit 1
fi
printf 'Всё прогнанное — зелёное.\n'
exit 0
