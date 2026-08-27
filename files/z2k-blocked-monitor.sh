#!/bin/sh
# z2k-blocked-monitor.sh
# Runtime monitor for likely blocked destinations outside zapret hostlists.
# Writes candidates to separate TCP/UDP files with host/ip, proto and port.

set -u

# PATH ЗАДАЁМ САМИ, И ЭТО НЕ ГИГИЕНА, А УСЛОВИЕ РАБОТОСПОСОБНОСТИ.
#
# Ниже стоит `sh -c '…' _ arg1 … arg12` — запуск tcpdump с двенадцатью
# аргументами. Какой это будет `sh`, решает PATH, а на Keenetic /bin/sh — НЕ
# ash: это NDM Shell Wrapper v1.0.10, и позиционные аргументы `sh -c` он
# ТЕРЯЕТ. Замер на роутере владельца 2026-08-27:
#
#   /bin/sh     -c 'echo [$0] [$1]' _ ААА  →  [/opt/bin/sh] []
#   /opt/bin/sh -c 'echo [$0] [$1]' _ ААА  →  [_] [ААА]
#
# То есть без /opt/bin впереди PATH вся команда захвата собиралась из пустых
# строк. Скрипт запускают руками и из cron, а cron на Entware отдаёт PATH без
# /opt/bin — там это и стреляло. Остальные наши скрипты PATH объявляют, этот
# был единственным без него.
export PATH="${Z2K_STUB_PATH:+$Z2K_STUB_PATH:}/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin"

ZAPRET_BASE="${ZAPRET_BASE:-/opt/zapret2}"
ZAPRET_CONFIG="${ZAPRET_CONFIG:-$ZAPRET_BASE/config}"
CACHE_DIR="${ZAPRET_BASE}/extra_strats/cache/blocked_monitor"
# PID file lives in /tmp (tmpfs), NOT under $CACHE_DIR on flash: a flash pidfile
# survives reboot, and after a reboot the kernel reuses PIDs, so a stale pid
# that happens to be re-allocated to an unrelated process makes running_pid
# report a false "already running". /tmp is wiped on reboot → no stale pid.
PID_FILE="/tmp/z2k-blocked-monitor.pid"
AWK_FILE="${CACHE_DIR}/monitor.awk"
ERR_LOG="${CACHE_DIR}/tcpdump.err.log"
PARSER_ERR_LOG="${CACHE_DIR}/parser.err.log"
ALL_TSV="${CACHE_DIR}/blocked_all.tsv"
TCP_TSV="${CACHE_DIR}/blocked_tcp.tsv"
UDP_TSV="${CACHE_DIR}/blocked_udp.tsv"
IPMAP_TSV="${CACHE_DIR}/ip2host.tsv"
# Потолок на каждый TSV. ~200к строк это порядка 20 МБ — с запасом для разбора
# и заведомо безопасно для флешки. См. trim_tsv() в start_monitor.
MAX_TSV_LINES="${MAX_TSV_LINES:-200000}"

DEFAULT_TCP_PORTS="80,443,2053,2083,2087,2096,8443"
DEFAULT_UDP_PORTS="443"

exists_cmd() {
	command -v "$1" >/dev/null 2>&1
}

find_tcpdump_bin() {
	if exists_cmd tcpdump; then
		command -v tcpdump
		return 0
	fi
	if [ -x /opt/sbin/tcpdump ]; then
		echo /opt/sbin/tcpdump
		return 0
	fi
	if [ -x /opt/bin/tcpdump ]; then
		echo /opt/bin/tcpdump
		return 0
	fi
	return 1
}

choose_capture_iface() {
	# Prefer "any" when supported by local tcpdump build/libpcap.
	if "$1" -D 2>/dev/null | grep -Eq '(^[0-9]+\.)?any([[:space:]]|$)'; then
		echo any
		return 0
	fi

	# Fallback: default route interface.
	if exists_cmd ip; then
		local defif
		defif="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
		if [ -n "$defif" ]; then
			echo "$defif"
			return 0
		fi
	fi

	# Last fallback: first non-loopback interface from ifconfig.
	if exists_cmd ifconfig; then
		local ifc
		ifc="$(ifconfig 2>/dev/null | awk -F: '/^[A-Za-z0-9._-]+:/{print $1}' | grep -v '^lo$' | head -n 1)"
		if [ -n "$ifc" ]; then
			echo "$ifc"
			return 0
		fi
	fi

	# Absolute fallback.
	echo any
}

ensure_dirs() {
	mkdir -p "$CACHE_DIR" || return 1
	chmod 755 "$CACHE_DIR" 2>/dev/null || true
}

