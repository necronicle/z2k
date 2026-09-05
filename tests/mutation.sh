#!/bin/sh
# tests/mutation.sh — mutation testing for the code paths that broke in the field.
#
# A green test suite proves nothing on its own: it may be asserting on stubs, or guarding
# behaviour nobody depends on. This harness answers the only question that matters —
# "if someone silently breaks this guard, does a test go red?"
#
# Each MUTANT below is a real regression we either shipped or nearly shipped. The harness
# applies it to a scratch copy, runs the suite, and requires the suite to FAIL. A mutant that
# SURVIVES is a hole: the code is unprotected there, whatever the coverage number says.
#
# Usage: sh tests/mutation.sh          (exit 0 = every mutant was killed)

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO="${GO:-$HOME/go/bin/go1.25.12}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KILLED=0
SURVIVED=0
STALE=0
SURVIVORS=""
STALES=""

pass() { printf '  [KILLED]   %s\n' "$1"; KILLED=$((KILLED + 1)); }
fail() { printf '  [SURVIVED] %s\n' "$1"; SURVIVED=$((SURVIVED + 1)); SURVIVORS="$SURVIVORS\n    - $1"; }

# Протухший мутант — это НЕ убитый мутант.
#
# Якорь (строка, которую мутант портит) уезжает при обычном рефакторинге. Раньше
# такой случай печатался как [SKIP] и не попадал никуда: ни в KILLED, ни в
# SURVIVED. Счёт при этом честно показывал «18 killed, 0 survived», хотя часть
# мутантов не запускалась вовсе — то есть проверка молча исчезала ровно тогда,
# когда её код правили, а это единственный момент, когда она нужна.
#
# Теперь протухшие считаются отдельно и роняют прогон: чинится это правкой
# якоря на одну строку, а цена необнаружения — вся защита соответствующего
# поведения.
stale() { printf '  [STALE]    %s\n' "$1"; STALE=$((STALE + 1)); STALES="$STALES\n    - $1"; }

# МУТАНТЫ ГОНЯЮТСЯ ПАРАЛЛЕЛЬНО.
#
# Каждый мутант и так работает на СВОЕЙ копии кода — репозиторий не портится, —
# поэтому мешать друг другу им нечем; мешал только общий каталог $WORK/<вид>.
# Замер 05.09.2026: 18 мутантов по очереди стоили 193 c, то есть 44 % всего CI
# после того, как остальные стадии распараллелили.
#
# Вердикт пишется в файл, а не в счётчик: подоболочка не может увеличить KILLED
# у родителя. Родитель печатает вердикты в исходном порядке, поэтому вывод
# совпадает с последовательным прогоном строка в строку.
#
# СТРАХОВКА ОТ ПОТЕРИ. Мутант, который не запустился, — худший исход: счёт
# покажет «все убиты», а защиты не будет. Поэтому каждый запуск учитывается, и
# отсутствие вердикта считается выжившим, а не пропускается молча.
MUT_SEQ=0
BATCH=""
VERD="$WORK/verdicts"; mkdir -p "$VERD"

_mut_start() { MUT_SEQ=$((MUT_SEQ + 1)); BATCH="$BATCH $MUT_SEQ"; }

_drain() {
    wait
    for _d_id in $BATCH; do
        if [ ! -f "$VERD/$_d_id" ]; then
            printf '  [ПОТЕРЯН]  мутант #%s не оставил вердикта\n' "$_d_id"
            SURVIVED=$((SURVIVED + 1))
            SURVIVORS="$SURVIVORS\n    - мутант #$_d_id не отработал"
            continue
        fi
        _d_verd=$(cut -f1 "$VERD/$_d_id")
        _d_desc=$(cut -f2- "$VERD/$_d_id")
        case "$_d_verd" in
            pass)  pass  "$_d_desc" ;;
            fail)  fail  "$_d_desc" ;;
            stale) stale "$_d_desc" ;;
        esac
    done
    BATCH=""
}

# ---------------------------------------------------------------------------
# Go mutants — rt-proxy/main.go
# ---------------------------------------------------------------------------
go_mutant() {
    desc="$1"; from="$2"; to="$3"
    _mut_start; _id="$MUT_SEQ"; _dir="$WORK/go.$_id"
    (
        mkdir -p "$_dir"
        cp "$ROOT/rt-proxy/"*.go "$ROOT/rt-proxy/go.mod" "$_dir/"
        if ! grep -qF "$from" "$_dir/main.go"; then
            printf 'stale\t%s (якорь не найден — мутант протух)\n' "$desc" > "$VERD/$_id"
            exit 0
        fi
        python3 - "$_dir/main.go" "$from" "$to" <<'PY'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
open(path, 'w', encoding='utf-8').write(s.replace(frm, to, 1))
PY
        if (cd "$_dir" && CGO_ENABLED=0 "$GO" test -count=1 ./... >/dev/null 2>&1); then
            printf 'fail\tgo: %s\n' "$desc" > "$VERD/$_id"
        else
            printf 'pass\tgo: %s\n' "$desc" > "$VERD/$_id"
        fi
    ) &
}

