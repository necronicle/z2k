/* z2k-classify — symptom-to-block-type decision tree.
 *
 * Pure functions: takes probe_aggregate_t + cdn tag, writes block_type
 * + reason. No I/O, no mallocs.
 *
 * Distinguishing classes:
 *   - DNS / transit / mobile-csp (L3-L4, not our layer)
 *   - RKN_RST (early RST after CH inspection)
 *   - TSPU_16KB (byte-counter gate ~15-17K)
 *   - AWS_NO_TS (server doesn't speak TS)
 *   - SIZE_DPI (RST at non-16K size)
 *   - ANTI_DDOS_SLOWSTART (server initial winsize < 1500 — not DPI)
 *   - HYBRID / NONE / UNKNOWN
 *
 * Multi-replica analysis: if some replicas show block, others don't,
 * we mark `is_probabilistic` and still classify as the dominant block
 * type. Single-shot would have miscalled this as NONE.
 */
#include "classify.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *block_type_name(block_type_t t) {
	switch (t) {
	case BLOCK_NONE:                return "none";
	case BLOCK_TRANSIT_DROP:        return "transit_drop";
	case BLOCK_RKN_RST:             return "rkn_rst";
	case BLOCK_TSPU_16KB:           return "tspu_16kb";
	case BLOCK_AWS_NO_TS:           return "aws_no_ts";
	case BLOCK_MOBILE_ICMP:         return "mobile_icmp";
	case BLOCK_SIZE_DPI:            return "size_dpi";
	case BLOCK_JA3_FILTER:          return "ja3_filter";
	case BLOCK_ANTI_DDOS_SLOWSTART: return "anti_ddos_slowstart";
	case BLOCK_IP_LEVEL_CDN:        return "ip_level_cdn";
	case BLOCK_L3_ISP_DROP:         return "l3_isp_drop";
	case BLOCK_HYBRID:              return "hybrid";
	default:                        return "unknown";
	}
}

static int cmp_int(const void *a, const void *b) {
	int aa = *(const int *)a, bb = *(const int *)b;
	return (aa > bb) - (aa < bb);
}

void classify_aggregate(probe_aggregate_t *agg) {
	int n = agg->replica_count;
	if (n <= 0) return;

	agg->dns_ok = false;
	agg->icmp_reachable = false;
	agg->server_ts_negotiated = false;
	agg->tcp_connect_success_count = 0;
	agg->rst_observed_count = 0;
	agg->any_stalled_at_16kb = false;
	agg->all_stalled_at_16kb = true;
	agg->max_size_before_stall = 0;
	agg->max_size_final = 0;
	agg->min_server_winsize = 0xFFFFFFFFu;
	agg->total_duration_ms = 0;

	int rst_offsets[PROBE_REPLICAS_MAX];
	int rst_count = 0;

	for (int i = 0; i < n; i++) {
		const probe_replica_t *r = &agg->replicas[i];
		if (r->dns_ok)             agg->dns_ok = true;
		if (r->icmp_reachable)     agg->icmp_reachable = true;
		if (r->tcp_connect_ok)     agg->tcp_connect_success_count++;
		if (r->server_ts_negotiated) agg->server_ts_negotiated = true;
		if (r->server_rst_received) {
			agg->rst_observed_count++;
			rst_offsets[rst_count++] = r->rst_after_bytes;
		}
		if (r->size_before_stall > 0) {
			agg->any_stalled_at_16kb = true;
		} else {
			agg->all_stalled_at_16kb = false;
		}
		if (r->size_before_stall > agg->max_size_before_stall)
			agg->max_size_before_stall = r->size_before_stall;
		if (r->size_final > agg->max_size_final)
			agg->max_size_final = r->size_final;
		if (r->server_initial_winsize > 0 &&
		    r->server_initial_winsize < agg->min_server_winsize)
			agg->min_server_winsize = r->server_initial_winsize;
		agg->total_duration_ms += r->duration_ms;
	}

	if (agg->min_server_winsize == 0xFFFFFFFFu) agg->min_server_winsize = 0;

	if (rst_count > 0) {
		qsort(rst_offsets, rst_count, sizeof(int), cmp_int);
		if (rst_count % 2 == 1) {
			agg->median_rst_after_bytes = rst_offsets[rst_count / 2];
		} else {
			agg->median_rst_after_bytes =
				(rst_offsets[rst_count / 2 - 1] +
				 rst_offsets[rst_count / 2]) / 2;
		}
	}

	agg->is_probabilistic = (agg->rst_observed_count > 0 &&
	                          agg->rst_observed_count < n) ||
	                         (agg->any_stalled_at_16kb && !agg->all_stalled_at_16kb);

	if (n > 0 && !agg->any_stalled_at_16kb) agg->all_stalled_at_16kb = false;
}

