#!/bin/sh
# Contract tests for the unique strategy-set runner. The detector and pool
# writer are stubbed; the real orchestration and selection functions are used.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/stages" "$SB/custom"
export STRATEGY_PICK_OUT="$SB/last-pick.json"
export STRATEGY_UNIQUE_RESULT_FILE="$SB/result.json"
export UNIQUE_SET_DIR="$SB/stages"
export CUSTOM_STRAT_DIR="$SB/custom"
export CALL_LOG="$SB/calls.log"
export SAVE_LOG="$SB/save.log"
is_running() { return 1; }
eval "$(awk '/^json_escape\(\)/,/^}/; /^json_string\(\)/,/^}/' "$ROOT/webpanel/cgi/api.sh")"

strategy_pick_run() {
    domain=$1 mode=$2 pinned_ip=${3:-}
    also_test_ips=${4:-}
    printf '%s %s %s %s\n' "$domain" "$mode" "${pinned_ip:--}" "${also_test_ips:--}" >> "$CALL_LOG"
    [ "${UNIQUE_FAIL_STAGE:-}" = "$domain $mode $pinned_ip" ] && return 9
    [ "${UNIQUE_FAIL_STAGE:-}" = "$domain $mode" ] && return 9
    [ "${UNIQUE_MISSING_STAGE:-}" = "$domain $mode $pinned_ip" ] && {
        printf '{"verdict":"no_strategy"}\n' > "$STRATEGY_PICK_OUT"; return 0;
    }
    if [ "${UNIQUE_MISSING_STAGE:-}" = "$domain $mode" ]; then
        strategy=
    else
    case "$UNIQUE_CASE:$domain:$mode" in
        common:i.ytimg.com:mixed) strategy=yt-measured ;;
        common:googlevideo.com:mixed) strategy=gv-measured ;;
        common:instagram.com:quic) strategy=ig-quic ;;
        common:discord.com:tcp13|common:instagram.com:tcp13|common:rutor.org:tcp13) strategy=shared-rkn ;;
        common-space:discord.com:tcp13) strategy='shared   rkn' ;;
        common-space:instagram.com:tcp13) strategy='shared rkn' ;;
        common-space:rutor.org:tcp13) strategy=' shared rkn  ' ;;
        mismatch:discord.com:tcp13) strategy=discord-rkn ;;
        mismatch:instagram.com:tcp13) strategy=instagram-rkn ;;
        mismatch:rutor.org:tcp13) strategy=rutor-rkn ;;
        missing-required:googlevideo.com:mixed) strategy= ;;
        missing-required:i.ytimg.com:mixed|missing-required:instagram.com:quic) strategy= ;;
        missing-discord:discord.com:tcp13) strategy= ;;
        missing-optional:instagram.com:tcp13|missing-optional:rutor.org:tcp13) strategy= ;;
        technical-error:*:*) return 9 ;;
        *) strategy=required-measured ;;
    esac
    fi
    if [ "${UNIQUE_CDN_SHARED:-}" = "$domain" ] && [ -n "$also_test_ips" ]; then
        if [ "$pinned_ip" = 142.250.74.14 ]; then strategy=; else strategy=shared-after-cross-check; fi
    fi
    if [ -z "$strategy" ]; then
        printf '{"verdict":"no_strategy"}\n' > "$STRATEGY_PICK_OUT"
        return 0
    fi
    case "$mode" in
        quic) printf '{"mode":"quic","tcp":null,"quic":{"strategy":"%s"},"voice":null}\n' "$strategy" > "$STRATEGY_PICK_OUT" ;;
        *) printf '{"mode":"%s","tcp":{"strategy":"%s"},"quic":null,"voice":null}\n' "$mode" "$strategy" > "$STRATEGY_PICK_OUT" ;;
    esac
}

nslookup() {
    [ "${DNS_ONE_IP:-0}" = 1 ] && {
        printf 'Name: %s\nAddress 1: 142.250.74.14 edge-a\n' "$1"
        return 0
    }
    cat <<'DNS'
Server: 127.0.0.1
Address 1: 127.0.0.1 localhost
Name: i.ytimg.com
Address 1: 142.250.74.14 edge-a
Address 2: 142.250.74.46 edge-b
Address 3: 142.250.74.14 edge-a
DNS
}

strategy_complete_line() {
    pool=$1
    read -r measured
    printf 'complete:%s:%s\n' "$pool" "$measured"
}

