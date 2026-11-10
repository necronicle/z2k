#!/bin/sh
# Проверка DNS: доступность, согласованность UDP с собственным DoH и заглушки.
# Разные адреса CDN не доказывают подмену. TLS удостоверяет источник ответа,
# но не отсутствие фильтрации самим оператором. Результаты сохраняются в tmpfs.
set -u

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
OUT="${Z2K_DNS_OUT:-/tmp/z2k-dns-check.json}"
TIMEOUT="${Z2K_DNS_TIMEOUT:-5}"
OWN_LIST="${Z2K_DNS_OWN:-$ZAPRET2_DIR/lists/dns-check.txt}"
CURRENT_ADDR=""

# Несвязанные цели для повторов заглушки. shikimori.one оставлен: варианты
# CDN дают только расхождение с собственным DoH, никогда сами по себе spoof.
TARGETS="${Z2K_DNS_TARGETS:-rutor.info flibusta.is rezka.ag shikimori.one}"
# Прокси-цели из реального случая xbox-dns.ru (997c09c1).
PROXY_TARGETS="${Z2K_DNS_PROXY_TARGETS:-api.github.com www.notion.so}"
# Контроль показывает доступность, но не заменяет ответы целевых доменов.
CONTROL="${Z2K_DNS_CONTROL:-example.com}"
# Отдельная мишень: имя, которое человеку нужнее всего.
#
# В поиске подмены оно НЕ участвует, и это осознанно: замер на роутере
# владельца показал, что youtube.com приходит с настоящими адресами Google
# даже по отравленному пути — заглушки там нет, искать нечего.
#
# Проверяется другое: отдаёт ли сервер адрес ВООБЩЕ. Часть резолверов (с
# фильтрацией, семейные, корпоративные) на это имя не отвечает или отвечает
# пустотой — и тогда видео не откроется никаким обходом, потому что клиент не
# узнает, куда идти. Отказ такого рода снаружи выглядит как «интернет есть, а
# ютуб не работает», и найти его иначе нечем.
YT_DOMAIN="${Z2K_DNS_YT:-youtube.com}"
# Канарейка: RFC 5737, TEST-NET-1. DNS там не существует.
CANARY="${Z2K_DNS_CANARY:-192.0.2.1}"

# Серверы по умолчанию: «имя|udp|doh». Пустое поле — протокол не проверяем.
# Поля: имя|udp|doh|dot. Пустое — путь у этого сервера не проверяем.
DEFAULT_SERVERS="Cloudflare|1.1.1.1|https://cloudflare-dns.com/dns-query|one.one.one.one
Google|8.8.8.8|https://dns.google/dns-query|dns.google
Quad9|9.9.9.9|https://dns.quad9.net/dns-query|dns.quad9.net
AdGuard|94.140.14.14|https://dns.adguard-dns.com/dns-query|dns.adguard-dns.com
Яндекс|77.88.8.8|https://common.dot.dns.yandex.net/dns-query|common.dot.dns.yandex.net
NextDNS|45.90.28.0|https://dns.nextdns.io/dns-query|dns.nextdns.io
ControlD|76.76.2.0|https://freedns.controld.com/p0|p0.freedns.controld.com"

# --- примитивы ----------------------------------------------------------------

# udp_a СЕРВЕР ДОМЕН — адреса A через nslookup, по одному в строке.
# Ответ самого резолвера (первые строки Server/Address) отбрасываем: нас
# интересуют только адреса ответа, иначе адрес сервера попал бы в статистику
# повторов и был бы объявлен заглушкой.
udp_a() {
    _ua=$(nslookup "$2" "$1" 2>/dev/null); _ur=$?
    # nslookup может завершиться ошибкой на NXDOMAIN: это ответ без A,
    # в отличие от таймаута. Не выдаём ошибку транспорта за пустой ответ.
    if [ "$_ur" -ne 0 ]; then
        case "$_ua" in *NXDOMAIN*|*SERVFAIL*|*REFUSED*|*NOTIMP*|*FORMERR*|*"No answer"*|*"No data"*) ;; *) return 1 ;; esac
    fi
    printf '%s\n' "$_ua" | awk '
        /^Name:/ { inans = 1; next }
        inans && /^Address/ {
            ip = $3
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print ip
        }'
}

