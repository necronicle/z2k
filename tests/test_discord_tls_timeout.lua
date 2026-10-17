local H=dofile('tests/lib/detector_harness.lua')
dofile('files/lua/z2k-modern-core.lua')
local CLIENT=string.char(22,3,3,0,100,1,0,0,96,3,3)..string.rep('x',94)
local function initial(host)
    local d=H.tcp(H.track(host or 'updates.discord.com'),true,1,CLIENT,'tls_client_hello')
    d.arg.hostkey='z2k_service_hostkey'; d.arg.nld='0'
    d.arg.discord_tls_timeout='1'
    d.arg.discord_tls_in_limit='10'; d.arg.discord_tls_out_limit='20'
    d.dis.tcp.th_seq=1000; d.dis.tcp.th_ack=9000
    d.dis.tcp.th_sport=50001; d.dis.tcp.th_dport=443
    d.track.pos.direct.pcounter=3
    return d
end
local function reply(d,payload,acknowledged)
    local p=H.tcp(d.track,false,1,payload or '', 'unknown')
    p.arg=d.arg
    p.dis.tcp.th_seq=9000
    p.dis.tcp.th_ack=acknowledged or ((d.dis.tcp.th_seq+#CLIENT)%4294967296)
    p.dis.tcp.th_sport=443; p.dis.tcp.th_dport=50001
    p.ifout='lan-test'; p.fwmark=123
    p.track.pos.direct.pcounter=2
    return p
end
local function waiting()
    local d=initial(); local h,c=H.step(d)
    H.step(reply(d))
    return d,h,c
end
H.test('ACKed silence counts each attempt once, resets the client and rotates after quorum',function()
    local original_send=rawsend_dissect
    local options
    rawsend_dissect=function(dis,opts) options=opts; return original_send(dis) end
    local h,c
    for i=1,3 do
        local d
        d,h,c=waiting()
        H.advance(9); H.eq(i-1,#H.sent)
        H.advance(1)
        H.eq(true,c.failure); H.eq(i,#H.sent)
        H.eq(i<3 and 1 or 2,h.nstrategy)
        H.eq(9000,H.sent[i].tcp.th_seq)
        H.eq(443,H.sent[i].tcp.th_sport); H.eq(50001,H.sent[i].tcp.th_dport)
        H.eq(TH_RST,H.sent[i].tcp.th_flags); H.eq(nil,H.sent[i].payload)
        H.eq('lan-test',options.ifout); H.eq(123,options.fwmark)
        H.step(reply(d)); H.advance(1); H.eq(i,#H.sent)
    end
    rawsend_dissect=original_send
end)
H.test('missing or partial ACK never counts a timeout or sends reset',function()
    local d=initial(); local h=H.step(d)
    H.advance(11); H.eq(nil,h.failure_counter); H.eq(0,#H.sent)
    d=initial(); H.step(d); H.step(reply(d,'',1001))
    H.advance(11); H.eq(nil,h.failure_counter); H.eq(0,#H.sent)
end)
H.test('a wrong server sequence and a ClientHello spanning TLS records cannot arm a reset',function()
    local d=initial(); local h=H.step(d)
    local ack=reply(d); ack.dis.tcp.th_seq=9001; H.step(ack)
    H.advance(11); H.eq(0,#H.sent); H.eq(nil,h.failure_counter)
    d=initial()
    d.dis.payload=CLIENT:sub(1,8)..string.char(120)..CLIENT:sub(10)
    local _,c=H.step(d); H.step(reply(d)); H.advance(11)
    H.eq(nil,c.discord_tls); H.eq(0,#H.sent)
    d=initial()
    d.reasm_data=nil
    d.dis.payload=CLIENT:sub(1,60)
    _,c=H.step(d); H.step(reply(d)); H.advance(11)
    H.eq(nil,c.discord_tls); H.eq(0,#H.sent)
end)
H.test('a slow response, including one byte of a fragmented TLS record, cancels the timer',function()
    local d,h=waiting()
    H.advance(9)
    H.step(reply(d,string.char(22)))
    H.advance(20)
    H.eq(0,#H.sent); H.eq(nil,h.failure_counter)
end)
H.test('unrelated hosts, subdomains, pools, ports and both opt-outs are untouched',function()
    local cases={
        function(d) d.track.hostname='discord.com' end,
        function(d) d.track.hostname='foo.updates.discord.com' end,
        function(d) d.arg.key='cf_extra' end,
        function(d) d.arg.hostkey='standard_hostkey' end,
        function(d) d.arg.discord_tls_timeout=nil end,
        function(d) d.arg.reset=nil end,
        function(d) d.dis.tcp.th_dport=8443 end,
    }
    for _,change in ipairs(cases) do
        local d=initial(); change(d)
        local h,c=H.step(d); H.step(reply(d)); H.advance(11)
        H.eq(nil,c.discord_tls); H.eq(nil,h.failure_counter); H.eq(0,#H.sent)
    end
end)
H.test('stale timer cannot reset or penalize a manually changed strategy',function()
    local _,h=waiting()
    h.nstrategy=2
    H.advance(11)
    H.eq(2,h.nstrategy); H.eq(nil,h.failure_counter); H.eq(0,#H.sent)
end)
H.test('freeze and terminal verdict veto a pending timer',function()
    local _,h=waiting(); h.final=h.nstrategy
    H.advance(11); H.eq(nil,h.failure_counter); H.eq(0,#H.sent)
    h.final=nil
    local d,c
    d,h,c=waiting()
    circular_report_failure(h,c,d.arg)
    H.advance(11); H.eq(1,h.failure_counter); H.eq(0,#H.sent)
end)
H.test('connection close and exhausted capture window cancel observation',function()
    for _,mode in ipairs({'fin','rst','limit'}) do
        local d,h=waiting(); local p=reply(d)
        if mode=='limit' then p.track.pos.direct.pcounter=10
        else p.dis.tcp.th_flags=(mode=='fin' and TH_FIN or TH_RST)+TH_ACK end
        H.step(p)
        local count=h.failure_counter
        H.advance(11); H.eq(count,h.failure_counter); H.eq(0,#H.sent)
    end
end)
H.test('at most six retries in five minutes even across strategy rotations',function()
    for i=1,6 do waiting(); H.advance(11) end
    H.eq(6,#H.sent)
    local _,h,c=waiting(); H.eq(nil,c.discord_tls)
    H.advance(100); H.eq(6,#H.sent)
    H.advance(140) -- 306 seconds since the first watch
    waiting(); H.advance(11)
    H.eq(7,#H.sent); H.eq(1,h.discord_tls_budget.used)
end)
H.test('parallel connections share a single pending watch',function()
    local _,h=waiting()
    local d=initial(); local _,c=H.step(d); H.step(reply(d))
    H.eq(nil,c.discord_tls)
    H.advance(11); H.eq(1,#H.sent); H.eq(1,h.failure_counter)
end)
H.test('absolute ACK comparison handles TCP sequence wraparound',function()
    local d=initial(); d.dis.tcp.th_seq=4294967250
    local _,c=H.step(d); H.step(reply(d)); H.advance(11)
    H.eq(true,c.failure); H.eq(1,#H.sent)
end)
H.test('moving a connection to another host record invalidates the old timer',function()
    local d,h=waiting()
    d.track.hostname='other.example'
    H.step(reply(d))
    H.advance(11)
    H.eq(0,#H.sent); H.eq(nil,h.failure_counter)
end)
H.finish()
