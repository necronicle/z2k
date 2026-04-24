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
	 *   1  — multisplit pos=1 seqovl=681 pattern=www.google.com
	 *   3  — multisplit pos=1 seqovl=568 pattern=4pda.to
	 *   4  — multisplit pos=1,sniext+1 seqovl=1 (sniext trick)
	 *   5  — fake blob=0x00000000 + multidisorder
	 *   7  — fake fake_default_tls tcp_seq=2 + fakedsplit
	 *   8  — fake blob=tls_clienthello_activated (badseq via alias)
	 *   44 — multidisorder pos=2,5,105,host+5,sld-1,endsld-5,endsld
	 *   46 — fake blob=tls_clienthello_gosuslugi_ru (badseq increment=2)
	 *   47 — multisplit pos=1 seqovl=700 pattern=gosuslugi_ru
	 */
	{BLOCK_RKN_RST, "rkn_tcp", {4, 1, 3, 46, 8, 7, 47, 5, 44}, 9},

	/* tspu_16kb — CF/OVH/Hetzner/DO whitelist-SNI byte-gate. cdn_tls
	 * rotator is already 7 strategies tuned for exactly this case:
	 *   1 — multisplit pos=1,sniext+1 seqovl=1
	 *   2 — fake tls_clienthello_www_google_com + badseq-equivalent
	 *   3 — hostfakesplit host=mail.ru seqovl=1 badsum
	 *   4 — multidisorder pos=method+2,midsld,5
	 *   6 — fake tls_mod=padencap
	 *   7 — fake tls_mod=rndsni
	 *   8 — per-provider SNI dispatch via pick_cdn_sni (dynamic)
	 */
	{BLOCK_TSPU_16KB, "cdn_tls", {8, 1, 2, 3, 6, 7, 4}, 7},

	/* aws_no_ts — same profile as tspu_16kb but server doesn't
	 * negotiate TS. Strategies that use TTL fooling (not tcp_ts):
	 *   5 — fake fake_default_tls ip_autottl=-2,3-20
	 * Also rkn_tcp ones with TTL-based fooling fall back here.
	 * Phase 2 ships minimal set; Phase 4 will expand with Rule-6b
	 * specific templates once we capture real AWS traffic. */
	{BLOCK_AWS_NO_TS, "cdn_tls", {5, 1, 3}, 3},

	/* google_tls block — YT/googlevideo handlers have their own
	 * 44-strategy rotator. If classifier detects block symptoms on
	 * google-owned IP, probe those. (Not currently auto-detected by
	 * Phase 1 — reserved for Phase 4 when we add dst-IP-to-profile
	 * mapping.) */

};

const template_t *template_for_block(block_type_t t) {
	for (size_t i = 0; i < sizeof(templates) / sizeof(templates[0]); i++) {
		if (templates[i].block == t) return &templates[i];
	}
	return NULL;
}