# udp_ms СЕРВЕР — задержка обычного UDP-запроса в миллисекундах, или пусто.
#
# Единственный источник — `dig`: он печатает «;; Query time: N msec» сам,
# измеряя ровно обмен, а не запуск процесса. Пакет bind-dig ставится отдельно и
# есть не у всех — тогда возвращаем пусто, и строка выглядит как раньше.
#
# +tries=1 обязателен: по умолчанию dig повторяет запрос трижды и печатает
# время ПОСЛЕДНЕЙ попытки — на потерянном пакете это выглядело бы как быстрый
# сервер после двух секунд ожидания.
udp_ms() {
    if command -v dig >/dev/null 2>&1; then
        dig +time="$TIMEOUT" +tries=1 +noall +stats @"$1" "$2" A 2>/dev/null \
            | sed -n 's/^;; Query time: \([0-9][0-9]*\) msec.*/\1/p' | head -1
        return 0
    fi
    # БЕЗ dig МЕРЯЕТ НАШ СОБСТВЕННЫЙ БИНАРНИК.
    #
    # Раньше здесь было «нет dig — нет числа», и у половины людей строки
    # «Обычный DNS» стояли без времени, а DoH и DoT рядом — с временем
    # (жалоба 16.09.2026). Пакет bind-dig тянет bind-libs, это 2,4 МБ на флешке
    # ради одного числа, и ставить его за человека мы не будем.
    #
    # Оболочкой это не измерить: дробного sleep у busybox нет, `date +%s%N`
    # печатает literal %N, `nc -u` в их сборке отсутствует. Счётчик usleep с
    # шагом 10 мс, которым меряется DoT, обычный запрос огрубил бы до
    # неразличимости — он укладывается в единицы миллисекунд.
    #
    # z2k-detect уже лежит на каждом роутере (его возит проба блока по объёму),
    # и подкоманда dnsms меряет ровно обмен. Замер на роутере владельца: 26 мс
    # против 28 у dig на том же сервере.
    for _dd in /opt/sbin /opt/bin "${ZAPRET2_DIR:-/opt/zapret2}"; do
        if [ -x "$_dd/z2k-detect" ]; then
            "$_dd/z2k-detect" dnsms -server "$1" -name "$2" \
                -timeout "${TIMEOUT}s" 2>/dev/null | head -1
            return 0
        fi
    done
    return 0
}

# _wire_query ДОМЕН — двоичный DNS-запрос A-записи (RFC 1035 §4.1).
_wire_query() {
    printf '\253\315\001\000\000\001\000\000\000\000\000\000'
    _q="$1"
    while [ -n "$_q" ]; do
        case "$_q" in
            *.*) _lbl="${_q%%.*}"; _q="${_q#*.}" ;;
            *)   _lbl="$_q"; _q="" ;;
        esac
        printf "\\$(printf '%03o' "${#_lbl}")%s" "$_lbl"
    done
    printf '\000\000\001\000\001'
}

# Закрепляем IP DoH, сохраняя имя URL для SNI и проверки сертификата.
# Используется стандартный двоичный DNS over HTTPS, без отключения TLS-проверки.
_resolve_set() {   # _resolve_set URL IP -> _RIP пуст, если адреса нет
    _RIP=""; _RH=""; _RP=443
    [ -n "${2:-}" ] || return 0
    case "$2" in *[!0-9.]*) return 0 ;; esac
    _RH=${1#*://}; _RH=${_RH%%/*}
    case "$_RH" in *:*) _RP=${_RH##*:}; _RH=${_RH%%:*} ;; esac
    _RIP="$2"
}

