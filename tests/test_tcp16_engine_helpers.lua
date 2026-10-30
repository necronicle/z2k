-- Real engine Lua header/fooling/options code; C TLS modifier and wire I/O
-- are fixtures. This is not a live-engine or DPI effectiveness test.
local root = os.getenv('Z2K_FORK_DIR') or '../zapret2-z2k-fork'
local H = dofile(root .. '/tests/harness.lua')
TCP_KIND_MD5, TCP_KIND_TS, TCP_KIND_NOOP, TCP_KIND_END = 19, 8, 1, 0
IPPROTO_AH = 51
brandom = function(n) return string.rep('R', n) end
parse_hex = function(hex) assert(hex == ''); return '' end
bu32 = function(n) return string.pack('>I4', n) end
u32 = function(s) return string.unpack('>I4', s) end
fake_default_tls = 'TLS-TEMPLATE'
tls_mod = function(base, mods, real)
    assert(base == fake_default_tls)
    assert(mods == 'rnd,dupsid,sni=hcaptcha.com')
    assert(#real == 4096)
    return string.rep('F', 100)
end
dofile('files/lua/z2k-tcp16.lua')
z2k_sni_for = function() return 'hcaptcha.com' end
z2k_sni_pinned = function() return nil end

for _, ipv6 in ipairs({false, true}) do
    for _, ts in ipairs({false, true}) do
        H.test('real header helpers: ipv6=' .. tostring(ipv6) .. ', timestamp=' .. tostring(ts), function()
            local options = ts and {{kind=TCP_KIND_TS, data=bu32(2000)..bu32(0)}} or {}
            local d = {func_instance='compact_test', arg={tcp_md5='', tcp_ts='-1000', repeats='8'},
                outgoing=true, l7payload='tls_client_hello', reasm_data=string.rep('R',4096),
                dis={payload='REAL',tcp={th_seq=1,th_flags=24,options=options}}}
            if ipv6 then d.dis.ip6={exthdr={{type=0,data=string.rep('\0',6)}}}
            else d.dis.ip={ip_id=1} end
            -- Budget derived from real helper after adding MD5, not a magic cap.
            local prepared = deepcopy(d.dis)
            apply_fooling(d, prepared, d.arg)
            d.tcp_mss = 100 + l3l4_extra_len(prepared)
            local sends = 0
            rawsend_dissect = function(dis, rawopts)
                sends = sends + 1
                assert(#dis.payload == 100)
                assert(#dis.payload + l3l4_extra_len(dis) == d.tcp_mss)
                assert(rawopts.repeats == '8')
                assert(find_tcp_option(dis.tcp.options, TCP_KIND_MD5))
                if ts then
                    local idx = find_tcp_option(dis.tcp.options, TCP_KIND_TS)
                    assert(u32(dis.tcp.options[idx].data) == 1000)
                end
                return true
            end
            z2k_sni_fake(nil,d)
            assert(sends == 1, 'packet was not sent')
            assert(d.dis.payload == 'REAL')
            assert(not find_tcp_option(d.dis.tcp.options, TCP_KIND_MD5))
            d.tcp_mss = d.tcp_mss - 1
            z2k_sni_fake(nil,d)
            assert(sends == 1, 'oversized packet sent')
        end)
    end
end
H.finish()
