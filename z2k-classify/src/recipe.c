/* z2k-classify — causal strategy library, indexed by block_type.
 *
 * Each block_type maps to a small set of strategies whose parameters
 * are derived from the physics of THAT specific block — not a
 * cartesian sweep of arbitrary axes. The only intentional rotation
 * is across "innocent SNI" alternatives (blob / sni= / host=) since
 * TSPU whitelists vary per ASN and we can't tell which works without
 * trying — but the structural parameters (pos, seqovl, repeats,
 * tcp_seq, tcp_ack, tls_mod, ip_autottl) are FIXED per strategy by
 * causal reasoning:
 *
 *   - pos=1,sniext+1   — split exactly at the SNI extension boundary
 *                        (only SNI byte boundary that matters for DPI).
 *   - seqovl=1         — minimum overlap; first byte of the second
 *                        segment is the first SNI byte. Forces DPI
 *                        to see different bytes than the server.
 *   - tcp_seq=2,
 *     tcp_ack=-66000   — bol-van's "badseq" pair. Decoys reach DPI
 *                        but the real server's SYN window rejects
 *                        them, so no decoy state pollutes the flow.
 *   - tls_mod=rnd,dupsid — anti-fingerprint. Random session ID +
 *                        duplicate session ID extension.
 *   - repeats=6        — minimum to cover retransmits + TSPU's
 *                        2-3 packet inspection window.
 *   - badsum           — first segment with bad checksum: server
 *                        drops it, DPI sees decoy SNI, real CH in
 *                        second segment passes through.
 *   - ip_autottl=-2,3-20 — auto-discovered TTL minus 2, clamped to
 *                        3-20: packet dies before reaching the server
 *                        but TSPU sees decoy. Used when TCP TS
 *                        timestamps aren't negotiated (aws_no_ts).
 *
 * Innocent SNI rotation: TSPU whitelists differ per ISP/ASN. For some
 * the universal works (google.com), for others mail.ru / 4pda.to /
 * gosuslugi.ru / max.ru / vk.com hit the local whitelist. We rotate
 * across the curated set as the only causal "axis".
 */
#include "recipe.h"

#include <stddef.h>

/* ---------- innocent SNI bytestrings used in fake/multisplit ---------- */
/* These are blob names — DPI hostlists across major Russian ISPs
 * historically allow them through. The corresponding `--blob=` flags
 * are pre-declared in S99zapret2.new. */
#define BLOB_GOOGLE     "tls_clienthello_www_google_com"
#define BLOB_4PDA       "tls_clienthello_4pda_to"
#define BLOB_GOSUSLUGI  "tls_clienthello_gosuslugi_ru"
#define BLOB_MAX_RU     "tls_max_ru"

/* Hostnames used in `hostfakesplit:host=...` decoy injection. */
#define HOST_MAIL_RU   "mail.ru"
#define HOST_RZD       "rzd.ru"
#define HOST_OZON      "ozon.ru"
#define HOST_VK        "vk.com"