printf '\n=== Go mutants (rt-proxy) ===\n'

# The regression that hung RuTracker on a fresh browser start: accept after ONE record.
go_mutant "second-record requirement removed (accept after just the ServerHello)" \
    'hdr2, err := br.Peek(off + 5)' \
    'hdr2, err := br.Peek(off); _ = hdr2; if false {} ; hdr2, err = make([]byte, off+5), error(nil); if err != nil {} ; hdr2, err = br.Peek(off), error(nil)'

# Accepting any record type after the ServerHello lets a proxy answering for ITSELF through.
go_mutant "second-record type check removed" \
    'case 0x14, 0x16, 0x17: // ChangeCipherSpec, handshake, application_data — a flight continuing' \
    'case 0x14, 0x16, 0x17, 0x15, 0x00:'

# A resumed handshake is ~137 bytes; a byte-count gate demotes every healthy node. Guard it.
go_mutant "second record not required to be complete" \
    'if _, err := br.Peek(off + 5 + n2); err != nil {' \
    'if _, err := br.Peek(0); err != nil {'

# Weakening the record-type check lets a proxy answering for itself pass as a relayed site.
go_mutant "handshake record-type check inverted" \
    'if hdr[0] != 0x16 {' \
    'if hdr[0] == 0x16 {'

# Removing the length sanity check re-opens absurd allocations / desynced streams.
go_mutant "record-length sanity check removed" \
    'if n <= 0 || n > 16384 {' \
    'if n < 0 {'

# demote() is what stops a proven-dead node being handed to the very next client.
go_mutant "demote() made a no-op" \
    'func (p *pool) demote(ip string) {' \
    'func (p *pool) demote(ip string) { if true { return };'

# A pool that hands out the same node defeats the whole retry design.
go_mutant "pick() pinned to the first node" \
    'return p.live[p.rr%uint64(len(p.live))]' \
    'return p.live[0]'

# The probe must pull real body bytes; dropping that is how stalling nodes got back in.
go_mutant "probe body-byte requirement removed" \
    'if n, err := io.CopyN(io.Discard, rd, int64(*probeBytes)); err != nil || n < int64(*probeBytes) {' \
    'if n, err := io.CopyN(io.Discard, rd, 0); err != nil && n < 0 {'

# ---------------------------------------------------------------------------
# Shell mutants — files/z2k-warp.sh against tests/test_warp_script.sh
# ---------------------------------------------------------------------------
sh_mutant() {
    desc="$1"; from="$2"; to="$3"
    _mut_start; _id="$MUT_SEQ"; _dir="$WORK/sh.$_id"
    (
        mkdir -p "$_dir/files" "$_dir/tests"
        cp "$ROOT/files/z2k-warp.sh" "$_dir/files/"
        cp "$ROOT/tests/test_warp_script.sh" "$_dir/tests/"
        if ! grep -qF "$from" "$_dir/files/z2k-warp.sh"; then
            printf 'stale\t%s (якорь не найден — мутант протух)\n' "$desc" > "$VERD/$_id"
            exit 0
        fi
        python3 - "$_dir/files/z2k-warp.sh" "$from" "$to" <<'PY'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
open(path, 'w', encoding='utf-8').write(s.replace(frm, to, 1))
PY
        if sh "$_dir/tests/test_warp_script.sh" >/dev/null 2>&1; then
            printf 'fail\tsh: %s\n' "$desc" > "$VERD/$_id"
        else
            printf 'pass\tsh: %s\n' "$desc" > "$VERD/$_id"
        fi
    ) &
}

_drain

printf '\n=== Shell mutants (z2k-warp.sh) ===\n'

# Fail-open: мёртвый туннель обязан отпустить трафик напрямую, а не держать его в чёрной дыре.
sh_mutant "fail-open removed (dead tunnel keeps the route)" \
    '        warp_pbr_down            # fail open: напрямую лучше, чем в чёрную дыру' \
    '        warp_pbr_up'

# Маршрут — только на доказанно живой туннель.
sh_mutant "enable routes regardless of readiness" \
    '    if warp_ready; then
        warp_pbr_up' \
    '    if true; then
        warp_pbr_up'

