#!/bin/sh
# Выполняем настоящий сбор и классификацию; сеть заменена сохранёнными ответами.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S="$ROOT/files/z2k-dns-check.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM
PASS=0; FAIL=0
assert_eq() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '[FAIL] %s: ожидалось %s, получено %s\n' "$1" "$2" "$3"; fi
}
A="$ROOT/webpanel/cgi/actions.sh"
_ow=$(mktemp -d)
_save=$(sed -n '/^dns_check_own_save/,/^}/p' "$A")
printf '1.2.3.4' | sh -c "DNS_CHECK_OWN=$_ow/one.txt; $_save; dns_check_own_save" >/dev/null 2>&1
assert_eq "один сервер без Enter сохраняется" "1.2.3.4" "$(cat "$_ow/one.txt" 2>/dev/null | tr -d '\n')"
printf '1.2.3.4\n8.8.8.8' | sh -c "DNS_CHECK_OWN=$_ow/two.txt; $_save; dns_check_own_save" >/dev/null 2>&1
assert_eq "и оба, когда их два" "2" "$(awk 'END {print NR+0}' "$_ow/two.txt" 2>/dev/null)"

# ── Свои DoT-серверы сохраняются из панели (issue #80) ──────────────────────
#
# z2k-dns-check.sh понимает `dot:ИМЯ`, а сохранение отбрасывало такую строку как
# «не адрес», и каждое «Сохранить» стирало дописанное руками.
_res=$(printf 'https://x.cloudflare-gateway.com/dns-query\ndot:x.cloudflare-gateway.com\ndot:1.1.1.1' \
    | sh -c "DNS_CHECK_OWN=$_ow/dot.txt; $_save; dns_check_own_save" 2>/dev/null)
assert_eq "dot:имя сохраняется рядом с DoH" "dot:x.cloudflare-gateway.com" "$(grep '^dot:x' "$_ow/dot.txt" 2>/dev/null)"
assert_eq "dot:адрес тоже"                  "dot:1.1.1.1" "$(grep '^dot:1' "$_ow/dot.txt" 2>/dev/null)"
assert_eq "отброшенных нет"                 "entries=3 dropped=0" "$_res"
_res=$(printf 'dot:\ndot:localhost\ndot:-x.example.org\ndot:.example.org\ndot:example.org.\ndot:a..example.org\ndot:a|b.example.org\ndot:a;b.example.org' \
    | sh -c "DNS_CHECK_OWN=$_ow/bad.txt; $_save; dns_check_own_save" 2>/dev/null)
assert_eq "кривые dot: отброшены все" "entries=0 dropped=8" "$_res"
assert_eq "и в файл не попали"        "0" "$(awk 'END {print NR+0}' "$_ow/bad.txt" 2>/dev/null)"

