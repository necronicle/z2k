/* z2k-classify — per-block-type strategy templates.
 *
 * Strategy numbers below match strats_new2.txt as of 2026-04-24
 * (z2k-enhanced). These are the candidate-best strategies for each
 * block type, ordered roughly by observed field effectiveness.
 *
 * When strats_new2.txt gains/loses strategies, these lists need to be
 * updated. Phase 4 will make this dynamic (parse Strategy.txt live).
 */
#include "templates.h"

#include <stddef.h>

static const template_t templates[] = {

	/* rkn_rst — RKN DPI injects RST or silently drops after SNI
	 * inspection. rkn_tcp rotator strategies known to pass RKN DPI:
	 *   1  — fake fake_default_tls + tcp_ts=-1000 + multisplit
	 *   3  — multisplit pos=1 seqovl=568 pattern=4pda.to
	 *   4  — multisplit pos=1,sniext+1 seqovl=1 (sniext trick)
	 *   5  — fake blob=0x00000000 + multidisorder (uses tcp_seq=2)
	 *   7  — fake fake_default_tls tcp_seq=2 + fakedsplit
	 *   8  — fake blob=tls_clienthello_activated (badseq via alias)
	 *   44 — multidisorder pos=2,5,105,host+5,sld-1,endsld-5,endsld
	 *   46 — fake blob=tls_clienthello_gosuslugi_ru (badseq increment=2)
	 *   47 — multisplit pos=1 seqovl=700 pattern=gosuslugi_ru
	 *
	 * Phase 4 reordering (2026-04-25, Alexey field signal): strategy=1
	 * uses `tcp_ts=-1000` which has shown regression on some TSPU since
	 * mid-April (ntc.party 21161 #826). Pushed to LAST position so the
	 * non-tcp_ts strategies (which work consistently) get probed first. */
	{BLOCK_RKN_RST, "rkn_tcp", {4, 46, 47, 8, 7, 5, 44, 3, 1}, 9},

	/* tspu_16kb — CF/OVH/Hetzner/DO whitelist-SNI byte-gate. cdn_tls
	 * rotator is already 7 strategies tuned for exactly this case:
	 *   1 — multisplit pos=1,sniext+1 seqovl=1
	 *   2 — fake tls_clienthello_www_google_com + badseq-equivalent
	 *   3 — hostfakesplit host=mail.ru seqovl=1 badsum
	 *   4 — multidisorder pos=method+2,midsld,5
	 *   6 — fake tls_mod=padencap
	 *   7 — fake tls_mod=rndsni
	 *   8 — per-provider SNI dispatch via pick_cdn_sni (dynamic) */
	{BLOCK_TSPU_16KB, "cdn_tls", {8, 1, 2, 3, 6, 7, 4}, 7},

	/* aws_no_ts — server doesn't negotiate TS. tcp_ts fooling is a
	 * no-op so prefer TTL-only / split-only strategies. */
	{BLOCK_AWS_NO_TS, "cdn_tls", {5, 1, 3}, 3},

	/* size_dpi — DPI gate at non-16KB offset. Same primitive family as
	 * tspu_16kb but ordered to lead with size-manipulating strategies
	 * (padencap inflates ClientHello, multidisorder scrambles packet
	 * order DPI sees). The exact gate offset varies by ISP/AS; trying
	 * all 7 lets autocircular discover what works for each specific
	 * threshold. */
	{BLOCK_SIZE_DPI, "cdn_tls", {6, 4, 8, 1, 3, 7, 2}, 7},

	/* hybrid — multiple positive symptoms (both early-RST AND mid-flow
	 * stall, or unusual combo). Fall back to the broad rkn_tcp set
	 * since it has the largest variety of DPI bypass primitives.
	 * Probably overkill for any single hybrid case but ensures we try
	 * something useful before reporting "manual investigation needed". */
	{BLOCK_HYBRID, "rkn_tcp", {4, 46, 47, 1, 8, 7, 5, 44, 3}, 9},

	/* Block types intentionally without templates — no DPI strategy
	 * can help; classifier output already explains:
	 *   BLOCK_NONE         — domain reachable, nothing to bypass
	 *   BLOCK_TRANSIT_DROP — packets don't return, network-level
	 *   BLOCK_MOBILE_ICMP  — L4 quench, not DPI
	 *   BLOCK_JA3_FILTER   — Phase 1 probe can't reliably detect or
	 *                        bypass; needs curl-impersonate fork (post
	 *                        Phase 4 if becomes a real signal)
	 *   BLOCK_UNKNOWN      — by definition no template
	 */

};

const template_t *template_for_block(block_type_t t) {
	for (size_t i = 0; i < sizeof(templates) / sizeof(templates[0]); i++) {
		if (templates[i].block == t) return &templates[i];
	}
	return NULL;
}
