#!/bin/sh
# tests/test_state_rerun_after_reinstall.sh — переустановка не повторяет
# перенумерацию пулов, и у тех, у кого повтор уже случился, стратегии
# возвращаются из снимка.
#
# Дефект (08.11.2026): переустановка переносила state.tsv, но не отметки
# state/*.done. На первом старте init прогонял миграции v1..v3 ещё раз:
# автоматические записи стирались, замороженные уезжали на чужие плечи.
# Исполняются настоящие куски lib/install.sh и функции files/S99zapret2.new.
# POSIX sh (busybox ash).

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
INST="$ROOT/lib/install.sh"
INIT="$ROOT/files/S99zapret2.new"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

. "$ROOT/tests/lib/common.sh"

TMP="${TMPDIR:-/tmp}/z2k-rerun.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Кусок установщика от строки-метки до первого «fi» на том же отступе.
frag() {
    awk -v mark="$1" '
        index($0, mark) { grab = 1 }
        grab && !ind && /^[[:space:]]*if / { match($0, /^[[:space:]]*/); ind = RLENGTH }
        grab { print }
        grab && ind && /^[[:space:]]*fi[[:space:]]*$/ { match($0, /^[[:space:]]*/); if (RLENGTH == ind) exit }
    ' "$INST"
}
frag '# Отметки выполненных миграций (state/*.done) едут ВМЕСТЕ' > "$TMP/backup.sh"
frag '# Отметки миграций — при любом исходе выше' > "$TMP/restore.sh"
if grep -q 'state-done' "$TMP/backup.sh" && grep -q 'state-done' "$TMP/restore.sh"; then
    ok "бэкап и возврат отметок найдены в install.sh"
else
    bad "в install.sh нет переноса отметок"
fi

# Функции init: миграции и возврат.
for fn in _z2k_migrate_quic_pool_key _z2k_migrate_pool_renumber \
          _z2k_migrate_pool_renumber_v1 _z2k_migrate_pool_renumber_v2 \
          _z2k_migrate_pool_renumber_v3 _z2k_migrate_pool_renumber_v5 \
          _z2k_restore_state_after_rerun_v1; do
    awk "/^$fn\\(\\)/{p=1} p{print} p&&/^}/{exit}" "$INIT"
done > "$TMP/init.sh"
grep -q '^_z2k_restore_state_after_rerun_v1()' "$TMP/init.sh" \
    && ok "в init есть возврат после повтора" || bad "в init нет _z2k_restore_state_after_rerun_v1"
grep -q '^[[:space:]]*_z2k_restore_state_after_rerun_v1$' "$INIT" \
    && ok "возврат вызывается при старте" || bad "возврат не вызывается"

T=$(printf '\t')
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
STATE_SAMPLE() {
    echo "# z2k autocircular state"
    row rkn_tcp "fbcdn.net|4" 3 1794000001 auto
    row rkn_tcp "rutracker.org|4" 12 1794000002 frozen
    row google_tls "googlevideo.com|4" 45 1794000003 auto
    row quic "googlevideo.com|4" 5 1794000004 auto
}
migrate() { # $1 - корень
    ( . "$TMP/init.sh"
      ZAPRET_BASE="$1"; EXTRA_STRATS_DIR="$1/extra_strats"; Z2K_STATE_FALLBACK="$1/none.tsv"
      _z2k_migrate_quic_pool_key; _z2k_migrate_pool_renumber_v1; _z2k_migrate_pool_renumber_v2
      _z2k_migrate_pool_renumber_v3; _z2k_migrate_pool_renumber_v5 ) >/dev/null 2>&1
}
restore_rr() { # $1 - корень
    ( . "$TMP/init.sh"
      ZAPRET_BASE="$1"; EXTRA_STRATS_DIR="$1/extra_strats"
      _z2k_restore_state_after_rerun_v1 ) 2>&1
}

# --- 1. Переустановка: отметки едут, миграции не повторяются -------------------
OLD="$TMP/old"; NEW="$TMP/new"; BK="$TMP/bk"
mkdir -p "$OLD/extra_strats/cache/autocircular" "$OLD/state" "$NEW" "$BK"
STATE_SAMPLE > "$OLD/extra_strats/cache/autocircular/state.tsv"
for v in quic-pool-key pool-renumber-v1 pool-renumber-v2 pool-renumber-v3 pool-renumber-v5; do
    : > "$OLD/state/$v.done"
