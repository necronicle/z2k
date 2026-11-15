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
            ip = ($1 == "Address:" ? $2 : $3)
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print ip
        }'
}

_find_detect() {
    if [ -n "${Z2K_DETECT_BIN:-}" ] && [ -x "${Z2K_DETECT_BIN}" ]; then
        printf '%s' "$Z2K_DETECT_BIN"
        return 0
    fi
    [ "${Z2K_DNS_LIB:-}" != 1 ] || return 1
    for _dd in /opt/sbin /opt/bin "${ZAPRET2_DIR:-/opt/zapret2}"; do
        if [ -x "$_dd/z2k-detect" ]; then
            printf '%s' "$_dd/z2k-detect"
            return 0
        fi
    done
    return 1
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
    if _dbin=$(_find_detect); then
        "$_dbin" dnsms -server "$1" -name "$2" \
            -timeout "${TIMEOUT}s" 2>/dev/null | head -1
    fi
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
    case "$2" in
        *[!0-9.]*)
            case "$2" in
                *:*)
                    case "$2" in *[!0-9A-Fa-f:.]*) return 0 ;; esac
                    _RIP="[$2]" ;;
                *) return 0 ;;
            esac ;;
        *.*.*.*) _RIP="$2" ;;
        *) return 0 ;;
    esac
    _RH=${1#*://}; _RH=${_RH%%/*}
    case "$_RH" in
        \[*\]:*) _RP=${_RH##*\]:}; _RH="${_RH%\]:*}]" ;;
        \[*\]) ;;
        *:*) _RP=${_RH##*:}; _RH=${_RH%%:*} ;;
    esac
}

doh_wire_a() {
    _wq=$(_wire_query "$2" | base64 2>/dev/null | tr -d '=\n' | tr '+/' '-_')
    [ -n "$_wq" ] || return 1
    _wf="${_WDIR:-/tmp}/.z2k-dns-wa.$$"
    _resolve_set "$1" "${3:-}"
    _wc=$(curl -q -g -s -o "$_wf" --max-time "$TIMEOUT" -w '%{http_code}' ${_RIP:+--resolve} ${_RIP:+"$_RH:$_RP:$_RIP"} \
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
    _wf="${_WDIR:-/tmp}/.z2k-dns-wire.$$"
    _resolve_set "$1" "${2:-}"
    _wt=$(curl -q -g -s -o "$_wf" --max-time "$TIMEOUT" -w '%{time_total} %{http_code}' ${_RIP:+--resolve} ${_RIP:+"$_RH:$_RP:$_RIP"} \
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

# DoT (RFC 7858): резервная проверка одного контрольного запроса через openssl,
# когда z2k-detect недоступен или в системе нет корневых сертификатов для него.
dot_alive() {
    DOT_ADDRESSES=""
    command -v openssl >/dev/null 2>&1 || return 2
    _dh=$(openssl s_client -help 2>&1)
    _nameflag=-verify_hostname; _sni="$1"
    case "$1" in
        '') return 2 ;;
        *[!0-9.]*)
            case "$1" in
                *:*)
                    case "$1" in *[!0-9A-Fa-f:.]*) ;; *) _nameflag=-verify_ip; _sni="" ;; esac ;;
            esac ;;
        *) _nameflag=-verify_ip; _sni="" ;;
    esac
    for _flag in -verify_return_error "$_nameflag" -servername; do
        case "$_dh" in *"$_flag"*) ;; *) return 2 ;; esac
    done
    _ieof=""
    case "$_dh" in *-ign_eof*) _ieof=-ign_eof ;; esac
    _cafile=""
    case "$_dh" in
        *-CAfile*)
            for _cand in "${Z2K_DNS_CAFILE:-}" /opt/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt; do
                if [ -n "$_cand" ] && [ -s "$_cand" ]; then _cafile="$_cand"; break; fi
            done ;;
    esac
    _conn="${2:-$1}"
    case "$_conn" in *:*) _conn="[$_conn]:853" ;; *) _conn="$_conn:853" ;; esac
    _df="${_WDIR:-/tmp}/.z2k-dns-dot.$$"
    rm -f "$_df"
    printf '\000\035\253\315\001\000\000\001\000\000\000\000\000\000\007example\003com\000\000\001\000\001' \
        | openssl s_client -quiet ${_ieof:+"$_ieof"} ${_cafile:+-CAfile} ${_cafile:+"$_cafile"} \
            -verify_return_error "$_nameflag" "$1" \
            -connect "$_conn" ${_sni:+-servername} ${_sni:+"$_sni"} >"$_df" 2>/dev/null &
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

