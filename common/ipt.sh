ipt_connbytes="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes"
IPSET_EXCLUDE="-m set ! --match-set nozapret"
IPSET_EXCLUDE6="-m set ! --match-set nozapret6"
IPSET_PORTS_NAME=zport

# z2k: an existence check followed by an insert/append/delete is two iptables
# runs. -w only queues each run behind the xtables lock; without it a busy lock
# makes -C fail with status 4, which the old "-C || -I" read as "absent" and
# answered with a duplicate. Only status 1 means absent now; any other check
# failure is returned without mutating.
#
# A second, z2k-only kernel flock makes the check+mutation pair atomic between
# z2k processes (service commands, NDM hook, self-heal). The kernel drops it
# when the descriptor closes, including on SIGTERM/SIGKILL, so there is no
# owner bookkeeping and nothing to reclaim. It is never the xtables lock file:
# the iptables -w runs inside the pair take that one. The lock file is never
# unlinked so all waiters share one inode. Descriptor 8 is opened only around
# one transaction by a compound redirection, which saves and restores any
# descriptor 8 the caller already had.
#
# flock is an Entware package declared by the installer; installs that predate
# it run the pair unserialised (still with -w and strict statuses) rather than
# losing firewall rules.
_ipt_flock_wait()
{
	local waited=0 timeout="${Z2K_IPT_LOCK_TIMEOUT:-30}"
	flock -n 8 2>/dev/null && return 0
	[ -n "$_Z2K_IPT_FLOCK_W" ] || {
		# util-linux flock bounds the wait itself; BusyBox flock has no -w
		if flock --help 2>&1 | grep -q -- '--timeout'; then
			_Z2K_IPT_FLOCK_W=1
		else
			_Z2K_IPT_FLOCK_W=0
		fi
	}
	[ "$_Z2K_IPT_FLOCK_W" = 1 ] && {
		flock -w "$timeout" 8 2>/dev/null
		return
	}
	while [ "$waited" -lt "$timeout" ]; do
		sleep 1
		flock -n 8 2>/dev/null && return 0
		waited=$((waited + 1))
	done
	return 1
}
_ipt_locked()
{
	# $@ - transaction function and its arguments
	local _ipt_tx_rc=
	if command -v flock >/dev/null 2>&1; then
		{
			if _ipt_flock_wait; then
				if "$@"; then _ipt_tx_rc=0; else _ipt_tx_rc=$?; fi
			else
				# a live z2k transaction still holds the lock: fail closed
				_ipt_tx_rc=4
			fi
		} 8>>"${Z2K_IPT_LOCK:-/tmp/zapret2-ipt.flock}" || :
	fi
	# no flock, or the lock file could not be opened
	[ -n "$_ipt_tx_rc" ] || if "$@"; then _ipt_tx_rc=0; else _ipt_tx_rc=$?; fi
	return "$_ipt_tx_rc"
}
_ipt_cmd()
{
	# $1 - 4|6, $2 - iptables operation, $3.. - rule
	local fam="$1" op="$2"
	shift 2
	if [ "$fam" = 6 ]; then
		ip6tables -w "$op" "$@"
	else
		iptables $FW_EXTRA_PRE -w "$op" "$@" $FW_EXTRA_POST
	fi
}
_ipt_add()
{
	# $1 - 4|6, $2 - -I|-A, $3.. - rule
	local fam="$1" op="$2" rc
	shift 2
	if _ipt_cmd "$fam" -C "$@" >/dev/null 2>/dev/null; then
		return 0
	else
		rc=$?
	fi
	[ "$rc" = 1 ] || return "$rc"
	_ipt_cmd "$fam" "$op" "$@"
}
_ipt_del()
{
	# $1 - 4|6, $2.. - rule. Removes every exact copy; 1 if there was none.
	local fam="$1" rc deleted=0
	shift
	while :; do
		if _ipt_cmd "$fam" -C "$@" >/dev/null 2>/dev/null; then
			:
		else
			rc=$?
			[ "$rc" = 1 ] && [ "$deleted" = 1 ] && return 0
			return "$rc"
		fi
		if _ipt_cmd "$fam" -D "$@"; then
			deleted=1
		else
			return $?
		fi
	done
}

