-- luacheck configuration for z2k
-- nfqws2 provides these globals at runtime

std = "max"
max_line_length = false

-- nfqws2 runtime globals (provided by zapret-auto.lua and nfqws2 core)
globals = {
    -- Desync action entry points (registered by z2k)
    "z2k_tls_alert_fatal",
    "z2k_tls_stalled",
    "z2k_mid_stream_stall",
    "z2k_http_mid_stream_stall",
    "z2k_silent_drop_detector",
    -- HTTP-bypass primitives (z2k-http-strats.lua, ALFiX port)
    "z2k_http_methodeol_safe",
    "z2k_http_xpadding",
    "z2k_http_inject_safe_header",
    "z2k_http_simple_bypass",
    "z2k_http_lf_prefix",
    "z2k_http_space_prefix",
    "z2k_http_tab_prefix",
    "z2k_http_multi_crlf",
    "z2k_http_mixed_prefix",
    "z2k_http_garbage_prefix",
    "z2k_http_hostmod",
    "z2k_http_method_obfuscate",
    "z2k_http_version_downgrade",
    "z2k_http_oob_prefix",
    "z2k_http_absolute_url",
    "z2k_http_absolute_uri_v2",
    "z2k_http_methodeol_v2",
    "z2k_http_methodeol_hostcase",
    "z2k_http_pipeline_fake",
    "z2k_http_pipeline_fake_v2",
    "z2k_http_fake_continuation",
    "z2k_http_fake_xhost",
    "z2k_http_header_shuffle",
    "z2k_http_host_bytesplit",
    "z2k_http_seqovl_host",
    "z2k_http_triple_seqovl",
    "z2k_http_mgts_combo",
    "z2k_http_combo_bypass",
    "z2k_http_super_decoy",
    "z2k_http_multidisorder",
    "z2k_http_ipfrag",
    "z2k_http_syndata",
    "z2k_http_aggressive",
    "z2k_success_no_reset",
    "z2k_http_success_positive_only",
    "z2k_timing_morph",
    "z2k_quic_morph_v2",
    "z2k_game_udp",
    "z2k_flood_white",
    "z2k_white_sandwich",
    "z2k_ttl_ladder",
    -- 16KB-bypass white-SNI presets (z2k-white-presets.lua)
    "z2k_white_max",
    "z2k_white_yandex",
    "z2k_white_mail",
    "z2k_white_sber",
    "z2k_white_vk",
    "z2k_white_rzd",
    "z2k_white_gosus",
    "z2k_white_msn",
    "z2k_white_google",
    "z2k_white_youtube",
    "z2k_ipfrag3",
    "z2k_ipfrag3_tiny",
    "z2k_dynamic_ttl",
    "z2k_dynamic_strategy",
    "z2k_cdn_detect",
    "cond_tcp_has_ts",
    "cond_cdn_cf",
    "cond_cdn_ovh",
    "cond_cdn_hetzner",
    "cond_cdn_do",
    "cond_cdn_other",
    "pick_cdn_sni",
    "circular",
    -- z2k-detectors.lua internal helper, top-level so earlier detector
    -- functions in the same file (z2k_tls_alert_fatal) can call it
    "z2k_detector_log_init_once",
    -- z2k-detectors.lua exported HTTP classifier; called from
    -- z2k-autocircular.lua's has_positive_incoming_response()
    "z2k_classify_http_reply",
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