run_fixture() (
    Z2K_DNS_LIB=1 . "$S"
    OUT="$SB/$1.json"; OWN_LIST="$SB/absent"
    FIXTURE="$2"; SCENARIO="$1"
    if [ "$SCENARIO" = duplicate_default ]; then
        DEFAULT_SERVERS="$DEFAULT_SERVERS
$(printf '%s\n' "$DEFAULT_SERVERS" | head -1)"
    fi
    current_resolver() { printf '127.0.0.1'; }
    lookup() {
        _lv=$(awk -F'|' -v n="$1" -v d="$2" -v p="$3" '$1==n && $2==d {print (p=="u"?$3:$4)}' "$FIXTURE")
        [ "$_lv" != '!error' ] || return 1
        printf '%s' "$_lv" | tr ',' '\n'
    }
    server_name() {
        printf '%s\n' "$DEFAULT_SERVERS" | awk -F'|' -v s="$1" '$2==s || $3==s {print $1; exit}'
    }
    udp_a() {
        if [ "$1" = "$CANARY" ]; then
            [ "$SCENARIO" = canary ] || return 1
            printf '93.184.216.34\n'; return 0
        fi
        case "$2" in example.com|youtube.com) printf '93.184.216.34\n'; return 0 ;; esac
        if [ "$1" = 127.0.0.1 ]; then lookup router "$2" u
        else lookup "$(server_name "$1")" "$2" u; fi
    }
    doh_wire_a() {
        case "$2" in example.com|youtube.com) printf '93.184.216.34\n'; return 0 ;; esac
        lookup "$(server_name "$1")" "$2" d
    }
    udp_ms() { printf 10; }
    doh_wire_ms() { printf 20; }
    dot_alive() {
        if [ "$SCENARIO" = limited ]; then DOT_MS=15; DOT_ADDRESSES=93.184.216.34; return 0; fi
        return 2
    }
    main >"$SB/$1.stdout" 2>"$SB/$1.log"
)
run_fixture owner "$ROOT/tests/fixtures/dns-check/owner.tsv"
run_fixture user "$ROOT/tests/fixtures/dns-check/user.tsv"
python3 - "$SB" <<'PYTEST'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
o=json.loads((p/'owner.json').read_text()); u=json.loads((p/'user.json').read_text())
assert o['intercept']==1 and o['stub']=='188.186.146.208', o
for s in o['servers']:
    if s.get('current'): assert s['udp']=='works', s
    else:
        assert s['udp']=='hijack', s
        assert s['doh']==('unknown' if s['name']=='NextDNS' else 'works'), s
for s in u['servers']:
    assert s['udp']=='works' and s['doh'] in ('works','none'), s
assert not u['intercept'], u
# В замере отсутствуют контроль, канарейка и DoT; их исходы заданы явно.
# Сценарий пользователя дополняет описанные CDN-пары адресами остальных целей.
obs=o['observations']
x=[x for x in obs if x['server']=='ControlD' and x['domain']=='shikimori.one']
assert len(x)==2 and x[0]['addresses']==x[1]['addresses'], x
assert all(x['comparison']=='overlap' for x in x if x['path']=='u'), x
print('[PASS] оба набора, обратный порядок и согласованность ControlD')
PYTEST
assert_eq "оба набора данных" 0 "$?"
# Мутации одних и тех же сохранённых ответов испытывают настоящий main.
python3 - "$ROOT/tests/fixtures/dns-check/user.tsv" "$SB" <<'PYCASES'
from pathlib import Path
import sys
rows=[x.split('|') for x in Path(sys.argv[1]).read_text().splitlines()]
p=Path(sys.argv[2])
for case in ('timeout','empty','mismatch','nearby','stub_doh','single_operator','one_vote','partial','one_domain','hidden_stub'):
    result=[]
    for n,d,u,h in rows:
        if n=='Cloudflare':
            if case=='timeout': u=h='!error'
            if case=='empty': u=h=''
            if case=='partial' and d=='rutor.info': u='!error'
            if case=='mismatch': u={'rutor.info':'193.46.255.30','flibusta.is':'179.43.150.84','rezka.ag':'179.43.189.163','shikimori.one':'188.114.96.77'}[d]
            if case=='nearby':
                u='193.46.255.30'
                if d=='rutor.info': h='193.46.255.29'
            if case=='single_operator': u='203.0.113.99'; h='203.0.113.99'
            if case=='stub_doh': h='203.0.113.99'
            if case=='hidden_stub': u=u+',203.0.113.99'
            if case=='one_domain' and d=='rutor.info': u='193.46.255.29,193.46.255.29'
        if case=='one_vote':
            if n=='Cloudflare': h='203.0.113.'+str(['rutor.info','flibusta.is','rezka.ag','shikimori.one'].index(d)+10)
            if n=='router': u='203.0.113.'+str(['rutor.info','flibusta.is','rezka.ag','shikimori.one'].index(d)+10)
        result.append('|'.join((n,d,u,h)))
    (p/(case+'.tsv')).write_text('\n'.join(result)+'\n')
PYCASES
for scenario in timeout empty mismatch nearby stub_doh single_operator one_vote partial one_domain hidden_stub; do
    run_fixture "$scenario" "$SB/$scenario.tsv"