ipt()
{
	_ipt_locked _ipt_add 4 -I "$@"
}
ipta()
{
	_ipt_locked _ipt_add 4 -A "$@"
}
ipt_del()
{
	_ipt_locked _ipt_del 4 "$@"
}
ipt_add_del()
{
	on_off_function ipt ipt_del "$@"
}
ipta_add_del()
{
	on_off_function ipta ipt_del "$@"
}
ipt6()
{
	_ipt_locked _ipt_add 6 -I "$@"
}
ipt6a()
{
	_ipt_locked _ipt_add 6 -A "$@"
}
ipt6_del()
{
	_ipt_locked _ipt_del 6 "$@"
}
ipt6_add_del()
{
	on_off_function ipt6 ipt6_del "$@"
}
ipt6a_add_del()
{
	on_off_function ipt6a ipt6_del "$@"
}

is_ipt_flow_offload_avail()
{
	# $1 = '' for ipv4, '6' for ipv6
	grep -q FLOWOFFLOAD 2>/dev/null /proc/net/ip$1_tables_targets
}

filter_apply_ipset_target4()
{
	# $1 - var name of ipv4 iptables filter
	if [ "$MODE_FILTER" = "ipset" ]; then
		eval $1="\"\$$1 -m set --match-set zapret dst\""
	fi
}
filter_apply_ipset_target6()
{
	# $1 - var name of ipv6 iptables filter
	if [ "$MODE_FILTER" = "ipset" ]; then
		eval $1="\"\$$1 -m set --match-set zapret6 dst\""
	fi
}
filter_apply_ipset_target()
{
	# $1 - var name of ipv4 iptables filter
	# $2 - var name of ipv6 iptables filter
	filter_apply_ipset_target4 $1
	filter_apply_ipset_target6 $2
}

reverse_nfqws_rule_stream()
{
	sed -e 's/-o /-i /g' -e 's/--dport /--sport /g' -e 's/--dports /--sports /g' -e 's/ dst$/ src/' -e 's/ dst / src /g' -e 's/--connbytes-dir=original/--connbytes-dir=reply/g' -e "s/-m mark ! --mark $DESYNC_MARK\/$DESYNC_MARK//g"
}
reverse_nfqws_rule()
{
	echo "$@" | reverse_nfqws_rule_stream
}

ipt_mark_filter()
{
	[ -n "$FILTER_MARK" ] && echo "-m mark --mark $FILTER_MARK/$FILTER_MARK"
}

ipt_print_op()
{
	if [ "$1" = "1" ]; then
		echo "Inserting ip$4tables rule for $3 : $2"
	else
		echo "Deleting ip$4tables rule for $3 : $2"
	fi
}



_fw_nfqws_post4()
{
	# $1 - 1 - add, 0 - del
	# $2 - iptable filter for ipv4
	# $3 - queue number
	# $4 - wan interface names space separated
	[ "$DISABLE_IPV4" = "1" -o -z "$2" ] || {
		local i

		ipt_print_op $1 "$2" "nfqws postrouting (qnum $3)"

		rule="$(ipt_mark_filter) -m mark ! --mark $DESYNC_MARK/$DESYNC_MARK $2 $IPSET_EXCLUDE dst -j NFQUEUE --queue-num $3 --queue-bypass"
		if [ -n "$4" ] ; then
			for i in $4; do
				ipt_add_del $1 POSTROUTING -t mangle -o $i $rule
			done
		else
			ipt_add_del $1 POSTROUTING -t mangle $rule
		fi
	}
}
_fw_nfqws_post6()
{
	# $1 - 1 - add, 0 - del
	# $2 - iptable filter for ipv6
	# $3 - queue number
	# $4 - wan interface names space separated
	[ "$DISABLE_IPV6" = "1" -o -z "$2" ] || {
		local i

		ipt_print_op $1 "$2" "nfqws postrouting (qnum $3)" 6

		rule="$(ipt_mark_filter) -m mark ! --mark $DESYNC_MARK/$DESYNC_MARK $2 $IPSET_EXCLUDE6 dst -j NFQUEUE --queue-num $3 --queue-bypass"
		if [ -n "$4" ] ; then
			for i in $4; do
				ipt6_add_del $1 POSTROUTING -t mangle -o $i $rule
			done
		else
			ipt6_add_del $1 POSTROUTING -t mangle $rule
		fi
	}
}
fw_nfqws_post()
{
	# $1 - 1 - add, 0 - del
	# $2 - iptable filter for ipv4
	# $3 - iptable filter for ipv6
	# $4 - queue number
	fw_nfqws_post4 $1 "$2" $4
	fw_nfqws_post6 $1 "$3" $4
}

