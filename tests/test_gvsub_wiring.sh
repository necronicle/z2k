#!/bin/sh
# tests/test_gvsub_wiring.sh — обвязка службы подмены плохих адресов googlevideo
# (z2k-detect gvsub) и пробы на IPv6.
#
# Звенья в разных файлах, каждое ломает механизм молча: цепочки первыми в
# PREROUTING (иначе движок обрабатывает соединение ПОСЛЕ переадресации и его
# пакеты уходят с адресом из локальной сети — стенд 09.11.2026), очередь для
# ответов DNS с --queue-bypass (без службы DNS обязан работать), SIGHUP службе
# после перестройки таблиц Keenetic, порядок остановки, ключ в генераторе,
# тумблер в панели. Код исполняется с подставными iptables, а не ищется grep'ом.
# POSIX sh (busybox ash).

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
S99="$ROOT/files/S99zapret2.new"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

TMP="${TMPDIR:-/tmp}/z2k-gvsub-wiring.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

fn() { awk -v f="$1" '$0 == f "()" || $0 == f "() {" {p=1} p{print} p&&/^}/{exit}' "$S99"; }
body() { fn "$1" | tr '\n' ' '; }

# --- 1. Порядок в init ---------------------------------------------------------
SF=$(body start_fw)
_last=$(fn start_fw | grep -vE '^[[:space:]]*(#|$|return|\}|\{)' | tail -1 | tr -d ' ')
[ "$_last" = "z2k_gvsub_fw_start" ] \
    && ok "цепочки подмены ставятся последними в start_fw (встают первыми в PREROUTING)" \
    || bad "в start_fw после подмены ещё что-то вставляет правила: последний вызов '$_last'"
has "z2k_gvsub_fw_stop" "$(body stop_fw)" && ok "stop_fw снимает цепочки подмены" || bad "stop_fw не снимает цепочки подмены"
ST=$(body stop)
case "$ST" in
    *z2k_gvsub_stop*stop_daemons*) ok "служба останавливается раньше движка и правил" ;;
    *) bad "порядок в stop(): служба обязана уйти до stop_daemons" ;;
esac
case "$(body start)" in
    *start_daemons*z2k_gvsub_start*) ok "служба стартует после движка" ;;
    *) bad "порядок в start(): служба до движка" ;;
esac
has "z2k_preflight_v6_gate" "$(body start_daemons)" && ok "проверка IPv6 стоит перед запуском движка" || bad "start_daemons не зовёт z2k_preflight_v6_gate"

# --- 2. Цепочки и очередь DNS ----------------------------------------------------
FUNCS="$TMP/funcs.sh"
{ sed -n '/^Z2K_GVSUB_BIN=/,/^Z2K_GVSUB_STATUS=/p' "$S99"
  for f in z2k_gvsub_dns_rule z2k_gvsub_fw_start z2k_gvsub_fw_stop z2k_gvsub_enabled z2k_preflight_v6_gate; do fn "$f"; done
} > "$FUNCS"