done
( ZAPRET2_DIR="$OLD"; backup_tmp="$BK"; . "$TMP/backup.sh" ) >/dev/null 2>&1
mkdir -p "$NEW/extra_strats/cache/autocircular"
cp "$OLD/extra_strats/cache/autocircular/state.tsv" "$NEW/extra_strats/cache/autocircular/state.tsv"
( ZAPRET2_DIR="$NEW"; backup_tmp="$BK"; . "$TMP/restore.sh" ) >/dev/null 2>&1
N=$(ls "$NEW/state/"*.done 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 5 ] && ok "все отметки миграций пережили переустановку" || bad "отметок после переустановки: $N из 5"
migrate "$NEW"
if cmp -s "$OLD/extra_strats/cache/autocircular/state.tsv" "$NEW/extra_strats/cache/autocircular/state.tsv"; then
    ok "после переустановки миграции state.tsv не трогают"
else
    bad "миграции переписали state.tsv: $(tr '\t' ' ' < "$NEW/extra_strats/cache/autocircular/state.tsv" | tr '\n' '|')"
fi

# Без переноса (как было) — повтор стирает записи: проверка, что тест видит дефект.
BUG="$TMP/bug"; mkdir -p "$BUG/extra_strats/cache/autocircular"
STATE_SAMPLE > "$BUG/extra_strats/cache/autocircular/state.tsv"
migrate "$BUG"
grep -q "fbcdn.net" "$BUG/extra_strats/cache/autocircular/state.tsv" \
    && bad "без отметок повтор не стёр запись — тест не воспроизводит дефект" \
    || ok "без отметок повтор стирает записи (дефект воспроизводится)"

# --- 2. Возврат у пострадавших ---------------------------------------------------
# Повтор уже был: снимок v1 рядом, отметка v1 свежая. После повтора человек
# заморозил fbcdn.net заново (новое время записи), хост vk.com подобран с нуля.
VIC="$TMP/vic"; AC="$VIC/extra_strats/cache/autocircular"
mkdir -p "$AC"
STATE_SAMPLE > "$AC/state.tsv"
migrate "$VIC"
[ -f "$AC/state.tsv.pre-renumber-v1" ] && ok "повтор оставил снимок v1" || bad "снимка v1 нет"
row rkn_tcp "vk.com|4" 2 1794100000 auto >> "$AC/state.tsv"
row rkn_tcp "fbcdn.net|4" 3 1794100001 frozen >> "$AC/state.tsv"
OUT=$(restore_rr "$VIC")
S=$(cat "$AC/state.tsv")
has_row() { printf '%s\n' "$S" | grep -q "^$1$T$2$T$3$T"; }
has_row rkn_tcp "rutracker.org|4" 12 && ok "замороженная запись вернулась на своё плечо (12)" \
    || bad "rutracker.org не вернулся на 12: $(printf '%s' "$S" | grep rutracker | tr '\t' ' ')"
has_row google_tls "googlevideo.com|4" 45 && ok "стёртая автоматическая запись вернулась" \
    || bad "googlevideo.com не вернулся"
has_row quic "googlevideo.com|4" 5 && ok "запись QUIC вернулась без сдвига" || bad "quic не вернулся на 5"
has_row rkn_tcp "fbcdn.net|4" 3 && [ "$(printf '%s\n' "$S" | grep -c "fbcdn.net")" = 1 ] \
    && printf '%s\n' "$S" | grep "fbcdn.net" | grep -q frozen \
    && ok "заморозка, поставленная человеком после повтора, осталась" || bad "fbcdn.net испорчен: $(printf '%s' "$S" | grep fbcdn | tr '\t' ' ')"
has_row rkn_tcp "vk.com|4" 2 && ok "подобранное заново осталось" || bad "vk.com пропал"
[ -f "$VIC/state/rerun-restore-v1.done" ] && ok "возврат отмечен выполненным" || bad "нет отметки возврата"
case "$OUT" in *"restored"*) ok "возврат пишет строку в журнал" ;; *) bad "возврат молчит: $OUT" ;; esac
BEFORE=$(cat "$AC/state.tsv"); restore_rr "$VIC" >/dev/null
[ "$BEFORE" = "$(cat "$AC/state.tsv")" ] && ok "второй старт ничего не трогает" || bad "второй старт изменил state.tsv"

# Старая отметка v1 (законный прогон в октябре) — снимок не трогаем.
OLDV="$TMP/oldv"; AC2="$OLDV/extra_strats/cache/autocircular"
mkdir -p "$AC2"; STATE_SAMPLE > "$AC2/state.tsv"; migrate "$OLDV"
if z2k_backdate "$OLDV/state/pool-renumber-v1.done" 202610270300; then
    BEFORE=$(cat "$AC2/state.tsv"); restore_rr "$OLDV" >/dev/null
    [ "$BEFORE" = "$(cat "$AC2/state.tsv")" ] && ok "законная октябрьская миграция не откатывается" \
        || bad "возврат сработал по старой отметке"
    [ -f "$OLDV/state/rerun-restore-v1.done" ] && ok "и отметка всё равно ставится" || bad "нет отметки при старой миграции"
else
    printf '[SKIP] старую метку времени здесь поставить нечем (busybox touch)\n'
fi

printf '\nИТОГ: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