doh_wire_a() {
    _wq=$(_wire_query "$2" | base64 2>/dev/null | tr -d '=\n' | tr '+/' '-_')
    [ -n "$_wq" ] || return 1
    _wf="/tmp/.z2k-dns-wa.$$"
    _resolve_set "$1" "${3:-}"
    _wc=$(curl -q -s -o "$_wf" --max-time "$TIMEOUT" -w '%{http_code}' ${_RIP:+--resolve} ${_RIP:+"$_RH:$_RP:$_RIP"} \
          -H 'accept: application/dns-message' "$1?dns=$_wq" 2>/dev/null) || { rm -f "$_wf"; return 1; }
    [ "$_wc" = "200" ] || { rm -f "$_wf"; return 1; }
    dns_file_a "$_wf"
    _wr=$?
    rm -f "$_wf"
    return "$_wr"
}

# Разбираем весь DNS-пакет, отвергаем обрыв и чужой формат. Успешный ответ
# без A (включая DNS-отказ) отличается кодом возврата от ошибки транспорта.
dns_file_a() {
    hexdump -v -e '1/1 "%u "' "$1" 2>/dev/null | awk '
    function skipname(p,   len) {
        while (p <= n) {
            len=b[p]
            if (len >= 192) return (p+1 <= n ? p+2 : n+1)
            if (len == 0) return p+1
            if (len > 63) return n+1
            p += len+1
        }
        return n+1
    }
    {
        parsed=1; n=NF; for(i=1;i<=n;i++) b[i]=$i+0
        if(n<12 || b[1]!=171 || b[2]!=205 || b[3]<128 || int(b[3]/2)%2) exit 1
        q=b[5]*256+b[6]; an=b[7]*256+b[8]; p=13
        if(q!=1) exit 1
        p=skipname(p)+4; if(p>n+1) exit 1
        out=""
        for(k=0;k<an;k++) {
            p=skipname(p); if(p+9>n) exit 1
            t=b[p]*256+b[p+1]; c=b[p+2]*256+b[p+3]
            rl=b[p+8]*256+b[p+9]; p+=10
            if(p+rl>n+1) exit 1
            if(t==1 && c==1 && rl==4) out=out b[p] "." b[p+1] "." b[p+2] "." b[p+3] "\n"
            p+=rl
        }
        if(b[4]%16==0) printf "%s",out
    }
    END {if(!parsed) exit 1}'
}

# Задержка контрольного DoH-запроса; успех требует проверенного HTTPS и A.
doh_wire_ms() {
    _wq=$(printf '\253\315\001\000\000\001\000\000\000\000\000\000\007example\003com\000\000\001\000\001' \
          | base64 2>/dev/null | tr -d '=\n' | tr '+/' '-_')
    [ -n "$_wq" ] || return 1
    _wf="/tmp/.z2k-dns-wire.$$"
    _resolve_set "$1" "${2:-}"
    _wt=$(curl -q -s -o "$_wf" --max-time "$TIMEOUT" -w '%{time_total} %{http_code}' ${_RIP:+--resolve} ${_RIP:+"$_RH:$_RP:$_RIP"} \
          -H 'accept: application/dns-message' "$1?dns=$_wq" 2>/dev/null) || { rm -f "$_wf"; return 1; }
    case "$_wt" in
        *" 200") ;;
        *) rm -f "$_wf"; return 1 ;;
    esac
    _ma=$(dns_file_a "$_wf"); _mr=$?
    rm -f "$_wf"
    [ "$_mr" = 0 ] && [ -n "$_ma" ] || return 1
    printf '%s' "${_wt%% *}" | awk '{printf "%d", $1 * 1000}'
}

