#!/bin/sh
# tests/test_no_forked_production_code.sh — тест не имеет права охранять СВОЮ
# копию боевой функции.
#
# ЧТО СЛУЧИЛОСЬ (аудит 31.08.2026). Два теста держали «local copy — kept in sync
# with lib/config_official.sh». Синхронными они не были: у одного копия
# подставляла умолчание детектора, которое боевой код убрал НАМЕРЕННО — оно
# указывало на функцию из удалённого файла и довело бы до движка несуществующее
# имя. То есть тест охранял поведение, от которого код отказался, и остался бы
# зелёным при любой поломке боевого.
#
# ПРАВИЛО. Если тест определяет функцию с боевым именем, он обязан ЗАГРУЖАТЬ тот
# файл, где эта функция живёт: подключать целиком либо вырезать её текст. Тогда
# переопределение — это заглушка поверх настоящего кода, а не замена ему.
#
# ГРАНИЦА СТОРОЖА, названная честно. Проверка идёт ПО ТЕСТУ, а не по функции:
# если тест где-то в коде загружает нужный файл, копия другой функции из того же
# файла проскочит. Ловится главный случай — тест, который вообще не трогает
# боевой файл. Из двух найденных аудитом подделок сторож ловит одну, вторая
# требовала бы разбора по каждой функции отдельно.
#
# ИСКЛЮЧЕНИЕ — границы. z2k_fetch, au_log, печать и системные утилиты подменяют
# затем, чтобы тест не лез в сеть и не звал iptables. Это законно и в список
# ниже внесено явно: молчаливого исключения быть не должно.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# Границы: подменять можно где угодно.
BOUNDARY=" z2k_fetch au_log print_info print_success print_warning print_error
 _wlog log die warn info ok no bad assert_eq cleanup main usage setof
 curl wget iptables ip6tables ipset pgrep pkill sleep date hostname nft
 au_download_repo_file z2k_sha256_file safe_config_read read_flag is_running
 au_snapshot_services au_step_refresh_binaries au_repo_base start stop restart "
# Список многострочный, а сверка идёт подстрокой " имя ". За последним словом
# каждой строки стоит перевод строки, а не пробел, поэтому такие имена в
# исключение не попадали: is_running был внесён явно и всё равно объявлялся
# нарушением. Сводим к одной строке с пробелами по краям.
BOUNDARY=" $(printf '%s' "$BOUNDARY" | tr '\n' ' ') "

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Карта: боевая функция -> файл, где она определена.
: > "$TMP/prod"
for f in lib/*.sh files/*.sh files/init.d/S* webpanel/cgi/*.sh files/S99zapret2.new; do
    [ -f "$f" ] || continue
    sed -n 's/^[[:space:]]*\([a-z_][a-z0-9_]*\)()[[:space:]]*{.*/\1/p' "$f" \
        | while IFS= read -r fn; do
            [ -n "$fn" ] && printf '%s\t%s\n' "$fn" "$f" >> "$TMP/prod"
        done
done

viol=0
for t in tests/test_*.sh; do
    [ -f "$t" ] || continue
    # Комментарии выбрасываем: фраза «kept in sync with lib/config_official.sh»
    # — это признание в копии, а не её загрузка. Первая версия сторожа
    # засчитывала такое упоминание и потому не ловила ровно тот случай, ради
    # которого написана.
    body=$(sed 's/[[:space:]]*#.*$//' "$t")
    printf '%s\n' "$body" | sed -n 's/^\([a-z_][a-z0-9_]*\)()[[:space:]]*{.*/\1/p' | sort -u \
    | while IFS= read -r fn; do
        [ -n "$fn" ] || continue
        case "$BOUNDARY" in *" $fn "*) continue ;; esac
        src=$(awk -F'\t' -v n="$fn" '$1==n {print $2; exit}' "$TMP/prod")
        [ -n "$src" ] || continue
        # Загружает ли тест этот файл: по имени файла в тексте теста.
        base=$(basename "$src")
        case "$body" in
            *"$base"*) : ;;
            *) printf '%s\t%s\t%s\n' "$t" "$fn" "$src" >> "$TMP/viol" ;;
        esac
    done
done

if [ -s "$TMP/viol" ]; then
    while IFS="$(printf '\t')" read -r t fn src; do
        bad "$(basename "$t"): держит свою копию $fn() — боевая в $src, а файл не загружается"
    done < "$TMP/viol"
else
    ok "ни один тест не охраняет собственную копию боевой функции"
fi

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