fw_calls() { # $1 — DISABLE_IPV6, $2 — 1: служба запущена
    ( . "$FUNCS"
      CALLS="$TMP/calls"; : > "$CALLS"
      DISABLE_IPV6="$1"
      # $3 — 1: цепочка уже есть и крючок первый (повторный start_fw хука NDM)
      ipt() { echo "$@" >> "$CALLS"; shift
          case "$*" in
              *" -N "*) [ "$EXISTS" = 1 ] && return 1 ;;
              *"-S FORWARD"*) [ "$EXISTS" = 1 ] && printf '%s\n' "-P FORWARD ACCEPT" "-A FORWARD -j Z2K_GVSUB_Q" ;;
              *"-S PREROUTING"*) [ "$EXISTS" = 1 ] && printf '%s\n' "-P PREROUTING ACCEPT" "-A PREROUTING -j Z2K_GVSUB" ;;
              *" -C "*|*" -D "*) return 1 ;;
          esac; return 0; }
      EXISTS="$3"
      iptablesw()  { ipt 4 "$@"; }
      ip6tablesw() { ipt 6 "$@"; }
      z2k_gvsub_enabled() { return 0; }
      z2k_insmod_fw() { return 0; }
      kill() { echo "kill $*" >> "$CALLS"; }
      Z2K_GVSUB_PID="$TMP/pid"
      if [ "$2" = 1 ]; then echo 4242 > "$Z2K_GVSUB_PID"; else rm -f "$Z2K_GVSUB_PID"; fi
      z2k_gvsub_fw_start
      cat "$CALLS" )
}
C=$(fw_calls 0 1)
CK=$(fw_calls 0 1 1)
CD=$(fw_calls 0 0 1)
for fam in 4 6; do
    for t in nat mangle; do
        has "$fam -t $t -N Z2K_GVSUB" "$C" && has "$fam -t $t -I PREROUTING 1 -j Z2K_GVSUB" "$C" \
            && ok "IPv$fam $t: цепочка создана и стоит первой" \
            || bad "IPv$fam $t: цепочка не на месте"
        has "$fam -t $t -F Z2K_GVSUB" "$CK" && bad "IPv$fam $t: цепочка живой службы очищена повторным start_fw" \
            || ok "IPv$fam $t: повторный start_fw не снимает подмены живой службы"
        has "$fam -t $t -D PREROUTING" "$CK" && bad "IPv$fam $t: крючок, уже стоящий первым, переставлен" \
            || ok "IPv$fam $t: крючок на месте — не трогается"
        has "$fam -t $t -F Z2K_GVSUB" "$CD" && ok "IPv$fam $t: без службы бесхозные подмены вычищаются" \
            || bad "IPv$fam $t: без службы подмены остались в цепочке"
    done
    for cmd in '-N Z2K_GVSUB_Q' '-I FORWARD 1 -j Z2K_GVSUB_Q'; do
        has "$fam -t filter $cmd" "$C" && ok "IPv$fam start: $cmd" || bad "IPv$fam start: нет $cmd"
    done
    has "$fam -t filter -F Z2K_GVSUB_Q" "$CK" && bad "живой службе очистили filter" || ok "IPv$fam: filter живой службы сохранён"
    has "$fam -t filter -D FORWARD" "$CK" && bad "первый filter hook переставлен" || ok "IPv$fam: первый filter hook сохранён"
    has "$fam -t filter -F Z2K_GVSUB_Q" "$CD" && ok "IPv$fam: бесхозные отказы вычищены" || bad "бесхозные отказы остались"
    has "$fam -t mangle -I OUTPUT 1 ! -o lo -p udp --sport 53 -m string --algo bm --string googlevideo -j NFQUEUE --queue-num 210 --queue-bypass" "$C" \
        && ok "IPv$fam: очередь ответов DNS с --queue-bypass (без службы DNS не ломается)" \
        || bad "IPv$fam: нет очереди ответов DNS"
    has "$fam -t mangle -I OUTPUT 1 ! -o lo -p udp --sport 53 -m string --algo bm --hex-string |016307796f757475626503636f6d00| -j NFQUEUE --queue-num 210 --queue-bypass" "$C" \
        && ok "IPv$fam: очередь DNS c.youtube.com" || bad "IPv$fam: нет очереди DNS c.youtube.com"
    if has "$fam -t mangle -I OUTPUT 1 ! -o lo -p udp --sport 53 -m string --algo bm --hex-string |046776743103636f6d00| -j NFQUEUE --queue-num 210 --queue-bypass" "$C"; then
        ok "IPv$fam: очередь DNS gvt1.com"
    else
        bad "IPv$fam: нет очереди DNS gvt1.com"
    fi
done
has "kill -HUP 4242" "$C" && ok "после пересоздания цепочек служба получает SIGHUP" || bad "служба не узнаёт о пустых цепочках"
has "kill -HUP 4242" "$CK" && ok "повторный start_fw тоже шлёт SIGHUP (строки могла вычистить перестройка)" || bad "повторный start_fw без SIGHUP"
has "kill" "$(fw_calls 0 0)" && bad "SIGHUP без запущенной службы" || ok "нет службы — сигнал не шлётся"
has "6 -t" "$(fw_calls 1 0)" && bad "DISABLE_IPV6=1, а ip6tables тронут" || ok "DISABLE_IPV6=1 — IPv6 не трогаем"

# 10.11.2026: оставшийся REJECT мешал бы QUIC после остановки службы.
fw_stop_calls() {
    ( . "$FUNCS"
      DISABLE_IPV6="$1"
      iptablesw() { echo "4 $*"; return 1; }
      ip6tablesw() { echo "6 $*"; return 1; }
      z2k_gvsub_fw_stop )
}
STOP=$(fw_stop_calls 0)
for fam in 4 6; do
    has "$fam -t mangle -D OUTPUT ! -o lo -p udp --sport 53 -m string --algo bm --hex-string |016307796f757475626503636f6d00|" "$STOP" \
        && ok "IPv$fam stop: очередь c.youtube.com снята" || bad "IPv$fam stop: очередь c.youtube.com осталась"