# Полный конвейерный опрос DoT по порту 853 через z2k-detect dnsdot: проверяет
# сертификат и опрашивает контроль, целевые, прокси-домены и youtube.com за
# одно TLS-соединение.
dot_batch() {
    DOT_MS=""; DOT_YT=""
    _db_srv="$1"; _db_host="$2"; _db_addr="${3:-}"; _db_op="${4:-}"
    _db_out="${_WDIR:-/tmp}/.z2k-dns-dotb.$$"
    set -- "control:$CONTROL"
    for _d in $TARGETS; do set -- "$@" "target:$_d"; done
    for _d in $PROXY_TARGETS; do set -- "$@" "proxy:$_d"; done
    set -- "$@" "youtube:$YT_DOMAIN"
    "$_dot_bin" dnsdot -server "$_db_host" ${_db_addr:+-addr} ${_db_addr:+"$_db_addr"} -timeout "${TIMEOUT}s" \
        ${Z2K_DNS_CAFILE:+-cafile} ${Z2K_DNS_CAFILE:+"$Z2K_DNS_CAFILE"} "$@" >"$_db_out" 2>/dev/null
    _dbr=$?
    if [ "$_dbr" != 0 ]; then
        rm -f "$_db_out"
        return "$_dbr"
    fi
    while IFS="$(printf '\t')" read -r _kind _p _dom _outc _addrs; do
        case "$_kind" in
            ms) DOT_MS="$_p" ;;
            obs)
                printf '%s\037t\037%s\037%s\037%s\037%s\037%s\n' "$_db_srv" "$_dom" "$_outc" "$_addrs" "$_db_op" "$_p" >> "$_ans"
                [ "$_p" != youtube ] || DOT_YT="$_outc" ;;
        esac
    done < "$_db_out"
    rm -f "$_db_out"
    return 0
}

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
    awk '/^[[:space:]]*nameserver[[:space:]]+/ {
        ip = $2
        sub(/%.*/, "", ip)
        if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || (ip ~ /:/ && ip ~ /^[0-9A-Fa-f:.]+$/)) {
            print ip
            exit
        }
    }' "${Z2K_DNS_RESOLV_CONF:-/etc/resolv.conf}" 2>/dev/null
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
    function s24_of(ip,   o) {
        return split(ip,o,".")==4 ? o[1] "." o[2] "." o[3] : ""
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
                if($2=="d" && $6!="") {
                    if(!votes[$3 SUBSEP ips[i] SUBSEP $6]++) agree[$3 SUBSEP ips[i]]++
                    s24=s24_of(ips[i])
                    if(s24!="" && !svotes[$3 SUBSEP s24 SUBSEP $6]++) sagree[$3 SUBSEP s24]++
                }
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
                    if((path=="u" || path=="t") && ((name SUBSEP "d") in paths)) {
                        if(state[other]=="addresses") {
                            if(overlap(addr[k],addr[other])) cmp="overlap"
                            else if(path=="t" && !stub[key]) {
                                n=split(addr[k],ips,","); m24=0
                                for(i=1;i<=n;i++) {
                                    s24=s24_of(ips[i])
                                    if(s24!="" && sagree[d SUBSEP s24]>=2) m24=1
                                }
                                cmp=m24?"overlap":"different"
                            } else cmp="different"
                            if(cmp=="different") diff++
                        } else missing++
                    } else if(path=="u" || path=="t") {
                        n=split(addr[k],ips,","); matched=0; reference=0
                        for(v in agree) {split(v,a,SUBSEP); if(a[1]==d && agree[v]>=2) reference=1}
                        if(!reference) {
                            for(v in sagree) {split(v,a,SUBSEP); if(a[1]==d && sagree[v]>=2) reference=1}
                        }
                        for(i=1;i<=n;i++) {
                            if(agree[d SUBSEP ips[i]]>=2) matched=1
                            else if(!stub[key]) {
                                s24=s24_of(ips[i])
                                if(s24!="" && sagree[d SUBSEP s24]>=2) matched=1
                            }
                        }
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

_probe_one() {
    _WDIR="$1"; name="$2"; udp="$3"; doh="$4"; dot="$5"
    _ans="$_WDIR/ans"; : > "$_ans"
    _op=""
    # Только встроенные записи имеют известную независимость операторов.
    if printf '%s\n' "$DEFAULT_SERVERS" | grep -F -x -q "$name|$udp|$doh|$dot"; then _op="$name"; fi
    _sip=""
    case "$udp" in
        ''|*[!0-9A-Fa-f:.]*) ;;
        *.*.*.*|*:*) _sip="$udp" ;;
    esac
    ums=""; dms=""; tms=""; st_t=none; st_yt=none; DOT_YT=""
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
        if [ -n "${_dot_bin:-}" ]; then
            dot_batch "$name" "$dot" "$_sip" "$_op" || _tr=$?
            if [ "$_tr" = 0 ]; then
                st_t=classified; tms="$DOT_MS"
            elif [ "$_tr" = 2 ]; then
                st_t=unverified
                printf '%s\037t\037%s\037unverified\037\037%s\037control\n' "$name" "$CONTROL" "$_op" >> "$_ans"
            else
                st_t=silent
                printf '%s\037t\037%s\037error\037\037%s\037control\n' "$name" "$CONTROL" "$_op" >> "$_ans"
            fi
        else
            dot_alive "$dot" "$_sip" || _tr=$?
            case "$_tr" in
                0) st_t=limited; tms="$DOT_MS"; _to=addresses ;;
                2) st_t=unverified; _to=unverified ;;
                3) st_t=unknown; _to=no_a ;;
                *) st_t=silent; _to=error ;;
            esac
            printf '%s\037t\037%s\037%s\037%s\037%s\037control\n' "$name" "$CONTROL" "$_to" "$DOT_ADDRESSES" "$_op" >> "$_ans"
        fi
    fi
    # Ошибка транспорта не означает, что сервис отказал в A-записи.
    if [ -n "$doh" ]; then
        observe "$name" d "$doh" "$YT_DOMAIN" "$_sip" "$_op" youtube
    else _os=error; fi
    if [ "$_os" = error ] && [ -n "$udp" ]; then
        observe "$name" u "$udp" "$YT_DOMAIN" "" "$_op" youtube
    fi
    if [ "$_os" = error ] && [ -n "$DOT_YT" ]; then
        _os="$DOT_YT"
    fi
    case "$_os" in addresses) st_yt=ok ;; no_a) st_yt=empty ;; esac
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
        "$name" "$ums" "$dms" "$st_t" "$tms" "$st_yt" "$udp" "$doh" "$dot" > "$_WDIR/row"
    _dot_log="$st_t"
    [ "$_dot_log" != classified ] || _dot_log=works
    printf '  %-32s опрошен: обычный %s, DoH %s, DoT %s\n' "$name" \
        "$([ -z "$udp" ] && printf '—' || { [ -n "$ums" ] && printf '%s мс' "$ums" || printf 'опрошен'; })" \
        "$([ -z "$doh" ] && printf '—' || { [ -n "$dms" ] && printf '%s мс' "$dms" || printf 'опрошен'; })" \
        "$([ -z "$dot" ] && printf 'не проверялся' || { [ "$st_t" = classified ] && [ -n "$tms" ] && printf '%s мс' "$tms" || _say "$_dot_log"; })" > "$_WDIR/log"
}

