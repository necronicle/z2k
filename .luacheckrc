-- luacheck configuration for z2k
-- nfqws2 provides these globals at runtime

std = "max"
max_line_length = false

-- nfqws2 runtime globals (provided by zapret-auto.lua and nfqws2 core)
globals = {
    -- Desync action entry points (registered by z2k)
    "z2k_fail_tls_alert",
    -- Детектор молчания QUIC и его таймер-функция (files/lua/z2k-quic-silence.lua).
    -- Обе объявляются глобально намеренно: движок ищет detector по имени в _G,
    -- а таймер-функцию — по строке, переданной в timer_set.
    "z2k_fail_quic_silence",
    "z2k_quic_silence_timer",
    "z2k_tls_alert_fatal",
    "z2k_tls_stalled",
    "z2k_mid_stream_stall",
    "z2k_http_mid_stream_stall",
    "z2k_silent_drop_detector",
    "z2k_http_partial_response",
    "z2k_quic_success",
    "z2k_quic_stall",
    -- HTTP-bypass primitives (z2k-http-strats.lua, ALFiX port)
    "z2k_success_no_reset",
    "z2k_http_success_positive_only",
    "z2k_timing_morph",
    "z2k_quic_morph_v2",
    "z2k_game_udp",
    "z2k_ipfrag3",
    "z2k_ipfrag3_tiny",
    "z2k_dynamic_ttl",
    "z2k_dynamic_strategy",
    "z2k_cdn_detect",
    "cond_tcp_has_ts",
    "automate_host_record",
    "circular",
    -- Сброс накопленных счётчиков удач/неудач хоста. Предусмотрен движком
    -- ровно для нашего случая: состояние ротации меняет не детектор, а человек
    -- (пин/выбор стратегии в панели). Зовём через гейт на существование, так
    -- что на старом движке без него ничего не ломается.
    "automate_failure_counter_reset",
    -- Счётчик неудач хоста. Из таймера вызывается штатно: ему нужны только
    -- hrec/crec и os.time(), никакого desync (lua/zapret-auto.lua).
    "automate_failure_counter",
    -- z2k-modern-core.lua hostkey fn (returns "nohost" for IP/no-hostname flows)
    "z2k_nohost_key",
    -- z2k-state-persist.lua exported API table
    "z2k_state_persist",
    -- z2k-detectors.lua internal helper, top-level so earlier detector
    -- functions in the same file (z2k_tls_alert_fatal) can call it
    "z2k_detector_log_init_once",
    -- z2k-detectors.lua exported HTTP classifier; called from
    -- z2k-autocircular.lua's has_positive_incoming_response()
    "z2k_classify_http_reply",
    -- z2k-detectors.lua internal classifier; called from
    -- z2k_silent_drop_detector and z2k_tls_alert_fatal in the same file
    "z2k_classify_server_active",
    -- nfqws2 writable state/functions (set by fallback stubs or runtime)
    "DLOG",
    "DLOG_ERR",
    "autostate",
    "b_debug",
}

read_globals = {
    -- nfqws2 core functions (may be set by fallback stubs)
    "deepcopy",
    "l3_len",
    "l3_base_len",
    "l3_extra_len",
    "l4_len",
    "rawsend_dissect",
    "rawsend_dissect_ipfrag",
    "rawsend_payload_segmented",
    "blob",
    "blob_exist",
    "apply_fooling",
    "apply_ip_id",
    "desync_opts",
    "tls_dissect",
    "tls_reconstruct",
    "direction_check",
    "direction_cutoff_opposite",
    "payload_check",
    "instance_cutoff_shim",
    "replay_first",
    "replay_drop",
    "replay_drop_set",
    "resolve_pos",
    "insert_ip6_exthdr",
    "http_dissect_reply",
    "array_field_search",
    "is_dpi_redirect",
    "dissect_url",
    "dissect_nld",
    "find_tcp_option",
    "bu16",
    "bu32",

    -- nfqws2 detectors
    "standard_failure_detector",
    "standard_success_detector",

    -- zapret-antidpi.lua desync primitives (defined upstream, used by
    -- z2k-dynamic-strategy.lua dispatch table)
    "fake",
    "multisplit",
    "hostfakesplit",
    "multidisorder",

    -- nfqws2 host key functions
    "standard_hostkey",
    "nld_hostkey",
    "sld_hostkey",
    "tld_hostkey",

    -- nfqws2 time
    "clock_getfloattime",

    -- nfqws2 constants
    "VERDICT_DROP",
    "VERDICT_PASS",
    -- nfqws2 globals used by z2k-http-strats.lua / z2k-modern-core.lua /
    -- z2k-white-presets.lua (provided by zapret-lib.lua / zapret-antidpi.lua /
    -- zapret-auto.lua / nfqws2 core at runtime).
    "tls_mod",
    "tls_mod_shim",
    "fake_default_tls",
    "http_dissect_req",
    "instance_cutoff",
    "resolve_multi_pos",
    "delete_pos_1",
    "dis_timer_name",     -- nfqws2: имя по пятёрке адрес-порт для таймеров (lua/zapret-lib.lua)
    "is_retransmission",  -- nfqws2: пакет не выше уже виденного максимума позиции (lua/zapret-lib.lua)
    "timer_set",          -- nfqws2: завести таймер, timer_set(name, func, period_ms, oneshot, data)
    "pos_get",       -- nfqws2 byte/datagram counter accessor: pos_get(desync, mode[, reverse]) — manual §pos_get
    "pos_get_pos",   -- sibling: pos_get_pos(track_pos, mode)
    "rawsend_opts",
    "rawsend_opts_base",
    "reconstruct_opts",
    "VERDICT_MODIFY",
    "IP_MF",
    "IP6F_MORE_FRAG",
    "IPPROTO_FRAGMENT",
    "IPPROTO_DSTOPTS",
    "IPPROTO_HOPOPTS",
    "IPPROTO_ROUTING",
    "NOT7",
    "TLS_HANDSHAKE_TYPE_CLIENT",
    "TLS_EXT_SERVER_NAME",
    "TLS_EXT_PRE_SHARED_KEY",
    "TLS_EXT_ALPN",
    "TLS_EXT_SUPPORTED_GROUPS",
    "TCP_KIND_TS",

    -- TCP flag bits (zapret-lib.lua)
    "TH_FIN",
    "TH_SYN",
    "TH_RST",
    "TH_PUSH",
    "TH_ACK",
    "TH_URG",
    "TH_ECE",
    "TH_CWR",

    -- Lua bit library (provided by LuaJIT or nfqws2)
    "bitand",
    "bitor",
    "bitrshift",
    "bitlshift",
}

-- Ignore unused loop variables and common nfqws2 patterns
ignore = {
    "21./_.*",  -- unused _ variables
    "213",      -- unused loop variable
    "212",      -- unused argument (ctx in desync actions)
    "311",      -- unused assigned variable (common in multi-return)
}
