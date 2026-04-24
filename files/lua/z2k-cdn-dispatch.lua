-- z2k-cdn-dispatch.lua — per-CDN-provider SNI selection
--
-- ntc.party 17013 #851 insight: TSPU 16 KB whitelist-SNI enforcement
-- varies by ASN. A single hard-coded fake-SNI (our previous approach)
-- won't universally bypass — what works for Cloudflare may not work for
-- OVH/Hetzner/DigitalOcean and vice versa.
--
-- This helper lets cdn_tls strategies attach condition functions that
-- fire only when the destination IP belongs to a specific CDN provider.
-- Combined with per_instance_condition (zapret-auto.lua:413 cond_lua +
-- our fork commit c13284b), each strategy can target a specific
-- provider with the best fake SNI for that provider's whitelist.
--
-- Routes are compiled from a hand-curated list of the top blocked
-- subnets per provider (sourced from 123jjck/cdn-ip-ranges traffic
-- patterns, ordered by observed hit frequency). Not exhaustive — the
-- cdn_ips.txt ipset (~1666 CIDRs) is the primary profile trigger;
-- z2k_cdn_detect only refines WITHIN already-matched traffic.
--
-- Cost: one O(N) linear scan (N≈32) per ClientHello matched to the
-- cdn_tls profile. Negligible on MIPS (MIPS 580 MHz × 32 integer
-- compare+band ≈ 2 µs).

local cdn_routes = {
    -- Cloudflare AS13335 — top 8 blocked subnets
    {"104.16.0.0", 12, "cf"},
    {"172.64.0.0", 13, "cf"},
    {"141.101.64.0", 18, "cf"},
    {"162.158.0.0", 15, "cf"},
    {"190.93.240.0", 20, "cf"},
    {"108.162.192.0", 18, "cf"},
    {"172.65.0.0", 16, "cf"},
    {"198.41.128.0", 17, "cf"},
    -- OVH AS16276 — top 7 regions
    {"51.75.0.0", 16, "ovh"},
    {"51.68.0.0", 16, "ovh"},
    {"141.94.0.0", 16, "ovh"},
    {"145.239.0.0", 16, "ovh"},
    {"51.77.0.0", 16, "ovh"},
    {"51.83.0.0", 16, "ovh"},
    {"51.38.0.0", 16, "ovh"},
    -- Hetzner AS24940 — top 8 subnets
    {"78.46.0.0", 15, "hetzner"},
    {"88.198.0.0", 16, "hetzner"},
    {"94.130.0.0", 16, "hetzner"},
    {"116.202.0.0", 15, "hetzner"},
    {"162.55.0.0", 16, "hetzner"},
    {"176.9.0.0", 16, "hetzner"},
    {"49.12.0.0", 16, "hetzner"},
    {"65.109.0.0", 16, "hetzner"},
    -- DigitalOcean AS14061 — top 8 subnets
    {"104.131.0.0", 16, "do"},
    {"134.209.0.0", 16, "do"},
    {"138.68.0.0", 16, "do"},
    {"139.59.0.0", 16, "do"},
    {"157.230.0.0", 16, "do"},
    {"165.22.0.0", 16, "do"},
    {"167.71.0.0", 16, "do"},
    {"174.138.0.0", 17, "do"},
}

-- One-time compile: dotted-decimal + bits → (net_int, mask_int, provider)
local function ip_str_to_int(s)
    local a, b, c, d = string.match(s, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return tonumber(a) * 16777216 + tonumber(b) * 65536 + tonumber(c) * 256 + tonumber(d)
end

local cdn_compiled = {}
for _, r in ipairs(cdn_routes) do
    local net_int = ip_str_to_int(r[1])
    local bits = r[2]
    -- mask: high-order bits=1, low-order bits=0
    -- e.g. bits=16 → 0xFFFF0000
    local mask_int = bits == 0 and 0 or (bitlshift(0xFFFFFFFF, 32 - bits) % 0x100000000)
    if net_int then
        table.insert(cdn_compiled, {
            net = bitand(net_int, mask_int),
            mask = mask_int,
            prov = r[3],
        })
    end
end

-- Convert a raw 4-byte binary IP (struct in_addr as string) to 32-bit int.
-- desync.target.ip and desync.dis.ip.ip_dst are both pushed as raw bytes
-- (see nfq2/lua.c:1476 lua_pushf_raw).
local function raw_ip_to_int(raw)
    if not raw or #raw < 4 then return nil end
    local b1, b2, b3, b4 = string.byte(raw, 1, 4)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

-- Detect provider by dst IP. Returns "cf" / "ovh" / "hetzner" / "do" / nil.
function z2k_cdn_detect(desync)
    local ip_int
    if desync and desync.target and desync.target.ip then
        ip_int = raw_ip_to_int(desync.target.ip)
    elseif desync and desync.dis and desync.dis.ip and desync.dis.ip.ip_dst then
        ip_int = raw_ip_to_int(desync.dis.ip.ip_dst)
    end
    if not ip_int then return nil end
    for _, r in ipairs(cdn_compiled) do
        if bitand(ip_int, r.mask) == r.net then
            return r.prov
        end
    end
    return nil
end

-- Condition functions for per_instance_condition. Usage:
--   --lua-desync=fake:blob=X:tls_mod=sni=www.google.com:cond=cond_cdn_cf:strategy=N
function cond_cdn_cf(desync)
    return z2k_cdn_detect(desync) == "cf"
end
function cond_cdn_ovh(desync)
    return z2k_cdn_detect(desync) == "ovh"
end
function cond_cdn_hetzner(desync)
    return z2k_cdn_detect(desync) == "hetzner"
end
function cond_cdn_do(desync)
    return z2k_cdn_detect(desync) == "do"
end
-- Catch-all: IP belongs to cdn_ips.txt ipset (matched by profile filter)
-- but provider unrecognized. Fire a generic whitelist-SNI strategy.
function cond_cdn_other(desync)
    return z2k_cdn_detect(desync) == nil
end

-- Per-provider fake-SNI mapping. Empirically selected known-whitelist
-- SNIs for each CDN's AS. When the provider is unknown we fall back to
-- www.google.com (broadest historical coverage).
local cdn_sni_map = {
    cf = "www.google.com",
    ovh = "4pda.to",
    hetzner = "max.ru",
    ["do"] = "vk.com",
}

-- Set desync.cdn_sni based on dst IP. For use from luaexec:
--   --lua-desync=luaexec:code=pick_cdn_sni(desync)
--   --lua-desync=fake:blob=X:tls_mod=rnd,sni=%cdn_sni
-- tls_mod_shim (zapret-lib.lua:633) resolves %cdn_sni against desync.cdn_sni.
function pick_cdn_sni(desync)
    desync.cdn_sni = cdn_sni_map[z2k_cdn_detect(desync) or ""] or "www.google.com"
end
