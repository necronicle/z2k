#!/bin/sh
# tests/test_stop_without_killall.sh — стоп службы добивает nfqws2 без
# PID-файла, даже когда в системе нет killall/pidof; пропавшие ссылки busybox
# возвращаются.
#
# Дефект (issue #82, 09.11.2026): последний рубеж стопа был
# `killall nfqws2 2>/dev/null`. У части людей ссылки busybox в /opt/bin
# потеряны (killall, awk), и строка молча ничего не делала. Демон-сирота
# держал очередь, новый запуск падал с nfq_create_queue(): Operation not
# permitted, автообновление откатывалось. Исполняются настоящие функции
# files/S99zapret2.new, z2k.sh и lib/utils.sh. POSIX sh.

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
INIT="$ROOT/files/S99zapret2.new"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

. "$ROOT/tests/lib/common.sh"

TMP="${TMPDIR:-/tmp}/z2k-nokillall.$$"
mkdir -p "$TMP"
PIDS=""
cleanup() {
    for _p in $PIDS; do kill -9 "$_p" 2>/dev/null; done
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fn() { # файл имя — функция в стиле «имя()\n{» или «имя() {»
    awk -v fn="$2" '
        $0 == fn "()" || $0 == fn "() {" { p = 1 }
        p { print }
        p && /^}/ { exit }
    ' "$1"
}
for f in z2k_fracsleep_avail z2k_pid_running z2k_wait_gone z2k_pids_by_comm \
         stop_daemon_by_pidfile stop_all_nfqws; do
    fn "$INIT" "$f"
done > "$TMP/init.sh"
grep -q '^stop_all_nfqws()' "$TMP/init.sh" || bad "stop_all_nfqws не найден"

# Отвязанный процесс (внук, усыновлён init) — после kill не висит зомби.
spawn() { sh -c 'sleep 300 >/dev/null 2>&1 & echo $!'; }
alive() { kill -0 "$1" 2>/dev/null; }

# Поддельный /proc: имена как у ядра в comm.
P="$TMP/proc"; RUN="$TMP/run"; mkdir -p "$P" "$RUN"
ORPH1=$(spawn); ORPH2=$(spawn); WITHPID=$(spawn); OTHER=$(spawn)
PIDS="$ORPH1 $ORPH2 $WITHPID $OTHER"
for p in $ORPH1 $ORPH2 $WITHPID; do mkdir -p "$P/$p"; echo nfqws2 > "$P/$p/comm"; done
mkdir -p "$P/$OTHER"; echo dropbear > "$P/$OTHER/comm"
mkdir -p "$P/99999999"   # процесс исчез между листингом и чтением comm
echo "$WITHPID" > "$RUN/nfqws2_1.pid"

# killall и pidof нет: на их месте заглушки, которые ничего не делают.
mkdir -p "$TMP/bin"
for c in killall pidof; do printf '#!/bin/sh\nexit 127\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"; done

OUT=$( PATH="$TMP/bin:$PATH"; . "$TMP/init.sh"
       PIDDIR="$RUN"; Z2K_PROC="$P"; stop_all_nfqws ) 2>&1
alive "$WITHPID" && bad "демон с PID-файлом жив" || ok "демон с PID-файлом остановлен"
if alive "$ORPH1" || alive "$ORPH2"; then
    bad "сирота без PID-файла жив: $OUT"
else
    ok "сироты без PID-файла остановлены без killall"
fi
alive "$OTHER" && ok "чужой процесс не тронут" || bad "убит чужой процесс"
[ -z "$(ls "$RUN" 2>/dev/null)" ] && ok "PID-файлы убраны" || bad "PID-файлы остались"
case "$OUT" in *"without pidfile"*) ok "остановка сирот пишется в журнал" ;; *) bad "молча: $OUT" ;; esac

# Длинное имя: в comm ядро кладёт первые 15 символов.
mkdir -p "$P/1"; echo "tg-mtproxy-clie" > "$P/1/comm"
GOT=$( . "$TMP/init.sh"; Z2K_PROC="$P"; z2k_pids_by_comm tg-mtproxy-client )
[ "$GOT" = 1 ] && ok "имя длиннее 15 символов находится" || bad "длинное имя: '$GOT'"

# lib/utils.sh: z2k_kill_by_name, тем же способом.
U=$(z2k_extract_fn "$ROOT/lib/utils.sh" z2k_kill_by_name)
[ -n "$U" ] || bad "z2k_kill_by_name не найден"
V=$(spawn); PIDS="$PIDS $V"; mkdir -p "$P/$V"; echo "tg-mtproxy-clie" > "$P/$V/comm"
( eval "$U"; Z2K_PROC="$P"; z2k_kill_by_name tg-mtproxy-client KILL )
i=0; while alive "$V" && [ "$i" -lt 20 ]; do sleep 1; i=$((i+1)); done
alive "$V" && bad "z2k_kill_by_name не убил" || ok "z2k_kill_by_name убивает по comm"
alive "$OTHER" && ok "z2k_kill_by_name не трогает чужих" || bad "z2k_kill_by_name убил чужой"

