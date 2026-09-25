local H=dofile('tests/lib/detector_harness.lua')
local fork=os.getenv('Z2K_FORK_DIR') or '../zapret2-z2k-fork'
dofile(fork..'/lua/zapret-antidpi.lua')
dofile('files/lua/z2k-modern-core.lua')
VERDICT_DROP=1
instance_cutoff=function() end
local function profiles(path)
    local result={}
    for line in io.lines(path) do
        local range_in,range_out,payload='x','a','all'
        local instances,key={}
        for tok in line:gmatch('%S+') do
            if tok:match('^%-%-in%-range=') then range_in=tok:match('=(.*)')
            elseif tok:match('^%-%-out%-range=') then range_out=tok:match('=(.*)')
            elseif tok:match('^%-%-payload=') then payload=tok:match('=(.*)')
            elseif tok:match('^%-%-lua%-desync=') then
                local value=tok:match('=(.*)'); local fn=value:match('^[^:]+'); local arg={}
                for part in value:gmatch(':([^:]+)') do
                    local k,v=part:match('^([^=]+)=(.*)$')
                    arg[k or part]=v or true
                end
                local instance={func=fn,arg=arg,range_in=range_in,range_out=range_out,payload=payload}
                instances[#instances+1]=instance
                if fn=='circular' then key=arg.key end
            end
        end
        if key then result[key]=instances end
    end
    return result
end
local all=profiles(assert(os.getenv('Z2K_PROFILE_FIXTURE')))
local no_reset=profiles(assert(os.getenv('Z2K_PROFILE_NO_RESET')))
local timeout_off=profiles(assert(os.getenv('Z2K_PROFILE_TIMEOUT_OFF')))
local function circular_instance(pool)
    for _,ins in ipairs(assert(all[pool],pool)) do if ins.func=='circular' then return ins end end
    error('missing circular: '..pool)
end
H.test('every shipped TCP pool uses retrans=2, quorum 3, and the reset opt-out',function()
    for _,key in ipairs({'rkn_tcp','yt_tcp','gv_tcp','http_rkn'}) do
        local c=circular_instance(key)
        H.eq('2',c.arg.retrans); H.eq('3',c.arg.fails); H.eq(true,c.arg.reset)
        H.eq('-s5556',c.range_in); H.eq('all',c.payload)
        for _,ins in ipairs(no_reset[key]) do if ins.func=='circular' then H.eq(nil,ins.arg.reset) end end
    end
    H.eq('60',circular_instance('rkn_tcp').arg.time)
    H.eq('300',circular_instance('yt_tcp').arg.time)
    H.eq('300',circular_instance('gv_tcp').arg.time)
end)
H.test('QUIC drops only outgoing Initials, never replies or later packets',function()
    local checked=0
    for _,ins in ipairs(all.quic) do
        if ins.func=='drop' then
            checked=checked+1
            for _,out in ipairs({true,false}) do
                for _,kind in ipairs({'quic_initial','unknown'}) do
                    local d=H.udp(nil,out,'data',kind); d.arg=ins.arg; d.func_instance='drop_'..ins.arg.strategy
                    H.eq(out and kind=='quic_initial' and VERDICT_DROP or nil,drop(nil,d))
                end
            end
        end
    end
    assert(checked>0,'missing replacement drop fixture')
end)
H.test('Discord observer sees replies and unknown data while fakes stay within outbound d4',function()
    local c=circular_instance('discord_udp')
    H.eq('a',c.range_in); H.eq('a',c.range_out); H.eq('all',c.payload)
    local d=H.udp(nil,true,'discovery','discord_ip_discovery'); d.arg=c.arg
    local h=H.step(d); h.failure_counter=2
    local reply=H.udp(d.track,false,'reply','unknown',1,2); reply.arg=c.arg
    H.step(reply); H.eq(nil,h.failure_counter)
    for _,ins in ipairs(all.discord_udp) do
        if ins.func~='circular' then
            H.eq('x',ins.range_in); H.eq('-d4',ins.range_out)
            H.eq('discord_ip_discovery,stun',ins.payload)
        end
    end
end)
H.test('host scope separates public suffixes and unrelated API services',function()
    for _,key in ipairs({'rkn_tcp','yt_tcp','gv_tcp','quic'}) do
        local arg=circular_instance(key).arg
        H.eq('z2k_service_hostkey',arg.hostkey)
        for _,host in ipairs({'youtube.co.uk','bbc.co.uk','fonts.googleapis.com','youtubei.googleapis.com'}) do
            local d=H.tcp(H.track(host),true,1,'x'); d.arg=arg
            H.eq(host..'|4',z2k_service_hostkey(d))
            H.eq(host,d.track.hostname); H.eq('0',arg.nld)
        end
    end
end)
H.test('only the explicit video CDN is grouped and families remain separate',function()
    for _,key in ipairs({'gv_tcp','quic'}) do
        local arg=circular_instance(key).arg
        for _,host in ipairs({'rr1.googlevideo.com','rr2.googlevideo.com'}) do
            local d=H.tcp(H.track(host),true,1,'x'); d.arg=arg
            H.eq('googlevideo.com|4',z2k_service_hostkey(d))
            d.dis.ip=nil; d.dis.ip6={}; H.eq('googlevideo.com|6',z2k_service_hostkey(d))
        end
        local d=H.tcp(H.track('googlevideo.com.example.org'),true,1,'x'); d.arg=arg
        H.eq('googlevideo.com.example.org|4',z2k_service_hostkey(d))
    end
end)
H.test('YouTube TCP hosts keep independent rotation records',function()
    local arg=circular_instance('yt_tcp').arg
    local function record(host,pool_arg)
        local d=H.tcp(H.track(host),true,1,'x'); d.arg=pool_arg or arg
        return z2k_service_hostkey(d),automate_host_record(d)
    end
    local root_key,root=record('youtube.com')
    local seen={[root]=true}
    for _,host in ipairs({'www.youtube.com','m.youtube.com','img.youtube.com','accounts.youtube.com','ads.youtube.com'}) do
        local key,rec=record(host)
        H.eq(host..'|4',key)
        assert(not seen[rec],'YouTube hosts must not share failure counters')
        seen[rec]=true
    end
    H.eq('youtube.com|4',root_key)
    local api_key,api=record('youtubei.googleapis.com')
    H.eq('youtubei.googleapis.com|4',api_key)
    assert(api~=root,'an unrelated API must retain its own counter')
    local quic_key=record('www.youtube.com',circular_instance('quic').arg)
    H.eq('www.youtube.com|4',quic_key)
end)
H.test('a success on another API host cannot reset failures for this host',function()
    local arg=circular_instance('yt_tcp').arg
    local d=H.tcp(H.track('youtubei.googleapis.com'),true,1,H.client,'tls_client_hello'); d.arg=arg
    local h=H.step(d); h.failure_counter=2
    local other=H.tcp(H.track('fonts.googleapis.com'),false,1,H.hello,'tls_server_hello'); other.arg=arg; H.step(other)
    other=H.tcp(other.track,false,4200,'new content'); other.arg=arg; H.step(other)
    H.eq(2,h.failure_counter)
end)
H.test('previously unprotected TCP fakes carry an invalid checksum',function()
    for key,num in pairs({rkn_tcp='38',yt_tcp='18',gv_tcp='18'}) do
        local checked=false
        for _,ins in ipairs(all[key]) do
            if ins.func=='fake' and ins.arg.strategy==num then
                H.eq(true,ins.arg.badsum); checked=true
            end
        end
        assert(checked,'missing fake '..key)
    end
end)
H.test('GV slot 11 is distinct while the existing 1..22 numbering is retained',function()
    local ids,slot6,slot11={}
    for _,ins in ipairs(all.gv_tcp) do
        if ins.arg.strategy then ids[tonumber(ins.arg.strategy)]=true end
        if ins.func=='multisplit' and ins.arg.strategy=='6' then slot6=ins.arg end
        if ins.func=='multisplit' and ins.arg.strategy=='11' then slot11=ins.arg end
    end
    for i=1,22 do H.eq(true,ids[i]) end
    H.eq('1',slot6.seqovl); H.eq(nil,slot11.seqovl)
    H.eq(slot6.pos,slot11.pos)
end)
-- Exercise persistence with the hostkey arguments emitted by the real generator.
-- Testing the key helper and persistence separately misses a rejected helper.
dofile('files/lua/z2k-state-persist.lua')
local P=z2k_state_persist
local state_path=assert(os.getenv('Z2K_STATE_DIR_OVERRIDE'))..'/state.tsv'
local function fresh_state()
    os.remove(state_path)
    P._reset()
end
local function disk_strategy(key,host)
    local f=io.open(state_path)
    if not f then return nil end
    local result
    for line in f:lines() do
        local k,h,n=line:match('^([^\t]+)\t([^\t]+)\t(%d+)')
        if k==key and h==host then result=tonumber(n) end
    end
    f:close()
    return result
end
local function profile_initial(key,host)
    local d
    if key=='quic' then d=H.qstart(H.track(host))
    elseif key=='http_rkn' then d=H.tcp(H.track(host),true,1,'GET / HTTP/1.1\r\n\r\n','http_req')
    else d=H.tcp(H.track(host),true,1,H.client,'tls_client_hello') end
    d.arg=circular_instance(key).arg
    return d
end
H.test('generated RKN profile wires the TLS timeout and its opt-out',function()
    local arg=circular_instance('rkn_tcp').arg
    H.eq('1',arg.discord_tls_timeout)
    H.eq('10',arg.discord_tls_in_limit); H.eq('20',arg.discord_tls_out_limit)
    for _,ins in ipairs(timeout_off.rkn_tcp) do
        if ins.func=='circular' then H.eq(nil,ins.arg.discord_tls_timeout) end
    end
    for _,key in ipairs({'yt_tcp','gv_tcp','http_rkn','quic','discord_udp'}) do
        H.eq(nil,circular_instance(key).arg.discord_tls_timeout)
    end
end)
local function discord_waiting()
    local d=profile_initial('rkn_tcp','updates.discord.com')
    local hello=string.char(22,3,3,0,100,1,0,0,96,3,3)..string.rep('x',94)
    d.dis.payload=hello
    d.dis.tcp.th_seq=1000; d.dis.tcp.th_ack=9000; d.dis.tcp.th_dport=443
    d.track.pos.direct.pcounter=3
    local h,c=H.step(d)
    local ack=H.tcp(d.track,false,1,'','unknown'); ack.arg=d.arg
    ack.dis.tcp.th_ack=1000+#hello; ack.dis.tcp.th_seq=9000; ack.dis.tcp.th_sport=443
    ack.track.pos.direct.pcounter=2
    H.step(ack)
    return h,c
end
H.test('generated TLS timeout persists rotation and honors a disk freeze before expiry',function()
    fresh_state()
    local h,c
    for i=1,3 do h=discord_waiting(); H.advance(11) end
    H.eq(2,h.nstrategy); H.eq(3,#H.sent)
    H.eq(2,disk_strategy('rkn_tcp','updates.discord.com|4'))
    h,c=discord_waiting()
    local f=assert(io.open(state_path,'w'))
    f:write('rkn_tcp\tupdates.discord.com|4\t2\t1033\tfrozen\n'); f:close()
    H.advance(11)
    H.eq(2,h.final); H.eq(nil,c.failure); H.eq(3,#H.sent)
end)
H.test('generated host keys persist the selected strategy for every domain pool',function()
    fresh_state()
    for _,key in ipairs({'rkn_tcp','yt_tcp','gv_tcp','http_rkn','quic'}) do
        local host=key=='gv_tcp' or key=='quic'
        host=host and 'rr1.googlevideo.com' or 'api.example.co.uk'
        local d=profile_initial(key,host)
        local h=H.step(d)
        h.nstrategy=2
        H.step(profile_initial(key,host))
        P.flush()
        H.eq(2,disk_strategy(key,z2k_service_hostkey(d)))
    end
end)
H.test('generated host keys restore a frozen selection before executing a strategy',function()
    fresh_state()
    local f=assert(io.open(state_path,'w'))
    f:write('yt_tcp\tapi.example.co.uk|4\t2\t1000\tfrozen\n')
    f:close()
    local h=H.step(profile_initial('yt_tcp','api.example.co.uk'))
    H.eq(2,H.executed)
    H.eq(2,h.nstrategy)
    H.eq(2,h.final)
    -- The IPv4 pin must not seed the separate IPv6 record.
    local d=profile_initial('yt_tcp','api.example.co.uk')
    d.dis.ip=nil; d.dis.ip6={}
    h=H.step(d)
    H.eq(1,h.nstrategy)
    H.eq(nil,h.final)
end)
H.test('a frozen YouTube TCP host does not pin its siblings',function()
    fresh_state()
    local f=assert(io.open(state_path,'w'))
    f:write('yt_tcp\tyoutube.com|4\t1\t1000\tauto\n')
    f:write('yt_tcp\twww.youtube.com|4\t2\t1000\tfrozen\talt.example\n')
    f:write('gv_tcp\tgooglevideo.com|4\t3\t1000\tfrozen\n')
    f:close()
    local h=H.step(profile_initial('yt_tcp','www.youtube.com'))
    H.eq(2,H.executed); H.eq(2,h.final)
    h=H.step(profile_initial('yt_tcp','img.youtube.com'))
    H.eq(1,H.executed); H.eq(nil,h.final)
    H.eq(1,disk_strategy('yt_tcp','youtube.com|4'))
    H.eq(2,disk_strategy('yt_tcp','www.youtube.com|4'))
    H.eq(3,disk_strategy('gv_tcp','googlevideo.com|4'))
end)
H.test('conflicting frozen YouTube TCP hosts retain their own pins',function()
    fresh_state()
    local f=assert(io.open(state_path,'w'))
    f:write('yt_tcp\tyoutube.com|4\t3\t900\tfrozen\n')
    f:write('yt_tcp\twww.youtube.com|4\t2\t1000\tfrozen\n')
    f:close()
    local h=H.step(profile_initial('yt_tcp','www.youtube.com'))
    H.eq(2,H.executed); H.eq(2,h.final)
    h=H.step(profile_initial('yt_tcp','youtube.com'))
    H.eq(3,H.executed); H.eq(3,h.final)
end)
H.test('generated QUIC profile persists a timer rotation without another packet',function()
    fresh_state()
    local h
    for i=1,3 do h=H.step(profile_initial('quic','rr2.googlevideo.com')) end
    H.advance(6)
    H.eq(2,h.nstrategy)
    H.eq(2,disk_strategy('quic','googlevideo.com|4'))
end)
H.finish()
