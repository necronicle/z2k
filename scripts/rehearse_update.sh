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
# ВЫЗОВ, а не результат. Отдельный контракт перед прогоном исполняет настоящий
# генератор на чистом /tmp-эквиваленте; nfqws2 --dry-run он не заменяет.
#
# АДРЕСА ПЕРЕПИСЫВАЮТСЯ ПОД КОРЕНЬ ПЕСОЧНИЦЫ. install_map содержит цели ВНЕ
# ZAPRET2_DIR — /opt/etc/init.d/S99zapret2, /opt/etc/ndm/netfilter.d/… и ещё
# восемь, — они зашиты абсолютными и подмену корня не уважают. Держать их
# песочница не может, поэтому кандидатский манифест копируется с префиксом:
# «/opt/x» становится «$SBOX/opt/x». Раскладка исходного дерева и сверка идут
# по ОДНОЙ этой карте — две карты разъедутся, и зелёный перестанет что-либо
# значить.
#
# Правильность самих адресов проверяет не эта репетиция, а
# tests/test_manifest_install_map.sh: здесь проверяется МЕХАНИЗМ.
#
# Использование:
#   sh scripts/rehearse_update.sh --prev КАТ --candidate КАТ --from ТЕГ --to ТЕГ
#                                 [--interrupt-after N]
#
#   --prev      дерево предыдущего релиза В ВИДЕ РЕПОЗИТОРИЯ (files/…, lib/…)
#   --candidate дерево кандидата, тоже в виде репозитория, с UPDATES.json
#   --updater   ЧЕЙ апдейтер выполняет обновление: prev (по умолчанию) или
#               candidate
#
# ПОЧЕМУ ПО УМОЛЧАНИЮ ЧУЖОЙ. На роутере обновление всегда выполняет СТАРЫЙ
# апдейтер — тот, что уже лежит на диске; новый приезжает этим же обновлением и
# начинает работать только со следующего. Гейт релиза обязан репетировать то,
# что произойдёт на самом деле, поэтому берёт код из --prev.
#
# Новый апдейтер при этом не остаётся непроверенным: его на каждом коммите гоняет
# tests/test_release_rehearsal.sh с --updater candidate. Разделение то же, что и
# в жизни: релизный гейт отвечает на «сядет ли это на роутеры», постоянный тест
# — на «не сломали ли мы код».
#
# Возврат: 0 — все утверждения выполнены, 1 — нарушено хотя бы одно.
#
# POSIX sh.
set -u

PREV=""; CAND=""; FROM=""; TO=""; INTERRUPT=0; UPDATER="prev"
while [ $# -gt 0 ]; do
    case "$1" in
        --prev)            PREV="${2:-}"; shift 2 ;;
        --candidate)       CAND="${2:-}"; shift 2 ;;
        --from)            FROM="${2:-}"; shift 2 ;;
        --to)              TO="${2:-}"; shift 2 ;;
        --interrupt-after) INTERRUPT="${2:-0}"; shift 2 ;;
        --updater)         UPDATER="${2:-prev}"; shift 2 ;;
        *) printf 'неизвестный ключ: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$PREV" ] && [ -n "$CAND" ] && [ -n "$FROM" ] && [ -n "$TO" ] \
    || { printf 'нужны --prev --candidate --from --to\n' >&2; exit 2; }
