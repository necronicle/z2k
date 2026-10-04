#!/bin/sh
# Shared WAN discovery for the firewall and its periodic repair. Read-only:
# never change provider priorities, policy rules or the user's WAN_IFACE.
# The main routing table is the automatic-discovery boundary: a device with a
# main default is selected even if its name resembles a VPN. Policy-only routes
# stay outside automatic discovery; WAN_IFACE can select any device explicitly.
# Do not query link netlink: it can hang on an unhealthy driver (issue #18).
z2k_wan_auto_excluded() {
    # A bridge can be the WAN (e.g. br2 via an upstream router). Candidates
    # already carry a live main-table default; connected LAN routes and
    # policy-only defaults are rejected by the route parser below.
    [ "$1" != lo ] || return 0
    return 1
}

z2k_wan_ifaces() {
    local family="$1" override="${2:-}" routes candidates dev
    if [ -n "$override" ]; then
        printf '%s\n' "$override" | tr ',' ' ' | awk '{for(i=1;i<=NF;i++) if(!seen[$i]++) print $i}' | xargs
        return 0
    fi
    routes=$(ip "$family" route show table main 2>/dev/null) ||
        routes=$(ip "$family" route show default 2>/dev/null) || return 1
    candidates=$(printf '%s\n' "$routes" | awk '
        function emit(d,bad) {
            if(d!="" && !bad && !seen[d]++) print d
        }
        function main_table( i) {
            for(i=1;i<NF;i++)
                if($i=="table" && $(i+1)!="main" && $(i+1)!="254") return 0
            return 1
        }
        function devices(i, d,bad) {
            d=""; bad=0
            for(;i<=NF;i++) {
                if($i=="nexthop") {emit(d,bad); d=""; bad=0}
                if($i=="dev") d=$(i+1)
                if($i=="dead" || $i=="linkdown") bad=1
            }
            emit(d,bad)
        }
        # iproute2 can put ECMP nexthops on continuation lines. Each hop has
        # its own dead/linkdown state, so one failed sibling cannot hide another.
        $1=="nexthop" {if(active && main_table()) devices(1); next}
        {
            active=($1=="default" || $1=="0.0.0.0/0" || $1=="::/0") && main_table()
            if(active) devices(1)
        }
    ')
    for dev in $candidates; do
        z2k_wan_auto_excluded "$dev" && continue
        printf '%s\n' "$dev"
    done | xargs
}
