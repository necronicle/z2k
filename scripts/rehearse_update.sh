#!/bin/sh
# scripts/rehearse_update.sh — репетиция обновления в песочнице.
#
# Прогоняет НАСТОЯЩИЙ апдейтер против дерева, изображающего установленный
# роутер, и проверяет не «не упало», а объявленные свойства: сходимость,
# непустой снимок, шаги в объявленном порядке, отметку версии.
#
# ОБОЛОЧКА — dash с set -e, и это не придирка. Это правила z2k.sh, при которых
# обновление умирало молча: приём `cmd; rc=$?` под errexit код возврата не
# ловит, а убивает оболочку до присваивания. Панель тот же код выполняет без
# errexit и потому работала — расхождение нашёл живой человек, а не мы.
#
# ЖЕЛЕЗА НЕ ТРЕБУЕТСЯ. Сходимость работает с файлами; ipset, iptables и ndmc
# появляются только в шагах, а шаги подменяются счётчиком вызовов: проверяется
# ВЫЗОВ, а не результат. Что делают сами шаги — за границей этой проверки, и в
# спеке это записано прямо.
#
# Использование:
#   sh scripts/rehearse_update.sh --base КАТ --candidate КАТ --from ТЕГ --to ТЕГ
#                                 [--interrupt-after N]
#
# Возврат: 0 — все утверждения выполнены, 1 — нарушено хотя бы одно.
#
# POSIX sh.
set -u

BASE=""; CAND=""; FROM=""; TO=""; INTERRUPT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --base)            BASE="${2:-}"; shift 2 ;;
        --candidate)       CAND="${2:-}"; shift 2 ;;
        --from)            FROM="${2:-}"; shift 2 ;;
        --to)              TO="${2:-}"; shift 2 ;;
        --interrupt-after) INTERRUPT="${2:-0}"; shift 2 ;;
        *) printf 'неизвестный ключ: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$BASE" ] && [ -n "$CAND" ] && [ -n "$FROM" ] && [ -n "$TO" ] \
    || { printf 'нужны --base --candidate --from --to\n' >&2; exit 2; }
[ -d "$BASE" ] || { printf 'нет дерева --base: %s\n' "$BASE" >&2; exit 2; }
[ -s "$CAND/UPDATES.json" ] || { printf 'нет %s/UPDATES.json\n' "$CAND" >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=$(cd "$BASE" && pwd)
CAND=$(cd "$CAND" && pwd)

FAILED=0
ok()  { printf '[OK] %s\n' "$1"; }
bad() { printf '[FAIL] %s\n' "$1"; FAILED=1; }

WORK=$(mktemp -d) || exit 2
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Слепок исходного дерева — чтобы проверить откат ПОБАЙТНО, а не «файлы на
# месте». Половина обновления выглядит как целое дерево, если считать файлы.
BEFORE="$WORK/before.list"
( cd "$BASE" && find . -type f -exec sha256sum {} + 2>/dev/null | sort ) > "$BEFORE" 2>/dev/null \
    || ( cd "$BASE" && find . -type f -exec shasum -a 256 {} + 2>/dev/null | sort ) > "$BEFORE"

# --- Локальный источник --------------------------------------------------------
#
# Адрес не похож на raw.githubusercontent.com, поэтому зеркала и VPS-слой не
# задействуются, а сам загрузчик и sha-гейт работают настоящие.
PORT=$(awk 'BEGIN { srand(); printf "%d", 20000 + int(rand() * 20000) }' </dev/null)

if [ "$INTERRUPT" -gt 0 ]; then
    # Обрыв — остановка сервера после N отданных файлов. Это ровно потеря связи
    # посреди обновления, и он ДЕТЕРМИНИРОВАН: N задаётся, а не ловится на удачу.
    # Манифест не считаем: он приходит первым и до доставки, обрывать на нём
    # значит проверять не то.
    cat > "$WORK/srv.py" <<'PY'
import functools, http.server, os, sys
limit = int(sys.argv[1]); served = 0
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        global served
        if self.path.endswith('.json') or self.path.endswith('.sig'):
            return super().do_GET()
        served += 1
        if served > limit:
            os._exit(0)
        return super().do_GET()
    def log_message(self, *a):
        pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[2])),
                       functools.partial(H, directory=sys.argv[3])).serve_forever()
