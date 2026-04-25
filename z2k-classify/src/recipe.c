/* z2k-classify — per-block-type primitive recipe library.
 *
 * Encodes the empirical knowledge of which DPI primitives + parameter
 * ranges historically work for which block type. Sources:
 *   - ntc.party threads 17013 (CF/OVH/Hetzner block) and 21161
 *     (zapret2 discussion)
 *   - Smart-Zapret-Launcher gaming_*.conf flag analysis
 *   - Our strats_new2.txt (47 rkn_tcp + 22 yt + 22 gv + 7 cdn_tls)
 *   - Field reports (Alexey rutracker, Andrey games, Maksim AWS-eu-central)
 *
 * When a new block type / new effective primitive shows up in the
 * field, edit this file. Generator picks up new axes/values at the
 * next build.
 */
#include "recipe.h"

#include <stddef.h>

/* ---------- shared whitelist SNI strings ---------- */
/* Used as values in `seqovl_pattern=` and `blob=`/`sni=` axes. These
 * are the bytestrings DPI hostlists historically allow through. */
#define SNI_GOOGLE     "tls_clienthello_www_google_com"
#define SNI_4PDA       "tls_clienthello_4pda_to"
#define SNI_MAX_RU     "tls_max_ru"
#define SNI_VK         "tls_clienthello_vk_com"
#define SNI_GOSUSLUGI  "tls_clienthello_gosuslugi_ru"
#define SNI_ACTIVATED  "tls_clienthello_activated"
#define SNI_ONETRUST   "tls_clienthello_www_onetrust_com"
#define SNI_OZON_QUIC  "quic_ozon_ru"