done
run_fixture canary "$ROOT/tests/fixtures/dns-check/user.tsv"
run_fixture duplicate_default "$SB/single_operator.tsv"
run_fixture limited "$SB/timeout.tsv"
python3 - "$SB" <<'PYCHECK'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
def load(c): return json.loads((p/(c+'.json')).read_text())
def cf(c): return next(s for s in load(c)['servers'] if s['name']=='Cloudflare')
assert cf('timeout')['udp']=='silent' and cf('timeout')['doh']=='silent'
assert cf('empty')['udp']=='unknown' and cf('empty')['doh']=='unknown'
assert cf('partial')['udp']=='unknown'
assert cf('mismatch')['udp']=='mismatch' and cf('mismatch')['doh']=='works'
assert cf('nearby')['udp']=='spoof', cf('nearby')
assert not load('nearby')['intercept']
assert cf('stub_doh')['doh']=='spoof' and not load('stub_doh')['intercept']
assert cf('single_operator')['udp']=='spoof' and cf('single_operator')['doh']=='spoof'
assert not load('duplicate_default')['intercept'], 'повтор одного оператора не даёт общий перехват'
assert cf('limited')['dot']=='limited' and cf('limited')['verdict']=='unknown', cf('limited')
assert cf('hidden_stub')['udp']=='spoof', cf('hidden_stub')
assert not load('single_operator')['intercept'], 'два протокола одного оператора не дают общий перехват'
assert cf('one_domain')['udp']=='works', cf('one_domain')
r=next(s for s in load('one_vote')['servers'] if s['current'])
assert r['udp']=='mismatch', r
c=load('canary')
assert c['intercept']==1 and c['intercept_by']=='path'
assert next(s for s in c['servers'] if s['current'])['udp']=='works'
for case,outcome in [('timeout','error'),('empty','no_a')]:
    assert all(x['outcome']==outcome for x in load(case)['observations'] if x['server']=='Cloudflare' and x['purpose']=='target')
print('[PASS] ошибки, пустые ответы, расхождения, /24, происхождение и канарейка')
PYCHECK
assert_eq "пограничные сценарии" 0 "$?"

# Прокси-цели: настоящий main, все IP, каждый путь и чужой оператор.
python3 - "$ROOT/tests/fixtures/dns-check/user.tsv" "$SB" <<'PYPROXY'
from pathlib import Path
import sys
base=Path(sys.argv[1]).read_text(); out=Path(sys.argv[2])
names=list(dict.fromkeys(row.split('|')[0] for row in base.splitlines()))
for case in ('xbox','cdn','no_doh','partial_doh','own_only','full_overlap','multi_network','near_ip','proxy_doh'):
    rows=[]
    for name in names:
        for domain,ip,ref in [('api.github.com','87.228.47.198','140.82.121.6'),('www.notion.so','87.228.47.199','162.159.128.61')]:
            u=h=ref
            if name=='router': u=ip
            if case=='cdn':
                u='104.18.1.'+('1' if domain=='api.github.com' else '2')
                h='104.18.9.8,'+u
            if case=='no_doh' or (case=='partial_doh' and domain=='www.notion.so'): h='!error'
            if case=='own_only':
                h=ip if name=='Cloudflare' else '!error'
                if name=='Cloudflare': u=ip
            if case=='full_overlap' and name=='router': u=ip+','+ref
            if case=='multi_network' and name=='router' and domain=='www.notion.so': u+=',203.0.113.1'
            if case=='near_ip': h='87.228.47.200' if domain=='api.github.com' else '87.228.47.201'
            if case=='proxy_doh' and name=='Cloudflare': u=h=ip
            rows.append('|'.join((name,domain,u,h)))
    (out/(case+'.tsv')).write_text(base+'\n'.join(rows)+'\n')
PYPROXY
for scenario in xbox cdn no_doh partial_doh own_only full_overlap multi_network near_ip proxy_doh; do
    run_fixture "$scenario" "$SB/$scenario.tsv"
