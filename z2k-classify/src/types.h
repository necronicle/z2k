/* z2k-classify — shared types and enums
 *
 * Keep this header self-contained and C99. Used by probe.c, classify.c,
 * and main.c.
 */
#ifndef Z2K_CLASSIFY_TYPES_H
#define Z2K_CLASSIFY_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include <netinet/in.h>

/* Block types. Keep in sync with block_type_name() in classify.c. */
typedef enum {
	BLOCK_NONE = 0,       /* no block detected */
	BLOCK_TRANSIT_DROP,   /* packets don't come back (upstream loss) */
	BLOCK_RKN_RST,        /* DPI injects RST after ClientHello */
	BLOCK_TSPU_16KB,      /* flow hangs at ~16 KB boundary */
	BLOCK_AWS_NO_TS,      /* server doesn't negotiate TCP timestamps */
	BLOCK_MOBILE_ICMP,    /* ICMP/early-packet quench */
	BLOCK_SIZE_DPI,       /* response truncated at non-16 KB offset */
	BLOCK_JA3_FILTER,     /* response diverges for real-browser JA3 */
	BLOCK_HYBRID,         /* multiple positive symptoms */
	BLOCK_UNKNOWN,        /* all rules failed */
	BLOCK_COUNT_
} block_type_t;

/* Single probe symptom result. */
typedef struct {
	bool dns_ok;              /* name resolved to IPv4 */
	bool icmp_reachable;      /* ping got at least one echo-reply */
	bool tcp_connect_ok;      /* TCP 3-way handshake completed */
	bool tls_handshake_ok;    /* TLS ClientHello → ServerHello */
	uint32_t size_before_stall;  /* bytes received before stall/truncate */
	uint32_t size_final;         /* bytes total when flow ended */
	bool server_ts_negotiated;   /* TCP timestamp option echoed by server */
	bool server_rst_received;    /* saw RST while app expected data */
	int rst_after_bytes;         /* offset at which RST arrived (0 = SYN/ACK) */
	int duration_ms;             /* wall clock for this probe */
} probe_result_t;

/* Full classification output. */
typedef struct {
	char domain[256];
	struct in_addr resolved_ip;
	probe_result_t probe;
	block_type_t block_type;
	char reason[512];         /* human-readable why this type */
	char recommended[1024];   /* comma-list of candidate primitives (Phase 1 only) */
} classify_result_t;

/* Utility from classify.c. */
const char *block_type_name(block_type_t t);

#endif
