#!/bin/sh
# tests/test_rst_filter_removed.sh — RST-фильтры сняты и не должны вернуться.
#
# ЗАЧЕМ. В проекте жили два независимых механизма, и оба отнимали больше,
# чем давали:
#
#   1. RST_FILTER -> --rst-filter движка. Дроп входящего RST происходит в
#      dpi_desync_packet_play ДО диспетчеризации профиля, то есть до
#      standard_failure_detector (lua/zapret-auto.lua) и до детектора
#      автохостлиста. На входящем RST стоит ротация стратегий и автоподбор
#      доменов; ради того, чтобы nfqws вообще ЭТОТ RST видел, init-скрипт
#      специально ставит tcp_be_liberal=1. Включённый фильтр ослеплял ровно
#      то, ради чего conntrack и настраивался.
#
#   2. DROP_DPI_RST -> правило iptables u32 по IP ID 0x0000-0x000F (паттерн
#      из GoodbyeDPI). Легитимный RST от Linux-сервера идёт с id 0 — снято
#      с боевого VPS 2026-08-17: `id 0, flags [DF] ... Flags [R.]`. Правило
#      резало нормальные ресеты: вместо мгновенного отказа клиент ждал
#      таймаут.
#
# ЧТО ОХРАНЯЕТСЯ:
#   1. Init-скрипт нигде не передаёт --rst-filter движку.
#   2. Ни один флаг (RST_FILTER / DROP_DPI_RST) не читается и не пишется
#      ни init-скриптом, ни генератором конфига, ни панелью, ни меню.
#   3. Уборка старой цепочки z2k_dpi_rst зовётся и на старте, и на стопе —
#      у тех, кто успел включить флаг, она осталась в raw PREROUTING и без
#      этого продолжала бы резать ресеты после обновления.
#   4. Уборка ходит через iptablesw (с -w): без блокировки NDM вырывает
#      правило из-под руки (см. restart_fw storm, r-60).
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
INIT="$ROOT/files/S99zapret2.new"
[ -f "$INIT" ] || { printf '[FAIL] нет %s\n' "$INIT"; exit 1; }

# --- 1. Флаг движку не передаётся ---------------------------------------------
if grep -v '^[[:space:]]*#' "$INIT" | grep -q -- '--rst-filter'; then
    no "init не передаёт --rst-filter" "нашлось в S99zapret2.new"
else
    ok "init не передаёт --rst-filter движку"
fi

# --- 2. Флаги нигде не живут ---------------------------------------------------
# Комментарии не в счёт — сторожим исполняемый код.
for f in files/S99zapret2.new lib/config_official.sh lib/menu.sh \
         webpanel/cgi/api.sh webpanel/cgi/actions.sh lib/install.sh; do
    _hits=$(grep -v '^[[:space:]]*#' "$ROOT/$f" 2>/dev/null \
            | grep -c -E 'RST_FILTER|DROP_DPI_RST' || true)
    case "$_hits" in ''|*[!0-9]*) _hits=0 ;; esac
    if [ "$_hits" = "0" ]; then
        ok "$f: флагов RST-фильтра в коде нет"
    else
        no "$f: флагов RST-фильтра в коде нет" "вхождений: $_hits"
    fi
done

# --- 3. Уборка цепочки зовётся на старте и на стопе -----------------------------
_calls=$(grep -c '^[[:space:]]*z2k_rst_filter_purge[[:space:]]*$' "$INIT")
if [ "$_calls" -ge 2 ]; then
    ok "purge старой цепочки зовётся и на старте, и на стопе ($_calls)"
else
    no "purge зовётся дважды" "вызовов: $_calls"
fi

# --- 4. Уборка ходит через iptablesw -------------------------------------------
_fn=$(awk '/^z2k_rst_filter_purge\(\)/{f=1} f{print} f&&/^}$/{exit}' "$INIT")
if printf '%s' "$_fn" | grep -q 'iptablesw -t raw'; then
    ok "уборка ходит через iptablesw (-w, лок NDM)"
else
    no "уборка через iptablesw" "нашёлся голый iptables"
fi
if printf '%s' "$_fn" | grep -qE '^[[:space:]]*iptables -t raw'; then
    no "в уборке не осталось голого iptables" "остался"
else
    ok "в уборке не осталось голого iptables"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