done
python3 - "$SB" <<'PYPROXYCHECK'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
def load(c): return json.loads((p/(c+'.json')).read_text())
def server(c,name): return next(s for s in load(c)['servers'] if s['name']==name)
def router(c): return next(s for s in load(c)['servers'] if s['current'])
assert router('xbox')['udp']=='proxy' and router('xbox')['verdict']=='spoof'
assert router('xbox')['stub']==0, router('xbox')
assert router('cdn')['udp']=='works', router('cdn')
for case in ('no_doh','partial_doh'):
    assert router(case)['udp']=='unknown' and router(case)['verdict']=='unknown', router(case)
assert server('own_only','Cloudflare')['udp']=='unknown', 'свой DoH не независимый образец'
assert server('own_only','Cloudflare')['doh']=='unknown'
for case in ('full_overlap','multi_network'):
    assert router(case)['udp']!='proxy', router(case)
assert router('near_ip')['udp']=='proxy', 'одинаковый /24 образца не равен совпадению точного IP'
cf=server('proxy_doh','Cloudflare')
assert cf['udp']=='proxy' and cf['doh']=='proxy' and cf['verdict']=='spoof', cf
obs=[x for x in load('xbox')['observations'] if x['purpose']=='proxy']
assert {x['domain'] for x in obs}=={'api.github.com','www.notion.so'}
assert 'свой прокси вместо сайта' in (p/'xbox.log').read_text()
print('[PASS] xbox, CDN, отсутствие DoH, полные множества, точные IP и независимость операторов')
PYPROXYCHECK
assert_eq "обнаружение прокси в main" 0 "$?"

# Транспортные примитивы выполняются без main и без внешней сети.
(
    Z2K_DNS_LIB=1 . "$S"
    nslookup() {
        printf 'Server: 1.1.1.1\nAddress: 1.1.1.1\nName: target\nAddress 1: 192.0.2.4 reverse.name\nAddress: 192.0.2.5\n'
    }
    [ "$(udp_a 1.1.1.1 target | tr '\n' ',')" = '192.0.2.4,192.0.2.5,' ] || exit 1
    nslookup() { printf 'connection timed out'; return 1; }
    udp_a 1.1.1.1 target && exit 1
    nslookup() { printf 'NXDOMAIN'; return 1; }
    udp_a 1.1.1.1 target || exit 1
    nslookup() { printf 'SERVFAIL'; return 1; }
    udp_a 1.1.1.1 target || exit 1
    dig() { printf '%s\n' "$*" > "$SB/dig-args"; printf ';; Query time: 28 msec\n'; }
    [ "$(udp_ms 1.1.1.1 example.com)" = 28 ] || exit 1
    grep -F -q '+tries=1' "$SB/dig-args" || exit 1
    _wire_query example.com > "$SB/query"
)
assert_eq "примитив UDP и POSIX-пакет" 0 "$?"
python3 - "$SB" <<'PYWIRE'
import struct,sys
from pathlib import Path
p=Path(sys.argv[1]); q=b'\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'
assert (p/'query').read_bytes()==q
answer=b'\xab\xcd\x81\x80\x00\x01\x00\x02\x00\x00\x00\x00'+q[12:]
for ip in [b'\xc0\x00\x02\x04',b'\xc0\x00\x02\x05']:
    answer+=b'\xc0\x0c'+struct.pack('!HHIH',1,1,60,4)+ip
