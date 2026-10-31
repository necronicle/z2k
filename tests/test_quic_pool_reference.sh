#!/bin/sh
# tests/test_quic_pool_reference.sh — пул quic = референсные QUIC-страты один в один.
#
# Пул собран из QUIC-страт референсного набора (UDP 443, включённые профили) без
# собственных вариаций. Записи nfqws1 переведены на nfqws2 и сверены на
# дифференциальном стенде побайтно: тот же Initial (одной и двумя датаграммами)
# даёт на проводе одинаковые пакеты у обоих движков.
#
# Три правила перевода, на которых держится совпадение:
#   * fake на UDP в nfqws1 после фейков сам переотправляет оригинал и роняет его
#     из очереди — в nfqws2 это fake + send + drop;
#   * --dpi-desync-cutoff=nN ограничивает ВСЕ действия плеча — out_range=-nN
#     стоит на каждом;
#   * send не проверяет payload= сам, поэтому плечи стоят под --payload=quic_initial:
#     под --payload=all send дублировал каждый короткий пакет потока (замер стенда).
#
# ЧТО ОХРАНЯЕТСЯ: состав и порядок плеч; одна копия пула (холодный старт
# генератора берёт аварийный пул, а не свой список плеч); аварийный пул — плечо
# набора на встроенном блобе.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INI="$HERE/quic_strats.ini"
GEN="$HERE/lib/config_official.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

HEAD='--in-range=a --out-range=a --payload=all --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=5:key=quic:nld=2 --payload=quic_initial'

# Плечо на строку: инстансы без хвоста :strategy=N.
EXPECTED=$(cat <<'ARMS'
fake:blob=quic_google:repeats=6 send:dir=out drop:dir=out
fake:blob=quic_google:repeats=11 send:dir=out drop:dir=out
fake:blob=quic6:repeats=2:out_range=-n3 udplen:increment=8:pattern=0x0F0F0E0F:out_range=-n3 send:dir=out:out_range=-n3 drop:dir=out:out_range=-n3
fake:blob=fake_default_quic:repeats=6 send:dir=out drop:dir=out
fake:blob=quic5:repeats=3:out_range=-n3 send:dir=out:ipfrag:ipfrag_pos_udp=8:out_range=-n3 drop:dir=out:out_range=-n3
fake:blob=quic4:repeats=2:out_range=-n3 udplen:increment=4:out_range=-n3 send:dir=out:out_range=-n3 drop:dir=out:out_range=-n3
fake:blob=quic4:repeats=2:out_range=-n4 udplen:increment=8:pattern=0xFEA82025:out_range=-n4 send:dir=out:out_range=-n4 drop:dir=out:out_range=-n4
fake:blob=quic5:repeats=2:out_range=-n3 udplen:increment=25:out_range=-n3 send:dir=out:out_range=-n3 drop:dir=out:out_range=-n3
fake:blob=quic1:repeats=6:out_range=-n3 send:dir=out:out_range=-n3 drop:dir=out:out_range=-n3
fake:blob=quic_google:repeats=8 send:dir=out drop:dir=out
ARMS
)

ARGS=$(awk '/^\[quic_autocircular\]/{a=1;next} a && /^args=/{sub(/^args=/,"");print;exit}' "$INI")

case "$ARGS" in
    "$HEAD "*) ok "шапка пула: circular, затем плечи под --payload=quic_initial" ;;
    *) no "шапка пула" "$HEAD" "$(printf '%s' "$ARGS" | cut -c1-160)" ;;
esac

# Разбор плеч: каждый --lua-desync=...:strategy=N уходит в строку N.
GOT=$(printf '%s\n' "$ARGS" | tr ' ' '\n' | awk '
    /^--lua-desync=/ && /:strategy=[0-9]+$/ {
        s = $0; sub(/^--lua-desync=/, "", s)
        n = s; sub(/.*:strategy=/, "", n); sub(/:strategy=[0-9]+$/, "", s)
        k = n + 0
        # Правая часть отдельно: BusyBox создаёт arm[k] из левой части раньше,
        # чем проверяет (k in arm).
        v = (k in arm) ? arm[k] " " s : s
        arm[k] = v
        if (k > max) max = k
    }
    END { for (i = 1; i <= max; i++) print arm[i] }')

eq "число плеч" "$(printf '%s\n' "$EXPECTED" | wc -l | tr -d ' ')" "$(printf '%s\n' "$GOT" | wc -l | tr -d ' ')"
i=0
printf '%s\n' "$EXPECTED" > "${TMPDIR:-/tmp}/quicref.want.$$"
printf '%s\n' "$GOT" > "${TMPDIR:-/tmp}/quicref.got.$$"
while IFS= read -r want; do
    i=$((i+1))
    got=$(sed -n "${i}p" "${TMPDIR:-/tmp}/quicref.got.$$")
    eq "плечо $i" "$want" "$got"
done < "${TMPDIR:-/tmp}/quicref.want.$$"
rm -f "${TMPDIR:-/tmp}/quicref.want.$$" "${TMPDIR:-/tmp}/quicref.got.$$"

# Ничего, кроме плеч, после шапки: ни одного инстанса без номера.
loose=$(printf '%s\n' "${ARGS#"$HEAD"}" | tr ' ' '\n' | grep -- '^--lua-desync=' | grep -vc ':strategy=[0-9]*$')
eq "инстансов без номера плеча" "0" "$loose"

# Одна копия пула: в генераторе нет своего списка QUIC-плеч.
inline=$(grep -c 'key=quic:nld=2 --lua-desync=fake' "$GEN")
eq "в генераторе нет второй копии пула quic" "0" "$inline"

# Без манифеста генератор берёт аварийный пул (lib/utils.sh), а не свою копию:
# плечи профиля quic в конфиге совпадают с плечами аварийного пула.
arms_of() { tr ' ' '\n' | grep -- '^--lua-desync=.*:strategy=' | tr '\n' ' '; }
# shellcheck disable=SC1090
COLD=$( . "$HERE/lib/utils.sh" >/dev/null 2>&1; . "$GEN" >/dev/null 2>&1
    T=$(mktemp -d); mkdir -p "$T/extra_strats/TCP/RKN" "$T/extra_strats/UDP/YT" "$T/lists"
    printf 'rutracker.org\n' > "$T/extra_strats/TCP/RKN/List.txt"
    printf 'youtube.com\n' > "$T/extra_strats/UDP/YT/List.txt"
    ZAPRET2_DIR="$T" generate_nfqws2_opt_from_strategies 2>/dev/null | grep -- 'key=quic:' | arms_of; rm -rf "$T")
# shellcheck disable=SC1090
EMERG=$( . "$HERE/lib/utils.sh" >/dev/null 2>&1; z2k_emergency_quic_pool | arms_of)
[ -n "$EMERG" ] || no "аварийный пул quic доступен" "плечи" "пусто"
eq "холодный старт берёт аварийный пул quic" "$EMERG" "$COLD"

printf '\nИТОГ: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