init_output_files() {
	[ -f "$ALL_TSV" ] || printf '# ts\thost\tip\tproto\tport\treason\tdetails\n' > "$ALL_TSV"
	[ -f "$TCP_TSV" ] || printf '# ts\thost\tip\tproto\tport\treason\tdetails\n' > "$TCP_TSV"
	[ -f "$UDP_TSV" ] || printf '# ts\thost\tip\tproto\tport\treason\tdetails\n' > "$UDP_TSV"
	[ -f "$IPMAP_TSV" ] || printf '# ts\tip\thost\n' > "$IPMAP_TSV"
	[ -f "$ERR_LOG" ] || : > "$ERR_LOG"
	[ -f "$PARSER_ERR_LOG" ] || : > "$PARSER_ERR_LOG"
	chmod 644 "$ALL_TSV" "$TCP_TSV" "$UDP_TSV" "$IPMAP_TSV" "$ERR_LOG" "$PARSER_ERR_LOG" 2>/dev/null || true
}

collect_ports() {
	# $1: tcp|udp
	local proto="$1"
	[ -f "$ZAPRET_CONFIG" ] || return 0

	grep -o -- "--filter-${proto}=[^[:space:]]*" "$ZAPRET_CONFIG" 2>/dev/null | \
		sed "s/^--filter-${proto}=//" | tr ',' '\n' | \
		awk '
			$0 ~ /^[0-9]+$/ || $0 ~ /^[0-9]+-[0-9]+$/ {
				if (!seen[$0]++) {
					out = out (out ? "," : "") $0
				}
			}
			END { print out }
		'
}

build_proto_expr() {
	# $1: tcp|udp
	# $2: comma-separated ports/ranges
	local proto="$1"
	local ports="$2"
	local expr=""
	local item a b part

	local oldifs="$IFS"
	IFS=','
	set -- $ports
	IFS="$oldifs"

	for item in "$@"; do
		[ -n "$item" ] || continue
		case "$item" in
			*-*)
				a="${item%-*}"
				b="${item#*-}"
				case "$a$b" in
					''|*[!0-9]*)
						continue
						;;
				esac
				part="portrange ${a}-${b}"
				;;
			*)
				case "$item" in
					*[!0-9]*)
						continue
						;;
				esac
				part="port ${item}"
				;;
		esac
		[ -n "$expr" ] && expr="${expr} or "
		expr="${expr}${part}"
	done

	[ -n "$expr" ] && echo "(${proto} and (${expr}))"
}

build_tcpdump_filter() {
	local tcp_ports udp_ports tcp_expr udp_expr filter

	tcp_ports="$(collect_ports tcp)"
	udp_ports="$(collect_ports udp)"

	[ -n "$tcp_ports" ] || tcp_ports="$DEFAULT_TCP_PORTS"
	[ -n "$udp_ports" ] || udp_ports="$DEFAULT_UDP_PORTS"

	tcp_expr="$(build_proto_expr tcp "$tcp_ports")"
	udp_expr="$(build_proto_expr udp "$udp_ports")"

	filter=""
	[ -n "$tcp_expr" ] && filter="$tcp_expr"
	if [ -n "$udp_expr" ]; then
		[ -n "$filter" ] && filter="${filter} or "
		filter="${filter}${udp_expr}"
	fi

	# DNS capture for IP->host mapping.
	[ -n "$filter" ] && filter="${filter} or "
	filter="${filter}(udp and port 53) or (tcp and port 53)"

	echo "$filter"
}

