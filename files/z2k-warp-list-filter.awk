# Canonical WARP destination-list parser. BusyBox awk and BSD awk compatible.
# mode=save preserves comments; ipset (IPv4), ipset6 (IPv6) and domains emit only
# their normalized entries;
# count prints counts for the input (not for a previously normalized file).
function z2k_warp_addr_ok(s,   ip, h, o) {
    if (s !~ /^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/) return 0
    ip = s
    if (split(s, h, "/") == 2) ip = h[1]
    split(ip, o, ".")
    if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) return 0
    if (o[1] == 10 || o[1] == 127 || o[1] >= 224) return 0
    if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 0
    if (o[1] == 169 && o[2] == 254) return 0
    if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 0
    if (o[1] == 192 && o[2] == 168) return 0
    if (o[1] == 192 && o[2] == 0 && (o[3] == 0 || o[3] == 2)) return 0
    if (o[1] == 198 && (o[2] == 18 || o[2] == 19)) return 0
    if (o[1] == 198 && o[2] == 51 && o[3] == 100) return 0
    if (o[1] == 203 && o[2] == 0 && o[3] == 113) return 0
    return 1
}
function z2k_warp_hex(g,   i, v) {
    v = 0
    for (i = 1; i <= length(g); i++) v = v * 16 + index("0123456789abcdef", substr(g, i, 1)) - 1
    return v
}
# IPv6-адрес или подсеть в интернете: только глобальный юникаст 2000::/3 и без
# служебных диапазонов — тех же, что отсекает warpd у адресов из DNS
# (domainroute.EligibleDestination): Teredo 2001::/32, бенчмарки 2001:2::/48,
# документация 2001:db8::/32 и 3fff::/20, 6to4 2002::/16.
function z2k_warp_addr6_ok(s,   a, h, p, n, i, dbl, nonempty, g1, g2, g3) {
    if (s !~ /^[0-9A-Fa-f:]+(\/([1-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$/) return 0
    a = tolower(s)
    if (split(a, h, "/") == 2) a = h[1]
    if (a ~ /:::/) return 0
    dbl = gsub(/::/, "::", a)
    if (dbl > 1) return 0
    if (a ~ /^:[^:]/ || a ~ /[^:]:$/) return 0
    n = split(a, p, ":")
    nonempty = 0
    for (i = 1; i <= n; i++) {
        if (p[i] == "") continue
        if (length(p[i]) > 4) return 0
        nonempty++
    }
    if (dbl == 0 && (n != 8 || nonempty != 8)) return 0
    if (dbl == 1 && nonempty > 7) return 0
    if (p[1] == "") return 0
    g1 = z2k_warp_hex(p[1]); g2 = (n >= 2) ? z2k_warp_hex(p[2]) : 0; g3 = (n >= 3) ? z2k_warp_hex(p[3]) : 0
    if (g1 < 8192 || g1 > 16383) return 0
    if (g1 == 8193 && (g2 == 0 || g2 == 3512 || (g2 == 2 && g3 == 0))) return 0
    if (g1 == 8194) return 0
    if (g1 == 16383 && g2 < 4096) return 0
    return 1
}
function z2k_warp_domain_ok(s,   d, n, labels, i, label, tld) {
    if (length(s) > 255 || s ~ /[^A-Za-z0-9.*-]/) return 0
    d = s
    if (substr(d, 1, 2) == "*.") d = substr(d, 3)
    if (d ~ /\*/) return 0
    if (length(d) < 4 || length(d) > 253) return 0
    n = split(d, labels, ".")
    if (n < 2) return 0
    for (i = 1; i <= n; i++) {
        label = labels[i]
        if (length(label) < 1 || length(label) > 63) return 0
        if (label !~ /^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$/ && label !~ /^[A-Za-z0-9]$/) return 0
    }
    tld = labels[n]
    if (tld !~ /^[A-Za-z]+$/ && tld !~ /^xn--[A-Za-z0-9-]+$/) return 0
    return 1
}
BEGIN {
    if (mode != "save" && mode != "ipset" && mode != "ipset6" && mode != "domains" && mode != "count") exit 2
}
{
    sub(/\r$/, "")
    gsub(/^[ \t]+|[ \t]+$/, "")
    if ($0 == "") next
    if ($0 ~ /^#/) { if (mode == "save") print; next }
    if (z2k_warp_addr_ok($0)) {
        ip++
        if (mode == "save" || mode == "ipset") print
        next
    }
    if (z2k_warp_addr6_ok($0)) {
        ip++
        if (mode == "save" || mode == "ipset6") print tolower($0)
        next
    }
    if (z2k_warp_domain_ok($0)) {
        domain++
        if (mode == "save" || mode == "domains") print tolower($0)
        next
    }
    invalid++
}
END {
    if (mode == "count") printf "ip=%d domain=%d invalid=%d\n", ip + 0, domain + 0, invalid + 0
}