[ -d "$PREV" ] || { printf 'нет дерева --prev: %s\n' "$PREV" >&2; exit 2; }
[ -s "$CAND/UPDATES.json" ] || { printf 'нет %s/UPDATES.json\n' "$CAND" >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREV=$(cd "$PREV" && pwd)
CAND=$(cd "$CAND" && pwd)

# Основной прогон ниже подменяет au_run_step (включая validate-config).
# Поэтому отдельно исполняем генератор КАНДИДАТА на пустом /tmp-эквиваленте:
# именно зависимость --ipset от S99 start ломала обновление p-87.28.
# Минимальные фикстуры доставки без генератора не проверяют этот контракт.
if [ -f "$CAND/lib/config_official.sh" ]; then
    dash "$ROOT/tests/test_gvsub_config.sh" "$CAND" || exit 1
fi

FAILED=0
ok()  { printf '[OK] %s\n' "$1"; }
bad() { printf '[FAIL] %s\n' "$1"; FAILED=1; }

# ЧТО КАНДИДАТ КОНТРОЛИРУЕТ, А ЧТО НАСЛЕДУЕТ — РАЗНЫЕ ВЕЩИ.
#
# Гейт релиза гоняет СТАРЫЙ апдейтер: так обновление и происходит на роутере.
# Значит часть свойств принадлежит уже установленной версии, и кандидат
# исправить их не может по построению — исправление приедет ЭТИМ релизом и
# заработает со следующего.
#
# Провалить релиз за дефект предыдущего значит запретить его чинить: ровно это
# и случилось бы с p-79.16, который чинит пустой снимок p-79.15. Поэтому такие
# свойства говорятся ГРОМКО, но не блокируют — а под своим апдейтером
# (постоянный тест) остаются жёсткими, потому что там код наш.
inherited() {
    if [ "$UPDATER" = "prev" ]; then
        printf '[ВНИМАНИЕ] %s\n' "$1"
        printf '           это свойство УСТАНОВЛЕННОЙ версии, кандидат его не меняет\n'
    else
        bad "$1"
    fi
}

WORK=$(mktemp -d) || exit 2
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

SBOX="$WORK/root"
BASE="$SBOX/opt/zapret2"
mkdir -p "$BASE"

# --- Кандидатский манифест под корень песочницы ---------------------------------
#
# Каждая цель install_map получает префикс. Одна карта — и для раскладки
# исходного дерева, и для сверки после: две карты разъедутся, и зелёный
# перестанет что-либо значить.
CANDSB="$WORK/cand"
mkdir -p "$CANDSB"
cp -R "$CAND/." "$CANDSB/" 2>/dev/null || { printf 'не копируется кандидат\n' >&2; exit 2; }
awk -v sb="$SBOX" '
    /"[^"]+"[[:space:]]*:[[:space:]]*\[/ {
        line = $0; out = ""
        while (match(line, /"\/[^"]*"/)) {
            out = out substr(line, 1, RSTART) sb substr(line, RSTART + 1, RLENGTH - 1)
            line = substr(line, RSTART + RLENGTH)
        }
        print out line; next
    }
    { print }
' "$CAND/UPDATES.json" > "$CANDSB/UPDATES.json"

# --- Исходное дерево ------------------------------------------------------------
#
# Строит ДВИЖОК, а не вызывающий: раскладка и сверка обязаны идти по одной
# карте. Файлы, которых в предыдущем релизе не было, просто не появляются — и
# сходимость обязана их привезти.
sh "$ROOT/scripts/rehearse_check_sha.sh" --targets "$CANDSB/UPDATES.json" \
| while IFS="$(printf '\t')" read -r repo_path target; do
    [ -n "$target" ] || continue
    [ -f "$PREV/$repo_path" ] || continue
    mkdir -p "$(dirname "$target")" 2>/dev/null
    cp -f "$PREV/$repo_path" "$target"
done
printf '%s\n' "$FROM" > "$BASE/.z2k-installed-tag"

_n_base=$(find "$BASE" -type f 2>/dev/null | awk 'END {print NR+0}')
[ "${_n_base:-0}" -gt 0 ] || { printf 'исходное дерево пустое — раскладка не сработала\n' >&2; exit 2; }