# DoT (RFC 7858): DNS-фрейм с двухбайтовой длиной внутри проверенного TLS.
# Ожидание ограничено вручную: timeout и дробного sleep у BusyBox может не быть.
# usleep даёт шаг 10 мс; без него время не публикуем.
dot_alive() {
    DOT_ADDRESSES=""
    command -v openssl >/dev/null 2>&1 || return 2
    _dh=$(openssl s_client -help 2>&1)
    _nameflag=-verify_hostname; _sni="$1"
    case "$1" in
        *[!0-9.]*|'') ;;
        *) _nameflag=-verify_ip; _sni="" ;;
    esac
    for _flag in -verify_return_error "$_nameflag" -servername; do
        case "$_dh" in *"$_flag"*) ;; *) return 2 ;; esac
    done
    _df="/tmp/.z2k-dns-dot.$$"
    rm -f "$_df"
    printf '\000\035\253\315\001\000\000\001\000\000\000\000\000\000\007example\003com\000\000\001\000\001' \
        | openssl s_client -quiet -verify_return_error "$_nameflag" "$1" \
            -connect "${2:-$1}:853" ${_sni:+-servername} ${_sni:+"$_sni"} >"$_df" 2>/dev/null &
    _dpid=$!
    _fine=1
    command -v usleep >/dev/null 2>&1 || _fine=0
    _w=0
    if [ "$_fine" = 1 ]; then _lim=$((TIMEOUT * 100)); else _lim="$TIMEOUT"; fi
    while [ "$_w" -lt "$_lim" ]; do
        # Ждём весь фрейм, а не первый байт TCP. Проверка TLS предшествует
        # выдаче прикладных данных s_client благодаря verify_return_error.
        if [ -s "$_df" ]; then
            _complete=$(hexdump -v -e '1/1 "%u "' "$_df" 2>/dev/null | awk '{print (NF>=14 && NF>=2+$1*256+$2)?1:0}')
            [ "$_complete" = 1 ] && break
        fi
        kill -0 "$_dpid" 2>/dev/null || break
        if [ "$_fine" = 1 ]; then usleep 10000; else sleep 1; fi
        _w=$((_w + 1))
    done
    if [ "$_fine" = 1 ]; then DOT_MS=$((_w * 10)); else DOT_MS=""; fi
    kill "$_dpid" 2>/dev/null || :
    wait "$_dpid" 2>/dev/null || :
    # Клиент мог закрыться после последнего опроса и успеть записать ответ.
    _complete=$(hexdump -v -e '1/1 "%u "' "$_df" 2>/dev/null | awk '{print (NF>=14 && NF>=2+$1*256+$2)?1:0}')
    # Проверяем DNS-заголовок и A в полном ответе контрольного запроса.
    dd if="$_df" of="$_df.dns" bs=1 skip=2 2>/dev/null
    _da=$(dns_file_a "$_df.dns"); _dr=$?
    rm -f "$_df" "$_df.dns"
    if [ "$_complete" = 1 ] && [ "$_dr" = 0 ]; then
        DOT_ADDRESSES=$(printf '%s\n' "$_da" | sort -u | tr '\n' ',' | sed 's/,$//')
        [ -n "$_da" ] || return 3
    fi
    [ "$_complete" = 1 ] && [ "$_dr" = 0 ] && [ -n "$_da" ]
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

_say() {
    case "$1" in
        works) printf 'признаков подмены нет' ;;
        proxy) printf 'свой прокси вместо сайта' ;;
        spoof) printf 'ответ подменён (заглушка)' ;;
        hijack) printf 'перехвачено на пути' ;;
        mismatch) printf 'ответы расходятся' ;;
        unknown) printf 'недостаточно данных' ;;
        unverified) printf 'TLS не проверен' ;;
        limited) printf 'TLS проверен, только контрольный запрос' ;;
        silent) printf 'нет ответа или ошибка транспорта' ;;
        *) printf 'не проверялся' ;;
    esac
}

