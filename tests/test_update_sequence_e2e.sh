#!/bin/sh
# tests/test_update_sequence_e2e.sh — прогон настоящей цепочки обновления:
# пересобрать конфиг → проверить его валидатором. Тот самый порядок, на котором
# встал r-81.1.
#
# ЧТО ЭТО ЛОВИТ. Апдейтер после доставки файлов зовёт regen-config, а следом
# validate-config; код 2 у валидатора = вето на перезапуск и откат всего патча.
# 30.08.2026 генератор начал выдавать конфиг с блобом z2k_ch, который наш Lua
# собирает в рантайме, а валидатор требовал файл на каждый blob= — и обновление
# откатывалось у всех, у кого механизм включён. Ни один структурный тест этого
# не видел: строки в файлах были на месте, ломалась связка.
#
# Поэтому здесь не проверяется наличие строк. Берётся НАСТОЯЩИЙ генератор и
# НАСТОЯЩИЙ валидатор, и прогоняется настоящая последовательность шагов.
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
ES="$SB/extra_strats"
mkdir -p "$ES/TCP/RKN" "$ES/TCP/YT" "$ES/TCP/YT_GV" "$ES/UDP/YT" \
         "$ES/cache/autocircular" "$SB/lists" "$SB/nfq2" "$SB/lib" \
         "$SB/files/fake" "$SB/state" "$SB/ipset"

cp "$DIR/lib/utils.sh" "$DIR/lib/config_official.sh" "$SB/lib/"
[ -f "$DIR/lib/strategies.sh" ] && cp "$DIR/lib/strategies.sh" "$SB/lib/"
cp "$DIR/files/z2k-config-validator.sh" "$SB/z2k-config-validator.sh"
# Карта регистраций блобов живёт в init-скрипте: без него валидатор про
# quic_dbankcloud и прочие имена не знает и ругается на них по своей же
# причине, маскируя настоящий дефект.
cp "$DIR/files/S99zapret2.new" "$SB/S99zapret2"
cp "$DIR/lib/auto_update.sh" "$SB/lib/auto_update.sh"

printf 'rutracker.org\n' > "$ES/TCP/RKN/List.txt"
printf 'youtube.com\n'   > "$ES/TCP/YT/List.txt"
printf 'googlevideo.com\n' > "$ES/TCP/YT_GV/List.txt"
printf 'youtube.com\n'   > "$ES/UDP/YT/List.txt"
printf 'whitelisted.example.com\n' > "$SB/lists/whitelist.txt"
# Все блоб-файлы, на которые ссылаются поставляемые стратегии: их проверяет
# валидатор, и без них стенд падал бы по своей же вине, маскируя настоящий
# дефект. Имена берём из дерева, а не перечисляем руками — иначе список
# отстанет при первой же новой стратегии.
for _b in "$DIR"/files/fake/*.bin; do
    [ -f "$_b" ] && printf 'x' > "$SB/files/fake/$(basename "$_b")"
done
printf 'x' > "$SB/files/fake/fake_default_tls.bin"
# Файлы под именами из карты регистраций init-скрипта.
grep -oE -- '--blob=[A-Za-z_][A-Za-z0-9_]*:@[^ "]+' "$DIR/files/S99zapret2.new" 2>/dev/null \
  | sed 's/.*:@//' | while IFS= read -r _p; do
        _f=$(basename "$_p")
        [ -n "$_f" ] && printf 'x' > "$SB/files/fake/$_f"
    done
# Хостлисты, которые генератор объявляет безусловно.
: > "$SB/lists/discovered-domains.txt"
: > "$SB/lists/extra-domains.txt"
printf '#!/bin/sh\nexit 0\n' > "$SB/nfq2/nfqws2"; chmod +x "$SB/nfq2/nfqws2"

printf '%s\n' '--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:strategy=1' > "$ES/TCP/RKN/Strategy.txt"
printf '%s\n' '--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4' > "$ES/TCP/YT/Strategy.txt"
cp "$ES/TCP/YT/Strategy.txt" "$ES/TCP/YT_GV/Strategy.txt"
printf '%s\n' '--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=yt_quic --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=3:strategy=1' > "$ES/UDP/YT/Strategy.txt"
printf 'ENABLED=1\n' > "$SB/config"

run_steps() {
    # Журнал апдейтера — в стенд, иначе он лезет в /opt/var/log.
    ( cd "$SB" && ZAPRET2_DIR="$SB" ZAPRET_BASE="$SB" INIT_SCRIPT="$SB/S99zapret2" Z2K_AU_LOG_FILE="$SB/au.log" \
        sh -c '. ./lib/auto_update.sh >/dev/null 2>&1
               au_step_regen_config    || exit 10
               au_step_validate_config || exit 11
               exit 0' 2>&1 )
}

# --- 1. Механизм ВЫКЛЮЧЕН (линия не измерена) -------------------------------
rm -f "$SB/state/tcp16.flag"
OUT=$(run_steps); RC=$?
if [ "$RC" != 0 ]; then
    printf 'ДИАГ: %s\n' "$(ZAPRET_BASE="$SB" INIT_SCRIPT="$SB/S99zapret2" sh "$SB/z2k-config-validator.sh" "$SB/config" 2>&1 | grep '\[FAIL\]' | head -4 | tr '\n' ' ')"
fi
[ "$RC" = 0 ] && ok "без измеренной линии цепочка проходит" \
              || bad "цепочка встала (код $RC): $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
grep -q 'z2k_sni_pick' "$SB/config" \
    && bad "механизм попал в конфиг, хотя линия не измерена" \
    || ok "без измерения механизма в конфиге нет"

# --- 2. Механизм ВКЛЮЧЁН — ровно случай r-81.1 ------------------------------
printf '1\n' > "$SB/state/tcp16.flag"
OUT=$(run_steps); RC=$?
if grep -q 'z2k_sni_pick' "$SB/config"; then
    ok "при измеренном блоке механизм попадает в конфиг"
else
    bad "механизм в конфиг не попал — обход работать не будет"
fi
if [ "$RC" = 0 ]; then
    ok "валидатор не наложил вето на конфиг с механизмом"
else
    bad "ВЕТО: цепочка встала (код $RC) — обновление откатится. $(printf '%s' "$OUT" | grep -i 'FAIL' | head -2 | tr '\n' ' ')"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
