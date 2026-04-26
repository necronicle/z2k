/* z2k-classify — shared types and enums.
 *
 * Used by probe.c, classify.c, recipe.c, generator.c, main.c.
 * C99, self-contained.
 */
#ifndef Z2K_CLASSIFY_TYPES_H
#define Z2K_CLASSIFY_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include <netinet/in.h>

/* Block types. Keep in sync with block_type_name() in classify.c. */
typedef enum {
	BLOCK_NONE = 0,
	BLOCK_TRANSIT_DROP,           /* packets don't come back (upstream loss) */
	BLOCK_RKN_RST,                /* DPI injects RST after ClientHello */
	BLOCK_TSPU_16KB,              /* flow hangs at ~16 KB byte-gate */
	BLOCK_AWS_NO_TS,              /* server doesn't negotiate TCP timestamps */
	BLOCK_MOBILE_ICMP,            /* ICMP/early-packet quench */
	BLOCK_SIZE_DPI,               /* response truncated at non-16 KB offset */
	BLOCK_JA3_FILTER,             /* response diverges for real-browser JA3 */
	BLOCK_ANTI_DDOS_SLOWSTART,    /* server window<expected — NOT DPI, escalate */
	BLOCK_IP_LEVEL_CDN,           /* per-CIDR whitelist — only hosts override works */
	BLOCK_HYBRID,                 /* multiple positive symptoms */
	BLOCK_UNKNOWN,
	BLOCK_COUNT_
} block_type_t;

/* CDN/hosting identifier from resolved IP. Drives recipe selection
 * because the same block type often needs CDN-specific bins (OVH wants
 * gosuslugi.ru bin, CF wants google.com bin). Lookup in recipe.c via
 * cdn_for_ip(). */
typedef enum {
	CDN_UNKNOWN = 0,              /* not on any major CDN we know — generic recipe */
	CDN_CLOUDFLARE,
	CDN_OVH,
	CDN_HETZNER,
	CDN_DIGITALOCEAN,
	CDN_AWS,                      /* general AWS (EC2, S3) — TS-quirky */
	CDN_CLOUDFRONT,               /* AWS CloudFront — separate ranges */
	CDN_ORACLE,
	CDN_AKAMAI,
	CDN_GOOGLE,
	CDN_FASTLY,
	CDN_COUNT_
} cdn_id_t;

/* Single probe replica. */
typedef struct {
	bool dns_ok;
	bool icmp_reachable;
	bool tcp_connect_ok;
	bool tls_handshake_ok;
	bool server_ts_negotiated;
	bool server_rst_received;
	int  rst_after_bytes;
	uint32_t size_before_stall;   /* non-zero if 16K stall heuristic fired */
	uint32_t size_final;
	uint32_t server_initial_winsize;  /* server's SYN-ACK window — for slow-start detection */
	int  duration_ms;
} probe_replica_t;

#define PROBE_REPLICAS_MAX 5

/* Aggregate over N probe replicas. */
typedef struct {
	probe_replica_t replicas[PROBE_REPLICAS_MAX];
	int  replica_count;

	/* derived signals */
	bool dns_ok;
	bool icmp_reachable;
	int  tcp_connect_success_count;
	int  rst_observed_count;
	bool is_probabilistic;            /* RST in some replicas not all */
	bool any_stalled_at_16kb;
	bool all_stalled_at_16kb;
	bool server_ts_negotiated;        /* at least once */
	int  median_rst_after_bytes;
	uint32_t max_size_before_stall;
	uint32_t max_size_final;
	uint32_t min_server_winsize;      /* lowest seen — antiddos signal if <1500 */
	int  total_duration_ms;
} probe_aggregate_t;

/* Full classification output. */
typedef struct {
	char domain[256];
	struct in_addr resolved_ip;
	cdn_id_t cdn;                     /* discriminator from resolved_ip */
	probe_aggregate_t agg;
	block_type_t block_type;
	char reason[512];
	char recommended[1024];           /* informational; may be empty */

	/* Generator output — filled when --apply was used. */
	bool apply_attempted;
	bool apply_succeeded;
	bool unmapped;                    /* no recipe entry for (block, cdn, has_ts) */
	int  winner_strategy;             /* assigned id from inject_persist; -1 dry-run; 0 transient-only */
	char winner_profile[64];          /* "rkn_tcp" / "cdn_tls" / etc. */
	char winner_family[32];           /* "multisplit" / "fake" / etc. */
	char winner_label[160];           /* human label of selected recipe */
	char winner_cite[160];            /* source cite */
	char apply_note[320];
} classify_result_t;

/* From classify.c */
const char *block_type_name(block_type_t t);

#endif