main() {
    _work=$(mktemp -d /tmp/.z2k-dns.XXXXXX) || return 1
    _WDIR="$_work"
    _ans="$_work/answers"; _classified="$_work/classified"; _rows="$_work/rows"; _sumlog="$_work/summary"
    : > "$_ans"; : > "$_rows"; : > "$_sumlog"
    _tmp="${OUT}.new.$$"
    trap 'rm -rf "$_work"; rm -f "$_tmp" /tmp/.z2k-dns-wa.$$ /tmp/.z2k-dns-wire.$$ /tmp/.z2k-dns-dot.$$ /tmp/.z2k-dns-dot.$$.dns' EXIT
    trap 'exit 1' INT TERM
    printf 'Проверяю DNS тремя путями: UDP, DoH внутри HTTPS, DoT внутри TLS.\n' >&2
    _dot_bin=""
    if _dbin=$(_find_detect); then
        case "$("$_dbin" -h 2>&1)" in *dnsdot*) _dot_bin="$_dbin" ;; esac
    fi
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
            127.*|::1) CURRENT_ADDR="Резолвер роутера ($_cur)" ;;
            *) CURRENT_ADDR="Ваш DNS ($_cur)" ;;
        esac
        servers="$servers
$CURRENT_ADDR|$_cur||"
    fi
    _jobs="${Z2K_DNS_JOBS:-4}"
    case "$_jobs" in ''|*[!0-9]*|0) _jobs=4 ;; esac
    _idx=0; _running=0
    while IFS='|' read -r name udp doh dot; do
        [ -n "$name" ] || continue
        _idx=$((_idx + 1))
        _sdir="$_work/srv.$_idx"
        mkdir -p "$_sdir"
        _probe_one "$_sdir" "$name" "$udp" "$doh" "$dot" &
        _running=$((_running + 1))
        if [ "$_running" -ge "$_jobs" ]; then
            wait
            _running=0
        fi
    done <<EOF