# «Удалить» оставляет ключ устройства: иначе каждая переустановка — новое устройство у Cloudflare.
sh_mutant "remove burns the device key" \
    '    rm -f "$WARP_BIN" "$WARP_BIN".new.* 2>/dev/null' \
    '    rm -f "$WARP_BIN" "$WARP_BIN".new.* "$WARP_DEVICE" 2>/dev/null'

# Без движка флаг обязан откатиться, иначе панель врёт «включено».
sh_mutant "enable without engine leaves the flag on" \
    '    [ -x "$WARP_BIN" ] || { _wlog "движок не установлен — нажмите «Установить»"; warp_set_flag 0; return 1; }' \
    '    [ -x "$WARP_BIN" ] || { _wlog "движок не установлен — нажмите «Установить»"; return 1; }'

# --set-mark затирает mark-word Keenetic; форма с маской — не косметика.
sh_mutant "MARK regresses to --set-mark (clobbers the mark word)" \
    '            || iptables -w -t mangle -A PREROUTING -m set --match-set $set -j MARK --set-xmark "$WARP_MARK/$WARP_MARK" 2>/dev/null' \
    '            || iptables -w -t mangle -A PREROUTING -m set --match-set $set -j MARK --set-mark "$WARP_MARK" 2>/dev/null'

# Selfheal при выключенном режиме — no-op, иначе реген воскрешает выключенную функцию.
sh_mutant "selfheal runs with the mode off" \
    'warp_selfheal() {
    [ "$(warp_flag)" = "1" ] || return 0' \
    'warp_selfheal() {
    true'

# Установка — это бинарь и ключ, и только. Демон стартует по тумблеру.
sh_mutant "install starts the daemon" \
    '    if out=$("$WARP_BIN" register --device "$WARP_DEVICE" 2>&1); then
        _wlog "$out"; return 0' \
    '    if out=$("$WARP_BIN" register --device "$WARP_DEVICE" 2>&1); then
        _wlog "$out"; sh "$WARP_INIT" start >/dev/null 2>&1; return 0'

# ---------------------------------------------------------------------------
# Init-script mutants — files/init.d/S51z2k-warp against tests/test_warp_init_thin.sh
# ---------------------------------------------------------------------------
init_mutant() {
    desc="$1"; from="$2"; to="$3"
    _mut_start; _id="$MUT_SEQ"; _dir="$WORK/init.$_id"
    (
        mkdir -p "$_dir/files/init.d" "$_dir/tests"
        cp "$ROOT/files/init.d/S51z2k-warp" "$_dir/files/init.d/"
        cp "$ROOT/tests/test_warp_init_thin.sh" "$_dir/tests/"
        if ! grep -qF "$from" "$_dir/files/init.d/S51z2k-warp"; then
            printf 'stale\t%s (якорь не найден — мутант протух)\n' "$desc" > "$VERD/$_id"
            exit 0
        fi
        python3 - "$_dir/files/init.d/S51z2k-warp" "$from" "$to" <<'PY2'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
open(path, 'w', encoding='utf-8').write(s.replace(frm, to, 1))
PY2
        if sh "$_dir/tests/test_warp_init_thin.sh" >/dev/null 2>&1; then
            printf 'fail\tinit: %s\n' "$desc" > "$VERD/$_id"
        else
            printf 'pass\tinit: %s\n' "$desc" > "$VERD/$_id"
        fi
    ) &
}

_drain

printf '\n=== Init mutants (S51z2k-warp) ===\n'

# Без бинаря — штатно, exit 0; иначе Entware считает сервис сломанным на каждом буте.
init_mutant "missing engine reported as failure" \
    '[ -x "$BIN" ] || exit 0' \
    '[ -x "$BIN" ] || exit 1'

# Повторный start не плодит второй демон.
init_mutant "second start spawns a second daemon" \
    '        if running; then' \
    '        if false; then'

# MIPS без asyncpreemptoff — известный краш Go.
init_mutant "MIPS async-preempt guard removed" \
    'case "$(uname -m)" in mips*) export GODEBUG=asyncpreemptoff=1 ;; esac' \
    ':'

_drain

printf '\n=== mutation score: %d killed, %d survived, %d stale ===\n' "$KILLED" "$SURVIVED" "$STALE"
if [ "$SURVIVED" -ne 0 ]; then
    printf 'SURVIVING MUTANTS (unguarded behaviour):%b\n' "$SURVIVORS"
    exit 1
fi
if [ "$STALE" -ne 0 ]; then
    printf 'ПРОТУХШИЕ МУТАНТЫ (не запускались — поведение НЕ проверено):%b\n' "$STALES"
    printf 'Якорь уехал при правке кода. Обновите строку-якорь, иначе счёт врёт.\n'
    exit 1
fi
printf 'every mutant was killed by the suite\n'
