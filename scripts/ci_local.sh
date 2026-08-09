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
step "дайджест-гейт (files_sha256 в UPDATES.json)"
if git diff --quiet -- UPDATES.json webpanel/www/index.html 2>/dev/null; then
    if sh scripts/gen_file_hashes.sh >/dev/null 2>&1 && git diff --quiet -- UPDATES.json; then
        passed "files_sha256 синхронен с деревом"
    else
        printf 'files_sha256 отстал от дерева. Перегенерированная карта уже в UPDATES.json —\n'
        printf 'посмотри diff и закоммить (или git checkout -- UPDATES.json webpanel/www/index.html).\n'
        failed "files_sha256"
    fi
else
    # Прогон поверх незакоммиченного UPDATES.json затёр бы рабочие правки.
    skipped "files_sha256" "UPDATES.json/index.html изменены в рабочем дереве — гейт отработает в CI"
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
    for m in mtproxy-client rt-proxy vps-relay z2k-detect; do
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
        case "$m" in
            z2k-detect) tst='$GO_TEST test -count=1 ./...' ;;
            *)          tst='$GO_TEST test -count=1 ./...' ;;
        esac
        if (cd "$m" && eval "$tst"); then passed "$m test"; else failed "$m test"; fi
        # Те же цели, что в ci.yml (списки исторические, менять синхронно).
        case "$m" in
            mtproxy-client) targets="linux/arm64 linux/arm linux/amd64 linux/mips linux/mipsle linux/mips64le linux/ppc64 linux/riscv64 linux/386"; pkg="." ;;
            rt-proxy)       targets="linux/arm64 linux/arm linux/amd64 linux/mips linux/mipsle"; pkg="." ;;
            z2k-detect)     targets="linux/arm64 linux/mipsle linux/mips64le"; pkg="./cmd/z2k-detect" ;;
            vps-relay)      targets="linux/amd64"; pkg="./..." ;;
        esac
        xrc=0
        for t in $targets; do
            goos=${t%%/*}; goarch=${t##*/}; extra=""
            case "$m/$goarch" in
                mtproxy-client/arm) extra="GOARM=5" ;;
                rt-proxy/arm)       extra="GOARM=7" ;;
                */mips|*/mipsle)    extra="GOMIPS=softfloat" ;;
                */mips64le)         extra="GOMIPS64=softfloat" ;;
            esac
            if ! (cd "$m" && env CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" $extra \
                    "$GO" build -trimpath -ldflags="-s -w" -o /dev/null "$pkg"); then
                printf 'сломана сборка %s/%s\n' "$goos" "$goarch"; xrc=1
            fi
        done
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
