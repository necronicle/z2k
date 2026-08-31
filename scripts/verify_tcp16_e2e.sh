#!/bin/sh
# scripts/verify_tcp16_e2e.sh — «чистая комната»: доказать, что механизм обхода
# блока по объёму ВКЛЮЧАЕТСЯ у человека после обычного обновления.
#
# ЗАЧЕМ ЭТОТ СКРИПТ СУЩЕСТВУЕТ. Механизм не работал у людей три выпуска подряд,
# и каждый раз проверка «по кускам» показывала зелёное: проба работает, гейт
# конфига работает, стартовый блок работает. Ломалась связка, которую никто не
# прогонял целиком: у людей не было бинарника, у них не перезапускался
# планировщик, у них шаг не объявлялся релизом. Проверять надо ЦЕПЬ, а не звенья.
#
# ЧТО ДЕЛАЕТ. Воспроизводит состояние пользователя на живом роутере: сносит
# бинарник, флаг, подобранные имена, отметку планировщика и дроссель, откатывает
# версию на опубликованную. Затем поднимает раздачу кандидата и гоняет ШТАТНОЕ
# обновление — тем же путём, каким его получит человек. Реинсталлом проверять
# нельзя: он поднимает всё заново и прячет ровно этот класс дефектов.
#
# КРИТЕРИЙ ОБЪЯВЛЕН ЗАРАНЕЕ и не подгоняется под результат:
#   флаг = 1, подобранных имён > 0, механизм в конфиге, служба жива.
#
# Роутер остаётся на кандидате — это и есть проверяемое состояние.
#
# Использование: sh scripts/verify_tcp16_e2e.sh [версия-кандидата]
set -e

CAND_VER="${1:-p-99.9-проверка}"
ROUTER="${Z2K_ROUTER:-192.168.1.1}"
RPORT="${Z2K_ROUTER_SSH_PORT:-222}"
MAC_IP="${Z2K_MAC_IP:-192.168.1.67}"
HTTP_PORT="${Z2K_HTTP_PORT:-8099}"
KEY="${Z2K_SIGNING_KEY:-$HOME/.z2k-signing/z2k-update.key}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

rsh() { sshpass -p "${Z2K_ROUTER_PASS:?нужен Z2K_ROUTER_PASS}" \
        ssh -o StrictHostKeyChecking=no -p "$RPORT" "root@$ROUTER" "$@"; }

say() { printf '%s\n' "$*"; }
die() { printf 'ПРОВАЛ: %s\n' "$*" >&2; exit 1; }

WORK=$(mktemp -d) || die "нет временного каталога"

# ВОЗВРАТ ВЕРСИИ ОБЯЗАТЕЛЕН. Проверочная версия отсутствует в истории релизов, и
# роутер, оставленный на ней, больше не обновится вовсе: обновлятель честно
# скажет «версии нет в истории» и остановится. Прогон часто идёт на живом
# роутере, которым человек пользуется, поэтому отметку возвращаем ВСЕГДА — и на
# провале, и по Ctrl-C. Один раз я этого не сделал, и владелец увидел в панели
# «Установлена последняя версия (p-99.1-проверка)».
ORIG_TAG=""
cleanup() {
    [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null
    if [ -n "$ORIG_TAG" ]; then
        rsh "printf '%s\n' '$ORIG_TAG' > /opt/zapret2/.z2k-installed-tag" 2>/dev/null \
            && printf 'версия возвращена на %s\n' "$ORIG_TAG"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ── 1. Кандидат ──────────────────────────────────────────────────────────────
say "1/5 собираю кандидата $CAND_VER"
git -C "$ROOT" clone -q --local --no-hardlinks --branch z2k-staging . "$WORK/repo"
( cd "$WORK/repo" && sh scripts/gen_file_hashes.sh >/dev/null 2>&1 ) || die "не пересчитались суммы"

PUBLISHED=$(python3 - "$WORK/repo/UPDATES.json" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))["current"])
PY
) || die "не читается манифест"
say "    опубликованная версия: $PUBLISHED"

python3 - "$WORK/repo/UPDATES.json" "$CAND_VER" <<'PY' || die "не собралась запись истории"
import sys, datetime
p, ver = sys.argv[1], sys.argv[2]
s = open(p).read()
cur = s.index('"current": "'); end = s.index('"', cur + 12)
s = s[:cur] + '"current": "' + ver + s[end:]
last = s.rindex('{"v":'); nl = s.index('\n', last) + 1
prev = s[last:nl].rstrip('\n').rstrip()
entry = ('{"v": "%s", "type": "patch", "ts": "%s", "ref": "HEAD", '
         '"desc": "Проверочный кандидат чистой комнаты, в сеть не уходит.", '
         '"changed_files": ["files/z2k-tcp16-probe.sh"], "steps": ["restart-service"], '
         '"full_install": false}\n') % (ver, datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))
open(p, 'w').write(s[:last] + prev + ('' if prev.endswith(',') else ',') + '\n' + entry + s[nl:])
PY