current_resolver() {
    sed -n 's/^nameserver[[:space:]]*\([0-9.]*\).*/\1/p' /etc/resolv.conf 2>/dev/null | head -1
}

# Запись: сервер, путь, домен, исход, множество A, оператор, назначение. Неизвестные
# собственные адреса не считаем независимыми операторами межсерверного сигнала.
observe() {
    _or=0
    if [ "$2" = u ]; then _oa=$(udp_a "$3" "$4") || _or=$?
    else _oa=$(doh_wire_a "$3" "$4" "$5") || _or=$?; fi
    _oa=$(printf '%s\n' "$_oa" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | sort -u | tr '\n' ',' | sed 's/,$//')
    if [ "$_or" != 0 ]; then _os=error; _oa=""
    elif [ -n "$_oa" ]; then _os=addresses
    else _os=no_a; fi
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$1" "$2" "$4" "$_os" "$_oa" "$6" "${7:-target}" >> "$_ans"
}

# Полные множества точных IP. Сравнение с другими операторами — диагностика,
# оно не обвиняет DoH и не расширяет эталон одним голосом. Повтор IP считается
# по разным доменам внутри одного пути; общий перехват — только по UDP разных
# известных операторов. Сохраняем происхождение каждого наблюдения в JSON.
classify() {
    awk -F'\037' -v canary="$intercept" -v cur="$CURRENT_ADDR" -v proxy_targets="$PROXY_TARGETS" '
    function overlap(a,b,   x,y,i,j,n,m) {
        n=split(a,x,","); m=split(b,y,",")
        for(i=1;i<=n;i++) for(j=1;j<=m;j++) if(x[i]!="" && x[i]==y[j]) return 1
        return 0
    }
    BEGIN {
        nproxy=split(proxy_targets,pt,/ +/)
        for(pi=1;pi<=nproxy;pi++) if(pt[pi]!="") proxy_domains[pt[pi]]=1
    }
    $7=="proxy" {
        key=$1 SUBSEP $2
        proxy_addr[key SUBSEP $3]=$5; op[$1]=$6
        if($2=="d" && $4=="addresses" && $6!="") refs[$1 SUBSEP $3]=$5
        next
    }
    $7!="target" {next}
    {
        key=$1 SUBSEP $2; paths[key]=1; domains[$3]=1
        state[key SUBSEP $3]=$4; addr[key SUBSEP $3]=$5; op[$1]=$6
        total[key]++
        if($4!="error") replies[key]++
        if($4=="addresses") {
            count[key]++; n=split($5,ips,",")
            for(i=1;i<=n;i++) {
                k=key SUBSEP ips[i]
                if(!seen[k SUBSEP $3]++) hits[k]++
                if($2=="d" && $6!="" && !votes[$3 SUBSEP ips[i] SUBSEP $6]++) agree[$3 SUBSEP ips[i]]++
            }
        }
    }
    END {
        for(k in hits) if(hits[k]>=2) {
            split(k,f,SUBSEP); key=f[1] SUBSEP f[2]; stub[key]+=hits[k]
            if(f[2]=="u" && op[f[1]]!="" && !orig[f[3] SUBSEP op[f[1]]]++) operators[f[3]]++
        }
        common=""
        for(ip in operators) if(operators[ip]>=2) {
            if(common=="" || ip<common) common=ip
            for(k in hits) {
                split(k,f,SUBSEP)
                if(f[2]=="u" && f[3]==ip && hits[k]>=2) shared[f[1]]=1
            }
        }
        print "meta" FS common
        for(key in paths) {
            split(key,f,SUBSEP); name=f[1]; path=f[2]; diff=0; missing=0
            for(d in domains) {
                k=key SUBSEP d; cmp="unavailable"
                if(state[k]=="addresses") {
                    other=name SUBSEP "d" SUBSEP d
                    if(path=="u" && ((name SUBSEP "d") in paths)) {
                        if(state[other]=="addresses") {
                            cmp=overlap(addr[k],addr[other])?"overlap":"different"
                            if(cmp=="different") diff++
                        } else missing++
                    } else if(path=="u") {
                        n=split(addr[k],ips,","); matched=0; reference=0
                        for(v in agree) {split(v,a,SUBSEP); if(a[1]==d && agree[v]>=2) reference=1}
                        for(i=1;i<=n;i++) if(agree[d SUBSEP ips[i]]>=2) matched=1
                        if(matched) cmp="consensus"
                        else if(reference) {cmp="different"; diff++}
                        else missing++
                    } else cmp="tls"
                } else missing++
                print "comparison" FS name FS path FS d FS cmp
            }
            st="works"
            if(!replies[key]) st="silent"
            else if(count[key]<total[key] || missing) st="unknown"
            if(diff) st="mismatch"
            # Все адреса всех прокси-целей должны лежать в ОДНОМ /24.
            # Совпадение хотя бы одного точного IP с любым чужим проверенным
            # DoH снимает обвинение. Для каждой цели нужен свой DoH-образец.
            net=""; candidate=1; checked=0; matched=0; enough=1
            for(d in proxy_domains) {
                addresses=proxy_addr[key SUBSEP d]
                if(addresses=="") {candidate=0; continue}
                checked++; n=split(addresses,ips,",")
                for(i=1;i<=n;i++) {
                    split(ips[i],oct,"."); subnet=oct[1] "." oct[2] "." oct[3]
                    if(net=="") net=subnet
                    else if(net!=subnet) candidate=0
                }
                reference=0
                for(r in refs) {
                    split(r,a,SUBSEP)
                    if(a[2]!=d || a[1]==name || (op[name]!="" && op[a[1]]==op[name])) continue
                    reference=1
                    if(overlap(addresses,refs[r])) matched=1
                }
                if(!reference) enough=0
            }
            if(candidate && checked>=2 && !matched) st=enough?"proxy":"unknown"
            if(stub[key]) st="spoof"
            # Одна общая заглушка не обвиняет все остальные UDP-пути.
            if(path=="u" && name!=cur && replies[key] && (canary || shared[name])) st="hijack"
            print "state" FS name FS path FS st FS count[key]+0 FS total[key]+0 FS stub[key]+0
        }
    }' "$_ans" > "$_classified"
}

