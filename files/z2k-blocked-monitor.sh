#!/bin/sh
# z2k-blocked-monitor.sh
# Runtime monitor for likely blocked destinations outside zapret hostlists.
# Writes candidates to separate TCP/UDP files with host/ip, proto and port.

set -u

ZAPRET_BASE="${ZAPRET_BASE:-/opt/zapret2}"
ZAPRET_CONFIG="${ZAPRET_CONFIG:-$ZAPRET_BASE/config}"
CACHE_DIR="${ZAPRET_BASE}/extra_strats/cache/blocked_monitor"
PID_FILE="${CACHE_DIR}/monitor.pid"
AWK_FILE="${CACHE_DIR}/monitor.awk"
ERR_LOG="${CACHE_DIR}/tcpdump.err.log"
PARSER_ERR_LOG="${CACHE_DIR}/parser.err.log"
ALL_TSV="${CACHE_DIR}/blocked_all.tsv"
TCP_TSV="${CACHE_DIR}/blocked_tcp.tsv"
UDP_TSV="${CACHE_DIR}/blocked_udp.tsv"
IPMAP_TSV="${CACHE_DIR}/ip2host.tsv"

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
	chmod 777 "$CACHE_DIR" 2>/dev/null || true
}

init_output_files() {
	[ -f "$ALL_TSV" ] || echo "# ts\thost\tip\tproto\tport\treason\tdetails" > "$ALL_TSV"
	[ -f "$TCP_TSV" ] || echo "# ts\thost\tip\tproto\tport\treason\tdetails" > "$TCP_TSV"
	[ -f "$UDP_TSV" ] || echo "# ts\thost\tip\tproto\tport\treason\tdetails" > "$UDP_TSV"
	[ -f "$IPMAP_TSV" ] || echo "# ts\tip\thost" > "$IPMAP_TSV"
	[ -f "$ERR_LOG" ] || : > "$ERR_LOG"
	[ -f "$PARSER_ERR_LOG" ] || : > "$PARSER_ERR_LOG"
	chmod 666 "$ALL_TSV" "$TCP_TSV" "$UDP_TSV" "$IPMAP_TSV" "$ERR_LOG" "$PARSER_ERR_LOG" 2>/dev/null || true
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
function split_endpoint(ep, out, s, p) {
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
		if (age >= tcp_timeout && syns >= tcp_min_syn) {
			emit_block(ts, "TCP", ip, port, "tcp_no_synack", "syn_retries=" syns)
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
		if (age >= udp_timeout && outs >= udp_min_out && ins <= udp_max_in) {
			emit_block(ts, "UDP", ip, port, "udp_no_reply", "out=" outs ",in=" ins)
			cleanup_udp(k)
		}
	}
}

function process_dns_query(ts, src_ip, src_port, payload, txid, domain, k) {
	txid = payload
	sub(/^[[:space:]]*/, "", txid)
	sub(/\+.*/, "", txid)
	if (txid !~ /^[0-9]+$/) return

	domain = payload
	sub(/.* A\? /, "", domain)
	if (domain == payload) return
	sub(/[[:space:]].*$/, "", domain)
	gsub(/\.$/, "", domain)
	if (domain == "") return
	k = src_ip "|" src_port "|" txid
	dns_query_key_to_host[k] = domain
}

function process_dns_response(ts, dst_ip, dst_port, payload, txid, k, domain, ip) {
	txid = payload
	sub(/^[[:space:]]*/, "", txid)
	sub(/[[:space:]].*$/, "", txid)
	if (txid !~ /^[0-9]+$/) return

	k = dst_ip "|" dst_port "|" txid
	domain = dns_query_key_to_host[k]
	if (domain == "") return

	ip = payload
	sub(/.* A /, "", ip)
	if (ip == payload) return
	sub(/[^0-9.].*$/, "", ip)
	if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return

	ip2host[ip] = domain
	print int(ts) "\t" ip "\t" domain >> ipmap_out
	delete dns_query_key_to_host[k]
}

BEGIN {
	tcp_timeout = (tcp_timeout == "" ? 8 : tcp_timeout) + 0
	tcp_min_syn = (tcp_min_syn == "" ? 3 : tcp_min_syn) + 0
	udp_timeout = (udp_timeout == "" ? 10 : udp_timeout) + 0
	udp_min_out = (udp_min_out == "" ? 4 : udp_min_out) + 0
	udp_max_in = (udp_max_in == "" ? 1 : udp_max_in) + 0
	dedupe_sec = (dedupe_sec == "" ? 60 : dedupe_sec) + 0

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

	colon_pos = index($0, ":")
	payload = (colon_pos > 0) ? substr($0, colon_pos + 1) : ""

	# DNS mapping: query/response.
	if (dst_port + 0 == 53) process_dns_query(ts, src_ip, src_port, payload)
	if (src_port + 0 == 53) process_dns_response(ts, dst_ip, dst_port, payload)

	# TCP tracking.
	if (index($0, "Flags [") > 0) {
		if (index($0, "Flags [S]") > 0 && index($0, "Flags [S.]") == 0 && is_watched_port(dst_port, "tcp")) {
			k = src_ip "|" src_port "|" dst_ip "|" dst_port
			tcp_syn_count[k]++
			if (!(k in tcp_first_ts)) tcp_first_ts[k] = ts
		} else if (index($0, "Flags [S.]") > 0 && is_watched_port(src_port, "tcp")) {
			k = dst_ip "|" dst_port "|" src_ip "|" src_port
			tcp_ok[k] = 1
		} else if (index($0, "Flags [R") > 0 && is_watched_port(src_port, "tcp")) {
			k = dst_ip "|" dst_port "|" src_ip "|" src_port
			tcp_rst[k] = 1
			if (!(k in tcp_first_ts)) tcp_first_ts[k] = ts
		} else if (is_watched_port(src_port, "tcp")) {
			# Any packet from server watched port means flow is alive.
			k = dst_ip "|" dst_port "|" src_ip "|" src_port
			tcp_ok[k] = 1
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
	kill -0 "$pid" 2>/dev/null || return 1
	echo "$pid"
	return 0
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

	echo "# started: $(date)" >> "$ALL_TSV"
	echo "# tcp_ports: $tcp_ports" >> "$ALL_TSV"
	echo "# udp_ports: $udp_ports" >> "$ALL_TSV"
	echo "# tcpdump_bin: $tcpdump_bin" >> "$ALL_TSV"
	echo "# iface: $iface" >> "$ALL_TSV"
	echo "# filter: $filter" >> "$ALL_TSV"

	"$tcpdump_bin" -i "$iface" -nn -l -tt "$filter" 2>>"$ERR_LOG" | \
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
			-f "$AWK_FILE" 2>>"$PARSER_ERR_LOG" &

	echo "$!" > "$PID_FILE"
	chmod 666 "$PID_FILE" 2>/dev/null || true

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

	kill "$pid" 2>/dev/null || true
	sleep 1
	kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
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