_fw_nfqws_pre4()
{
	# $1 - 1 - add, 0 - del
	# $2 - iptable filter for ipv4
	# $3 - queue number
	# $4 - wan interface names space separated
	[ "$DISABLE_IPV4" = "1" -o -z "$2" ] || {
		local i

		ipt_print_op $1 "$2" "nfqws input+forward (qnum $3)"

		rule="$2 $IPSET_EXCLUDE src -j NFQUEUE --queue-num $3 --queue-bypass"
		if [ -n "$4" ] ; then
			for i in $4; do
				# iptables PREROUTING chain is before NAT. not possible to have DNATed ip's there
				ipt_add_del $1 INPUT -t mangle -i $i $rule
				ipt_add_del $1 FORWARD -t mangle -i $i $rule
			done
		else
			ipt_add_del $1 INPUT -t mangle $rule
			ipt_add_del $1 FORWARD -t mangle $rule
		fi
	}
}
_fw_nfqws_pre6()
{
	# $1 - 1 - add, 0 - del
	# $2 - iptable filter for ipv6
	# $3 - queue number
	# $4 - wan interface names space separated
	[ "$DISABLE_IPV6" = "1" -o -z "$2" ] || {
		local i

		ipt_print_op $1 "$2" "nfqws input+forward (qnum $3)" 6

		rule="$2 $IPSET_EXCLUDE6 src -j NFQUEUE --queue-num $3 --queue-bypass"
		if [ -n "$4" ] ; then
			for i in $4; do
				# iptables PREROUTING chain is before NAT. not possible to have DNATed ip's there
				ipt6_add_del $1 INPUT -t mangle -i $i $rule
				ipt6_add_del $1 FORWARD -t mangle -i $i $rule
			done
		else
			ipt6_add_del $1 INPUT -t mangle $rule
			ipt6_add_del $1 FORWARD -t mangle $rule
		fi
	}
}
fw_nfqws_pre()
{
	# $1 - 1 - add, 0 - del
	# $2 - iptable filter for ipv4
	# $3 - iptable filter for ipv6
	# $4 - queue number
	fw_nfqws_pre4 $1 "$2" $4
	fw_nfqws_pre6 $1 "$3" $4
}


fw_reverse_nfqws_rule4()
{
	fw_nfqws_pre4 $1 "$(reverse_nfqws_rule "$2")" $3
}
fw_reverse_nfqws_rule6()
{
	fw_nfqws_pre6 $1 "$(reverse_nfqws_rule "$2")" $3
}
fw_reverse_nfqws_rule()
{
	# ensure that modes relying on incoming traffic work
	# $1 - 1 - add, 0 - del
	# $2 - rule4
	# $3 - rule6
	# $4 - queue number
	fw_reverse_nfqws_rule4 $1 "$2" $4
	fw_reverse_nfqws_rule6 $1 "$3" $4
}

ipt_port_ipset()
{
	# $1 - ipset name
	# $2 - ports
	ipset -q flush $1 || {
		ipset create $1 bitmap:port range 0-65535 || return
	}
	echo "$2" | tr ',' '\n' | sed -nEe "s/^.+$/add $1 &/p" | ipset -! restore
}

ipt_first_packets()
{
	# $1 - packet count
	# 0:N, а не 1:N. На ядре Keenetic первый ОТВЕТНЫЙ пакет (SYN-ACK) проходит
	# mangle FORWARD/INPUT со счётчиком conntrack ещё 0, и 1:N его не отдаёт в
	# очередь. Движок тогда не знает окно сервера, и его защита «reasm cancelled
	# because server window size is smaller» молчит: сервер с окном 1448
	# (анти-DDoS reg.ru) держит клиент на первом сегменте ClientHello, а nfqws
	# держит сегмент до сборки — дедлок до таймаута. Замер 11.09.2026 на
	# Keenetic: правило 1:50 на SYN-ACK — 0 пакетов, 0:50 — все. Семантика
	# «первые N пакетов» не меняется.
	[ -n "$1" -a "$1" != keepalive ] && [ "$1" -ge 1 ] && echo "$ipt_connbytes 0:$1"
}
ipt_do_nfqws_in_out()
{
	# $1 - 1 - add, 0 - del
	# $2 - tcp,udp
	# $3 - ports
	# $4 - PKT. special value : 'keepalive'
	# $5 - 1 - out, 0 - in
	# $6 - ipset base name
	local f f4 f6 first_packets_only ipset
	[ -n "$3" ] || return
	ipset="${6}_$2"
	[ "$4" = keepalive ] && ipset="${ipset}_k"
	[ "$1" = 1 ] && ipt_port_ipset $ipset "$3"
	[ -n "$4" -a "$4" != 0 ] &&
	{
		first_packets_only="$(ipt_first_packets $4)"
		f4="-p $2 -m set --match-set $ipset"
		if [ "$5" = 1 ]; then
			f4="$f4 dst"
			f=fw_nfqws_post
		else
			f4="$f4 src"
			f=fw_reverse_nfqws_rule
		fi
		f4="$f4 $first_packets_only"
		f6=$f4
		filter_apply_ipset_target f4 f6
		$f $1 "$f4" "$f6" $QNUM
	}
	[ "$1" = 1 ] || ipset -q destroy $ipset
}