done
for fam in 4 6; do
    if has "$fam -t mangle -D OUTPUT ! -o lo -p udp --sport 53 -m string --algo bm --hex-string |046776743103636f6d00|" "$STOP"; then
        ok "IPv$fam stop: очередь gvt1.com снята"
    else
        bad "IPv$fam stop: очередь gvt1.com осталась"
    fi
done
for fam in 4 6; do
    for cmd in '-D FORWARD -j Z2K_GVSUB_Q' '-F Z2K_GVSUB_Q' '-X Z2K_GVSUB_Q'; do
        has "$fam -t filter $cmd" "$STOP" && ok "IPv$fam stop: $cmd" || bad "IPv$fam stop не снял $cmd"
    done
done
has '6 -t' "$(fw_stop_calls 1)" && bad 'stop трогает выключенный IPv6' || ok 'stop учитывает DISABLE_IPV6'

# --- 3. Когда служба включается --------------------------------------------------
en() { # $1 — Z2K_GV_SUBST, $2 — FWTYPE, $3 — вывод бинарника
    ( . "$FUNCS"
      printf '#!/bin/sh\necho "%s"\n' "$3" > "$TMP/bin"; chmod +x "$TMP/bin"
      Z2K_GVSUB_BIN="$TMP/bin"; FWTYPE="$2"
      if [ -n "$1" ]; then Z2K_GV_SUBST="$1"; else unset Z2K_GV_SUBST; fi
      z2k_gvsub_enabled && echo on || echo off )
}
[ "$(en "" iptables "gvsub [-queue N]")" = on ] && ok "без ключа включено" || bad "без ключа выключено"
[ "$(en 0 iptables "gvsub [-queue N]")" = off ] && ok "Z2K_GV_SUBST=0 выключает" || bad "Z2K_GV_SUBST=0 не выключает"
[ "$(en "" nftables "gvsub [-queue N]")" = off ] && ok "на nftables не включается" || bad "включается на nftables"
[ "$(en "" iptables "probe classify")" = off ] && ok "старый z2k-detect без gvsub — тихо выключено" || bad "старый бинарник запускается как служба"

# --- 4. Проба на IPv6: снимается только за настоящим NAT --------------------------
gate() { # $1 — DISABLE_IPV6, $2 — вывод ip6tables -t nat -S
    ( . "$FUNCS"
      printf '#!/bin/sh\ncat <<"E"\n%s\nE\n' "$2" > "$TMP/ip6tables"; chmod +x "$TMP/ip6tables"
      PATH="$TMP:$PATH"; DISABLE_IPV6="$1"
      NFQWS2_OPT="--a --lua-desync=z2k_preflight:pieces=6:timeout=4:v6 --lua-desync=circular:x"
      z2k_preflight_v6_gate >/dev/null
      printf '%s' "$NFQWS2_OPT" )
}
KEEN='-A _NDM_POSTROUTING_NETMAP -o ppp0 -m ndmmark --ndmmark 0x0/0x2 -m set ! --match-set _NDM_W6P_ppp0 src -j NETMAP --to 2a03:1ac0:5857:5d0b::/64'
has ":v6" "$(gate 0 "-P POSTROUTING ACCEPT")" && ok "IPv6 без NAT — проба на IPv6 остаётся" || bad "IPv6 без NAT, а v6 снят"
has ":v6" "$(gate 0 "$KEEN")" && ok "штатный NETMAP Keenetic (только чужие префиксы) не считается NAT" || bad "NETMAP Keenetic снял пробу на IPv6"
R=$(gate 0 "-A POSTROUTING -o ppp0 -j MASQUERADE")
has ":v6" "$R" && bad "за MASQUERADE для IPv6 проба осталась" || ok "MASQUERADE для IPv6 — v6 снят"
has "z2k_preflight:pieces=6:timeout=4 --lua-desync=circular:x" "$R" && ok "остальная строка движка не тронута" || bad "строка движка испорчена: $R"
has ":v6" "$(gate 1 "-P POSTROUTING ACCEPT")" && bad "DISABLE_IPV6=1, а v6 остался" || ok "DISABLE_IPV6=1 — v6 снят"