(p/'wire').write_bytes(answer)
(p/'no-a').write_bytes(b'\xab\xcd\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00'+q[12:])
(p/'truncated').write_bytes(answer[:-1]); (p/'zero').write_bytes(b'')
(p/'dot-wire').write_bytes(struct.pack('!H',len(answer))+answer)
no_a=(p/'no-a').read_bytes(); (p/'dot-no-a').write_bytes(struct.pack('!H',len(no_a))+no_a)
PYWIRE
assert_eq "пакет запроса соответствует DNS" 0 "$?"
(
    Z2K_DNS_LIB=1 . "$S"
    [ "$(dns_file_a "$SB/wire" | tr '\n' ',')" = '192.0.2.4,192.0.2.5,' ] || exit 1
    dns_file_a "$SB/no-a" || exit 1
    dns_file_a "$SB/truncated" && exit 1
    dns_file_a "$SB/zero" && exit 1
    curl() {
        _out=''
        while [ "$#" -gt 0 ]; do
            case "$1" in -o) shift; _out="$1" ;; esac
            shift
        done
        cp "$SB/wire" "$_out"
        printf '%s' "$HTTP_CODE"
        return "$CURL_RC"
    }
    HTTP_CODE=200; CURL_RC=0
    [ "$(doh_wire_a https://dns.example/dns-query example.com)" = "$(dns_file_a "$SB/wire")" ] || exit 1
    HTTP_CODE=500
    doh_wire_a https://dns.example/dns-query example.com && exit 1
    HTTP_CODE=200; CURL_RC=60
    doh_wire_a https://dns.example/dns-query example.com && exit 1
    exit 0
)
assert_eq "двоичный DoH, DNS-отказ, обрыв, HTTP и TLS ошибки" 0 "$?"

(
    Z2K_DNS_LIB=1 . "$S"
    TIMEOUT=1
    openssl() {
        if [ "$2" = -help ]; then
            [ "$TLS_MODE" != unsupported ] && printf '%s' '-verify_return_error -verify_hostname -verify_ip -servername'
            return 0
        fi
        printf '%s\n' "$*" > "$SB/tls-args"
        if [ "$TLS_MODE" = no_a ]; then cat "$SB/dot-no-a"; return 0; fi
        [ "$TLS_MODE" = valid ] || return 1
        cat "$SB/dot-wire"
    }
    TLS_MODE=unsupported; rc=0; dot_alive dns.example 1.1.1.1 || rc=$?
    [ "$rc" = 2 ] || exit 1
    TLS_MODE=badcert; rc=0; dot_alive dns.example 1.1.1.1 || rc=$?
    [ "$rc" = 1 ] || exit 1
    TLS_MODE=no_a; rc=0; dot_alive dns.example 1.1.1.1 || rc=$?
    [ "$rc" = 3 ] || exit 1
    TLS_MODE=valid; dot_alive dns.example 1.1.1.1 || exit 1
    # Проверяем фактический вызов TLS-клиента, не наличие строки в исходнике.
    for flag in '-verify_return_error' '-verify_hostname dns.example' '-servername dns.example' '-connect 1.1.1.1:853'; do
        grep -F -q -- "$flag" "$SB/tls-args" || exit 1
    done
    dot_alive 1.1.1.1 || exit 1
    grep -F -q -- '-verify_ip 1.1.1.1' "$SB/tls-args" || exit 1
    if grep -F -q -- '-servername' "$SB/tls-args"; then exit 1; fi
)
assert_eq "DoT: проверка цепочки/имени, ошибка сертификата и старый клиент" 0 "$?"

# Текстовая сводка читает тот же JSON и не прячет состояния отдельных путей.
_snapshot=$(sed -n '/^print_dns_check_snapshot()/,/^}/p' "$ROOT/files/z2k-diag.sh")
_text=$(Z2K_DIAG_DNS_CHECK_JSON="$SB/owner.json" dash -c "$_snapshot; print_dns_check_snapshot")
case "$_text" in
    *'без признаков подмены 7'*'недостаточно данных 1'*'TLS не проверен 7'*'перехват 7'*) _rc=0 ;;
    *) _rc=1; printf '%s\n' "$_text" ;;
esac
assert_eq "сводка сохраняет ограничения путей" 0 "$_rc"
_text=$(Z2K_DIAG_DNS_CHECK_JSON="$SB/mismatch.json" dash -c "$_snapshot; print_dns_check_snapshot")
case "$_text" in *'пути: расхождение 1'*) _rc=0 ;; *) _rc=1 ;; esac
assert_eq "сводка показывает расхождение при общем works" 0 "$_rc"

