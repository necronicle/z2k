#!/bin/sh
# tests/test_silent_fallback_removed.sh — тумблер «Silent fallback РКН» снят.
#
# ЗАЧЕМ. Замер генератора 2026-08-17 (тот же конфиг, флаг 0 против 1) показал,
# что вся разница тумблера — один добавленный токен перед circular:
#
#   --payload=tls_client_hello,empty
#
# В дефолтном пути payload-токен переносится ЗА circular, поэтому circular и
# так работает с `--payload=all` (дефолт движка по мануалу), а
# all ⊃ {tls_client_hello, empty}. То есть тумблер обзор не расширял, а сужал.
# Детектор z2k_silent_drop_detector, ради которого он назывался silent,
# срезается z2k_strip_custom_detectors при Z2K_NATIVE_DETECTORS=1 (дефолт) и
# в конфиг не попадал ни при ON, ни при OFF — проверено на боевом роутере.
# Флаг-файл rkn_silent_fallback.flag читал только архивный z2k-autocircular.lua,
# который не грузится с 2026-05-28, но при этом бэкапился и восстанавливался
# при каждом обновлении.
#
# ЧТО ОХРАНЯЕТСЯ: ни флага, ни флаг-файла, ни маршрута панели, ни пункта меню.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# Код, а не комментарии: причину удаления мы в комментариях как раз держим.
for f in lib/config_official.sh lib/menu.sh lib/install.sh \
         webpanel/cgi/api.sh webpanel/cgi/actions.sh files/z2k-diag.sh; do
    _hits=$(grep -v '^[[:space:]]*#' "$ROOT/$f" 2>/dev/null \
            | grep -c -E 'RKN_SILENT_FALLBACK|rkn_silent_fallback' || true)
    case "$_hits" in ''|*[!0-9]*) _hits=0 ;; esac
    if [ "$_hits" = "0" ]; then
        ok "$f: тумблера silent fallback в коде нет"
    else
        no "$f: тумблера silent fallback в коде нет" "вхождений: $_hits"
    fi
done

# Фронт панели: ни тумблера, ни строки в сводке.
_js=$(grep -rn 'silent_fallback\|silent-fallback' "$ROOT/webpanel/www/js/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_js" = "0" ]; then
    ok "панель: тумблера нет ни в списке, ни в сводке"
else
    no "панель без тумблера" "вхождений в js: $_js"
fi

# Маршрут API не должен приниматься.
if grep -q 'toggle/silent-fallback' "$ROOT/webpanel/cgi/api.sh"; then
    no "маршрут /toggle/silent-fallback снят" "маршрут на месте"
else
    ok "маршрут /toggle/silent-fallback снят"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