# В рабочем коде killall больше нет там, где он гасил наши процессы.
LEFT=$(grep -nE '(^|[^_[:alnum:]])killall[[:space:]]' "$INIT" "$ROOT/lib/install.sh" "$ROOT/lib/menu.sh" \
       "$ROOT/z2k_cleanup.sh" "$ROOT/files/z2k-warp.sh" | grep -vE ':[0-9]+:[[:space:]]*#' \
       | grep -vE 'tpws|find killall pidof')
[ -z "$LEFT" ] && ok "killall в путях остановки не осталось" || bad "killall остался: $LEFT"

# --- Ссылки busybox ---------------------------------------------------------
B="$TMP/bb"; OTH="$TMP/other"; mkdir -p "$B" "$OTH"
cat > "$B/busybox" <<'BB'
#!/bin/sh
[ "$1" = --list ] && printf '%s\n' awk sed grep killall pidof foo
BB
chmod +x "$B/busybox"
: > "$B/sed"; chmod +x "$B/sed"           # есть — не трогать
: > "$OTH/killall"                         # есть в другом каталоге — не трогать
ln -s "$B/nowhere" "$B/grep"               # битая ссылка — вернуть
for src in "$INIT" "$ROOT/z2k.sh"; do
    fn "$src" z2k_restore_busybox_links
done > "$TMP/links.sh"
A=$(fn "$INIT" z2k_restore_busybox_links); Bz=$(fn "$ROOT/z2k.sh" z2k_restore_busybox_links)
[ -n "$A" ] && [ "$A" = "$Bz" ] && ok "копии в S99 и z2k.sh совпадают" || bad "копии z2k_restore_busybox_links разошлись"
R=$( eval "$A"; Z2K_BUSYBOX="$B/busybox" Z2K_BIN_DIRS="$B $OTH" z2k_restore_busybox_links | tr '\n' ' ' )
[ "$R" = "awk grep pidof " ] && ok "вернулись ровно недостающие: $R" || bad "восстановлено: '$R'"
[ "$(readlink "$B/awk")" = "$B/busybox" ] && ok "awk ведёт на busybox" || bad "awk: $(readlink "$B/awk")"
[ -L "$B/sed" ] && bad "sed перезаписан" || ok "существующая команда не тронута"
[ -e "$B/killall" ] && bad "killall создан, хотя есть в другом каталоге" || ok "команду из другого каталога не дублируем"
[ -e "$B/foo" ] && bad "создано то, чего нет в нашем списке" || ok "чужие applet'ы не трогаем"
R2=$( eval "$A"; Z2K_BUSYBOX="$B/busybox" Z2K_BIN_DIRS="$B $OTH" z2k_restore_busybox_links )
[ -z "$R2" ] && ok "второй прогон ничего не делает" || bad "второй прогон: $R2"
# Каталог busybox проверяется всегда, даже если список каталогов задан иначе:
# там могут стоять GNU-версии из альтернатив opkg (sort, grep, find…).
echo gnu > "$B/sort"; ln -s "$B/sort-gnu" "$B/stat"; : > "$B/sort-gnu"
cat > "$B/busybox" <<'BB'
#!/bin/sh
[ "$1" = --list ] && printf '%s\n' awk sort stat
BB
R4=$( eval "$A"; Z2K_BUSYBOX="$B/busybox" Z2K_BIN_DIRS="$TMP/empty" z2k_restore_busybox_links )
[ -z "$R4" ] && [ "$(cat "$B/sort")" = gnu ] && [ "$(readlink "$B/stat")" = "$B/sort-gnu" ] \
    && ok "чужие версии в каталоге busybox не перезаписываются" || bad "перезаписано: '$R4'"
R3=$( eval "$A"; Z2K_BUSYBOX="$TMP/none/busybox" z2k_restore_busybox_links; echo "rc=$?" )
[ "$R3" = "rc=0" ] && ok "без busybox тихо выходит" || bad "без busybox: $R3"

# Установщик зовёт восстановление до первой строки с awk.
L1=$(grep -n 'z2k_restore_busybox_links)' "$ROOT/z2k.sh" | head -1 | cut -d: -f1)
L2=$(grep -n 'z2k_detect_entware_arch)' "$ROOT/z2k.sh" | head -1 | cut -d: -f1)
[ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ] && ok "установщик чинит ссылки до первого awk" \
    || bad "порядок в check_environment: $L1 / $L2"

printf '\nИТОГ: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