void classify_infer(classify_result_t *out) {
	const probe_aggregate_t *a = &out->agg;

	/* Rule 1 — DNS fail. */
	if (!a->dns_ok) {
		out->block_type = BLOCK_UNKNOWN;
		snprintf(out->reason, sizeof(out->reason),
		         "DNS resolution failed across all probes — check DNS "
		         "(router DoH / Keenetic ndmc ip host)");
		out->recommended[0] = '\0';
		return;
	}

	/* Rule 2a — Path discovery says trace stops at our ISP's last-mile
	 * router and never exits to dest. This is L3 null-route by the ISP
	 * (МТС on Pushwoosh per Михаил's case 2026-04-26: trace died at
	 * a197-cr07 МТС.msk; pushbr.com unreachable). DPI tactics WILL NOT
	 * help — packets never leave the ISP AS. VPN/proxy only.
	 *
	 * Detected: trace_attempted AND !reaches_dest AND last_live_ttl > 0
	 *           AND last hop's revdns matches a known ISP suffix. */
	if (a->trace_attempted && !a->trace_reaches_dest &&
	    a->trace_last_live_ttl > 0 && a->trace_isp_name[0]) {
		out->block_type = BLOCK_L3_ISP_DROP;
		snprintf(out->reason, sizeof(out->reason),
		         "L3 null-route inside %s (last live hop %d: %s). "
		         "Packets never exit the ISP AS toward the destination "
		         "— not a DPI block. DPI bypass strategies will NOT help. "
		         "Use VPN/proxy, or if the destination is on a CDN with "
		         "alternate anycast IPs, try a hosts override.",
		         a->trace_isp_name, a->trace_last_live_ttl,
		         a->trace_last_revdns[0] ? a->trace_last_revdns
		                                 : "(no rdns)");
		snprintf(out->recommended, sizeof(out->recommended),
		         "VPN/proxy (or hosts_override if CDN has alt anycast)");
		return;
	}

	/* Rule 2b — TCP timed out everywhere AND ICMP also lost (no trace
	 * data either). Generic transit drop. */
	if (a->tcp_connect_success_count == 0 && !a->icmp_reachable) {
		out->block_type = BLOCK_TRANSIT_DROP;
		snprintf(out->reason, sizeof(out->reason),
		         "TCP connect timed out (%d/%d replicas) AND ICMP "
		         "unreachable. Upstream routing black hole or full "
		         "IP-level block. Not a DPI problem — no strategy helps. "
		         "Check traceroute.",
		         a->replica_count, a->replica_count);
		out->recommended[0] = '\0';
		return;
	}

	/* Rule 3 — ICMP works but TCP fails. Mobile CSP / port block. */
	if (a->icmp_reachable && a->tcp_connect_success_count == 0) {
		out->block_type = BLOCK_MOBILE_ICMP;
		snprintf(out->reason, sizeof(out->reason),
		         "ICMP works but TCP connect fails (%d/%d) — mobile CSP "
		         "quench (Beeline/T2/MegaFon pattern) or dst-port block. "
		         "DPI strategies don't help at L4.",
		         a->tcp_connect_success_count, a->replica_count);
		snprintf(out->recommended, sizeof(out->recommended),
		         "none (not a DPI block)");
		return;
	}

	/* Rule 4 — anti-DDoS slow-start. NOT auto-detected here: tcpi_snd_mss
	 * is just MSS, not advertised window — can't tell from probe alone.
	 * Real signal needs raw packet capture (winsize<256 in SYN-ACK).
	 * Left as a manual override path; classify_infer never enters this
	 * branch from probe data. (BLOCK_ANTI_DDOS_SLOWSTART exists in the
	 * enum for future raw-capture upgrade.) */

	/* Rule 5 — RST seen in MAJORITY of replicas + early offset = RKN_RST.
	 * Majority gate (rst*2 >= n) prevents single transient RSTs from
	 * masking 16KB stalls in hybrid blocks; minority RSTs fall through
	 * to Rule 6 (stall) first, then Rule 5b (HYBRID) below. */
	if (a->rst_observed_count > 0 && a->median_rst_after_bytes < 500 &&
	    a->rst_observed_count * 2 >= a->replica_count) {
		out->block_type = BLOCK_RKN_RST;
		snprintf(out->reason, sizeof(out->reason),
		         "RST observed in %d/%d replicas at byte offset ~%d — "
		         "RKN-style hostlist DPI%s.",
		         a->rst_observed_count, a->replica_count,
		         a->median_rst_after_bytes,
		         a->is_probabilistic ? " (probabilistic — sampled DPI)" : "");
		snprintf(out->recommended, sizeof(out->recommended),
		         "multisplit pos=1 seqovl=681 with google/gosuslugi bin "
		         "(RTK-universal); fallback fake+padencap (Beeline-validated)");
		return;
	}

	/* Rule 6 — flow stalls in 15-17K window. TSPU 16KB byte-gate. */
	if (a->any_stalled_at_16kb && a->max_size_before_stall >= 15000 &&
	    a->max_size_before_stall <= 17000) {
		out->block_type = BLOCK_TSPU_16KB;
		snprintf(out->reason, sizeof(out->reason),
		         "Flow stalled at %u bytes (15-17K window) in %d/%d "
		         "replicas — TSPU byte-gate / whitelist-SNI throttle. "
		         "Per ntc.party d/1812 + #1836: needs CDN-specific bin "
		         "+ padencap.",
		         a->max_size_before_stall,
		         (a->all_stalled_at_16kb ? a->replica_count :
		            (a->is_probabilistic ? 1 : a->replica_count)),
		         a->replica_count);
		snprintf(out->recommended, sizeof(out->recommended),
		         "fake+padencap (CF=google bin, OVH=gosuslugi bin) "
		         "+ wssize 1:6");
		return;
	}

	/* Rule 5b — minority RST (<50% replicas) at early offset, but no
	 * stall fired above. Hybrid signature: probabilistic DPI sampling
	 * that single-shot probing miscalls. Pin block_type=HYBRID so the
	 * apply_phase recipe lookup falls through to a defensive recipe
	 * (currently no HYBRID-specific recipe — recipe_for() returns NULL,
	 * apply emits "unmapped, escalate"). */
	if (a->rst_observed_count > 0 && a->median_rst_after_bytes < 500) {
		out->block_type = BLOCK_HYBRID;
		snprintf(out->reason, sizeof(out->reason),
		         "Probabilistic RST in %d/%d replicas at byte ~%d "
		         "(below majority gate); no 16KB stall observed. Hybrid "
		         "signature — sampled DPI or transient network event.",
		         a->rst_observed_count, a->replica_count,
		         a->median_rst_after_bytes);
		snprintf(out->recommended, sizeof(out->recommended),
		         "rerun probe with --replicas=5; if RST count climbs, "
		         "treat as RKN_RST; if not, suspect noise");
		return;
	}

	/* Rule 7 — silent drop: connect OK, NO bytes, NO RST. RKN-style
	 * silent ClientHello drop. */
	if (a->tcp_connect_success_count > 0 && a->max_size_final == 0 &&
	    a->rst_observed_count == 0) {
		out->block_type = BLOCK_RKN_RST;
		snprintf(out->reason, sizeof(out->reason),
		         "TCP connect OK but server sent NO bytes (%d/%d "
		         "replicas) — silent DPI drop after CH inspection. "
		         "Probe timed out waiting for ServerHello.",
		         a->replica_count, a->replica_count);
		snprintf(out->recommended, sizeof(out->recommended),
		         "multisplit seqovl=681 with cdn-matched bin");
		return;
	}

	/* Rule 8 — connect OK, no TS, response truncated or RST.
	 * AWS_NO_TS frontend pattern. */
	if (a->tcp_connect_success_count > 0 && !a->server_ts_negotiated &&
	    a->max_size_final > 0 &&
	    (a->rst_observed_count > 0 || a->max_size_final < 500)) {
		out->block_type = BLOCK_AWS_NO_TS;
		snprintf(out->reason, sizeof(out->reason),
		         "TCP connect OK, server did NOT negotiate TS, response "
		         "truncated (max=%u). AWS/CDN frontend pattern — tcp_ts "
		         "fooling is wasted. Use TTL-based or hostfakesplit "
		         "with badack-only mechanism.",
		         a->max_size_final);
		snprintf(out->recommended, sizeof(out->recommended),
		         "hostfakesplit host=vk.com tcp_ack=-66000 ip_ttl=4 "
		         "(per bol-van #2039)");
		return;
	}

	/* Rule 9 — RST at large offset (non-16K). Generic size-DPI. */
	if (a->rst_observed_count > 0 && a->median_rst_after_bytes > 1000 &&
	    (a->median_rst_after_bytes < 14000 ||
	     a->median_rst_after_bytes > 18000)) {
		out->block_type = BLOCK_SIZE_DPI;
		snprintf(out->reason, sizeof(out->reason),
		         "RST at byte offset ~%d (outside 15-17K window) — "
		         "size-gated DPI with non-standard threshold.",
		         a->median_rst_after_bytes);
		snprintf(out->recommended, sizeof(out->recommended),
		         "multidisorder pos=method+2,midsld,5");
		return;
	}

	/* Rule 10 — handshake OK, lots of bytes, no symptoms. Not blocked
	 * (or our minimal CH slipped through where Chrome's wouldn't —
	 * possible JA3 filter, undetectable here). */
	if (a->tcp_connect_success_count > 0 && a->max_size_final > 1000 &&
	    a->rst_observed_count == 0) {
		out->block_type = BLOCK_NONE;
		snprintf(out->reason, sizeof(out->reason),
		         "Full handshake + %u bytes received in all %d replicas "
		         "with minimal ClientHello. Domain appears reachable. "
		         "If a real browser fails here, suspect JA3 fingerprint "
		         "filter (Phase 1 can't detect — needs manual test).",
		         a->max_size_final, a->replica_count);
		out->recommended[0] = '\0';
		return;
	}

	/* Fallback. */
	out->block_type = BLOCK_UNKNOWN;
	snprintf(out->reason, sizeof(out->reason),
	         "Probe symptoms inconsistent: connect=%d/%d, rst=%d/%d, "
	         "size_final_max=%u, ts_negotiated=%d, winsize_min=%u. "
	         "Manual inspection required.",
	         a->tcp_connect_success_count, a->replica_count,
	         a->rst_observed_count, a->replica_count,
	         a->max_size_final, a->server_ts_negotiated,
	         a->min_server_winsize);
	out->recommended[0] = '\0';
}