main() {
    _work=$(mktemp -d /tmp/.z2k-dns.XXXXXX) || return 1
    _ans="$_work/answers"; _classified="$_work/classified"; _rows="$_work/rows"
    : > "$_ans"; : > "$_rows"
    _tmp="${OUT}.new.$$"
    trap 'rm -rf "$_work"; rm -f "$_tmp" /tmp/.z2k-dns-wa.$$ /tmp/.z2k-dns-wire.$$ /tmp/.z2k-dns-dot.$$ /tmp/.z2k-dns-dot.$$.dns' EXIT
    trap 'exit 1' INT TERM
    printf 'Проверяю DNS тремя путями: UDP, DoH внутри HTTPS, DoT внутри TLS.\n' >&2
    intercept=0; intercept_by=""
    observe "$CANARY" u "$CANARY" "$CONTROL" "" "" canary
    if [ "$_os" = addresses ]; then intercept=1; intercept_by="path"; fi
    # Совпадение с 127.0.0.1 не локализует перехват: оба запроса могли уйти
    # одному вышестоящему резолверу. Без правил маршрутизации место неизвестно.
    servers="$DEFAULT_SERVERS"
    if [ -s "$OWN_LIST" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(printf '%s' "$line" | tr -d ' \t\r')
            case "$line" in
                ''|'#'*) continue ;;
                https://*) servers="$servers
$line||$line|" ;;
                dot:*) servers="$servers
${line#dot:}|||${line#dot:}" ;;
                *) servers="$servers
