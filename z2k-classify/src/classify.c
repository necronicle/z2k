/* z2k-classify — symptom to block-type decision tree.
 *
 * Pure function: takes probe_result_t, writes block_type + reason +
 * recommended primitives. No I/O, no mallocs (fixed buffers).
 *
 * Decision logic summarizes the matrix we built from:
 *   - ntc.party 17013 (CF/OVH/Hetzner/DO 16KB throttle thread)
 *   - ntc.party 21161 (zapret2 discussion — AWS no-TS, mobile CSP)
 *   - our own field reports (Alexey on rutracker, Andrey on games)
 */
#include "classify.h"

#include <stdio.h>
#include <string.h>

const char *block_type_name(block_type_t t) {
	switch (t) {
	case BLOCK_NONE:         return "none";
	case BLOCK_TRANSIT_DROP: return "transit_drop";
	case BLOCK_RKN_RST:      return "rkn_rst";
	case BLOCK_TSPU_16KB:    return "tspu_16kb";
	case BLOCK_AWS_NO_TS:    return "aws_no_ts";
	case BLOCK_MOBILE_ICMP:  return "mobile_icmp";
	case BLOCK_SIZE_DPI:     return "size_dpi";
	case BLOCK_JA3_FILTER:   return "ja3_filter";
	case BLOCK_HYBRID:       return "hybrid";
	default:                 return "unknown";
	}
}