PY
    python3 "$WORK/srv.py" "$INTERRUPT" "$PORT" "$CAND" >/dev/null 2>&1 &
    SRV=$!
else
    ( cd "$CAND" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
    SRV=$!
fi

_w=0
while [ "$_w" -lt 50 ]; do
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT/UPDATES.json" 2>/dev/null && break
    _w=$((_w + 1)); sleep 1
done
[ "$_w" -lt 50 ] || { printf 'локальный источник не поднялся\n' >&2; exit 2; }

# --- Прогон ---------------------------------------------------------------------
STEPS="$WORK/steps.log"
LOG="$WORK/au.log"
: > "$STEPS"; : > "$LOG"

cat > "$WORK/run.sh" <<RUNNER
set -e
ZAPRET2_DIR="$BASE"; export ZAPRET2_DIR
Z2K_AU_TMP_DIR="$WORK/tmp"; export Z2K_AU_TMP_DIR
Z2K_AU_LOG_FILE="$LOG"; export Z2K_AU_LOG_FILE
Z2K_AU_INSTALLED_TAG_FILE="$BASE/.z2k-installed-tag"; export Z2K_AU_INSTALLED_TAG_FILE
Z2K_AU_REPO_RAW="http://127.0.0.1:$PORT"; export Z2K_AU_REPO_RAW
Z2K_AU_MANIFEST_URL="http://127.0.0.1:$PORT/UPDATES.json"; export Z2K_AU_MANIFEST_URL
GITHUB_RAW="http://127.0.0.1:$PORT"; export GITHUB_RAW
mkdir -p "\$Z2K_AU_TMP_DIR"
cp "$CAND/UPDATES.json" "\$Z2K_AU_TMP_DIR/UPDATES.json"
. "$ROOT/lib/utils.sh"
Z2K_AU_SOURCE_ONLY=1 . "$ROOT/lib/auto_update.sh"
# Шаги подменяем счётчиком: проверяется вызов и его порядок, а не результат.
au_run_step() { printf '%s\n' "\$1" >> "$STEPS"; return 0; }
# Проверка живости смотрит на СИСТЕМУ — работает ли nfqws2, парсятся ли
# установленные скрипты, отвечает ли github. В песочнице системы нет вовсе, и
# без подмены она валится, запускает откат и портит замер: в журнал уезжают
# лишние шаги отката, а отметка версии не двигается. По спеке результат шагов и
# состояние сервисов лежат за границей этой проверки.
au_health_check() { return 0; }
_steps=\$(au_steps_union "\$Z2K_AU_TMP_DIR/UPDATES.json" "$TO" | au_steps_ordered | tr '\n' ' ')
au_apply_converge "$TO" \$_steps
RUNNER

dash "$WORK/run.sh" > "$WORK/out" 2>&1
RUN_RC=$?

# --- Утверждения ----------------------------------------------------------------

if [ "$INTERRUPT" -gt 0 ]; then
    # Обрыв. Прогон ОБЯЗАН вернуть ошибку: доставка не удалась, и молчаливый
    # успех здесь означал бы, что роутер считает себя обновлённым, не будучи им.
    if [ "$RUN_RC" != 0 ]; then
        ok "обрыв распознан как провал доставки"
    else
        bad "обрыв не распознан — прогон отрапортовал успех"
    fi

    AFTER="$WORK/after.list"
    ( cd "$BASE" && find . -type f -exec sha256sum {} + 2>/dev/null | sort ) > "$AFTER" 2>/dev/null \
        || ( cd "$BASE" && find . -type f -exec shasum -a 256 {} + 2>/dev/null | sort ) > "$AFTER"
    if diff "$BEFORE" "$AFTER" >/dev/null 2>&1; then
        ok "откат: дерево вернулось как было"
    else
        bad "откат: дерево отличается от исходного — $(diff "$BEFORE" "$AFTER" 2>/dev/null | head -3 | tr '\n' ' ')"
    fi

    _tag=$(cat "$BASE/.z2k-installed-tag" 2>/dev/null | tr -d '\n')
    if [ "$_tag" = "$FROM" ]; then
        ok "отметка версии не сдвинулась: $_tag"
    else
        bad "отметка версии сдвинулась при обрыве: '$_tag' вместо '$FROM'"
    fi
    exit "$FAILED"
fi

if [ "$RUN_RC" = 0 ]; then
    ok "прогон дожил до конца под set -e"
else
    bad "прогон умер под set -e (код $RUN_RC): $(tail -3 "$WORK/out" | tr '\n' ' ')"
fi

if _sha_out=$(sh "$ROOT/scripts/rehearse_check_sha.sh" "$CAND/UPDATES.json" 2>&1); then
    ok "сходимость: дерево совпало с манифестом"
else
    bad "сходимость: $(printf '%s' "$_sha_out" | head -3 | tr '\n' ' ')"
fi

n_snap=$(find "$WORK/tmp/pre-apply" -type f 2>/dev/null | awk 'END {print NR+0}')
if [ "${n_snap:-0}" -gt 0 ]; then
    ok "снимок: $n_snap файлов"
else
    bad "снимок пуст — откатывать было бы нечего"
fi

want_steps=$(awk -v t="$TO" '
    $0 ~ "\"v\"[[:space:]]*:[[:space:]]*\"" t "\"" && /"steps"/ {
        s = $0; sub(/.*"steps"[[:space:]]*:[[:space:]]*\[/, "", s); sub(/\].*/, "", s)
        n = split(s, p, ",")
        for (i = 1; i <= n; i++) { gsub(/[[:space:]"]/, "", p[i]); if (p[i] != "") print p[i] }
        exit
    }' "$CAND/UPDATES.json")
got_steps=$(cat "$STEPS")
if [ "$want_steps" = "$got_steps" ]; then
    ok "шаги: [$(printf '%s' "$got_steps" | tr '\n' ' ')]"
else
    bad "шаги разошлись: объявлено [$(printf '%s' "$want_steps" | tr '\n' ' ')], выполнено [$(printf '%s' "$got_steps" | tr '\n' ' ')]"
fi

_tag=$(cat "$BASE/.z2k-installed-tag" 2>/dev/null | tr -d '\n')
if [ "$_tag" = "$TO" ]; then
    ok "отметка версии: $_tag"
else
    bad "отметка версии не сдвинулась: '$_tag' вместо '$TO'"
fi

# Время между строками журнала. ПЕЧАТАЕТСЯ, НО ПРОВАЛОМ НЕ СЧИТАЕТСЯ: раннеры
# бывают медленные, и красный CI из-за чужой нагрузки хуже, чем цифра, на
# которую надо посмотреть. Нужна она затем, чтобы сорок секунд тишины было
# видно здесь, а не приходило из поля.
awk '
    { t = substr($0, 2, 19)
      if (t !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/) next
      split(substr(t, 12), c, ":")
      s = c[1] * 3600 + c[2] * 60 + c[3]
      if (seen && s - prev > max) { max = s - prev; where = prevmsg }
      seen = 1; prev = s; prevmsg = substr($0, 23) }
    END {
        printf "самая длинная пауза в журнале: %d с", max + 0
        if (where != "") printf " (после «%s»)", where
        printf "\n"
    }
' "$LOG" 2>/dev/null

exit "$FAILED"
