#!/bin/sh
# tests/test_insta_refresh_cert_mismatch.sh — имя, которое не покрыто
# сертификатом, тоже обязано обновляться.
#
# ПОЛЕ 16.09.2026. Два человека прислали свои `ip host`, и у обоих на
# instagram.c10r.instagram.com стоял один и тот же адрес 157.240.214.63 —
# прошитый установкой и к тому времени мёртвый (с узла не отвечает ни ICMP, ни
# TCP 80/443). На остальных шести именах у них жили свежие 57.144.x, то есть
# рефреш работал и просто обходил это имя стороной.
#
# ПРИЧИНА. Сертификат Meta на этих узлах выписан на *.instagram.com, а
# звёздочка закрывает ровно одну метку: instagram.c10r.instagram.com (две метки
# перед apex) под неё не попадает. Рукопожатие проходит, но curl без -k отдаёт
# 000, проба считала адрес мёртвым, и filter_alive честно оставлял прежнюю
# запись. Прежняя была дохлой — и такой оставалась на каждом роутере навсегда.
#
# Пин мёртвого адреса ХУЖЕ отсутствия пина: своим резолвом человек получил бы
# живой узел, а так упирается в чёрную дыру.
#
# Здесь исполняется настоящий z2k-insta-ip-refresh.sh на подставных ndmc/curl,
# которые воспроизводят именно это поведение сети: без -k имя c10r отвечает
# 000, с -k — 404; мёртвый адрес молчит в любом случае.
#
# POSIX sh.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
R="$ROOT/files/z2k-insta-ip-refresh.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

[ -f "$R" ] || { printf '[FAIL] нет %s\n' "$R"; exit 1; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/instacert.XXXXXX") || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/z2k/lists"
cp "$ROOT/files/lists/meta-ranges.txt" "$SB/z2k/lists/meta-ranges.txt"

DEAD=157.240.214.63   # то, что стоит у людей с установки
LIVE1=57.144.222.192  # то, что отдаёт резолвер сейчас
LIVE2=57.144.248.192

# --- подставной ndmc: держит состояние записей в файле ------------------------
cat > "$SB/bin/ndmc" <<EOF
#!/bin/sh
_cmd=""
while [ \$# -gt 0 ]; do [ "\$1" = "-c" ] && { shift; _cmd="\$1"; }; shift; done
case "\$_cmd" in
    "show running-config") cat "$SB/records" ;;
    "no ip host "*)
        _rec="\${_cmd#no }"
        # grep -v без совпадений даёт код 1 — на && строка бы не удалилась
        grep -vF "\$_rec" "$SB/records" > "$SB/records.new" 2>/dev/null
        mv "$SB/records.new" "$SB/records"
        echo "\$_cmd" >> "$SB/ndmc.log" ;;
    *) echo "\$_cmd" >> "$SB/ndmc.log"
       case "\$_cmd" in "ip host "*) echo "\$_cmd" >> "$SB/records" ;; esac ;;
esac
exit 0
EOF

cat > "$SB/bin/openssl" <<'EOF'
#!/bin/sh
cat >/dev/null; echo "(stdin)= 00ff"
EOF

# --- подставной curl: сеть, как она замерена ---------------------------------
cat > "$SB/bin/curl" <<EOF
#!/bin/sh
case "\$*" in
    */resolve*)
        printf '%s' '{"results":{"instagram.c10r.instagram.com":["$LIVE1","$LIVE2"]}}'
        exit 0 ;;
esac
_k=0; _res=""; _prev=""; _out=""
for _a in "\$@"; do
    [ "\$_a" = "-k" ] && _k=1
    [ "\$_prev" = "--resolve" ] && _res="\$_a"
    [ "\$_prev" = "-o" ] && _out="\$_a"
    _prev="\$_a"
done
echo "\$_res k=\$_k" >> "$SB/probe.log"
_host=\${_res%%:*}; _ip=\${_res##*:}
case "\$_ip" in
    $DEAD) printf '000'; exit 0 ;;                 # мёртвый адрес: TCP не встаёт
esac
case "\$_host" in
    instagram.c10r.instagram.com)
        # сертификат *.instagram.com не покрывает две метки перед apex
        echo '<title>4xx Client Error</title>' > "\$_out"
        [ "\$_k" = 1 ] && printf '404' || printf '000' ;;
    *) printf '200' ;;
esac
exit 0
EOF
chmod +x "$SB/bin/ndmc" "$SB/bin/openssl" "$SB/bin/curl"

printf 'Z2K_INSTA_DNS=1\nZ2K_RESOLVE_SECRET=test\n' > "$SB/z2k/config"
printf 'ip host instagram.c10r.instagram.com %s\n' "$DEAD" > "$SB/records"
: > "$SB/ndmc.log"; : > "$SB/probe.log"