$line|$line||" ;;
            esac
        done < "$OWN_LIST"
    fi
    _cur=$(current_resolver); CURRENT_ADDR=""
    if [ -n "$_cur" ]; then
        case "$_cur" in
            127.*) CURRENT_ADDR="Резолвер роутера ($_cur)" ;;
            *) CURRENT_ADDR="Ваш DNS ($_cur)" ;;
        esac
        servers="$servers
$CURRENT_ADDR|$_cur||"
    fi
    printf '%s\n' "$servers" | while IFS='|' read -r name udp doh dot; do
        [ -n "$name" ] || continue
        _op=""
        # Только встроенные записи имеют известную независимость операторов.
        if printf '%s\n' "$DEFAULT_SERVERS" | grep -F -x -q "$name|$udp|$doh|$dot"; then _op="$name"; fi
        _sip=""; case "$udp" in ''|*[!0-9.]*) ;; *) _sip="$udp" ;; esac
        ums=""; dms=""; tms=""; st_t=none; st_yt=none
        for d in $TARGETS; do
            [ -z "$udp" ] || observe "$name" u "$udp" "$d" "" "$_op"
            [ -z "$doh" ] || observe "$name" d "$doh" "$d" "$_sip" "$_op"
        done
        for d in $PROXY_TARGETS; do
            [ -z "$udp" ] || observe "$name" u "$udp" "$d" "" "$_op" proxy
            [ -z "$doh" ] || observe "$name" d "$doh" "$d" "$_sip" "$_op" proxy
        done
        if [ -n "$udp" ]; then
            observe "$name" u "$udp" "$CONTROL" "" "$_op" control
            [ "$_os" != addresses ] || ums=$(udp_ms "$udp" "$CONTROL")
        fi
        if [ -n "$doh" ]; then
            observe "$name" d "$doh" "$CONTROL" "$_sip" "$_op" control
            [ "$_os" != addresses ] || dms=$(doh_wire_ms "$doh" "$_sip") || dms=""
        fi
        if [ -n "$dot" ]; then
            DOT_MS=""; DOT_ADDRESSES=""; _tr=0
            dot_alive "$dot" "$_sip" || _tr=$?
            case "$_tr" in
                0) st_t=limited; tms="$DOT_MS"; _to=addresses ;;
                2) st_t=unverified; _to=unverified ;;
                3) st_t=unknown; _to=no_a ;;
                *) st_t=silent; _to=error ;;
            esac
            printf '%s\037t\037example.com\037%s\037%s\037%s\037control\n' "$name" "$_to" "$DOT_ADDRESSES" "$_op" >> "$_ans"
        fi
        # Ошибка транспорта не означает, что сервис отказал в A-записи.
        if [ -n "$doh" ]; then
            observe "$name" d "$doh" "$YT_DOMAIN" "$_sip" "$_op" youtube
        else _os=error; fi
        if [ "$_os" = error ] && [ -n "$udp" ]; then
            observe "$name" u "$udp" "$YT_DOMAIN" "" "$_op" youtube
        fi
        case "$_os" in addresses) st_yt=ok ;; no_a) st_yt=empty ;; esac
        printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$name" "$ums" "$dms" "$st_t" "$tms" "$st_yt" >> "$_rows"
        printf '  %-32s опрошен: обычный %s, DoH %s, DoT %s\n' "$name" \
            "$([ -z "$udp" ] && printf '—' || { [ -n "$ums" ] && printf '%s мс' "$ums" || printf 'опрошен'; })" \
            "$([ -z "$doh" ] && printf '—' || { [ -n "$dms" ] && printf '%s мс' "$dms" || printf 'опрошен'; })" \
            "$(_say "$st_t")" >&2
    done
    printf '\nСверка ответов между серверами — итог:\n' >&2
    classify
    onpath=$(awk -F'\037' '$1=="meta" {print $2}' "$_classified")
    if [ -n "$onpath" ]; then intercept=1; intercept_by=path; fi
    {
        printf '{"ts":%s,"intercept":%s,"intercept_by":"%s","stub":"%s","servers":[' "$(date +%s)" "$intercept" "$intercept_by" "$onpath"
        first=1
        while IFS="$(printf '\037')" read -r name ums dms st_t tms st_yt; do
            st_u=none; st_d=none; n_ok=0; n_all=0; stub_hits=0
            _states=$(awk -F'\037' -v n="$name" '$1=="state" && $2==n {print $3 "|" $4 "|" $5 "|" $6 "|" $7}' "$_classified")
            while IFS='|' read -r path st count total stub; do
                case "$path" in
                    u) st_u="$st"; n_ok="$count"; n_all="$total" ;;
                    d) st_d="$st" ;;
                esac
                stub_hits=$((stub_hits + ${stub:-0}))
            done <<EOF
