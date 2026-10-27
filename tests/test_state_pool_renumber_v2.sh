#!/bin/sh
# tests/test_state_pool_renumber_v2.sh
#
# 27.10.2026: в пул quic вторым плечом вставлен нулевой фейк с подменой Initial
# (замер на стенде: Cloudflare 24/25 и ответ с первого Initial, у прежних плеч
# Cloudflare ≤ 18/25), прежнее 18-е (фрагментация, только Cloudflare, Google 0)
# снято как перекрытое новым. state.tsv хранит НОМЕР плеча, поэтому init
# переносит номера до подъёма демона: 2…17 → 3…18, 18 стирается, 1 остаётся.
# Порядок остальных плеч не менялся, поэтому автоматические записи переносятся,
# а не стираются. Перенос v1 (26.10) при этом не трогается и идёт первым.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^_z2k_migrate_pool_renumber(_v[0-9]+)?\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/migrate.sh"
. "$TMP/migrate.sh"
ZAPRET_BASE=$TMP/base
Z2K_STATE_FALLBACK=$TMP/fallback.tsv
export ZAPRET_BASE Z2K_STATE_FALLBACK
mkdir -p "$ZAPRET_BASE/extra_strats/cache/autocircular"
STATE=$ZAPRET_BASE/extra_strats/cache/autocircular/state.tsv
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }
check() { # check <desc> <key> <host> <expected strategy or ABSENT>
    if [ "$4" = ABSENT ]; then
        if awk -F'\t' -v k="$2" -v h="$3" '$1==k && $2==h {f=1} END{exit f}' "$STATE"; then ok "$1"; else no "$1"; fi
    else
        if awk -F'\t' -v k="$2" -v h="$3" -v s="$4" '$1==k && $2==h && $3==s {f=1} END{exit !f}' "$STATE"; then ok "$1"; else no "$1"; fi
    fi
}
{
printf '# z2k autocircular state (persisted circular nstrategy)\n# key\thost\tstrategy\tts\tmode\tsni\n'
printf 'quic\tfirst.example|4\t1\t100\tfrozen\t\n'
printf 'quic\tsecond.example|4\t2\t100\tfrozen\tsecond.example\n'
printf 'quic\tauto5.example|4\t5\t100\tauto\t\n'
printf 'quic\tlast17.example|4\t17\t100\tfrozen\t\n'
printf 'quic\tgone18.example|4\t18\t100\tauto\t\n'
printf 'quic\tgone18f.example|4\t18\t100\tfrozen\t\n'
printf 'rkn_tcp\tkeep18.example|4\t18\t100\tfrozen\t\n'
printf 'discord_udp\tnohost\t2\t100\tauto\t\n'
} > "$STATE"
cp "$STATE" "$TMP/original"
printf '# z2k autocircular state\nquic\tfb.example|4\t2\t100\tauto\t\n' > "$Z2K_STATE_FALLBACK"
# v1 уже прошёл на этом роутере (p-86.24): его отметка стоит, таблица v1 не применяется.
mkdir -p "$ZAPRET_BASE/state"; : > "$ZAPRET_BASE/state/pool-renumber-v1.done"

_z2k_migrate_pool_renumber_v1
_z2k_migrate_pool_renumber_v2
check "quic 1 stays 1"                        quic    'first.example|4'   1
check "quic frozen 2 -> 3"                    quic    'second.example|4'  3
check "quic auto 5 -> 6 (order kept, row kept)" quic  'auto5.example|4'   6
check "quic 17 -> 18"                         quic    'last17.example|4'  18
check "quic auto 18 erased (arm removed)"     quic    'gone18.example|4'  ABSENT
check "quic frozen 18 erased (arm removed)"   quic    'gone18f.example|4' ABSENT
check "rkn_tcp untouched"                     rkn_tcp 'keep18.example|4'  18
check "discord voice untouched"               discord_udp nohost          2
if awk -F'\t' '$2=="second.example|4" && $5=="frozen" && $6=="second.example" {f=1} END{exit !f}' "$STATE"; then ok "frozen mode and sni preserved"; else no "frozen mode and sni preserved"; fi
if awk -F'\t' '$2=="fb.example|4" && $3==3 {f=1} END{exit !f}' "$Z2K_STATE_FALLBACK"; then ok "fallback file migrated too"; else no "fallback file migrated too"; fi
if cmp -s "$TMP/original" "$STATE.pre-renumber-v2"; then ok "pre-migration snapshot kept"; else no "pre-migration snapshot kept"; fi
if [ -f "$ZAPRET_BASE/state/pool-renumber-v2.done" ]; then ok "v2 done marker written"; else no "v2 done marker written"; fi
cp "$STATE" "$TMP/once"
_z2k_migrate_pool_renumber_v2
if cmp -s "$TMP/once" "$STATE"; then ok "idempotent under marker"; else no "idempotent under marker"; fi

# Свежий роутер с p-86.23: v1 ещё не прошёл — сначала v1, потом v2, итог один и тот же.
rm -rf "$ZAPRET_BASE/state" "$STATE".* "$Z2K_STATE_FALLBACK".*
printf '# z2k autocircular state\nquic\told7.example|4\t7\t100\tfrozen\t\n' > "$STATE"
: > "$Z2K_STATE_FALLBACK"
_z2k_migrate_pool_renumber_v1
_z2k_migrate_pool_renumber_v2
check "chain v1 then v2: old 7 -> 14 -> 15"   quic    'old7.example|4'    15

# Таблица обязана соответствовать пулу: 18 плеч, новое второе, прежнее первое.
ARGS=$(awk '/^\[quic_autocircular\]/{a=1;next} a && /^args=/{print;exit}' "$ROOT/quic_strats.ini")
quic_max=$(printf '%s' "$ARGS" | grep -o ':strategy=[0-9]*' | sed 's/.*=//' | sort -n | tail -1)
[ "$quic_max" = 18 ] && ok "quic pool has 18 arms" || no "quic pool has 18 arms (got $quic_max)"
case "$ARGS" in *"blob=quic_google:repeats=11:strategy=1 "*"send:payload=quic_initial:dir=out:strategy=1 "*) ok "arm 1 still google x11 + send + drop" ;; *) no "arm 1 still google x11 + send + drop" ;; esac
case "$ARGS" in *"blob=0x00:repeats=11:strategy=2 --lua-desync=send:payload=quic_initial:dir=out:strategy=2 --lua-desync=drop:payload=quic_initial:dir=out:strategy=2 "*) ok "arm 2 = zero fake x11 + send + drop" ;; *) no "arm 2 = zero fake x11 + send + drop" ;; esac
case "$ARGS" in *"ipfrag_pos_udp=8:out_range=-n3"*) no "old arm 18 (fragmentation) removed" ;; *) ok "old arm 18 (fragmentation) removed" ;; esac

printf 'PASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