# --- 5. Генератор: v6 в шаге и ключ тумблера переживает пересборку ----------------
. "$ROOT/lib/utils.sh" 2>/dev/null
. "$ROOT/lib/config_official.sh" 2>/dev/null
grep -q 'timeout=4:v6"' "$ROOT/lib/config_official.sh" && ok "шаг пробы собирается с v6" || bad "в шаге пробы нет v6"
_rg="$TMP/regen"; mkdir -p "$_rg"
printf 'ENABLED=1\nZ2K_GV_SUBST=0\n' > "$_rg/config"
( ZAPRET2_DIR="$_rg" create_official_config "$_rg/config" >/dev/null 2>&1 )
grep -q '^Z2K_GV_SUBST=0$' "$_rg/config" && ok "Z2K_GV_SUBST=0 переживает пересборку" || bad "выключение подмены потеряно при пересборке"
printf 'ENABLED=1\n' > "$_rg/config"
( ZAPRET2_DIR="$_rg" create_official_config "$_rg/config" >/dev/null 2>&1 )
grep -q '^Z2K_GV_SUBST=' "$_rg/config" && bad "пересборка записала ключ за человека" || ok "без ключа пересборка его не пишет — действует умолчание"

# --- 6. Панель ------------------------------------------------------------------------
TG=$(awk '/^toggle_gv_subst\(\)/{p=1} p{print} p&&/^}/{exit}' "$ROOT/webpanel/cgi/actions.sh")
if [ -n "$TG" ]; then
    _calls="$TMP/tcalls"; : > "$_calls"
    ( set_flag() { echo "flag:$1=$2" >> "$_calls"; }
      regenerate_config() { echo regen >> "$_calls"; }
      restart_service_if_running() { echo restart >> "$_calls"; }
      CONFIG_FILE=x; eval "$TG"; toggle_gv_subst 0 )
    [ "$(tr '\n' ' ' < "$_calls")" = "flag:Z2K_GV_SUBST=0 restart " ] \
        && ok "тумблер пишет ключ и перезапускает службу (пересборка не нужна)" \
        || bad "тумблер делает не то: $(tr '\n' ' ' < "$_calls")"
else
    bad "в actions.sh нет toggle_gv_subst"
fi
grep -q '/toggle/gv-subst)' "$ROOT/webpanel/cgi/api.sh" && grep -q '"POST /toggle/gv-subst"' "$ROOT/webpanel/cgi/api.sh" \
    && ok "маршрут панели ведёт в тумблер" || bad "в api.sh нет маршрута тумблера"
grep -q 'gv_subst: "gv-subst"' "$ROOT/webpanel/www/js/pages/toggles.js" \
    && ok "страница знает имя тумблера в API" || bad "toggles.js не знает gv-subst"

# --- 7. Доставка бинарника ------------------------------------------------------------
STEPS=$(sh -c ". '$ROOT/lib/release_map.sh' 2>/dev/null
    z2k_steps_for z2k-detect/builds/z2k-detect-linux-arm64 | tr '\n' ' '")
has "refresh-binaries" "$STEPS" && ok "новый z2k-detect доставляется обновлением" || bad "сборка z2k-detect не доставляется: '$STEPS'"

# --- 8. Удаление z2k снимает службу и её правила -------------------------------
SW=$(awk '/^_z2k_sweep_our_rules\(\)/{p=1} p{print} p&&/^}/{exit}' "$ROOT/lib/install.sh")
FE=$(awk '/^_z2k_foreign_engine\(\)/{p=1} p{print} p&&/^}/{exit}' "$ROOT/lib/install.sh")
mkdir -p "$TMP/sw"
cat > "$TMP/sw/iptables" <<'STUB'
#!/bin/sh
case "$*" in
  *"-t filter -S FORWARD"*) echo "-A FORWARD -j Z2K_GVSUB_Q" ;;
  *"-t nat -S PREROUTING"*)   echo "-A PREROUTING -j Z2K_GVSUB" ;;
  *"-t mangle -S OUTPUT"*)    echo "-A OUTPUT -p udp -m udp --sport 53 -m string --string \"googlevideo\" --algo bm --to 65535 -j NFQUEUE --queue-num 210 --queue-bypass" ;;
  *" -S "*) ;;
  *) echo "${0##*/} $*" >> "$SWLOG" ;;
esac
exit 0
STUB
cp "$TMP/sw/iptables" "$TMP/sw/ip6tables"; chmod +x "$TMP/sw/iptables" "$TMP/sw/ip6tables"
SWLOG="$TMP/swlog"; : > "$SWLOG"
( PATH="$TMP/sw:$PATH"; export SWLOG; pidof() { return 1; }; eval "$FE"; eval "$SW"
  ZAPRET2_DIR="$TMP/none" _z2k_sweep_our_rules )