# Слепок исходного дерева — чтобы проверить откат ПОБАЙТНО, а не «файлы на
# месте». Половина обновления выглядит как целое дерево, если считать файлы.
#
# Каталог state/ из слепка ИСКЛЮЧЁН, и это уточнение проверки, а не поблажка.
# Туда обновление не доставляет НИ ОДНОГО файла (проверено по install_map): это
# рантайм самого роутера — отметка проверки линии, признак пройденной чистки,
# счётчик неудач доставки. Откат обязан вернуть ДОСТАВЛЕННОЕ, а не стереть то,
# что роутер записал про себя сам. Без исключения проверка падала на счётчике,
# который апдейтер честно ведёт и после неудачи.
BEFORE="$WORK/before.list"
_snap() { cd "$1" && find . -type f ! -path './opt/zapret2/state/*' -exec sha256sum {} + 2>/dev/null | sort; }
_snap_bsd() { cd "$1" && find . -type f ! -path './opt/zapret2/state/*' -exec shasum -a 256 {} + 2>/dev/null | sort; }
_snap "$SBOX" > "$BEFORE" 2>/dev/null || _snap_bsd "$SBOX" > "$BEFORE"

# --- Локальный источник --------------------------------------------------------
#
# Сетевой транспорт подменён на curl file://, как в тестах апдейтера.
# au_repo_base/au_manifest_ref и SHA-гейт остаются настоящими. Ветка и ref
# целевой записи отдают одно дерево кандидата: будущего тега ещё нет на GitHub.
# Неизвестные URL отвергаются — наружу репетиция за файлами не ходит.
REPO_BASE="https://raw.githubusercontent.com/necronicle/z2k"
BRANCH=$(python3 - "$CANDSB/UPDATES.json" <<'PYJSON'
import json, sys
print(json.load(open(sys.argv[1])).get('branch', 'z2k-enhanced'))
PYJSON
) || exit 2
TARGET_REF=$(python3 - "$CANDSB/UPDATES.json" "$TO" <<'PYJSON'
import json, sys
manifest = json.load(open(sys.argv[1]))
print(next((entry.get('ref', '') for entry in manifest.get('history', [])
            if entry.get('v') == sys.argv[2]), ''))
PYJSON
) || exit 2