static const recipe_t recipes[] = {

/* =========================================================================
 * RKN_RST — DPI inspects SNI in ClientHello, injects RST or silently
 * drops. Bypass: corrupt the SNI as DPI sees it (split, pad, replace),
 * or send an alternate-SNI fake before the real CH so DPI latches on
 * the decoy.
 * ========================================================================= */
{
	BLOCK_RKN_RST, "rkn_tcp", {

		/* Family 1 — sniext+1 split (the universal-ish trick from
		 * ntc.party 17013). Smashes SNI byte-boundary so DPI hashes
		 * different than real string. Highest priority. */
		{
			"sniext-split", "multisplit",
			"payload=tls_client_hello:dir=out",
			{
				{"pos", {"1,sniext+1", "1", "sniext+1", "sld+1"}, 4},
				{"seqovl", {"1", "100", "500", "681"}, 4},
				{"seqovl_pattern", {SNI_GOOGLE, SNI_4PDA, SNI_GOSUSLUGI}, 3},
			},
			3
		},

		/* Family 2 — fake decoy SNI sent BEFORE real CH. DPI sees
		 * the decoy first, latches on its allowed SNI, lets the
		 * real CH through. badseq (tcp_seq=-10000:tcp_ack=-66000)
		 * keeps the decoy invisible to the real server. */
		{
			"fake-decoy", "fake",
			"payload=tls_client_hello:dir=out",
			{
				{"blob", {SNI_GOOGLE, SNI_4PDA, SNI_GOSUSLUGI, SNI_ACTIVATED}, 4},
				{"repeats", {"6", "8", "11"}, 3},
				{"tcp_seq", {"-10000", "2", "1000"}, 3},
				{"tcp_ack", {"-66000", "0"}, 2},
				{"tls_mod", {"rnd,dupsid,sni=www.google.com",
				             "rnd,dupsid,sni=mail.ru",
				             "rndsni,dupsid"}, 3},
			},
			5
		},

		/* Family 3 — multidisorder: scramble packet order DPI sees.
		 * Different shape than splits — useful when DPI does flow
		 * reassembly tolerant of splits but not of disorders. */
		{
			"multidisorder", "multidisorder",
			"payload=tls_client_hello:dir=out",
			{
				{"pos", {"1,midsld",
				         "method+2,midsld,5",
				         "2,5,105,host+5,sld-1,endsld-5,endsld"}, 3},
			},
			1
		},

		/* Family 4 — hostfakesplit: inject a fake Host header
		 * cell into the split point. DPI matches on the fake host,
		 * real SNI passes. */
		{
			"hostfakesplit", "hostfakesplit",
			"payload=tls_client_hello:dir=out",
			{
				{"host", {"mail.ru", "rzd.ru", "ozon.ru",
				          "mapgl.2gis.com"}, 4},
				{"seqovl", {"1", "726"}, 2},
				{"badsum", {""}, 1},  /* fixed-flag axis (no value) */
			},
			3
		},

	}, 4
},

/* =========================================================================
 * TSPU_16KB — flow stalls at ~16 KB byte gate. Server's response gets
 * truncated. Bypass: get the request through before DPI accumulates
 * 16 KB of SNI-matched flow state, OR inflate ClientHello so the
 * "first 16 KB" boundary is hit on noise.
 * ========================================================================= */
{
	BLOCK_TSPU_16KB, "cdn_tls", {

		/* Family 1 — sniext+1 split with seqovl=1 (the THE proven
		 * trick from ntc.party 17013). */
		{
			"sniext-seqovl1", "multisplit",
			"payload=tls_client_hello:dir=out",
			{
				{"pos", {"1,sniext+1", "sniext+1", "1"}, 3},
				{"seqovl", {"1"}, 1},
			},
			2
		},

		/* Family 2 — fake decoy + tcp_ack=-66000 (badseq half).
		 * Crucial for TSPU 16 KB whitelist-SNI: the bad ACK lets
		 * the decoy fake escape the byte counter. */
		{
			"fake-badack", "fake",
			"payload=tls_client_hello:dir=out",
			{
				{"blob", {SNI_GOOGLE, SNI_4PDA, SNI_MAX_RU, SNI_ONETRUST}, 4},
				{"repeats", {"2", "6", "8"}, 3},
				{"tcp_seq", {"-10000", "2"}, 2},
				{"tcp_ack", {"-66000"}, 1},
				{"tls_mod", {"rnd,dupsid,sni=www.google.com",
				             "rnd,dupsid,padencap,sni=www.google.com",
				             "rndsni,dupsid"}, 3},
			},
			5
		},

		/* Family 3 — hostfakesplit. Same as RKN_RST family but with
		 * different host candidates for CDN whitelist context. */
		{
			"cdn-hostfake", "hostfakesplit",
			"payload=tls_client_hello:dir=out",
			{
				{"host", {"mail.ru", "max.ru", "vk.com"}, 3},
				{"seqovl", {"1", "726"}, 2},
				{"badsum", {""}, 1},
			},
			3
		},

	}, 3
},

/* =========================================================================
 * AWS_NO_TS — server doesn't negotiate TCP timestamps, so tcp_ts
 * fooling is wasted. Use TTL- and split-based primitives only.
 * ========================================================================= */
{
	BLOCK_AWS_NO_TS, "cdn_tls", {

		/* Family 1 — TTL-based fake. Hard ip_ttl and adaptive
		 * ip_autottl variations. Mix of positive and negative
		 * autottl deltas (denisv7 #159 pattern). */
		{
			"ttl-fake", "fake",
			"payload=tls_client_hello:dir=out",
			{
				{"blob", {SNI_GOOGLE, SNI_4PDA, "fake_default_tls"}, 3},
				{"repeats", {"4", "6", "8"}, 3},
				{"ip_ttl", {"3", "4", "5", "7"}, 4},
			},
			3
		},

		/* Family 2 — adaptive autottl, including negative delta. */
		{
			"autottl-fake", "fake",
			"payload=tls_client_hello:dir=out",
			{
				{"blob", {SNI_GOOGLE, "fake_default_tls"}, 2},
				{"repeats", {"4", "6"}, 2},
				{"ip_autottl", {"2,1-64", "3,1-64", "5,1-64",
				                "-2,3-20"}, 4},
			},
			3
		},

		/* Family 3 — split-only, no TTL/TS dependency. */
		{
			"sniext-split-only", "multisplit",
			"payload=tls_client_hello:dir=out",
			{
				{"pos", {"1,sniext+1", "1"}, 2},
				{"seqovl", {"1", "100"}, 2},
			},
			2
		},

	}, 3
},

/* =========================================================================
 * SIZE_DPI — byte-counter gate at non-16 KB offset. Same primitive
 * family as TSPU_16KB (size-manipulating wins), but parameter sweep
 * is broader to find the unknown threshold.
 * ========================================================================= */
{
	BLOCK_SIZE_DPI, "cdn_tls", {

		/* Family 1 — padencap to inflate ClientHello past whatever
		 * the gate is. */
		{
			"padencap", "fake",
			"payload=tls_client_hello:dir=out",
			{
				{"blob", {SNI_GOOGLE, SNI_4PDA}, 2},
				{"repeats", {"2", "4", "6", "8"}, 4},
				{"tls_mod", {"rnd,dupsid,padencap,sni=www.google.com",
				             "rnd,dupsid,padencap"}, 2},
				{"tcp_ack", {"-66000", "0"}, 2},
			},
			4
		},

		/* Family 2 — disorder + split combos. */
		{
			"disorder-split", "multidisorder",
			"payload=tls_client_hello:dir=out",
			{
				{"pos", {"method+2,midsld,5",
				         "1,midsld",
				         "2,5,105,host+5,sld-1"}, 3},
			},
			1
		},

	}, 2
},

/* =========================================================================
 * HYBRID — mixed symptoms, fall back to RKN_RST union-set since it
 * has the broadest primitive coverage.
 * ========================================================================= */
{
	BLOCK_HYBRID, "rkn_tcp", {

		/* Single broad family — combine sniext-split with diverse
		 * seqovl_pattern values. */
		{
			"broad-multisplit", "multisplit",
			"payload=tls_client_hello:dir=out",
			{
				{"pos", {"1,sniext+1", "1", "sniext+1"}, 3},
				{"seqovl", {"1", "500", "681"}, 3},
				{"seqovl_pattern", {SNI_GOOGLE, SNI_4PDA,
				                    SNI_GOSUSLUGI, SNI_MAX_RU}, 4},
			},
			3
		},

		/* Fake fallback. */
		{
			"broad-fake", "fake",
			"payload=tls_client_hello:dir=out",
			{
				{"blob", {SNI_GOOGLE, SNI_GOSUSLUGI}, 2},
				{"repeats", {"6", "8"}, 2},
				{"tcp_ack", {"-66000", "0"}, 2},
				{"tls_mod", {"rnd,dupsid,sni=www.google.com",
				             "rndsni,dupsid"}, 2},
			},
			4
		},

	}, 2
},

};  /* end recipes[] */

const recipe_t *recipe_for_block(block_type_t t) {
	for (size_t i = 0; i < sizeof(recipes) / sizeof(recipes[0]); i++) {
		if (recipes[i].block == t) return &recipes[i];
	}
	return NULL;
}