SWL=$(cat "$SWLOG")
has "-t nat -D PREROUTING -j Z2K_GVSUB" "$SWL" && ok "удаление снимает крючок цепочки подмены" || bad "крючок Z2K_GVSUB остаётся после удаления"
has "--queue-num 210 --queue-bypass" "$SWL" && ok "удаление снимает очередь ответов DNS" || bad "очередь ответов DNS остаётся после удаления"
has "-t nat -X Z2K_GVSUB" "$SWL" && ok "удаление удаляет сами цепочки" || bad "цепочки Z2K_GVSUB остаются"
grep -q 'z2k-gvsub.pid' "$ROOT/z2k_cleanup.sh" && grep -q 'X Z2K_GVSUB' "$ROOT/z2k_cleanup.sh" \
    && ok "отдельный скрипт удаления тоже снимает службу и цепочки" || bad "z2k_cleanup.sh не знает о службе подмены"

# 10.11.2026: проверяем оба пути удаления, чтобы REJECT не оставался без службы.
check_quic_cleanup() {
    for cmd in '-D FORWARD -j Z2K_GVSUB_Q' '-F Z2K_GVSUB_Q' '-X Z2K_GVSUB_Q'; do
        for fam in iptables ip6tables; do
            has "$fam -w -t filter $cmd" "$1" && ok "$2 $fam: $cmd" || bad "$2 $fam: нет $cmd"
        done
    done
}
: > "$SWLOG"
( PATH="$TMP/sw:$PATH"; export SWLOG; pidof() { return 1; }; eval "$FE"; eval "$SW"
  ZAPRET2_DIR="$TMP/none" _z2k_sweep_our_rules )
check_quic_cleanup "$(cat "$SWLOG")" install
CLEAN=$(awk '/^for fw_tool in iptables ip6tables; do/{p=1} p{print} p&&/^done$/{exit}' "$ROOT/z2k_cleanup.sh")
: > "$SWLOG"
( PATH="$TMP/sw:$PATH"; export SWLOG; log_info() { :; }; eval "$CLEAN" )
check_quic_cleanup "$(cat "$SWLOG")" cleanup

# --- 9. Реальный запуск функции init: путь whitelist доходит отдельным аргументом.
fn z2k_gvsub_start > "$TMP/start.sh"
cat > "$TMP/capture" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$GVSUB_ARGS"
STUB
chmod +x "$TMP/capture"
for root in default "$TMP/custom root"; do
    ( . "$TMP/start.sh"
      z2k_gvsub_enabled() { return 0; }
      z2k_gvsub_stop() { :; }
      Z2K_GVSUB_BIN="$TMP/capture"
      Z2K_GVSUB_QUEUE=210
      Z2K_GVSUB_LOG="$TMP/start.log"
      Z2K_GVSUB_STATUS="$TMP/status"
      Z2K_GVSUB_PID="$TMP/start.pid"
      Z2K_GVSUB_IPS="$TMP/ips"
      DISABLE_IPV6=0
      GVSUB_ARGS="$TMP/args"; export GVSUB_ARGS
      if [ "$root" = default ]; then unset ZAPRET2_DIR; else ZAPRET2_DIR="$root"; fi
      z2k_gvsub_start >/dev/null
      wait "$(cat "$Z2K_GVSUB_PID")" )
    want="$root/lists/whitelist.txt"
    [ "$root" != default ] || want=/opt/zapret2/lists/whitelist.txt
    got=$(awk 'p {print; exit} $0 == "-whitelist" {p=1}' "$TMP/args")
    [ "$got" = "$want" ] && ok "start gvsub передаёт -whitelist: $root" \
        || bad "start gvsub: whitelist '$got', нужен '$want'"
done

# Диагностика исполняет свой настоящий print_gvsub с изолированными путями.
awk '$0 == "print_gvsub() {" {p=1} p{print} p&&/^}/{exit}' "$ROOT/files/z2k-diag.sh" \
    | sed -e "s|/tmp/z2k-gvsub.json|$TMP/diag.json|g" \
          -e "s|/var/run/z2k-gvsub.pid|$TMP/diag.pid|g" \
          -e 's|/opt/sbin/z2k-detect|detect_mock|g' > "$TMP/diag.sh"
# В боевом JSON поле находится на отдельной строке (MarshalIndent).
printf '  "provider_rejected": 2,\n' > "$TMP/diag.json"
DIAG=$( . "$TMP/diag.sh"
    ZAPRET2_DIR="$TMP"
    detect_mock() { echo gvsub; }
    iptables() { return 1; }
    print_gvsub )
has 'кэш провайдера    : отклоняется адресов 2' "$DIAG" \
    && ok 'диагностика показывает число отклоняемых адресов' \
    || bad 'диагностика потеряла число отклоняемых адресов'

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
