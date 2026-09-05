#!/bin/sh
# tests/test_diag_agh_upstream.sh — приговор про AdGuard Home обязан учитывать,
# остался ли dns-proxy прошивки в цепочке.
#
# ЧТО БЫЛО. Строка считала только записи в `rewrites:` файла AdGuardHome.yaml и
# при нехватке объявляла: «AGH отвечает клиентам мимо ip host, обход
# Instagram/WhatsApp работать не будет». Для схемы «AGH забрал 53-й порт и ходит
# наружу сам» это верно. Но у части людей AGH стоит ПЕРЕД прошивочным прокси:
# слушает 5300, клиентов заворачивает REDIRECT, а `upstream_dns` — 127.0.0.1:53.
# Там пины применяются ниже по цепочке и доезжают до клиента, а рефрешер в
# rewrites не пишет и не должен — значит счёт `0/N` и крик получал КАЖДЫЙ такой
# пользователь на рабочем роутере. Проверено пакетом на живом роутере: ответ AGH
# на www.instagram.com равен записи `ip host`, TTL на несколько секунд меньше —
# кэш ответа прошивочного прокси.
#
# Проверяется ИСПОЛНЕНИЕМ настоящих функций из files/z2k-diag.sh с подставными
# ndmc и AdGuardHome.yaml.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"

cat > "$SB/bin/ndmc" <<'STUB'
#!/bin/sh
cat "$NDM_CONF" 2>/dev/null
STUB
# Состояние AGH к приговору отношения не имеет, но пусть оно будет одинаковым
# на машине разработчика и в CI — иначе набор зависит от того, что там запущено.
cat > "$SB/bin/pidof" <<'STUB'
#!/bin/sh
exit 1
STUB
# LAN-адрес роутера берётся настоящим get_lan_ip, а не подставляется переменной:
# проверять надо ту же цепочку, по которой сводка печатает строку «LAN IP».
cat > "$SB/bin/ip" <<'STUB'
#!/bin/sh
case "$*" in
    *"route get"*) [ -n "$IP_ROUTE_GET" ] && printf '%s\n' "$IP_ROUTE_GET" ;;
    *"addr show"*) [ -n "$IP_ADDR" ] && printf '%s\n' "$IP_ADDR" ;;
esac
exit 0
STUB
chmod +x "$SB/bin/ndmc" "$SB/bin/pidof" "$SB/bin/ip"

DEF_ROUTE='1.1.1.1 via 192.168.100.1 dev eth3 src 192.168.100.10'
DEF_ADDR='2: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0'

# Функции берём настоящие: тест сторожит поведение сводки, а не свою копию кода.
for fn in get_lan_ip insta_pinned agh_upstream_is_local print_agh; do
    awk -v f="$fn" 'index($0, f "() {") == 1, /^\}/' "$ROOT/files/z2k-diag.sh" >> "$SB/blk.sh"
    printf '\n' >> "$SB/blk.sh"