static const recipe_t recipes[] = {

/* =========================================================================
 * RKN_RST — TSPU inspects SNI in the first ClientHello, injects a TCP
 * RST back to the client. 3 causal counter-strategies:
 *   1. Split SNI across packet boundary so DPI hash diverges from
 *      reassembled real value.
 *   2. Send a decoy CH with whitelisted SNI BEFORE the real CH using
 *      badseq (decoy reaches DPI, dies at server's TCP window).
 *   3. hostfakesplit — overlay decoy host on first segment with bad
 *      checksum; DPI matches decoy, real CH in second segment.
 * Each strategy has fixed structural params + rotation across
 * innocent SNI/blob/host because whitelist varies per ASN.
 * ========================================================================= */
{
	BLOCK_RKN_RST, "rkn_tcp", {

		/* (1) sniext-boundary split. pos and seqovl are FIXED — they
		 * derive from the SNI extension byte position in TLS CH. */
		{
			"sniext-split", "multisplit",
			"payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1",
			{
				{"seqovl_pattern", {BLOB_GOOGLE, BLOB_4PDA,
				                    BLOB_GOSUSLUGI, BLOB_MAX_RU}, 4},
			},
			1
		},

		/* (2) badseq-fake decoy. Structural params are fixed (badseq
		 * pair, repeats, tls_mod). Rotation only across decoy SNI. */
		{
			"badseq-fake", "fake",
			"payload=tls_client_hello:dir=out:repeats=6:tcp_seq=2:tcp_ack=-66000:tls_mod=rnd,dupsid",
			{
				{"blob", {BLOB_GOOGLE, BLOB_4PDA,
				          BLOB_GOSUSLUGI, BLOB_MAX_RU}, 4},
			},
			1
		},

		/* (3) hostfakesplit with badsum. seqovl=1 + badsum are
		 * structural. Rotate the host overlay only. */
		{
			"hostfakesplit", "hostfakesplit",
			"payload=tls_client_hello:dir=out:seqovl=1:badsum",
			{
				{"host", {HOST_MAIL_RU, HOST_RZD,
				          HOST_OZON, HOST_VK}, 4},
			},
			1
		},

	}, 3
},

/* =========================================================================
 * TSPU_16KB — flow stalls around 16 KB of incoming bytes. ntc.party
 * 17013 #851 result: works only with sniext+1:seqovl=1 + (badack OR
 * padencap). 2 causal strategies:
 *   1. sniext+1:seqovl=1 — the proven trick from the thread.
 *   2. fake decoy padded with padencap to inflate ClientHello past
 *      the byte gate, with badack (tcp_ack=-66000).
 * ========================================================================= */
{
	BLOCK_TSPU_16KB, "cdn_tls", {

		/* (1) Same structural primitive as RKN_RST family 1, but
		 * documented to work specifically against the 16 KB gate
		 * (ntc.party 17013 #851). */
		{
			"sniext-seqovl1", "multisplit",
			"payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1",
			{
				{"seqovl_pattern", {BLOB_GOOGLE, BLOB_4PDA,
				                    BLOB_GOSUSLUGI, BLOB_MAX_RU}, 4},
			},
			1
		},

		/* (2) padencap-inflated fake. tls_mod=rnd,dupsid,padencap
		 * adds padding extension to push CH size past the gate.
		 * tcp_ack=-66000 keeps the decoy off-path. */
		{
			"padencap-fake", "fake",
			"payload=tls_client_hello:dir=out:repeats=2:tcp_ack=-66000",
			{
				{"tls_mod", {"rnd,dupsid,padencap,sni=www.google.com",
				             "rnd,dupsid,padencap,sni=mail.ru",
				             "rnd,dupsid,padencap,sni=gosuslugi.ru",
				             "rndsni,dupsid,padencap"}, 4},
			},
			1
		},

	}, 2
},

/* =========================================================================
 * AWS_NO_TS — server doesn't negotiate TCP timestamps in SYN/ACK, so
 * any tcp_ts=N fooling no-ops. Use TTL-based fake (decoy expires in
 * transit before reaching server, but TSPU sees it) or split-only
 * primitives. denisv7 ntc.party #159: ip_autottl=-2,3-20 works on
 * AWS-hosted blocked sites where positive autottl doesn't.
 * ========================================================================= */
{
	BLOCK_AWS_NO_TS, "rkn_tcp", {

		/* (1) Negative-delta autottl fake. autottl=-2 means "auto
		 * discovered minus 2" — packet dies 2 hops before server.
		 * 3-20 clamps to non-loopback range. */
		{
			"autottl-neg-fake", "fake",
			"payload=tls_client_hello:dir=out:repeats=6:ip_autottl=-2,3-20",
			{
				{"blob", {BLOB_GOOGLE, BLOB_4PDA, BLOB_GOSUSLUGI}, 3},
			},
			1
		},

		/* (2) Static low-TTL fake. Tries fixed ttl values for paths
		 * where autottl can't get a clean baseline. */
		{
			"static-ttl-fake", "fake",
			"payload=tls_client_hello:dir=out:repeats=6",
			{
				{"ip_ttl", {"3", "4", "5"}, 3},
			},
			1
		},

		/* (3) Split-only fallback (no TCP-level fooling at all). */
		{
			"sniext-split-aws", "multisplit",
			"payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1",
			{
				{"seqovl_pattern", {BLOB_GOOGLE, BLOB_4PDA}, 2},
			},
			1
		},

	}, 3
},

/* =========================================================================
 * SIZE_DPI — byte-counter gate at unknown offset (not 16 KB). Same
 * size-inflation primitive as TSPU_16KB but no proven seqovl=1 path
 * yet. Try padencap variants + disorder.
 * ========================================================================= */
{
	BLOCK_SIZE_DPI, "rkn_tcp", {

		/* (1) padencap — pad the CH past the gate. */
		{
			"padencap", "fake",
			"payload=tls_client_hello:dir=out:repeats=4:tcp_ack=-66000",
			{
				{"tls_mod", {"rnd,dupsid,padencap,sni=www.google.com",
				             "rnd,dupsid,padencap,sni=mail.ru",
				             "rndsni,dupsid,padencap"}, 3},
			},
			1
		},

		/* (2) multidisorder — scramble TCP segment order so DPI
		 * reassembly fails or counts differently. */
		{
			"disorder", "multidisorder",
			"payload=tls_client_hello:dir=out",
			{
				{"pos", {"method+2,midsld,5",
				         "1,midsld",
				         "2,5,105,host+5,sld-1,endsld-5,endsld"}, 3},
			},
			1
		},

	}, 2
},

/* =========================================================================
 * HYBRID — symptoms don't fit one bucket cleanly. Cast a wider net by
 * combining the strongest single primitive from each of RKN_RST and
 * TSPU_16KB families.
 * ========================================================================= */
{
	BLOCK_HYBRID, "rkn_tcp", {

		/* (1) sniext-split — the universal multisplit recipe. */
		{
			"sniext-split-hybrid", "multisplit",
			"payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1",
			{
				{"seqovl_pattern", {BLOB_GOOGLE, BLOB_4PDA,
				                    BLOB_GOSUSLUGI, BLOB_MAX_RU}, 4},
			},
			1
		},

		/* (2) badseq-fake — decoy SNI before real CH. */
		{
			"badseq-fake-hybrid", "fake",
			"payload=tls_client_hello:dir=out:repeats=6:tcp_seq=2:tcp_ack=-66000:tls_mod=rnd,dupsid",
			{
				{"blob", {BLOB_GOOGLE, BLOB_4PDA,
				          BLOB_GOSUSLUGI, BLOB_MAX_RU}, 4},
			},
			1
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