write_awk_parser() {
	cat > "$AWK_FILE" <<'AWK'
# i объявлена в параметрах НАМЕРЕННО: в awk локальные переменные функции — это
# лишние параметры, и без этого `i` была бы глобальной. Все восемь остальных
# функций здесь так и делают, а эта одна — нет. Сегодня безвредно (все циклы по
# `i` завершаются до вызова), но это мина: любой будущий цикл, зовущий
# split_endpoint внутри, молча получил бы затёртый счётчик. Проверено прогоном:
# цикл на три итерации выполнял одну и выходил с i=10.
function split_endpoint(ep, out, s, p, i) {
	s = ep
	gsub(/,/, "", s)
	sub(/:$/, "", s)
	p = 0
	for (i = length(s); i >= 1; i--) {
		if (substr(s, i, 1) == ".") {
			p = i
			break
		}
	}
	if (p == 0) {
		out["ip"] = s
		out["port"] = ""
		return
	}
	out["ip"] = substr(s, 1, p - 1)
	out["port"] = substr(s, p + 1)
}

function is_watched_port(port, mode, item, a, b) {
	if (port == "") return 0
	if (mode == "tcp") {
		for (item in tcp_ports_map) {
			if (item == "") continue
			if (index(item, "-") > 0) {
				split(item, r, "-")
				a = r[1] + 0
				b = r[2] + 0
				if (port + 0 >= a && port + 0 <= b) return 1
			} else if (port + 0 == item + 0) {
				return 1
			}
		}
		return 0
	}
	for (item in udp_ports_map) {
		if (item == "") continue
		if (index(item, "-") > 0) {
			split(item, r2, "-")
			a = r2[1] + 0
			b = r2[2] + 0
			if (port + 0 >= a && port + 0 <= b) return 1
		} else if (port + 0 == item + 0) {
			return 1
		}
	}
	return 0
}

function host_by_ip(ip) {
	if (ip in ip2host && ip2host[ip] != "") return ip2host[ip]
	return ip
}

function emit_block(ts, proto, ip, port, reason, details, key, host, line) {
	host = host_by_ip(ip)
	key = proto "|" host "|" port "|" reason
	if ((key in last_emit_ts) && (ts - last_emit_ts[key] < dedupe_sec)) return
	last_emit_ts[key] = ts

	line = int(ts) "\t" host "\t" ip "\t" proto "\t" port "\t" reason "\t" details
	print line >> all_out
	if (proto == "TCP") {
		print line >> tcp_out
	} else {
		print line >> udp_out
	}
}

function cleanup_tcp(k) {
	delete tcp_first_ts[k]
	delete tcp_syn_count[k]
	delete tcp_ok[k]
	delete tcp_rst[k]
}

function cleanup_udp(k) {
	delete udp_first_ts[k]
	delete udp_out_count[k]
	delete udp_in_count[k]
}

function sweep(ts, k, age, syns, outs, ins, ip, port, a) {
	for (k in tcp_first_ts) {
		age = ts - tcp_first_ts[k]
		if (k in tcp_ok) {
			cleanup_tcp(k)
			continue
		}
		syns = (k in tcp_syn_count) ? tcp_syn_count[k] : 0
		split(k, a, "|")
		ip = a[3]
		port = a[4]

		if ((k in tcp_rst) && age >= 1) {
			emit_block(ts, "TCP", ip, port, "tcp_rst", "rst_from_server")
			cleanup_tcp(k)
			continue
		}
		# ПО ИСТЕЧЕНИИ СРОКА УБИРАЕМ ВСЕГДА, а сообщаем — только если набралось.
		#
		# Раньше условие было одно на двоих: `age >= timeout && syns >= min_syn`.
		# Поток, который просрочился, но не добрал попыток (одна-две SYN вместо
		# трёх), не проходил ни по этой ветке, ни по какой другой — и оставался в
		# памяти НАВСЕГДА. А это самый обычный случай: браузер дёрнул адрес,
		# получил тишину и больше не пробовал. На шумной сети такие ключи копятся
		# всё время работы монитора, на устройстве со 128 МБ.
		if (age >= tcp_timeout) {
			if (syns >= tcp_min_syn) {
				emit_block(ts, "TCP", ip, port, "tcp_no_synack", "syn_retries=" syns)
			}
			cleanup_tcp(k)
		}
	}

	for (k in udp_first_ts) {
		age = ts - udp_first_ts[k]
		outs = (k in udp_out_count) ? udp_out_count[k] : 0
		ins = (k in udp_in_count) ? udp_in_count[k] : 0
		split(k, a, "|")
		ip = a[3]
		port = a[4]

		if (ins > udp_max_in) {
			cleanup_udp(k)
			continue
		}
		# Та же правка, что и для TCP выше: срок вышел — ключ уходит в любом
		# случае, сообщение печатается только при наборе порога.
		if (age >= udp_timeout) {
			if (outs >= udp_min_out && ins <= udp_max_in) {
				emit_block(ts, "UDP", ip, port, "udp_no_reply", "out=" outs ",in=" ins)
			}
			cleanup_udp(k)
		}
	}

	# НЕОТВЕЧЕННЫЕ DNS-ЗАПРОСЫ ТОЖЕ НАДО УБИРАТЬ.
	#
	# dns_query_key_to_host заполняется на каждый запрос, а удаляется только на
	# УСПЕШНОМ сопоставлении ответа. Запрос, оставшийся без ответа — то есть
	# ровно то, что бывает при блокировке по DNS, ради чего инструмент и
	# написан, — не удалялся ничем и никогда. Плюс к этому чтение
	# dns_query_key_to_host[k] для чужого ответа создаёт пустой элемент (в awk
	# обращение к несуществующему ключу его заводит), а `return` по пустому
	# домену происходит ДО delete — так что каждый посторонний DNS-ответ тоже
	# оставлял по ключу.
	for (k in dns_query_ts) {
		if (ts - dns_query_ts[k] >= dns_timeout) {
			delete dns_query_key_to_host[k]
			delete dns_query_ts[k]
			delete dns_query_srv[k]
		}
	}
}

function process_dns_query(ts, src_ip, src_port, srv_ip, payload, txid, domain, k) {
	# ИДЕНТИФИКАТОР БЕРЁМ ВЕДУЩИМИ ЦИФРАМИ, а не «до плюса».
	#
	# Было `sub(/\+.*/, "", txid)` — обрезка по флагу RD. Но флаг печатается
	# только когда бит выставлен: у запроса без рекурсии плюса нет, обрезать
	# нечего, и txid остаётся строкой вида «12346 A? google.com. (27)», которая
	# не проходит проверку на цифры. Такой запрос терялся целиком, и ответ на
	# него потом не с чем было сопоставить. match+substr берёт ровно ведущее
	# число, каким бы ни был хвост, и работает в BusyBox awk.
	txid = payload
	sub(/^[[:space:]]*/, "", txid)
	if (!match(txid, /^[0-9]+/)) return
	txid = substr(txid, RSTART, RLENGTH)

	# Тип записи не только A: AAAA, HTTPS и прочие ходят тем же путём. Раньше
	# ловилось строго « A? », поэтому запрос AAAA не запоминался вовсе, и ответ
	# на него оставался безымянным.
	domain = payload
	if (!match(domain, /[[:space:]][A-Z0-9]+\? /)) return
	domain = substr(domain, RSTART + RLENGTH)
	sub(/[[:space:]].*$/, "", domain)
	gsub(/\.$/, "", domain)
	if (domain == "") return
	k = src_ip "|" src_port "|" txid
	dns_query_key_to_host[k] = domain
	# Адрес резолвера, которому запрос ушёл. Нужен, чтобы ответ от постороннего
	# хоста не принимался за настоящий — см. проверку в process_dns_response.
	dns_query_srv[k] = srv_ip
	# Метка времени — чтобы sweep() мог убрать неотвеченный запрос.
	dns_query_ts[k] = ts
}

function process_dns_response(ts, dst_ip, dst_port, from_ip, payload, txid, k, domain, ip, rest, n) {
	# ТО ЖЕ, ЧТО В ЗАПРОСЕ: идентификатор — это ведущие цифры.
	#
	# Было `sub(/[[:space:]].*$/, "", txid)` — обрезка по первому пробелу. Но
	# tcpdump печатает флаги ответа СЛИТНО с идентификатором, без разделителя:
	# «34521*» (авторитетный), «34521-» (нет рекурсии), «34521|» (усечён), а
	# также текст кода ошибки. Такой txid не проходил проверку на цифры, и ответ
	# отбрасывался целиком. Хуже всего, что среди отброшенных — NXDomain и
	# SERVFAIL, то есть типовая подпись блокировки по DNS: ровно тот трафик,
	# ради которого монитор и включают.
	txid = payload
	sub(/^[[:space:]]*/, "", txid)
	if (!match(txid, /^[0-9]+/)) return
	txid = substr(txid, RSTART, RLENGTH)

	k = dst_ip "|" dst_port "|" txid
	# Проверяем наличие ключа, а НЕ читаем его: чтение несуществующего элемента
	# в awk создаёт его пустым, и такой мусор от чужих ответов оседал в массиве.
	if (!(k in dns_query_key_to_host)) return
	# ОТВЕТ ОБЯЗАН ПРИЙТИ ОТТУДА, КУДА УШЁЛ ЗАПРОС.
	#
	# Сопоставление шло только по «кому адресован пакет» и номеру запроса, а
	# личность отправителя не проверялась вовсе — её даже не передавали в
	# функцию. Любой хост, угадавший или подсмотревший шестнадцатибитный номер,
	# записывал в карту произвольный адрес под чужим именем. Воспроизведено:
	# посторонний 6.6.6.6 подменил bank.example.com на 203.0.113.66.
	#
	# Для инструмента, который наблюдает за цензурой, это особенно неуместно:
	# подмена DNS-ответов — штатный приём той самой стороны, за которой он и
	# следит, то есть отравить журнал может ровно тот, кого он изучает.
	if ((k in dns_query_srv) && dns_query_srv[k] != "" && dns_query_srv[k] != from_ip) return
	domain = dns_query_key_to_host[k]
	if (domain == "") { delete dns_query_key_to_host[k]; delete dns_query_ts[k]; delete dns_query_srv[k]; return }

	# ВСЕ АДРЕСА ОТВЕТА, А НЕ ПОСЛЕДНИЙ.
	#
	# Было `sub(/.* A /, "", ip)` — одиночная замена с жадным `.*`, то есть
	# отрезалось всё до ПОСЛЕДНЕГО « A ». У домена с несколькими A-записями
	# (обычное дело для любого CDN: google.com отдаёт шесть) запоминался ровно
	# один адрес, последний. Клиент же соединяется с любым из них, поэтому имя
	# находилось примерно в одном случае из N, а в остальных в отчёт попадал
	# голый IP вместо домена. Идём по строке циклом и запоминаем каждый.
	n = 0
	rest = payload
	while (match(rest, /[[:space:]]A[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
		ip = substr(rest, RSTART, RLENGTH)
		rest = substr(rest, RSTART + RLENGTH)
		sub(/^[[:space:]]*A[[:space:]]*/, "", ip)
		if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) continue
		ip2host[ip] = domain
		print int(ts) "\t" ip "\t" domain >> ipmap_out
		n++
	}
	# Ответ дошёл и разобран (даже если адресов в нём не было — например
	# NXDomain): запрос закрыт, ключ убираем, иначе он останется до подметания.
	delete dns_query_key_to_host[k]
	delete dns_query_ts[k]
	delete dns_query_srv[k]
}

BEGIN {
	tcp_timeout = (tcp_timeout == "" ? 8 : tcp_timeout) + 0
	tcp_min_syn = (tcp_min_syn == "" ? 3 : tcp_min_syn) + 0
	udp_timeout = (udp_timeout == "" ? 10 : udp_timeout) + 0
	udp_min_out = (udp_min_out == "" ? 4 : udp_min_out) + 0
	udp_max_in = (udp_max_in == "" ? 1 : udp_max_in) + 0
	dedupe_sec = (dedupe_sec == "" ? 60 : dedupe_sec) + 0
	# Срок жизни незакрытого DNS-запроса. Ответ приходит за миллисекунды, так
	# что тридцать секунд — это заведомо «ответа не будет». См. подметание в
	# sweep(): без него такие ключи не удалялись вообще ничем.
	dns_timeout = (dns_timeout == "" ? 30 : dns_timeout) + 0

	n_tcp = split(tcp_ports, tarr, ",")
	for (i = 1; i <= n_tcp; i++) {
		if (tarr[i] != "") tcp_ports_map[tarr[i]] = 1
	}
	n_udp = split(udp_ports, uarr, ",")
	for (i = 1; i <= n_udp; i++) {
		if (uarr[i] != "") udp_ports_map[uarr[i]] = 1
	}
}

{
	ts = systime()
	if ($1 ~ /^[0-9]+\.[0-9]+$/) ts = $1 + 0

	ippos = 0
	for (i = 1; i <= NF; i++) {
		if ($i == "IP" || $i == "IP6") {
			ippos = i
			break
		}
	}
	if (ippos == 0) {
		sweep(ts)
		next
	}

	src_raw = $(ippos + 1)
	dst_raw = $(ippos + 3)
	split_endpoint(src_raw, src)
	split_endpoint(dst_raw, dst)

	src_ip = src["ip"]
	src_port = src["port"]
	dst_ip = dst["ip"]
	dst_port = dst["port"]

	if (src_port == "" || dst_port == "") {
		sweep(ts)
		next
	}

	# РАЗДЕЛИТЕЛЬ — ДВОЕТОЧИЕ С ПРОБЕЛОМ, а не первое попавшееся двоеточие.
	#
	# `index($0, ":")` находил двоеточие ВНУТРИ адреса IPv6: у строки вида
	# `IP6 2001:db8::1.53 > ...` payload начинался с середины адреса, и весь
	# разбор DNS по IPv6 не работал вовсе. В самом адресе двоеточие никогда не
	# сопровождается пробелом, поэтому `: ` однозначно отделяет заголовок от
	# содержимого и для IPv4, и для IPv6.
	colon_pos = match($0, /: /)
	payload = (colon_pos > 0) ? substr($0, colon_pos + 1) : ""

	# DNS mapping: query/response.
	if (dst_port + 0 == 53) process_dns_query(ts, src_ip, src_port, dst_ip, payload)
	if (src_port + 0 == 53) process_dns_response(ts, dst_ip, dst_port, src_ip, payload)

	# TCP tracking.
	#
	# ФЛАГИ РАЗБИРАЕМ ПО СОДЕРЖИМОМУ СКОБОК, а не точным совпадением строки.
	#
	# Было `index($0, "Flags [S]")` — то есть SYN засчитывался, только если в
	# скобках стоит ровно «S». Но tcpdump печатает туда все взведённые флаги
	# разом, и у обычного современного клиента с ECN это «[S.E]», «[SEW]»,
	# «[SE]». Такой SYN не попадал в трекер ВООБЩЕ: соединение, оставшееся без
	# ответа, не считалось попыткой и не сообщалось как заблокированное — то
	# есть монитор молча пропускал ровно то, что должен ловить.
	#
	# Буквы tcpdump: S=SYN, .=ACK, R=RST, F=FIN, P=PUSH, U=URG, W=CWR, E=ECE.
	# Различаем по смыслу: SYN без ACK — наша попытка; SYN с ACK — ответ сервера.
	if (match($0, /Flags \[[^]]*\]/)) {
		tcpflags = substr($0, RSTART + 7, RLENGTH - 8)
		if (tcpflags ~ /S/ && tcpflags !~ /\./ && is_watched_port(dst_port, "tcp")) {
			k = src_ip "|" src_port "|" dst_ip "|" dst_port
			tcp_syn_count[k]++
			if (!(k in tcp_first_ts)) tcp_first_ts[k] = ts
		} else if (tcpflags ~ /S/ && tcpflags ~ /\./ && is_watched_port(src_port, "tcp")) {
			k = dst_ip "|" dst_port "|" src_ip "|" src_port
			tcp_ok[k] = 1
			# Метка времени нужна и здесь: sweep() ходит ТОЛЬКО по tcp_first_ts,
			# поэтому ключ, заведённый лишь в tcp_ok, не подметался никогда. Это
			# штатный случай — монитор включают на уже живущем соединении.
			if (!(k in tcp_first_ts)) tcp_first_ts[k] = ts
		} else if (tcpflags ~ /R/ && is_watched_port(src_port, "tcp")) {
			k = dst_ip "|" dst_port "|" src_ip "|" src_port
			tcp_rst[k] = 1
			if (!(k in tcp_first_ts)) tcp_first_ts[k] = ts
		} else if (is_watched_port(src_port, "tcp")) {
			# Any packet from server watched port means flow is alive.
			k = dst_ip "|" dst_port "|" src_ip "|" src_port
			tcp_ok[k] = 1
			if (!(k in tcp_first_ts)) tcp_first_ts[k] = ts
		}
	}

	# UDP tracking.
	if (index($0, " UDP,") > 0 || index($0, " UDP ") > 0) {
		if (is_watched_port(dst_port, "udp")) {
			k = src_ip "|" src_port "|" dst_ip "|" dst_port
			udp_out_count[k]++
			if (!(k in udp_first_ts)) udp_first_ts[k] = ts
		}
		if (is_watched_port(src_port, "udp")) {
			k = dst_ip "|" dst_port "|" src_ip "|" src_port
			udp_in_count[k]++
			if (!(k in udp_first_ts)) udp_first_ts[k] = ts
		}
	}

	sweep(ts)
}

END {
	sweep(9999999999)
}
AWK
}