done
printf 'print_agh\n' >> "$SB/blk.sh"
for fn in get_lan_ip insta_pinned agh_upstream_is_local print_agh; do
    grep -q "^${fn}() {" "$SB/blk.sh" || {
        bad "не нашёл $fn в z2k-diag.sh — проверка ослепла"
        printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"; exit 1; }
done

printf 'HOSTS="a.test b.test"\n' > "$SB/z2k-insta-ip-refresh.sh"
PINS='ip host a.test 1.2.3.4
ip host b.test 5.6.7.8'

run() {  # run <yaml> [running-config]
    printf '%s\n' "$1" > "$SB/agh.yaml"
    printf '%s\n' "${2-$PINS}" > "$SB/ndm.conf"
    env PATH="$SB/bin:$PATH" ZAPRET2_DIR="$SB" Z2K_AGH_YAML="$SB/agh.yaml" \
        NDM_CONF="$SB/ndm.conf" \
        IP_ROUTE_GET="${IP_ROUTE_GET-$DEF_ROUTE}" IP_ADDR="${IP_ADDR-$DEF_ADDR}" \
        "${Z2K_TEST_SH:-sh}" "$SB/blk.sh" 2>/dev/null
}

Y_LOCAL='dns:
  upstream_dns:
    - 127.0.0.1:53
  upstream_dns_file: ""
filtering:
  rewrites: []'

Y_EXTERNAL='dns:
  upstream_dns:
    - tls://1.1.1.1
    - https://dns.google/dns-query
  upstream_dns_file: ""
filtering:
  rewrites: []'

Y_MIXED='dns:
  upstream_dns:
    - 127.0.0.1:53
    - 8.8.8.8
  upstream_dns_file: ""
filtering:
  rewrites: []'

Y_SYNCED='dns:
  upstream_dns:
    - tls://1.1.1.1
  upstream_dns_file: ""
filtering:
  rewrites:
    - domain: a.test
      answer: 1.2.3.4
    - domain: b.test
      answer: 5.6.7.8'

Y_FORMS='dns:
  upstream_dns:
    - "[::1]:53"
    - udp://127.0.0.1
    - "[/instagram.com/]127.0.0.1:53"
  upstream_dns_file: ""
filtering:
  rewrites: []'

Y_OTHER_LOCAL='dns:
  upstream_dns:
    - 127.0.0.1:5353
  upstream_dns_file: ""
filtering:
  rewrites: []'

# Протухшая копия пинов в rewrites — то, что делают, «починив» роутер по старой
# формулировке этой же строки. Апстрим при этом локальный, то есть без счёта
# расхождений сводка сказала бы «и это норма».
Y_STALE='dns:
  upstream_dns:
    - 127.0.0.1:53
  upstream_dns_file: ""
filtering:
  rewrites:
    - domain: a.test
      answer: 9.9.9.9'

# Все пины на месте, но рядом лежит лишняя устаревшая запись: AGH отдаст оба
# адреса, и половина соединений уедет в мёртвый.
Y_SYNCED_PLUS_STALE='dns:
  upstream_dns:
    - 127.0.0.1:53
  upstream_dns_file: ""
filtering:
  rewrites:
    - domain: a.test
      answer: 1.2.3.4
    - domain: a.test
      answer: 9.9.9.9
    - domain: b.test
      answer: 5.6.7.8'

# --- 1. Главный случай: AGH перед прошивочным прокси --------------------------
# Это и есть исходный дефект: рабочему роутеру сообщалось «работать не будет».
# Значение на той же строке, что и ключ. AGH так не пишет, но правленые руками
# конфиги — ровно та аудитория, ради которой строка и переписывалась.
Y_INLINE='dns:
  upstream_dns: [127.0.0.1:53]
  upstream_dns_file: ""
filtering:
  rewrites: []'

Y_SCALAR='dns:
  upstream_dns: 127.0.0.1:53
  upstream_dns_file: ""
filtering:
  rewrites: []'

Y_INLINE_EXT='dns:
  upstream_dns: [tls://1.1.1.1, 8.8.8.8]
  upstream_dns_file: ""
filtering:
  rewrites: []'

# Собственный адрес роутера ведёт в тот же прошивочный прокси, что и петля.
Y_LAN='dns:
  upstream_dns:
    - 192.168.1.1:53
  upstream_dns_file: ""
filtering:
  rewrites: []'

Y_LAN_OTHER_PORT='dns:
  upstream_dns:
    - 192.168.1.1:5353
  upstream_dns_file: ""
filtering:
  rewrites: []'

out=$(run "$Y_LOCAL")
case "$out" in
    *'работать не будет'*) bad "ложная тревога: апстрим 127.0.0.1:53, пины доезжают: [$out]" ;;
    *'dns-proxy прошивки'*) ok "петля на 53-й порт распознана как штатная схема" ;;
    *) bad "непонятный вывод: [$out]" ;;
esac
case "$out" in
    *'127.0.0.1:53'*) ok "апстрим показан значением, а не пересказан" ;;
    *) bad "апстрим не показан: [$out]" ;;
esac

# --- 2. Настоящий диагноз сохранён --------------------------------------------
# Ради этого случая строка и добавлялась: AGH ходит наружу сам, ip host мёртв.
out=$(run "$Y_EXTERNAL")
case "$out" in
    *'НЕ синхронизированы'*) ok "AGH с внешними апстримами по-прежнему диагноз" ;;
    *) bad "главный диагноз потерян: [$out]" ;;
esac

# --- 3. Часть апстримов внешняя — это не «всё хорошо» -------------------------
out=$(run "$Y_MIXED")
case "$out" in
    *'через раз'*) ok "смешанные апстримы названы своим именем" ;;
    *) bad "смешанные апстримы разобраны неверно: [$out]" ;;
esac

# --- 4. Пины продублированы в rewrites — прежний зелёный вердикт --------------
out=$(run "$Y_SYNCED")
case "$out" in
    *'НЕ синхронизированы'*) bad "заполненные rewrites объявлены рассинхроном: [$out]" ;;
    *'— синхронизированы'*) ok "заполненные rewrites по-прежнему синхронизированы" ;;
    *) bad "непонятный вывод: [$out]" ;;
esac

# --- 5. Формы записи апстрима, которые встречаются в поле ---------------------
out=$(run "$Y_FORMS")
case "$out" in
    *'работать не будет'*) bad "[::1]:53 / udp:// / [/domain/] не распознаны локальными: [$out]" ;;
    *'dns-proxy прошивки'*) ok "IPv6, схема udp:// и доменный селектор разобраны" ;;
    *) bad "непонятный вывод: [$out]" ;;