OSSL=""
for c in /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl /usr/local/bin/openssl; do
    [ -x "$c" ] && "$c" genpkey -algorithm ed25519 -out /dev/null >/dev/null 2>&1 && { OSSL="$c"; break; }
done
[ -n "$OSSL" ] || die "нет OpenSSL с Ed25519"
[ -f "$KEY" ] || die "нет ключа подписи: $KEY"
"$OSSL" pkeyutl -sign -rawin -inkey "$KEY" -in "$WORK/repo/UPDATES.json" \
        -out "$WORK/repo/UPDATES.json.sig" || die "манифест не подписался"

# ── 2. Раздача ───────────────────────────────────────────────────────────────
say "2/5 раздаю кандидата на :$HTTP_PORT"
( cd "$WORK/repo" && python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 >/dev/null 2>&1 ) &
SRV_PID=$!
sleep 2
rsh "curl -fsS --max-time 8 http://$MAC_IP:$HTTP_PORT/UPDATES.json >/dev/null" \
    || die "роутер не видит раздачу"

# ── 3. Состояние пользователя ────────────────────────────────────────────────
say "3/5 воспроизвожу состояние пользователя (ничего не подложено)"
# Запоминаем ДО того, как тронем: возвращать будем именно то, что было.
ORIG_TAG=$(rsh "cat /opt/zapret2/.z2k-installed-tag 2>/dev/null" || true)
[ -n "$ORIG_TAG" ] || ORIG_TAG="$PUBLISHED"
rsh "sh -s" <<EOF || die "не удалось привести роутер в чистое состояние"
rm -f /opt/sbin/z2k-detect /opt/zapret2/z2k-detect
rm -f /opt/zapret2/state/tcp16.flag /opt/zapret2/state/tcp16.flag.ts
rm -f /opt/zapret2/state/tcp16_sni.txt /opt/zapret2/state/tcp16_asn.txt
rm -f /tmp/z2k-scheduler.mtime /tmp/z2k-sni-refresh.ts /tmp/z2k-tcp16-probe.log
rm -rf /tmp/z2k_au
printf '%s\n' "$PUBLISHED" > /opt/zapret2/.z2k-installed-tag
EOF
rsh "[ ! -e /opt/sbin/z2k-detect ] && [ ! -e /opt/zapret2/state/tcp16.flag ]" \
    || die "состояние не очистилось"

# ── 4. Штатное обновление ────────────────────────────────────────────────────
say "4/5 гоняю ШТАТНОЕ обновление $PUBLISHED -> $CAND_VER"
rsh "Z2K_AU_REPO_RAW=http://$MAC_IP:$HTTP_PORT Z2K_AU_NO_JITTER=1 Z2K_AU_MANUAL=1 \
     sh /opt/zapret2/z2k-auto-update.sh apply 2>&1 | tail -6"

# ── 5. Вердикт ───────────────────────────────────────────────────────────────
say "5/5 жду пробу и проверяю объявленный критерий"
# Ждём ЗАВЕРШЕНИЯ пробы, а не появления флага. Флаг пишется сразу после вердикта
# по линии, а имена подбираются ПОСЛЕ него и занимают ещё пару минут. На флаге я
# уже один раз остановился и получил «имён 0» на исправном коде — проверка
# соврала, а не продукт.
i=0
while [ "$i" -lt 60 ]; do
    i=$((i + 1))
    sleep 15
    if ! rsh "pgrep -f z2k-tcp16-probe.sh >/dev/null 2>&1"; then
        # процесса нет — либо отработала, либо не запускалась
        [ -n "$(rsh "cat /opt/zapret2/state/tcp16.flag 2>/dev/null" || true)" ] && break
    fi
    printf '    проба идёт, %s с\n' "$((i * 15))"
done

FLAG=$(rsh "cat /opt/zapret2/state/tcp16.flag 2>/dev/null" || true)
NAMES=$(rsh "grep -vc '^#' /opt/zapret2/state/tcp16_sni.txt 2>/dev/null" || echo 0)
INCFG=$(rsh "grep -c -- '--lua-desync=z2k_sni_pick' /opt/zapret2/config 2>/dev/null" || echo 0)
ALIVE=$(rsh "pgrep nfqws2 | wc -l" || echo 0)
VER=$(rsh "cat /opt/zapret2/.z2k-installed-tag 2>/dev/null" || true)

printf '\nверсия: %s\nфлаг: %s\nимён: %s\nв конфиге: %s\nnfqws2: %s\n' \
    "${VER:-нет}" "${FLAG:-нет}" "$NAMES" "$INCFG" "$ALIVE"

[ "$FLAG" = "1" ]      || die "флаг не выставлен — механизм не включился"
[ "${NAMES:-0}" -gt 0 ] || die "имена не подобраны"
[ "${INCFG:-0}" -gt 0 ] || die "механизма нет в конфиге"
[ "${ALIVE:-0}" -gt 0 ] || die "служба не работает"

say ""
say "ПРОЙДЕНО: механизм включился из чистого состояния штатным обновлением"