running_pid() {
	[ -f "$PID_FILE" ] || return 1
	local pid
	pid="$(cat "$PID_FILE" 2>/dev/null)"
	[ -n "$pid" ] || return 1
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null || return 1
	# Validate it is actually OUR capture pipeline, not a reused PID. `kill -0`
	# alone is not enough: even with the /tmp pidfile, a crash that leaves a
	# stale pidfile could collide with a recycled PID. The leader either runs
	# our `setsid sh -c '...tcpdump...'` (cmdline carries "tcpdump") or is the
	# plain subshell whose tcpdump CHILD is alive (matched via pgrep -P). If
	# neither holds, treat as not-running.
	if [ -r "/proc/$pid/cmdline" ] && \
	   tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "tcpdump"; then
		echo "$pid"
		return 0
	fi
	local cpid
	for cpid in $(pgrep -P "$pid" 2>/dev/null); do
		[ -r "/proc/$cpid/cmdline" ] || continue
		if tr '\0' ' ' < "/proc/$cpid/cmdline" 2>/dev/null | grep -q "tcpdump"; then
			echo "$pid"
			return 0
		fi
	done
	return 1
}

start_monitor() {
	ensure_dirs || {
		echo "ERROR: failed to create $CACHE_DIR"
		return 1
	}
	init_output_files

	local pid
	if pid="$(running_pid)"; then
		echo "blocked monitor already running (PID $pid)"
		return 0
	fi

	local tcpdump_bin
	tcpdump_bin="$(find_tcpdump_bin)" || {
		echo "ERROR: tcpdump not found (searched PATH, /opt/sbin/tcpdump, /opt/bin/tcpdump)"
		return 1
	}
	exists_cmd awk || {
		echo "ERROR: awk is required"
		return 1
	}

	local tcp_ports udp_ports filter iface
	tcp_ports="$(collect_ports tcp)"
	udp_ports="$(collect_ports udp)"
	[ -n "$tcp_ports" ] || tcp_ports="$DEFAULT_TCP_PORTS"
	[ -n "$udp_ports" ] || udp_ports="$DEFAULT_UDP_PORTS"

	filter="$(build_tcpdump_filter)"
	iface="$(choose_capture_iface "$tcpdump_bin")"
	write_awk_parser || return 1

	# ПОДРЕЗКА ПЕРЕД КАЖДЫМ ЗАПУСКОМ.
	#
	# Дальше tcpdump пишет в эти TSV непрерывно и без всякого потолка, а лежат
	# они под /opt, то есть на флешке. PID-файл автор осознанно вынес в /tmp
	# именно из этих соображений (комментарий в шапке файла), но к самим данным
	# то же рассуждение не применили: на шумной сети файл растёт часами и месяц
	# работы съедает раздел, на котором живёт весь z2k.
	#
	# Держим хвост: последние MAX_TSV_LINES строк. Инструмент диагностический,
	# смотрят в него свежее, а старое не нужно никому. Подрезаем на старте, а не
	# по таймеру — монитор включают руками на время разбора, и каждый следующий
	# запуск сам ограничивает то, что накопил предыдущий.
	trim_tsv() {
		_t="$1"
		[ -f "$_t" ] || return 0
		_n=$(wc -l < "$_t" 2>/dev/null) || return 0
		[ "${_n:-0}" -gt "$MAX_TSV_LINES" ] 2>/dev/null || return 0
		if tail -n "$MAX_TSV_LINES" "$_t" > "${_t}.trim" 2>/dev/null; then
			mv -f "${_t}.trim" "$_t" 2>/dev/null || rm -f "${_t}.trim" 2>/dev/null
		else
			rm -f "${_t}.trim" 2>/dev/null
		fi
	}
	for _tsv in "$ALL_TSV" "$TCP_TSV" "$UDP_TSV" "$IPMAP_TSV"; do
		trim_tsv "$_tsv"
	done

	echo "# started: $(date)" >> "$ALL_TSV"
	echo "# tcp_ports: $tcp_ports" >> "$ALL_TSV"
	echo "# udp_ports: $udp_ports" >> "$ALL_TSV"
	echo "# tcpdump_bin: $tcpdump_bin" >> "$ALL_TSV"
	echo "# iface: $iface" >> "$ALL_TSV"
	echo "# filter: $filter" >> "$ALL_TSV"

	# Launch the capture pipeline in its OWN process group via setsid so
	# stop_monitor's `kill -- -$pid` (process-group signal) actually reaches
	# the orphan tcpdump. In non-interactive ash there is no job control, so a
	# bare `( ... ) &` subshell is NOT a group leader — the negative-PID kill
	# would hit the SCRIPT's group (or nothing) and leave tcpdump capturing
	# forever. setsid makes the subshell a session+group leader whose PID == PGID.
	local setsid_bin=""
	if exists_cmd setsid; then
		setsid_bin="$(command -v setsid)"
	elif [ -x /opt/bin/setsid ]; then
		setsid_bin="/opt/bin/setsid"
	fi

	if [ -n "$setsid_bin" ]; then
		"$setsid_bin" sh -c '"$1" -i "$2" -nn -l -tt "$3" 2>>"$4" | \
			awk \
				-v all_out="$5" \
				-v tcp_out="$6" \
				-v udp_out="$7" \
				-v ipmap_out="$8" \
				-v tcp_ports="$9" \
				-v udp_ports="${10}" \
				-v tcp_timeout="8" \
				-v tcp_min_syn="3" \
				-v udp_timeout="10" \
				-v udp_min_out="4" \
				-v udp_max_in="1" \
				-v dedupe_sec="60" \
				-f "${11}" 2>>"${12}"' _ \
			"$tcpdump_bin" "$iface" "$filter" "$ERR_LOG" \
			"$ALL_TSV" "$TCP_TSV" "$UDP_TSV" "$IPMAP_TSV" \
			"$tcp_ports" "$udp_ports" "$AWK_FILE" "$PARSER_ERR_LOG" &
	else
		# No setsid — fall back to the plain subshell. stop_monitor also
		# tracks and pkills the tcpdump child directly, so the orphan is
		# still reaped even without a leadable process group.
		( "$tcpdump_bin" -i "$iface" -nn -l -tt "$filter" 2>>"$ERR_LOG" | \
			awk \
				-v all_out="$ALL_TSV" \
				-v tcp_out="$TCP_TSV" \
				-v udp_out="$UDP_TSV" \
				-v ipmap_out="$IPMAP_TSV" \
				-v tcp_ports="$tcp_ports" \
				-v udp_ports="$udp_ports" \
				-v tcp_timeout="8" \
				-v tcp_min_syn="3" \
				-v udp_timeout="10" \
				-v udp_min_out="4" \
				-v udp_max_in="1" \
				-v dedupe_sec="60" \
				-f "$AWK_FILE" 2>>"$PARSER_ERR_LOG" ) &
	fi

	echo "$!" > "$PID_FILE"
	chmod 644 "$PID_FILE" 2>/dev/null || true

	sleep 1
	if ! running_pid >/dev/null; then
		echo "ERROR: monitor exited right after start"
		echo "Check logs: $ERR_LOG and $PARSER_ERR_LOG"
		tail -n 10 "$ERR_LOG" 2>/dev/null || true
		tail -n 10 "$PARSER_ERR_LOG" 2>/dev/null || true
		return 1
	fi

	echo "blocked monitor started (PID $(cat "$PID_FILE"))"
	echo "output dir: $CACHE_DIR"
}