esac

# --- 6. Локальный, но ЧУЖОЙ резолвер — не наш случай --------------------------
# 127.0.0.1:5353 — это dnscrypt-proxy или stubby, ip host они не применяют.
# Ослабить проверку до «любой loopback» значило бы заменить одну ложь другой.
out=$(run "$Y_OTHER_LOCAL")
case "$out" in
    *'НЕ синхронизированы'*) ok "чужой локальный резолвер за прошивочный прокси не выдаётся" ;;
    *) bad "127.0.0.1:5353 ошибочно принят за dns-proxy прошивки: [$out]" ;;
esac

# --- 7. Протухшие rewrites сильнее апстрима — это поломка, а не «норма» -------
# Без этой проверки правка, глушащая ложную тревогу, открыла бы ложное «всё
# хорошо»: rewrites применяются ДО апстрима, и клиент получит адрес из них.
out=$(run "$Y_STALE")
case "$out" in
    *'норма'*) bad "протухшая запись в rewrites объявлена нормой: [$out]" ;;
    *'расходятся с ip host'*) ok "rewrites с чужим адресом при локальном апстриме — диагноз" ;;
    *) bad "непонятный вывод: [$out]" ;;
esac

# --- 8. Лишняя устаревшая запись поверх полного набора ------------------------
out=$(run "$Y_SYNCED_PLUS_STALE")
case "$out" in
    *'— синхронизированы'*) bad "лишняя устаревшая запись не замечена: [$out]" ;;
    *'расходятся с ip host'*) ok "устаревшая запись рядом с верными не теряется" ;;
    *) bad "непонятный вывод: [$out]" ;;
esac

# --- 9. Значение на строке ключа: inline-массив ------------------------------
# Разбор понимал только блочный список: ключ матчился, а значение с той же
# строки уходило в next — и получалась прежняя ложная тревога.
out=$(run "$Y_INLINE")
case "$out" in
    *'работать не будет'*) bad "inline-массив не разобран: [$out]" ;;
    *'dns-proxy прошивки'*) ok "inline-массив [127.0.0.1:53] разобран" ;;
    *) bad "непонятный вывод: [$out]" ;;
esac

# --- 10. Значение на строке ключа: скаляр ------------------------------------
out=$(run "$Y_SCALAR")
case "$out" in
    *'работать не будет'*) bad "скаляр не разобран: [$out]" ;;
    *'dns-proxy прошивки'*) ok "скаляр upstream_dns: 127.0.0.1:53 разобран" ;;
    *) bad "непонятный вывод: [$out]" ;;
esac

# --- 11. Inline с внешними — настоящий диагноз не потерян --------------------
out=$(run "$Y_INLINE_EXT")
case "$out" in
    *'НЕ синхронизированы'*) ok "inline с внешними апстримами по-прежнему диагноз" ;;
    *) bad "inline с внешними разобран неверно: [$out]" ;;
esac

# --- 12. LAN-адрес роутера — тот же прошивочный прокси -----------------------
out=$(run "$Y_LAN")
case "$out" in
    *'работать не будет'*) bad "192.168.1.1:53 объявлен внешним, хотя это сам роутер: [$out]" ;;
    *'dns-proxy прошивки'*) ok "LAN-адрес роутера распознан через get_lan_ip" ;;
    *) bad "непонятный вывод: [$out]" ;;
esac

# --- 13. LAN-адрес, но чужой порт — не наш случай ----------------------------
out=$(run "$Y_LAN_OTHER_PORT")
case "$out" in
    *'НЕ синхронизированы'*) ok "192.168.1.1:5353 за прошивочный прокси не выдаётся" ;;
    *) bad "чужой порт на адресе роутера принят за dns-proxy: [$out]" ;;
esac

# --- 14. LAN-адрес не определился — молча считаем внешним --------------------
# get_lan_ip в этом случае отдаёт "unknown", и сравнение не должно совпасть
# ни с чем: соврать «всё хорошо» здесь хуже, чем оставить прежний диагноз.
IP_ADDR=""; IP_ROUTE_GET=""
out=$(run "$Y_LAN")
unset IP_ADDR IP_ROUTE_GET
case "$out" in
    *'НЕ синхронизированы'*) ok "без известного LAN-адреса апстрим считается внешним" ;;
    *) bad "неизвестный LAN-адрес дал ложное «всё хорошо»: [$out]" ;;
esac

# --- 15. Записей ip host нет — сверять нечего ---------------------------------
out=$(run "$Y_LOCAL" "")
case "$out" in
    *'сверять нечего'*) ok "пустой ip host не объявляется поломкой" ;;
    *) bad "пустой ip host разобран неверно: [$out]" ;;
esac

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