Z2K_STUB_PATH="$SB/bin" ZAPRET2_DIR="$SB/z2k" CONFIG_FILE="$SB/z2k/config" \
    LOG_FILE="$SB/refresh.log" sh "$R" >/dev/null 2>&1

eq "мёртвая запись снята" "1" \
    "$(grep -c "^no ip host instagram.c10r.instagram.com $DEAD\$" "$SB/ndmc.log")"
eq "живой адрес прописан" "1" \
    "$(grep -c "^ip host instagram.c10r.instagram.com $LIVE1\$" "$SB/ndmc.log")"
eq "в состоянии роутера мёртвого адреса больше нет" "0" \
    "$(grep -c "$DEAD" "$SB/records")"
eq "изменение сохранено в конфигурацию" "1" \
    "$(grep -c '^system configuration save$' "$SB/ndmc.log")"
eq "в журнале нет отказа «ни один не ответил»" "0" \
    "$(grep -c 'ни один из адресов не ответил' "$SB/refresh.log")"

# Проба обязана ходить БЕЗ проверки сертификата — иначе это имя снова замрёт.
eq "проба идёт с -k" "0" "$(grep -c '^instagram.c10r.instagram.com:.*k=0' "$SB/probe.log")"

# --- Различающая сила не потеряна -------------------------------------------
# -k снимает проверку доверия, но не проверку достижимости: адрес, на котором
# не встаёт TCP, обязан остаться отвергнутым, иначе мы начнём пинить мертвечину
# вместо того, чтобы её выбрасывать.
SB2="$SB/dead"; mkdir -p "$SB2/z2k/lists"
cp "$ROOT/files/lists/meta-ranges.txt" "$SB2/z2k/lists/meta-ranges.txt"
printf 'Z2K_INSTA_DNS=1\nZ2K_RESOLVE_SECRET=test\n' > "$SB2/z2k/config"
printf 'ip host instagram.c10r.instagram.com 57.144.240.1\n' > "$SB/records"
: > "$SB/ndmc.log"
cat > "$SB/bin/curl" <<EOF
#!/bin/sh
case "\$*" in
    */resolve*) printf '%s' '{"results":{"instagram.c10r.instagram.com":["$DEAD"]}}'; exit 0 ;;
esac
printf '000'
exit 0
EOF
chmod +x "$SB/bin/curl"
Z2K_STUB_PATH="$SB/bin" ZAPRET2_DIR="$SB2/z2k" CONFIG_FILE="$SB2/z2k/config" \
    LOG_FILE="$SB/refresh2.log" sh "$R" >/dev/null 2>&1
eq "мёртвый адрес не прописывается" "0" \
    "$(grep -c "ip host instagram.c10r.instagram.com $DEAD\$" "$SB/ndmc.log")"
eq "прежняя запись при этом не снесена" "1" \
    "$(grep -c '57.144.240.1' "$SB/records")"

# --- Затравка установки не должна быть мертвечиной ---------------------------
# Адрес из затравки живёт на роутере до первого удачного рефреша, а у части
# людей — годами: именно он и стоял у обоих приславших.
eq "в затравке install.sh мёртвого адреса нет" "0" \
    "$(grep -c "ip host instagram.c10r.instagram.com $DEAD" "$ROOT/lib/install.sh")"
eq "затравка c10r на месте" "1" \
    "$(grep -c 'ip host instagram.c10r.instagram.com [0-9]' "$ROOT/lib/install.sh")"

# Исключение не должно ослаблять TLS остальных проб или работать без ranges.
eval "$(sed -n '/^probe_ip_alive()/,/^}/p' "$R")"
META_RANGES="$SB/z2k/lists/meta-ranges.txt"
PROBE_TIMEOUT=1
probe_dir="$SB"
: > "$probe_dir/body"
curl() { printf '%s\n' "$*" > "$SB/probe-args"; printf '200'; }
probe_ip_alive www.instagram.com "$LIVE1"
case "$(cat "$SB/probe-args")" in *' -k '*) no "обычные имена проверяют сертификат" strict insecure ;; *) ok "обычные имена проверяют сертификат" ;; esac
probe_ip_alive instagram.c10r.instagram.com "$LIVE1"
case "$(cat "$SB/probe-args")" in *' -k '*) ok "c10r с ranges допускает несовпадение сертификата" ;; *) no "c10r exception" insecure strict ;; esac
META_RANGES="$SB/missing-ranges"
probe_ip_alive instagram.c10r.instagram.com "$LIVE1"
case "$(cat "$SB/probe-args")" in *' -k '*) no "без ranges исключение запрещено" strict insecure ;; *) ok "без ranges исключение запрещено" ;; esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