stop_monitor() {
	local pid
	if ! pid="$(running_pid)"; then
		echo "blocked monitor is not running"
		rm -f "$PID_FILE" 2>/dev/null || true
		return 0
	fi

	# 1) Signal the whole process group (works when start used setsid →
	#    $pid is the group leader, so this reaches tcpdump + awk).
	kill -- -"$pid" 2>/dev/null || true
	# 2) Always also reap the tcpdump child of our subshell directly. On the
	#    no-setsid fallback the subshell is NOT a group leader, so the
	#    negative-PID kill above is a no-op and the orphan tcpdump would keep
	#    capturing — pkill -P targets the children of our pipeline by PPID.
	#    pkill на роутере НЕТ (busybox Entware его не собирает), поэтому
	#    детей берём pgrep -P и бьём поимённо. Прежний вызов не срабатывал
	#    никогда — тот же класс, что od -A в issue #43.
	for _c in $(pgrep -P "$pid" 2>/dev/null); do kill "$_c" 2>/dev/null; done
	# 3) Finally the subshell/leader itself.
	kill "$pid" 2>/dev/null || true

	sleep 1
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 -- -"$pid" 2>/dev/null || true
		for _c in $(pgrep -P "$pid" 2>/dev/null); do kill -9 "$_c" 2>/dev/null; done
		kill -9 "$pid" 2>/dev/null || true
	fi
	rm -f "$PID_FILE" 2>/dev/null || true
	echo "blocked monitor stopped"
}

