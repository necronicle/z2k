#!/bin/sh
# tests/test_fwtype_iptables_only.sh — выбор фаервола прибит к iptables, а
# несовпадение слышно.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. Все пять собственных слоёв z2k (правила NFQUEUE,
# исключения по connmark, снятие аппаратного ускорения, redirect Telegram,
# лечение udp-masquerade) построены на iptables и начинались со строки
# `[ "$FWTYPE" = "iptables" ] || return 0`. При этом установщик писал в конфиг
# то, что вернул автодетект, включая nftables. Результат такой конфигурации —
# сервис поднимается, рапортует успех, и не ставит НИ ОДНОГО правила: обхода
# нет, сообщения нет, узнать неоткуда.
#
# Почему именно iptables — правило автора движка: nftables он рекомендует
# только с ядром от 5.15 (docs/manual.md:416), у Keenetic 4.9; плюс nft-сеты
# требуют сотни мегабайт (там же :413) при 64 МБ на коробке.
#
# ЧТО ОХРАНЯЕТСЯ:
#   1. Установщик приводит FWTYPE к iptables при ЛЮБОМ ответе автодетекта.
#   2. Ни один слой больше не выходит молча — есть общий гейт, который
#      объясняет человеку, что обход не работает и почему.
#   3. Все пять слоёв ходят через этот гейт, а не через собственную проверку.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
INIT="$ROOT/files/S99zapret2.new"
INST="$ROOT/lib/install.sh"

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- 1. Установщик приводит к iptables --------------------------------------
if grep -q 'if \[ "\$FWTYPE" != "iptables" \]; then' "$INST"; then
    ok "установщик приводит любой FWTYPE к iptables"
else
    no "приведение к iptables" "проверка != iptables" "осталась старая, только на unsupported"
fi

# --- 2. Гейт исполняется и жалуется ------------------------------------------
awk '/^z2k_fw_is_iptables\(\)$/{f=1} f{print} f&&/^}$/{exit}' "$INIT" > "$TMP/gate.sh"
[ -s "$TMP/gate.sh" ] || { printf '[FAIL] гейт z2k_fw_is_iptables не найден\n'; exit 1; }

out=$( . "$TMP/gate.sh"; FWTYPE=iptables; z2k_fw_is_iptables; echo "rc=$?" )
case "$out" in
    "rc=0") ok "при iptables гейт молчит и пропускает" ;;
    *) no "iptables пропускается молча" "rc=0 без вывода" "$out" ;;
esac

out=$( . "$TMP/gate.sh"; FWTYPE=nftables; z2k_fw_is_iptables; echo "rc=$?" )
case "$out" in
    *ОШИБКА*rc=1*) ok "при nftables гейт кричит и не пропускает" ;;
    *) no "nftables — громкая ошибка" "ОШИБКА + rc=1" "$out" ;;
esac

# Жалоба ровно одна на запуск, а не по разу на каждый слой.
_n=$( . "$TMP/gate.sh"; FWTYPE=nftables
      z2k_fw_is_iptables >/dev/null 2>&1 || true
      z2k_fw_is_iptables 2>&1 | grep -c 'ОШИБКА' )
if [ "$_n" = "0" ]; then
    ok "повторные вызовы не засыпают лог одной и той же жалобой"
else
    no "жалоба один раз" "0 повторов" "$_n"
fi

# --- 3. Все слои ходят через гейт --------------------------------------------
_left=$(grep -c '\[ "\$FWTYPE" = "iptables" \] || return 0' "$INIT")
if [ "$_left" = "0" ]; then
    ok "собственных тихих проверок FWTYPE не осталось"
else
    no "все слои через гейт" "0 тихих проверок" "$_left осталось"
fi
_gated=$(grep -c 'z2k_fw_is_iptables || return 0' "$INIT")
if [ "$_gated" -ge 5 ]; then
    ok "через гейт проходят все пять слоёв ($_gated)"
else
    no "пять слоёв через гейт" ">=5" "$_gated"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