_text=$(Z2K_DIAG_DNS_CHECK_JSON="$SB/xbox.json" dash -c "$_snapshot; print_dns_check_snapshot")
case "$_text" in *'свой прокси вместо сайта 1'*) _rc=0 ;; *) _rc=1 ;; esac
assert_eq "сводка показывает свой прокси вместо сайта" 0 "$_rc"
# Старый снимок не содержит observations и использует прежний verdict=spoof.
printf '%s\n' '{"ts":1,"servers":[{"name":"Резолвер роутера (127.0.0.1)","udp":"proxy","verdict":"spoof"}]}' > "$SB/legacy.json"
_text=$(Z2K_DIAG_DNS_CHECK_JSON="$SB/legacy.json" dash -c "$_snapshot; print_dns_check_snapshot")
case "$_text" in *'подмена 1'*'свой прокси вместо сайта 1'*) _rc=0 ;; *) _rc=1 ;; esac
assert_eq "сводка читает старый снимок proxy" 0 "$_rc"

if command -v node >/dev/null 2>&1; then
    node "$ROOT/tests/test_dns_panel.cjs"
    assert_eq "панель: состояния и группировка" 0 "$?"
else
    printf '[SKIP] панель DNS: нет node; в CI проверяется\n'
fi

# Валидация своих серверов: IPv6 принимается, пустые ссылки, ведущие нули и кривые октеты отвергаются.
_res=$(printf '2606:4700:4700::1111\n2001:4860:4860::8888\n45.90.28.0\ndot:2606:4700:4700::1111\nhttps://[2606:4700:4700::1111]/dns-query' \
    | sh -c "DNS_CHECK_OWN=$_ow/v6.txt; $_save; dns_check_own_save" 2>/dev/null)
assert_eq "валидные IPv6/IPv4 с 0/DoH/DoT сохраняются" "entries=5 dropped=0" "$_res"
_res=$(printf 'https://\nhttps:///dns-query\nhttps://-bad.example.org/q\nhttps://user@dns.example/q\n999.999.999.999\n010.010.010.010\n1.2.3.08\n1.2.3.\ndot:999.999.999.999\n2001::1::2\ngggg::1' \
    | sh -c "DNS_CHECK_OWN=$_ow/bad2.txt; $_save; dns_check_own_save" 2>/dev/null)
assert_eq "пустые https://, ведущие нули, кривые октеты и битые IPv6 отброшены" "entries=0 dropped=11" "$_res"

# IPv6 в resolv.conf (%iface), _resolve_set и dot_alive с -ign_eof / -CAfile.
(
    Z2K_DNS_LIB=1 . "$S"
    printf 'nameserver fe80::1%%br0\n' > "$SB/resolv.v6"
    [ "$(Z2K_DNS_RESOLV_CONF="$SB/resolv.v6" current_resolver)" = "fe80::1" ] || exit 1
    _resolve_set "https://dns.google/dns-query" "2001:4860:4860::8888"
    [ "$_RIP" = "[2001:4860:4860::8888]" ] || exit 1
    printf 'CERT\n' > "$SB/ca.pem"
    TIMEOUT=1
    openssl() {
        if [ "$2" = -help ]; then
            printf '%s' '-verify_return_error -verify_hostname -verify_ip -servername -ign_eof -CAfile'
            return 0
        fi
        printf '%s\n' "$*" > "$SB/tls-v6-args"
        cat "$SB/dot-wire"
    }
    Z2K_DNS_CAFILE="$SB/ca.pem" dot_alive 2606:4700:4700::1111 || exit 1
    for flag in '-ign_eof' "-CAfile $SB/ca.pem" '-verify_ip 2606:4700:4700::1111' '-connect [2606:4700:4700::1111]:853'; do
        grep -F -q -- "$flag" "$SB/tls-v6-args" || exit 1
    done
)
assert_eq "IPv6 резолвер и флаги -ign_eof/-CAfile в dot_alive" 0 "$?"