zapret_do_firewall_standard_nfqws_rules_ipt()
{
	# $1 - 1 - add, 0 - del

	[ "$NFQWS2_ENABLE" = 1 ] && {
		ipt_do_nfqws_in_out $1 tcp "$NFQWS2_PORTS_TCP" "$NFQWS2_TCP_PKT_OUT" 1 $IPSET_PORTS_NAME
		ipt_do_nfqws_in_out $1 tcp "$NFQWS2_PORTS_TCP" "$NFQWS2_TCP_PKT_IN" 0 $IPSET_PORTS_NAME
		ipt_do_nfqws_in_out $1 tcp "$NFQWS2_PORTS_TCP_KEEPALIVE" keepalive 1 $IPSET_PORTS_NAME
		ipt_do_nfqws_in_out $1 udp "$NFQWS2_PORTS_UDP" "$NFQWS2_UDP_PKT_OUT" 1 $IPSET_PORTS_NAME
		ipt_do_nfqws_in_out $1 udp "$NFQWS2_PORTS_UDP" "$NFQWS2_UDP_PKT_IN" 0 $IPSET_PORTS_NAME
		ipt_do_nfqws_in_out $1 udp "$NFQWS2_PORTS_UDP_KEEPALIVE" keepalive 1 $IPSET_PORTS_NAME
	}
}
zapret_do_firewall_standard_rules_ipt()
{
	# $1 - 1 - add, 0 - del

	zapret_do_firewall_standard_nfqws_rules_ipt $1
}

zapret_do_firewall_rules_ipt()
{
	# $1 - 1 - add, 0 - del

	zapret_do_firewall_standard_rules_ipt $1
	custom_runner zapret_custom_firewall $1
	zapret_do_icmp_filter $1
}

zapret_do_icmp_filter()
{
	# $1 - 1 - add, 0 - del

	local FW_EXTRA_PRE= FW_EXTRA_POST=

	[ "$FILTER_TTL_EXPIRED_ICMP" = 1 ] && {
		[ "$DISABLE_IPV4" = 1 ] || {
			ipt_add_del $1 POSTROUTING -t mangle -m mark --mark $DESYNC_MARK/$DESYNC_MARK -j CONNMARK --or-mark $DESYNC_MARK
			ipt_add_del $1 INPUT -p icmp -m icmp --icmp-type time-exceeded -m connmark --mark $DESYNC_MARK/$DESYNC_MARK -j DROP
			ipt_add_del $1 FORWARD -p icmp -m icmp --icmp-type time-exceeded -m connmark --mark $DESYNC_MARK/$DESYNC_MARK -j DROP
		}
		[ "$DISABLE_IPV6" = 1 ] || {
			ipt6_add_del $1 POSTROUTING -t mangle -m mark --mark $DESYNC_MARK/$DESYNC_MARK -j CONNMARK --or-mark $DESYNC_MARK
			ipt6_add_del $1 INPUT -p icmpv6 -m icmp6 --icmpv6-type time-exceeded -m connmark --mark $DESYNC_MARK/$DESYNC_MARK -j DROP
			ipt6_add_del $1 FORWARD -p icmpv6 -m icmp6 --icmpv6-type time-exceeded -m connmark --mark $DESYNC_MARK/$DESYNC_MARK -j DROP
		}
	}
}

zapret_do_firewall_ipt()
{
	# $1 - 1 - add, 0 - del

	if [ "$1" = 1 ]; then
		echo Applying iptables
	else
		echo Clearing iptables
	fi

	# always create ipsets. ip_exclude ipset is required
	[ "$1" = 1 ] && create_ipset no-update

	zapret_do_firewall_rules_ipt "$@"

	if [ "$1" = 1 ] ; then
		existf flow_offloading_exempt && flow_offloading_exempt
	else
		existf flow_offloading_unexempt && flow_offloading_unexempt
	fi

	return 0
}
