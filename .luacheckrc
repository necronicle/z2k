-- luacheck configuration for z2k
-- nfqws2 provides these globals at runtime

std = "max"
max_line_length = false

-- nfqws2 runtime globals (provided by zapret-auto.lua and nfqws2 core)
globals = {
    -- Desync action entry points (registered by z2k)
    "z2k_tls_alert_fatal",
    "z2k_success_no_reset",
    "z2k_tls_extshuffle",
    "z2k_tls_fp_pack_v2",
    "z2k_timing_morph",
    "z2k_tcpoverlap3",
    "z2k_quic_morph_v2",
    "z2k_ech_passthrough",
    "z2k_strategy_profile",
    "z2k_ipfrag3",
    "z2k_ipfrag3_tiny",
    "cond_tcp_has_ts",
    "circular",
}

read_globals = {
    -- nfqws2 core functions
    "DLOG",
    "DLOG_ERR",
    "deepcopy",
    "l3_len",
    "l3_base_len",
    "l3_extra_len",
    "l4_len",
    "rawsend_dissect",
    "rawsend_dissect_ipfrag",
    "rawsend_payload_segmented",
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
    "find_tcp_option",
    "bu16",
    "bu32",

    -- nfqws2 detectors
    "standard_failure_detector",
    "standard_success_detector",

    -- nfqws2 host key functions
    "standard_hostkey",
    "nld_hostkey",
    "sld_hostkey",
    "tld_hostkey",

    -- nfqws2 state
    "autostate",
    "clock_getfloattime",

    -- nfqws2 constants
    "VERDICT_DROP",
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

    -- Lua bit library (provided by LuaJIT or nfqws2)
    "bitand",
    "bitor",
    "bitrshift",
    "bitlshift",
}

-- Ignore unused loop variables (common pattern in eviction functions)
ignore = {"21./_.*", "213"}