# CDN-домен: два независимых DoH-оператора дают разные адреса одной /24, роутер получает третий узел той же /24.
python3 - "$ROOT/tests/fixtures/dns-check/user.tsv" "$SB/cdn_s24.tsv" <<'PYCDNS24'
from pathlib import Path
import sys
rows = [x.split('|') for x in Path(sys.argv[1]).read_text().splitlines()]
out = []
for n, d, u, h in rows:
    if d == 'shikimori.one':
        if n == 'Cloudflare': h = '188.114.96.1'
        elif n == 'Google': h = '188.114.96.2'
        elif n == 'router': u = '188.114.96.77'
        else: h = '104.21.55.' + str(len(n))
    out.append('|'.join((n, d, u, h)))
Path(sys.argv[2]).write_text('\n'.join(out) + '\n')
PYCDNS24
run_fixture cdn_s24 "$SB/cdn_s24.tsv"
python3 - "$SB/cdn_s24.json" <<'PYCDNS24CHK'
import json, sys
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text())
r = next(s for s in d['servers'] if s['current'])
assert r['udp'] == 'works', r
obs = [o for o in d['observations'] if o['server'] == r['name'] and o['domain'] == 'shikimori.one']
assert len(obs) == 1 and obs[0]['comparison'] == 'consensus', obs
PYCDNS24CHK
assert_eq "CDN /24 с двумя независимыми эталонами не даёт ложный mismatch" 0 "$?"

# Полноценный DoT через z2k-detect dnsdot + параллельный опрос с сохранением порядка, addr_* и unverified.
cat > "$SB/fake-z2k-detect" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-h" ]; then
    printf 'dnsdot -server HOST\n'
    exit 0
fi
[ "${1:-}" = "dnsdot" ] || exit 1
shift
srv=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -server) shift; srv="$1" ;;
        -addr|-timeout|-cafile) shift ;;
        control:*|target:*|proxy:*|youtube:*) break ;;
    esac
    shift
done
[ "$srv" != "noroot.dot.test" ] || exit 2
printf 'ms\t17\n'
for item in "$@"; do
    p="${item%%:*}"; dom="${item#*:}"
    if [ "$srv" = "spoof.dot.test" ] && [ "$p" = "target" ]; then
        printf 'obs\t%s\t%s\taddresses\t203.0.113.200\n' "$p" "$dom"
    elif [ "$p" = "target" ]; then
        case "$dom" in
            rutor.info) ip=198.51.100.11 ;;
            flibusta.is) ip=198.51.100.12 ;;
            rezka.ag) ip=198.51.100.13 ;;
            *) ip=198.51.100.14 ;;
        esac
        printf 'obs\t%s\t%s\taddresses\t%s\n' "$p" "$dom" "$ip"
    elif [ "$p" = "proxy" ]; then
        case "$dom" in
            api.github.com) printf 'obs\tproxy\t%s\taddresses\t140.82.121.6\n' "$dom" ;;
            *) printf 'obs\tproxy\t%s\taddresses\t162.159.128.61\n' "$dom" ;;
        esac
    else
        printf 'obs\t%s\t%s\taddresses\t93.184.216.34\n' "$p" "$dom"
    fi