$_states
EOF
            verdict=silent
            for st in "$st_u" "$st_d" "$st_t"; do
                case "$st" in unknown|unverified|limited) verdict=unknown ;; esac
            done
            for severity in mismatch hijack spoof; do
                for st in "$st_u" "$st_d"; do
                    [ "$st" != proxy ] || st=spoof
                    [ "$st" != "$severity" ] || verdict="$severity"
                done
            done
            if [ "$st_u" = works ] || [ "$st_d" = works ]; then verdict=works; fi
            _yt=""; [ "$st_yt" != empty ] || _yt=", youtube.com: адреса нет"
            printf '  %s: UDP %s; DoH %s; DoT %s%s\n' "$name" "$(_say "$st_u")" "$(_say "$st_d")" "$(_say "$st_t")" "$_yt" >&2
            [ "$first" = 1 ] || printf ','; first=0
            _is_cur=0; [ "$name" != "$CURRENT_ADDR" ] || _is_cur=1
            case "$ums" in ''|*[!0-9]*) ums=null ;; esac
            case "$dms" in ''|*[!0-9]*) dms=null ;; esac
            case "$tms" in ''|*[!0-9]*) tms=null ;; esac
            printf '{"name":"%s","udp":"%s","udp_ms":%s,"doh":"%s","doh_ms":%s,"dot":"%s","dot_ms":%s,"yt":"%s","ok":%s,"total":%s,"stub":%s,"current":%s,"verdict":"%s"}' \
                "$(json_escape "$name")" "$st_u" "$ums" "$st_d" "$dms" "$st_t" "$tms" "$st_yt" "$n_ok" "$n_all" "$stub_hits" "$_is_cur" "$verdict"
        done < "$_rows"
        printf '],"observations":['
        first=1
        while IFS="$(printf '\037')" read -r name path domain outcome addresses operator purpose; do
            [ "$first" = 1 ] || printf ','; first=0
            comparison=$(awk -F'\037' -v n="$name" -v p="$path" -v d="$domain" '$1=="comparison" && $2==n && $3==p && $4==d {print $5}' "$_classified")
            [ "$purpose" = target ] || comparison="$purpose"
            printf '{"server":"%s","operator":"%s","path":"%s","domain":"%s","outcome":"%s","purpose":"%s","addresses":[' "$(json_escape "$name")" "$(json_escape "$operator")" "$path" "$domain" "$outcome" "$purpose"
            printf '%s' "$addresses" | awk -F, '{for(i=1;i<=NF;i++) {if(i>1)printf ","; printf "\"%s\"",$i}}'
            printf '],"comparison":"%s"}' "$comparison"
        done < "$_ans"
        printf ']}\n'
    } > "$_tmp"
    mv -f "$_tmp" "$OUT"
    printf '\nГотово.\n' >&2
    cat "$OUT"
}

# Подключение в тестах без сетевого запуска.
[ "${Z2K_DNS_LIB:-}" = 1 ] || main "$@"