strategy_pool_save_batch() {
    staged=$1
    : > "$SAVE_LOG"
    for pool in yt_tcp gv_tcp quic rkn_tcp; do
        printf '%s=' "$pool" >> "$SAVE_LOG"
        cat "$staged/$pool.txt" >> "$SAVE_LOG"
    done
}

# Load the production orchestration functions. A missing function is the
# expected RED failure before implementation.
eval "$(awk '/^strategy_unique_set_(strategy|normalize|measure|ipv4_valid|parse_ips|ips|consensus|lock_acquire|lock_release|result_write|stage|stage_multi_ip|run)\(\)/,/^}/' "$ROOT/webpanel/cgi/actions.sh")"

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '[OK]   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
expect_calls() {
    expected=$1
    [ "$(cat "$CALL_LOG")" = "$expected" ] || { bad "порядок замеров ($UNIQUE_CASE): $(cat "$CALL_LOG")"; return 1; }
    ok "фиксированный порядок замеров ($UNIQUE_CASE)"
}
run_case() {
    UNIQUE_CASE=$1; export UNIQUE_CASE
    UNIQUE_FAIL_STAGE=; UNIQUE_MISSING_STAGE=; UNIQUE_EDGE_MISMATCH=; DNS_ONE_IP=0
    export UNIQUE_FAIL_STAGE UNIQUE_MISSING_STAGE UNIQUE_EDGE_MISMATCH DNS_ONE_IP
    : > "$CALL_LOG"; : > "$SAVE_LOG"; rm -f "$STRATEGY_PICK_OUT" "$STRATEGY_UNIQUE_RESULT_FILE"
    rm -f "$UNIQUE_SET_DIR"/*
    strategy_unique_set_run > "$SB/run.log" 2>&1 || { cat "$SB/run.log"; return 1; }
}

if ! command -v strategy_unique_set_run >/dev/null 2>&1; then
    printf '[FAIL] отсутствует production-функция strategy_unique_set_run\n'
    exit 1
fi

all_calls=$(printf 'i.ytimg.com mixed 142.250.74.14 142.250.74.46\ngooglevideo.com mixed 142.250.74.14 142.250.74.46\ninstagram.com quic - -\ndiscord.com tcp13 - -\ninstagram.com tcp13 - -\nrutor.org tcp13 - -')

[ "$(printf 'Address 1: 127.0.0.1 localhost\nAddress 1: 142.1.2.3 edge\nAddress 2: 142.1.2.3 duplicate\nAddress 3: 8.8.8.8 edge\nAddress 4: 999.1.1.1 bad\n' | strategy_unique_set_parse_ips)" = "$(printf '142.1.2.3\n8.8.8.8')" ] && ok 'DNS-парсер берёт два уникальных IPv4 и отбрасывает loopback/мусор' || bad 'DNS-парсер некорректен'
strategy_unique_set_ipv4_valid 142.250.74.14 && ok 'IPv4 для pinned-зонда валидируется' || bad 'корректный IPv4 отвергнут'
strategy_unique_set_ipv4_valid 999.1.1.1 >/dev/null 2>&1 && bad 'некорректный IPv4 принят' || ok 'некорректный IPv4 отклонён'

run_case common || bad 'общий результат 3/3 должен примениться'
expect_calls "$all_calls"
grep -q '^rkn_tcp=complete:rkn_tcp:shared-rkn$' "$SAVE_LOG" && ok 'выбрано точное пересечение 3/3' || bad 'не выбрано пересечение 3/3'
grep -q '"coverage":"3/3"' "$STRATEGY_UNIQUE_RESULT_FILE" && ok 'в итог записано покрытие 3/3' || bad 'результат не содержит покрытие 3/3'
for pool in yt_tcp gv_tcp quic rkn_tcp; do
    grep -q "^$pool=complete:$pool:" "$SAVE_LOG" && ok "$pool получает свой замер" || bad "$pool не получил свой замер"
done

UNIQUE_CDN_SHARED=googlevideo.com; export UNIQUE_CDN_SHARED
: > "$CALL_LOG"; : > "$SAVE_LOG"; rm -f "$STRATEGY_PICK_OUT" "$STRATEGY_UNIQUE_RESULT_FILE" "$UNIQUE_SET_DIR"/*
run_case common || bad 'общий кандидат из разных первых результатов должен примениться'
grep -q 'googlevideo.com mixed 142.250.74.14 142.250.74.46' "$CALL_LOG" && ok 'Googlevideo-кандидаты проверяются на второй цели' || bad 'межадресная проверка не передана классификатору'
grep -q 'googlevideo.com mixed 142.250.74.46 142.250.74.14' "$CALL_LOG" && ok 'поиск повторяется с другим IP как опорным' || bad 'варианты второго адреса не были исследованы'
grep -q '^gv_tcp=complete:gv_tcp:shared-after-cross-check$' "$SAVE_LOG" && ok 'использован кандидат, прошедший обе Googlevideo-цели' || bad 'общий кандидат не выбран'
UNIQUE_CDN_SHARED=; export UNIQUE_CDN_SHARED

DNS_ONE_IP=1; export DNS_ONE_IP
: > "$CALL_LOG"; : > "$SAVE_LOG"; rm -f "$STRATEGY_PICK_OUT" "$STRATEGY_UNIQUE_RESULT_FILE" "$UNIQUE_SET_DIR"/*
if strategy_unique_set_run > "$SB/one-ip.log" 2>&1; then bad 'один CDN-IP принят'; else ok 'одного CDN-IP недостаточно'; fi
[ ! -s "$SAVE_LOG" ] && ok 'при одном IP пулы не меняются' || bad 'при одном IP вызван batch save'

run_case mismatch || bad 'Discord fallback должен примениться'
grep -q '^rkn_tcp=complete:rkn_tcp:discord-rkn$' "$SAVE_LOG" && ok 'несовпадение включает Discord-fallback' || bad 'при несовпадении нет Discord-fallback'
grep -q '"coverage":"Discord-fallback"' "$STRATEGY_UNIQUE_RESULT_FILE" && ok 'в итог записан Discord-fallback' || bad 'итог не пометил Discord-fallback'

run_case missing-optional || bad 'отсутствие optional домена должно дать fallback'
grep -q '^rkn_tcp=complete:rkn_tcp:required-measured$' "$SAVE_LOG" && ok 'нет Instagram/Rutor — используется Discord' || bad 'optional-отсутствие не обработано'

run_case common-space || bad 'нормализованное пересечение должно примениться'
grep -q '^rkn_tcp=complete:rkn_tcp:shared rkn$' "$SAVE_LOG" && ok 'сравнение сворачивает повторные и краевые пробелы' || bad 'whitespace-нормализация не совпала'
grep -q '"service_restarted":false,"needs_service_start":true' "$STRATEGY_UNIQUE_RESULT_FILE" && ok 'итог предупреждает о выключенном сервисе' || bad 'не записан статус выключенного сервиса'

run_case missing-required && bad 'пустой googlevideo результат принят' || ok 'пустой обязательный результат останавливает набор'
[ ! -s "$SAVE_LOG" ] && ok 'при ошибке обязательного замера ничего не сохраняется' || bad 'при ошибке обязательного замера был вызван save'

run_case missing-discord && bad 'пустой Discord результат принят' || ok 'пустой Discord останавливает набор'
[ ! -s "$SAVE_LOG" ] && ok 'без Discord ничего не сохраняется' || bad 'без Discord был вызван save'

for target in 'i.ytimg.com mixed' 'googlevideo.com mixed' 'instagram.com quic' 'discord.com tcp13'; do
    UNIQUE_CASE=common; UNIQUE_MISSING_STAGE=$target; export UNIQUE_CASE UNIQUE_MISSING_STAGE
    # These required-result cases must stop before the batch writer.
    : > "$CALL_LOG"; : > "$SAVE_LOG"; rm -f "$STRATEGY_PICK_OUT" "$STRATEGY_UNIQUE_RESULT_FILE" "$UNIQUE_SET_DIR"/*
    if strategy_unique_set_run >/dev/null 2>&1; then bad "$target: отсутствие результата принято"; else ok "$target: отсутствие результата остановило набор"; fi
    [ ! -s "$SAVE_LOG" ] && ok "$target: без частичного сохранения" || bad "$target: вызван save после отсутствия результата"
done

for target in 'i.ytimg.com mixed' 'googlevideo.com mixed' 'instagram.com quic' 'discord.com tcp13' 'instagram.com tcp13' 'rutor.org tcp13'; do
    UNIQUE_CASE=common; UNIQUE_FAIL_STAGE=$target; export UNIQUE_CASE UNIQUE_FAIL_STAGE
    : > "$CALL_LOG"; : > "$SAVE_LOG"; rm -f "$STRATEGY_PICK_OUT" "$STRATEGY_UNIQUE_RESULT_FILE" "$UNIQUE_SET_DIR"/*
    if strategy_unique_set_run >/dev/null 2>&1; then bad "$target: техническая ошибка принята"; else ok "$target: техническая ошибка остановила набор"; fi
    [ ! -s "$SAVE_LOG" ] && ok "$target: ошибка не запустила batch save" || bad "$target: ошибка вызвала batch save"
done

# The real transaction helper is loaded after runner assertions, leaving the
# network-facing orchestration test independent from filesystem stubs.
STRATEGY_PICK_OUT="$SB/last-pick.json"
CUSTOM_STRAT_DIR="$SB/live-custom"; CONFIG_FILE="$SB/config"; INIT_SCRIPT="$SB/init"; export CUSTOM_STRAT_DIR CONFIG_FILE INIT_SCRIPT
STRATEGY_CONFIG_LOCK="$SB/config-lock"; export STRATEGY_CONFIG_LOCK
mkdir -p "$CUSTOM_STRAT_DIR"
for pool in yt_tcp gv_tcp quic rkn_tcp; do printf 'old-%s\n' "$pool" > "$CUSTOM_STRAT_DIR/$pool.txt"; done
printf 'old-config\n' > "$CONFIG_FILE"
for pool in yt_tcp gv_tcp quic rkn_tcp; do printf 'candidate-%s\n' "$pool" > "$UNIQUE_SET_DIR/$pool.txt"; done
cat > "$INIT_SCRIPT" <<'INITEOF'
#!/bin/sh
[ "$1" = restart ] || exit 0
printf x >> "$RESTART_COUNT"
[ "${FAIL_RESTART:-0}" = 1 ] && exit 1
exit 0
INITEOF
chmod +x "$INIT_SCRIPT"
export VALIDATE_LOG="$SB/validate.log" REGEN_COUNT="$SB/regen-count" RESTART_COUNT="$SB/restart-count"
strategy_validate() {
    pool=$1; cat > "$SB/validate-input"
    printf '%s\n' "$pool" >> "$VALIDATE_LOG"
    for expected in yt_tcp gv_tcp quic rkn_tcp; do [ -s "$CUSTOM_STRAT_DIR/$expected.txt" ] || return 8; done
    [ "${FAIL_VALIDATE_POOL:-}" = "$pool" ] && return 7
    return 0
}
regenerate_config() { printf x >> "$REGEN_COUNT"; [ "${FAIL_REGEN:-0}" = 1 ] && return 1; printf 'new-config\n' > "$CONFIG_FILE"; }
is_running() { [ "${SERVICE_RUNNING:-1}" = 1 ]; }
ensure_init_exec() { :; }
strategy_config_lock_acquire() { return 0; }
strategy_config_lock_release() { :; }
unset -f strategy_pool_save_batch 2>/dev/null || :
eval "$(awk '/^strategy_config_lock_(acquire|release)\(\)/,/^}/; /^_strategy_pool_restore_batch\(\)/,/^}/; /^_strategy_pool_save_batch_locked\(\)/,/^}/; /^strategy_pool_save_batch\(\)/,/^}/' "$ROOT/webpanel/cgi/actions.sh")"

if ! command -v strategy_pool_save_batch >/dev/null 2>&1; then
    bad 'отсутствует production-функция strategy_pool_save_batch'
else
    batch_snapshot() {
        for pool in yt_tcp gv_tcp quic rkn_tcp; do cat "$CUSTOM_STRAT_DIR/$pool.txt"; done
        cat "$CONFIG_FILE"
    }
    for pool in yt_tcp gv_tcp quic rkn_tcp; do
        : > "$VALIDATE_LOG"; : > "$REGEN_COUNT"; : > "$RESTART_COUNT"
        FAIL_VALIDATE_POOL=$pool; export FAIL_VALIDATE_POOL
        before=$(batch_snapshot)
        strategy_pool_save_batch "$UNIQUE_SET_DIR" "$SB/txn-$pool" >/dev/null 2>&1 && bad "$pool: validation failure accepted" || ok "$pool: validation failure rejected"
        [ "$(batch_snapshot)" = "$before" ] && ok "$pool: validation failure rolled back" || bad "$pool: validation changed live state"
        [ ! -s "$REGEN_COUNT" ] && [ ! -s "$RESTART_COUNT" ] && ok "$pool: validation preceded mutation" || bad "$pool: early apply side effect"
    done

    reset_live() {
        for pool in yt_tcp gv_tcp quic rkn_tcp; do printf 'old-%s\n' "$pool" > "$CUSTOM_STRAT_DIR/$pool.txt"; done
        printf 'old-config\n' > "$CONFIG_FILE"
        rm -f "$REGEN_COUNT" "$RESTART_COUNT" "$VALIDATE_LOG"
        FAIL_VALIDATE_POOL=; FAIL_REGEN=0; FAIL_RESTART=0; SERVICE_RUNNING=1
        export FAIL_VALIDATE_POOL FAIL_REGEN FAIL_RESTART SERVICE_RUNNING
    }
    reset_live
    strategy_pool_save_batch "$UNIQUE_SET_DIR" "$SB/txn-success" > "$SB/success.log" 2>&1 && ok 'успешный batch применён' || bad 'успешный batch завершился ошибкой'
    [ "$(wc -c < "$REGEN_COUNT" | tr -d ' ')" = 1 ] && ok 'одна регенерация config' || bad 'регенерация не ровно одна'
    [ "$(wc -c < "$RESTART_COUNT" | tr -d ' ')" = 1 ] && ok 'один рестарт сервиса' || bad 'рестарт не ровно один'
    for pool in yt_tcp gv_tcp quic rkn_tcp; do grep -qx "candidate-$pool" "$CUSTOM_STRAT_DIR/$pool.txt" && ok "$pool установлен" || bad "$pool не установлен"; done

    reset_live; FAIL_REGEN=1; export FAIL_REGEN; before=$(batch_snapshot)
    strategy_pool_save_batch "$UNIQUE_SET_DIR" "$SB/txn-regenerate" >/dev/null 2>&1 && bad 'ошибка генерации принята' || ok 'ошибка генерации возвращена'
    [ "$(batch_snapshot)" = "$before" ] && ok 'ошибка генерации откатила файлы и config' || bad 'ошибка генерации оставила частичное состояние'
    [ ! -s "$RESTART_COUNT" ] && ok 'после ошибки генерации рестарт не запускался' || bad 'после ошибки генерации был рестарт'

    reset_live; FAIL_RESTART=1; export FAIL_RESTART; before=$(batch_snapshot)
    strategy_pool_save_batch "$UNIQUE_SET_DIR" "$SB/txn-restart" >/dev/null 2>&1 && bad 'ошибка рестарта принята' || ok 'ошибка рестарта возвращена'
    [ "$(batch_snapshot)" = "$before" ] && ok 'ошибка рестарта откатила файлы и config' || bad 'ошибка рестарта оставила частичное состояние'
    [ "$(wc -c < "$RESTART_COUNT" | tr -d ' ')" = 2 ] && ok 'после отката предпринята одна попытка рестарта старого config' || bad 'восстановленный config не перезапускался'

    reset_live; SERVICE_RUNNING=0; export SERVICE_RUNNING
    strategy_pool_save_batch "$UNIQUE_SET_DIR" "$SB/txn-stopped" > "$SB/stopped.log" 2>&1 && ok 'остановленный сервис: набор сохранён' || bad 'остановленный сервис: save ошибся'
    [ ! -s "$RESTART_COUNT" ] && grep -q 'запусти сервис' "$SB/stopped.log" && ok 'остановленный сервис не рестартовался и получил подсказку' || bad 'неверное поведение при выключенном сервисе'
fi

grep -q 'в среднем около 20 минут' "$ROOT/README.md" || bad 'README omits timing'
grep -q 'discord.com.*instagram.com.*rutor.org' "$ROOT/README.md" || bad 'README omits RKN probe order'
grep -qi 'Discord' "$ROOT/README.md" && grep -q 'fallback' "$ROOT/README.md" || bad 'README omits Discord fallback'
grep -q 'yt_tcp.*gv_tcp.*quic.*rkn_tcp' "$ROOT/README.md" || bad 'README omits target pools'
grep -q 'i.ytimg.com.*googlevideo.com' "$ROOT/README.md" || bad 'README omits updated YouTube targets'
grep -q 'два IPv4-адреса' "$ROOT/README.md" && grep -q 'общий кандидат не найден' "$ROOT/README.md" || bad 'README omits CDN common-candidate/no-apply rule'
grep -q 'специально для вашего провайдера' "$ROOT/webpanel/www/js/pages/strategies.js" && ok 'UI сохраняет согласованное короткое описание' || bad 'UI description changed unexpectedly'
sed -n '/^\.unique-set-badge {/,/^}/p' "$ROOT/webpanel/www/style.css" | grep -q 'background: #c62828' && ok 'экспериментальная пометка выделена красным' || bad 'экспериментальная пометка не выделена красным'

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