$servers
EOF
    wait
    _i=1
    while [ "$_i" -le "$_idx" ]; do
        _sdir="$_work/srv.$_i"
        [ -f "$_sdir/ans" ] && cat "$_sdir/ans" >> "$_ans"
        [ -f "$_sdir/row" ] && cat "$_sdir/row" >> "$_rows"
        [ -f "$_sdir/log" ] && cat "$_sdir/log" >&2
        _i=$((_i + 1))
    done
    printf '\nСверка ответов между серверами — итог:\n' >&2
    classify
    onpath=$(awk -F'\037' '$1=="meta" {print $2}' "$_classified")
    if [ -n "$onpath" ]; then intercept=1; intercept_by=path; fi
    awk -F'\037' \
        -v ts="$(date +%s)" \
        -v intercept="$intercept" \
        -v intercept_by="$intercept_by" \
        -v onpath="$onpath" \
        -v cur="$CURRENT_ADDR" \
        -v f_cls="$_classified" \
        -v f_rows="$_rows" \
        -v f_ans="$_ans" \
        -v sumlog="$_sumlog" '
    function jesc(s,   i, c, r) {
        r = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\\" || c == "\"") r = r "\\" c
            else r = r c
        }
        return r
    }
    function jms(s) {
        return (s != "" && s ~ /^[0-9]+$/) ? s : "null"
    }
    function say(st) {
        if (st == "works") return "признаков подмены нет"
        if (st == "proxy") return "свой прокси вместо сайта"
        if (st == "spoof") return "ответ подменён (заглушка)"
        if (st == "hijack") return "перехвачено на пути"
        if (st == "mismatch") return "ответы расходятся"
        if (st == "unknown") return "недостаточно данных"
        if (st == "unverified") return "TLS не проверен"
        if (st == "limited") return "TLS проверен, только контрольный запрос"
        if (st == "silent") return "нет ответа или ошибка транспорта"
        return "не проверялся"
    }
    function eff_sev(st) {
        return st == "proxy" ? "spoof" : st
    }
    FILENAME == f_cls {
        if ($1 == "state") {
            k = $2 SUBSEP $3
            c_st[k] = $4
            c_ok[k] = $5 + 0
            c_tot[k] = $6 + 0
            c_stub[k] = $7 + 0
        } else if ($1 == "comparison") {
            c_cmp[$2 SUBSEP $3 SUBSEP $4] = $5
        }
        next
    }
    FILENAME == f_rows {
        r_n++
        r_name[r_n] = $1; r_ums[r_n] = $2; r_dms[r_n] = $3
        r_stt[r_n] = $4;  r_tms[r_n] = $5; r_yt[r_n] = $6
        r_au[r_n] = $7;   r_ad[r_n] = $8;  r_at[r_n] = $9
        next
    }
    FILENAME == f_ans {
        o_n++
        o_srv[o_n] = $1; o_path[o_n] = $2; o_dom[o_n] = $3
        o_out[o_n] = $4; o_addr[o_n] = $5; o_op[o_n] = $6; o_purp[o_n] = $7
        next
    }
    END {
        printf "{\"ts\":%s,\"intercept\":%s,\"intercept_by\":\"%s\",\"stub\":\"%s\",\"servers\":[", \
            ts, intercept, jesc(intercept_by), jesc(onpath)
        for (i = 1; i <= r_n; i++) {
            name = r_name[i]
            ku = name SUBSEP "u"; kd = name SUBSEP "d"; kt = name SUBSEP "t"
            st_u = (ku in c_st) ? c_st[ku] : "none"
            st_d = (kd in c_st) ? c_st[kd] : "none"
            st_t = r_stt[i]
            if (st_t == "classified") st_t = (kt in c_st) ? c_st[kt] : "silent"

            n_ok = 0; n_all = 0
            if (ku in c_st) { n_ok = c_ok[ku]; n_all = c_tot[ku] }
            else if (kd in c_st) { n_ok = c_ok[kd]; n_all = c_tot[kd] }
            else if (kt in c_st) { n_ok = c_ok[kt]; n_all = c_tot[kt] }
            stub_hits = ((ku in c_stub) ? c_stub[ku] : 0) + ((kd in c_stub) ? c_stub[kd] : 0) + ((kt in c_stub) ? c_stub[kt] : 0)

            verdict = "silent"
            if (st_u ~ /^(unknown|unverified|limited)$/ || st_d ~ /^(unknown|unverified|limited)$/ || st_t ~ /^(unknown|unverified|limited)$/) {
                verdict = "unknown"
            }
            split("mismatch hijack spoof", sevs, " ")
            for (si = 1; si <= 3; si++) {
                sv = sevs[si]
                if (eff_sev(st_u) == sv || eff_sev(st_d) == sv || eff_sev(st_t) == sv) verdict = sv
            }
            if (st_u == "works" || st_d == "works" || st_t == "works") verdict = "works"

            yt_note = (r_yt[i] == "empty") ? ", youtube.com: адреса нет" : ""
            printf "  %s: UDP %s; DoH %s; DoT %s%s\n", name, say(st_u), say(st_d), say(st_t), yt_note >> sumlog

            if (i > 1) printf ","
            is_cur = (name == cur && cur != "") ? 1 : 0
            printf "{\"name\":\"%s\",\"udp\":\"%s\",\"udp_ms\":%s,\"doh\":\"%s\",\"doh_ms\":%s,\"dot\":\"%s\",\"dot_ms\":%s,\"yt\":\"%s\",\"ok\":%d,\"total\":%d,\"stub\":%d,\"current\":%d,\"verdict\":\"%s\",\"addr_udp\":\"%s\",\"addr_doh\":\"%s\",\"addr_dot\":\"%s\"}", \
                jesc(name), st_u, jms(r_ums[i]), st_d, jms(r_dms[i]), st_t, jms(r_tms[i]), \
                r_yt[i], n_ok, n_all, stub_hits, is_cur, verdict, \
                jesc(r_au[i]), jesc(r_ad[i]), jesc(r_at[i])
        }
        printf "],\"observations\":["
        for (j = 1; j <= o_n; j++) {
            if (j > 1) printf ","
            purp = o_purp[j]
            cmp = (purp == "target") ? c_cmp[o_srv[j] SUBSEP o_path[j] SUBSEP o_dom[j]] : purp
            printf "{\"server\":\"%s\",\"operator\":\"%s\",\"path\":\"%s\",\"domain\":\"%s\",\"outcome\":\"%s\",\"purpose\":\"%s\",\"addresses\":[", \
                jesc(o_srv[j]), jesc(o_op[j]), o_path[j], jesc(o_dom[j]), o_out[j], purp
            na = split(o_addr[j], arr, ",")
            first_a = 1
            for (ai = 1; ai <= na; ai++) {
                if (arr[ai] == "") continue
                if (!first_a) printf ","
                first_a = 0
                printf "\"%s\"", jesc(arr[ai])
            }
            printf "],\"comparison\":\"%s\"}", jesc(cmp)
        }
        printf "]}\n"
    }' "$_classified" "$_rows" "$_ans" > "$_tmp"
    cat "$_sumlog" >&2
    mv -f "$_tmp" "$OUT"
    printf '\nГотово.\n' >&2
    cat "$OUT"
}

# Подключение в тестах без сетевого запуска.
[ "${Z2K_DNS_LIB:-}" = 1 ] || main "$@"
