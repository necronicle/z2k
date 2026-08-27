#!/bin/sh
# tests/test_health_check_only_regressions.sh — после обновления сообщаем о
# сервисе, который РАБОТАЛ и перестал, а не о выключенном.
#
# ЧТО СЛУЧИЛОСЬ. Health-check перечислял пять сервисов и ругался на любой
# неработающий. Но часть из них выключается флагом — Z2K_DISCOVER по умолчанию
# OFF, — поэтому строку «ВНИМАНИЕ, после обновления не работают: S98z2k-detect»
# получал ВЕСЬ ФЛОТ при КАЖДОМ обновлении, на полностью здоровом роутере. Такие
# строки перестают читать, а вместе с ними перестают замечать настоящие.
#
# Правильный признак — регрессия: работал до обновления, не работает после. Он
# не зависит ни от одного флага фич. Ту же логику мы уже применяем к nfqws2.
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# Берём НАСТОЯЩИЕ функции из дерева.
eval "$(sed -n '/^au_services_list() {/,/^}/p' "$HERE/lib/auto_update.sh")"
eval "$(sed -n '/^au_service_pattern() {/,/^}/p' "$HERE/lib/auto_update.sh")"
eval "$(sed -n '/^au_snapshot_services() {/,/^}/p' "$HERE/lib/auto_update.sh")"

# Модель роутера: какие init-скрипты установлены и что «живёт».
INITDIR="$TMP/initd"; mkdir -p "$INITDIR"
for s in $(au_services_list); do : > "$INITDIR/$s"; chmod +x "$INITDIR/$s"; done
ALIVE_SET=""
pgrep() {
    # -f <pattern> — единственная форма, которой пользуется код.
    _p="$2"
    case " $ALIVE_SET " in *" $_p "*) return 0 ;; esac
    return 1
}
# Подменяем каталог init-скриптов: функции ходят в /opt/etc/init.d по константе,
# поэтому сверяем поведение на том, что реально управляемо, — списке живых.
au_snapshot_services() {
    _alive=""
    for _s in $(au_services_list); do
        _p=$(au_service_pattern "$_s") || continue
        pgrep -f "$_p" >/dev/null 2>&1 && _alive="$_alive $_s"
    done
    Z2K_AU_SVC_ALIVE="$_alive"
}

# Повторяем цикл health-check дословно.
_down_now() {
    _down=""
    for _svc in ${Z2K_AU_SVC_ALIVE:-}; do
        _svc_pat=$(au_service_pattern "$_svc") || continue
        pgrep -f "$_svc_pat" >/dev/null 2>&1 || _down="$_down $_svc"
    done
    printf '%s' "$_down"
}

# --- 1. выключенный флагом сервис молчит --------------------------------------
# z2k-detect выключен (Z2K_DISCOVER=0): не работал до, не работает после.
ALIVE_SET="lighttpd z2k-scheduler"
au_snapshot_services
got=$(_down_now)
if [ -z "$got" ]; then ok "выключенный сервис не поминается вовсе"
else no "выключенный сервис не поминается вовсе" "пусто" "$got"; fi

# --- 2. а вот упавший после обновления — поминается ---------------------------
ALIVE_SET="lighttpd z2k-scheduler"
au_snapshot_services
ALIVE_SET="lighttpd"          # планировщик умер на обновлении
got=$(_down_now)
case "$got" in
    *S99z2k-scheduler*) ok "сервис, работавший до обновления и упавший, назван" ;;
    *) no "сервис, работавший до обновления и упавший, назван" "S99z2k-scheduler" "$got" ;;
esac
case "$got" in
    *S98z2k-detect*) no "и при этом выключенный не приплетается" "без detect" "$got" ;;
    *) ok "и при этом выключенный не приплетается" ;;
esac

# --- 3. снимок снимается на всех путях обновления -----------------------------
# Без снимка список пуст, и проверка молча ничего не заметит — это ровно та
# тишина, которой быть не должно.
_sets=$(grep -c 'au_snapshot_services$' "$HERE/lib/auto_update.sh")
_nfq=$(grep -c 'export Z2K_AU_NFQWS_WAS_ALIVE' "$HERE/lib/auto_update.sh")
if [ "$_sets" -ge "$_nfq" ] && [ "$_nfq" -gt 0 ]; then
    ok "снимок сервисов снимается на всех путях, где снимается снимок nfqws2 ($_nfq)"
else
    no "снимок сервисов снимается на всех путях" "$_nfq" "$_sets"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