void classify_infer(classify_result_t *out) {
	const probe_result_t *p = &out->probe;

	/* Rule 1 — DNS fail -> blocked at DNS level (not our layer). */
	if (!p->dns_ok) {
		out->block_type = BLOCK_UNKNOWN;
		snprintf(out->reason, sizeof(out->reason),
		         "DNS resolution failed — check DNS (router DoH / Keenetic ndmc ip host)");
		out->recommended[0] = '\0';
		return;
	}

	/* Rule 2 — TCP connect times out AND ICMP also lost -> transit
	 * drop. Packets never come back. No DPI strategy saves this. */
	if (!p->tcp_connect_ok && !p->icmp_reachable) {
		out->block_type = BLOCK_TRANSIT_DROP;
		snprintf(out->reason, sizeof(out->reason),
		         "TCP connect timed out AND ICMP unreachable — upstream "
		         "routing black hole or full IP-level block. Not a DPI "
		         "problem, no strategy will help. Check traceroute.");
		out->recommended[0] = '\0';
		return;
	}

	/* Rule 3 — ICMP works but many early packets lost / rate-limited.
	 * Signature of mobile CSP quench. (Partial: Phase 1 doesn't yet
	 * send enough ICMP probes to distinguish this from a one-off.) */
	if (p->icmp_reachable && !p->tcp_connect_ok) {
		out->block_type = BLOCK_MOBILE_ICMP;
		snprintf(out->reason, sizeof(out->reason),
		         "ICMP works but TCP connect fails — possible mobile "
		         "CSP quench (Beeline/T2/MegaFon pattern) or dst-port "
		         "block. DPI strategies don't help at L4.");
		snprintf(out->recommended, sizeof(out->recommended),
		         "none (not a DPI block)");
		return;
	}

	/* Rule 4 — TCP connect OK, then RST fires before/during TLS.
	 * Classic RKN hostlist DPI signature: SNI inspected, RST injected. */
	if (p->tcp_connect_ok && p->server_rst_received && p->rst_after_bytes < 500) {
		out->block_type = BLOCK_RKN_RST;
		snprintf(out->reason, sizeof(out->reason),
		         "TCP connect OK, RST received at byte offset %d (early) — "
		         "RKN-style hostlist DPI injecting RST after SNI inspection.",
		         p->rst_after_bytes);
		snprintf(out->recommended, sizeof(out->recommended),
		         "multisplit(pos=1,sniext+1,seqovl=1), "
		         "fake(blob=tls_clienthello_www_google_com,repeats=6,tcp_ts=-1000), "
		         "fakedsplit(pos=method+2), "
		         "syndata(blob=syn_packet), "
		         "hostfakesplit(host=mail.ru)");
		return;
	}

	/* Rule 5 — TCP connect OK, flow stalls around 15-17 KB. The
	 * defining TSPU 16KB whitelist-SNI signature. Server's ClientHello
	 * reply got through, but flow chokes at the byte-counter gate. */
	if (p->tcp_connect_ok && p->size_before_stall >= 15000 &&
	    p->size_before_stall <= 17000) {
		out->block_type = BLOCK_TSPU_16KB;
		snprintf(out->reason, sizeof(out->reason),
		         "Flow stalled at %u bytes (within 15-17 KB window) — "
		         "TSPU whitelist-SNI throttle. Need a fake-SNI-in-decoy "
		         "or sniext+1 split strategy to escape the byte gate.",
		         p->size_before_stall);
		snprintf(out->recommended, sizeof(out->recommended),
		         "multisplit(pos=1,sniext+1,seqovl=1), "
		         "fake(blob=tls_clienthello_www_google_com,badseq,tcp_ack=-66000), "
		         "hostfakesplit(host=mail.ru,seqovl=1,badsum), "
		         "fake(tls_mod=padencap), "
		         "fake(tls_mod=rndsni)");
		return;
	}

	/* Rule 6a — silent drop: TCP connect OK, but server sent NOTHING
	 * at all (0 bytes) and no RST was injected. Common RKN DPI
	 * pattern — ClientHello reaches DPI, DPI silently drops all
	 * subsequent packets without injecting RST. Probe hits read
	 * timeout with empty rx. Different from RKN_RST which injects
	 * visible RST. */
	if (p->tcp_connect_ok && p->size_final == 0 && !p->server_rst_received) {
		out->block_type = BLOCK_RKN_RST;  /* reuse type; phase 2 will
		                                     split into RKN_DROP sub-type */
		snprintf(out->reason, sizeof(out->reason),
		         "TCP connect OK but server sent NO bytes (silent DPI "
		         "drop). Classical RKN filtering — ClientHello inspected, "
		         "flow silently dropped without RST injection. Probe "
		         "would have timed out waiting.");
		snprintf(out->recommended, sizeof(out->recommended),
		         "multisplit(pos=1,sniext+1,seqovl=1), "
		         "fake(blob=tls_clienthello_www_google_com,repeats=6), "
		         "fakedsplit(pos=method+2,badsum), "
		         "syndata(blob=syn_packet), "
		         "hostfakesplit(host=mail.ru,seqovl=1)");
		return;
	}

	/* Rule 6b — AWS/CDN frontend that doesn't negotiate timestamps.
	 * Critical: tcp_ts fooling becomes a no-op on such servers. Only
	 * trigger when we got a response (not silent-drop case above). */
	if (p->tcp_connect_ok && !p->server_ts_negotiated && p->size_final > 0 &&
	    (p->server_rst_received || p->size_final < 500)) {
		out->block_type = BLOCK_AWS_NO_TS;
		snprintf(out->reason, sizeof(out->reason),
		         "TCP connect OK, server did NOT negotiate timestamps "
		         "(AWS/CDN frontend pattern). tcp_ts=-N fooling is "
		         "wasted on this server — use TTL-based variants.");
		snprintf(out->recommended, sizeof(out->recommended),
		         "fake(ip_ttl=7), "
		         "fake(ip_autottl=-2,3-20), "
		         "multisplit(pos=1,sniext+1,seqovl=1), "
		         "fake(blob=tls_clienthello_www_google_com,ip_ttl=4)");
		return;
	}

	/* Rule 6c — server sent only a TLS alert record (~7 bytes) and
	 * closed. Not a DPI block — the server itself rejected our probe's
	 * ClientHello (likely TLS config mismatch: cipher-suite picky,
	 * requires SNI-specific vhost, etc.). Report as tooling limitation
	 * rather than misclassifying. */
	if (p->tcp_connect_ok && p->tls_handshake_ok &&
	    p->size_final >= 5 && p->size_final <= 50 &&
	    !p->server_rst_received) {
		out->block_type = BLOCK_UNKNOWN;
		snprintf(out->reason, sizeof(out->reason),
		         "Server replied with small (%u-byte) response — likely "
		         "TLS alert rejecting our probe's ClientHello. This is a "
		         "TOOLING limitation (our CH lacks TLS 1.3 key-share), "
		         "not a DPI signature. To confirm a block, try curl or "
		         "a browser and check what happens at network level.",
		         p->size_final);
		out->recommended[0] = '\0';
		return;
	}

	/* Rule 7 — TCP connect OK, flow truncated at a specific non-16KB
	 * offset. Catch-all for size-based DPI with different gate value. */
	if (p->tcp_connect_ok && p->server_rst_received &&
	    p->rst_after_bytes > 1000 &&
	    (p->rst_after_bytes < 14000 || p->rst_after_bytes > 18000)) {
		out->block_type = BLOCK_SIZE_DPI;
		snprintf(out->reason, sizeof(out->reason),
		         "Flow terminated at %d bytes (outside 15-17 KB window) "
		         "— size-gated DPI with non-standard threshold. Try "
		         "udplen-analog for TCP via padencap or multisplit.",
		         p->rst_after_bytes);
		snprintf(out->recommended, sizeof(out->recommended),
		         "fake(tls_mod=padencap), "
		         "multisplit(pos=sld+1), "
		         "multidisorder(pos=method+2,midsld,5)");
		return;
	}

	/* Rule 8 — No obvious symptom, handshake finished, bytes read OK.
	 * Either the domain isn't blocked or our probe's minimal CH slipped
	 * through while Chrome's wouldn't (possible JA3 filter). Phase 1
	 * can't distinguish; flag as candidate for JA3 check + suggest
	 * manual browser test. */
	if (p->tcp_connect_ok && p->tls_handshake_ok && p->size_final > 1000) {
		out->block_type = BLOCK_NONE;
		snprintf(out->reason, sizeof(out->reason),
		         "Full handshake + %u bytes received with minimal "
		         "ClientHello. Domain appears reachable. If a real "
		         "browser fails here, suspect JA3 fingerprint filter "
		         "(Phase 1 can't detect that — manual test needed).",
		         p->size_final);
		out->recommended[0] = '\0';
		return;
	}

	/* Fallback — symptoms don't match any known pattern. */
	out->block_type = BLOCK_UNKNOWN;
	snprintf(out->reason, sizeof(out->reason),
	         "Probe produced an unusual symptom combination "
	         "(connect=%d, tls_ok=%d, rst=%d, rst_at=%d, size=%u, "
	         "ts=%d). Manual inspection required.",
	         p->tcp_connect_ok, p->tls_handshake_ok,
	         p->server_rst_received, p->rst_after_bytes,
	         p->size_final, p->server_ts_negotiated);
	out->recommended[0] = '\0';
}