status_monitor() {
	local pid
	if pid="$(running_pid)"; then
		echo "blocked monitor: running (PID $pid)"
	else
		echo "blocked monitor: stopped"
	fi
	echo "output dir: $CACHE_DIR"
	echo "files:"
	echo "  $ALL_TSV"
	echo "  $TCP_TSV"
	echo "  $UDP_TSV"
	echo "  $IPMAP_TSV"
}

show_last() {
	local n="${2:-30}"
	case "$1" in
		all) [ -f "$ALL_TSV" ] && tail -n "$n" "$ALL_TSV" ;;
		tcp) [ -f "$TCP_TSV" ] && tail -n "$n" "$TCP_TSV" ;;
		udp) [ -f "$UDP_TSV" ] && tail -n "$n" "$UDP_TSV" ;;
		*) return 1 ;;
	esac
}

case "${1:-}" in
	start)
		start_monitor
		;;
	stop)
		stop_monitor
		;;
	restart)
		stop_monitor
		start_monitor
		;;
	status)
		status_monitor
		;;
	tail)
		show_last "${2:-all}" "${3:-30}" || {
			echo "Usage: $0 tail {all|tcp|udp} [lines]"
			exit 1
		}
		;;
	*)
		cat <<EOF
Usage: $0 {start|stop|restart|status|tail}
  start            start monitor
  stop             stop monitor
  restart          restart monitor
  status           show monitor status and file paths
  tail [type] [n]  show last lines from blocked files (type: all|tcp|udp)
EOF
		exit 1
		;;
esac