done
EOF
chmod +x "$SB/fake-z2k-detect"
(
    Z2K_DNS_LIB=1 . "$S"
    Z2K_DETECT_BIN="$SB/fake-z2k-detect"
    Z2K_DNS_JOBS=4
    OUT="$SB/dot_full.json"
    printf 'dot:spoof.dot.test\ndot:noroot.dot.test\n' > "$SB/own_dot.txt"
    OWN_LIST="$SB/own_dot.txt"
    DEFAULT_SERVERS="Cloudflare|1.1.1.1|https://cloudflare-dns.com/dns-query|one.one.one.one
Google|8.8.8.8|https://dns.google/dns-query|dns.google"
    current_resolver() { printf ''; }
    dot_alive() { return 1; }
    _ans_ip() {
        case "$1" in
            rutor.info) printf '198.51.100.11\n' ;;
            flibusta.is) printf '198.51.100.12\n' ;;
            rezka.ag) printf '198.51.100.13\n' ;;
            shikimori.one) printf '198.51.100.14\n' ;;
            api.github.com) printf '140.82.121.6\n' ;;
            www.notion.so) printf '162.159.128.61\n' ;;
            *) printf '93.184.216.34\n' ;;
        esac
    }
    udp_a() {
        [ "$1" != "$CANARY" ] || return 1
        [ "$1" != "1.1.1.1" ] || usleep 40000 2>/dev/null || :
        _ans_ip "$2"
    }
    doh_wire_a() { _ans_ip "$2"; }
    udp_ms() { printf 11; }
    doh_wire_ms() { printf 22; }
    main >"$SB/dot_full.stdout" 2>"$SB/dot_full.log"
)
python3 - "$SB/dot_full.json" <<'PYDOTFULL'
import json, sys
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text())
names = [s['name'] for s in d['servers']]
assert names == ['Cloudflare', 'Google', 'spoof.dot.test', 'noroot.dot.test'], names
s0 = d['servers'][0]
assert s0['udp'] == 'works' and s0['doh'] == 'works' and s0['dot'] == 'works' and s0['dot_ms'] == 17, s0
assert s0['addr_udp'] == '1.1.1.1' and s0['addr_doh'].startswith('https://') and s0['addr_dot'] == 'one.one.one.one', s0
s2 = d['servers'][2]
assert s2['dot'] == 'spoof' and s2['verdict'] == 'spoof', s2
s3 = d['servers'][3]
assert s3['dot'] == 'unverified' and s3['verdict'] == 'unknown', s3
PYDOTFULL
assert_eq "полный DoT (works/spoof/unverified), реквизиты addr_* и порядок при параллельном опросе" 0 "$?"

# ----------------------------------------------------------------------------
# Набор 10. Подменю [D] Диагностика в lib/menu.sh (Enter -> z2k-diag, 2 -> DNS)
# ----------------------------------------------------------------------------
_mdir="$SB/menu_dir"
mkdir -p "$_mdir"
printf '#!/bin/sh\necho "DIAG_RAN"\n' > "$_mdir/z2k-diag.sh"
printf '#!/bin/sh\necho "{\"ok\":1}"\necho "DNS_SUMMARY_ERR" >&2\n' > "$_mdir/z2k-dns-check.sh"
chmod +x "$_mdir/z2k-diag.sh" "$_mdir/z2k-dns-check.sh"
_m1=$(
    . "$ROOT/lib/utils.sh"
    . "$ROOT/lib/menu.sh"
    ZAPRET2_DIR="$_mdir"
    clear_screen() { :; }; pause() { :; }
    read_input() { eval "$1=\"\""; }
    menu_diag 2>&1
)
_m2=$(
    . "$ROOT/lib/utils.sh"
    . "$ROOT/lib/menu.sh"
    ZAPRET2_DIR="$_mdir"
    clear_screen() { :; }; pause() { :; }
    read_input() { eval "$1=2"; }
    menu_diag 2>&1
)
case "$_m1" in *DIAG_RAN*) _m1_ok=1 ;; *) _m1_ok=0 ;; esac
case "$_m2" in *DNS_SUMMARY_ERR*) _m2_ok=1 ;; *) _m2_ok=0 ;; esac
case "$_m2" in *'{"ok":1}'*) _m2_json=1 ;; *) _m2_json=0 ;; esac
assert_eq "menu_diag по Enter запускает z2k-diag.sh" 1 "$_m1_ok"
assert_eq "menu_diag по 2 запускает z2k-dns-check.sh и скрывает сырой JSON" "1:0" "$_m2_ok:$_m2_json"

rm -rf "$_ow"
printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