cat > "$WORK/transport.sh" <<'TRANSPORT'
z2k_fetch() {
    local url="$1" dest="$2" path count
    url=${url%%\?*}
    case "$url" in
        "$REPO_BASE/$BRANCH/"*) path=${url#"$REPO_BASE/$BRANCH/"} ;;
        "$REPO_BASE/$TARGET_REF/"*)
            [ -n "$TARGET_REF" ] || return 1
            path=${url#"$REPO_BASE/$TARGET_REF/"} ;;
        *) printf 'неизвестный URL репетиции: %s\n' "$url" >&2; return 1 ;;
    esac
    case "/$path/" in */../*|*/./*) return 1 ;; esac
    # Манифест и подпись не считаем. После обрыва не проходят и повторы,
    # включая перезапрос с кеш-бастером: источник остаётся недоступным.
    case "$path" in
        *.json|*.sig) ;;
        *)
            count=$(cat "$WORK/served" 2>/dev/null) || count=0
            count=$((count + 1))
            printf '%s\n' "$count" > "$WORK/served"
            if [ "$INTERRUPT" -gt 0 ] && [ "$count" -gt "$INTERRUPT" ]; then
                return 1
            fi ;;
    esac
    command curl -fsSL "file://$CANDSB/$path" -o "$dest" || return 1
    _z2k_verify_fetched "$dest" "$url"
}
TRANSPORT

# --- Прогон ---------------------------------------------------------------------
STEPS="$WORK/steps.log"
LOG="$WORK/au.log"
: > "$STEPS"; : > "$LOG"

# Чей апдейтер выполняет обновление — см. шапку.
case "$UPDATER" in
    prev)      LIBDIR="$PREV/lib" ;;
    candidate) LIBDIR="$CAND/lib" ;;
    *) printf 'у --updater бывает только prev или candidate\n' >&2; exit 2 ;;
esac
[ -f "$LIBDIR/auto_update.sh" ] || LIBDIR="$ROOT/lib"
printf 'апдейтер: %s (%s)\n' "$UPDATER" "$LIBDIR"

cat > "$WORK/run.sh" <<RUNNER
set -e
ZAPRET2_DIR="$BASE"; export ZAPRET2_DIR
Z2K_AU_TMP_DIR="$WORK/tmp"; export Z2K_AU_TMP_DIR
Z2K_AU_LOG_FILE="$LOG"; export Z2K_AU_LOG_FILE
Z2K_AU_INSTALLED_TAG_FILE="$BASE/.z2k-installed-tag"; export Z2K_AU_INSTALLED_TAG_FILE
Z2K_AU_REPO_RAW="$REPO_BASE/$BRANCH"; export Z2K_AU_REPO_RAW
Z2K_AU_MANIFEST_URL="$REPO_BASE/$BRANCH/UPDATES.json"; export Z2K_AU_MANIFEST_URL
GITHUB_RAW="$REPO_BASE/$BRANCH"; export GITHUB_RAW
mkdir -p "\$Z2K_AU_TMP_DIR"
cp "$CANDSB/UPDATES.json" "\$Z2K_AU_TMP_DIR/UPDATES.json"
. "$LIBDIR/utils.sh"
WORK="$WORK"; CANDSB="$CANDSB"; INTERRUPT="$INTERRUPT"
REPO_BASE="$REPO_BASE"; BRANCH="$BRANCH"; TARGET_REF="$TARGET_REF"
. "$WORK/transport.sh"
# Доставленный auto_update.sh перечитывается в подоболочке перед шагами.
# POSIX alias перехватывает только сорсинг, возвращая счётчик ПОСЛЕ него:
# иначе новый au_run_step затрёт подмену и полезет запускать сервисы роутера.
# Файл на диске не меняем — его байты обязаны пройти итоговую SHA-сверку.
rehearse_source() {
    command . "\$@" || return \$?
    au_run_step() { printf '%s\n' "\$1" >> "$STEPS"; return 0; }
    # Фоновая установка пакетов/обновление DNS тоже требуют живого роутера.
    au_provision_flock() { return 1; }
}
alias .='rehearse_source'
Z2K_AU_SOURCE_ONLY=1 . "$LIBDIR/auto_update.sh"
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
    # Тем же снимком, что и BEFORE, — две разные выборки сравнивать бессмысленно.
    _snap "$SBOX" > "$AFTER" 2>/dev/null || _snap_bsd "$SBOX" > "$AFTER"
    if diff "$BEFORE" "$AFTER" >/dev/null 2>&1; then
        ok "откат: дерево вернулось как было"
    else
        inherited "откат: дерево отличается от исходного — $(diff "$BEFORE" "$AFTER" 2>/dev/null | head -3 | tr '\n' ' ')"
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

if _sha_out=$(sh "$ROOT/scripts/rehearse_check_sha.sh" "$CANDSB/UPDATES.json" 2>&1); then
    ok "сходимость: дерево совпало с манифестом"
else
    bad "сходимость: $(printf '%s' "$_sha_out" | head -3 | tr '\n' ' ')"
fi

n_snap=$(find "$WORK/tmp/pre-apply" -type f 2>/dev/null | awk 'END {print NR+0}')
if [ "${n_snap:-0}" -gt 0 ]; then
    ok "снимок: $n_snap файлов"
else
    inherited "снимок пуст — откатывать было бы нечего"
fi

want_steps=$(awk -v t="$TO" '
    $0 ~ "\"v\"[[:space:]]*:[[:space:]]*\"" t "\"" && /"steps"/ {
        s = $0; sub(/.*"steps"[[:space:]]*:[[:space:]]*\[/, "", s); sub(/\].*/, "", s)
        n = split(s, p, ",")
        for (i = 1; i <= n; i++) { gsub(/[[:space:]"]/, "", p[i]); if (p[i] != "") print p[i] }
        exit
    }' "$CANDSB/UPDATES.json")
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
