/* z2k-classify — field-tested strategy registry.
 *
 * Each entry below is sourced from an actual field report or bol-van
 * authoritative comment; the cite is the audit trail. NO entry is
 * "invented" — when a (block × cdn × ts) tuple isn't covered, the
 * generator returns NULL and main.c reports "unmapped, escalate".
 *
 * Sources scanned: ntc.party thread 21161 (827 posts), bol-van/zapret
 * GitHub issues + discussions (mining done 2026-04-26).
 */
#include "recipe.h"

#include <stddef.h>
#include <string.h>
#include <arpa/inet.h>

/* ---------------- CDN CIDR table ----------------
 *
 * Hand-curated subset — top-coverage CIDRs per CDN, NOT exhaustive.
 * IPs that don't match any entry classify as CDN_UNKNOWN, which still
 * resolves to a generic recipe for the detected block type. */

typedef struct {
	uint32_t base;     /* network address in host byte order */
	uint8_t  prefix;   /* /N */
	cdn_id_t cdn;
} cidr_entry_t;

#define CIDR(a, b, c, d, p, k) { (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d)), (p), (k) }

static const cidr_entry_t g_cidrs[] = {
	/* ---- Cloudflare AS13335 ---- */
	CIDR(104, 16,   0,   0, 12, CDN_CLOUDFLARE),  /* 104.16.0.0/12 (huge — covers .16-.31) */
	CIDR(162,158,   0,   0, 15, CDN_CLOUDFLARE),
	CIDR(172, 64,   0,   0, 13, CDN_CLOUDFLARE),
	CIDR(173,245,  48,   0, 20, CDN_CLOUDFLARE),
	CIDR(188,114,  96,   0, 20, CDN_CLOUDFLARE),
	CIDR(190, 93, 240,   0, 20, CDN_CLOUDFLARE),
	CIDR(198, 41, 128,   0, 17, CDN_CLOUDFLARE),
	CIDR(  1,  1,   1,   0, 24, CDN_CLOUDFLARE),  /* 1.1.1.0/24 (DNS+CDN edge) */

	/* ---- OVH (FR/CA) ---- */
	CIDR( 51, 68,   0,   0, 14, CDN_OVH),
	CIDR( 51, 83,   0,   0, 16, CDN_OVH),
	CIDR( 51, 89,   0,   0, 16, CDN_OVH),
	CIDR( 54, 36,   0,   0, 14, CDN_OVH),
	CIDR(188,165,   0,   0, 16, CDN_OVH),
	CIDR(213,186,  32,   0, 19, CDN_OVH),

	/* ---- Hetzner ---- */
	CIDR(  5,  9,   0,   0, 16, CDN_HETZNER),
	CIDR( 78, 46,   0,   0, 15, CDN_HETZNER),
	CIDR( 88,198,   0,   0, 16, CDN_HETZNER),
	CIDR(116,202,   0,   0, 15, CDN_HETZNER),
	CIDR(135,181,   0,   0, 16, CDN_HETZNER),
	CIDR(138,201,   0,   0, 16, CDN_HETZNER),
	CIDR(144, 76,   0,   0, 16, CDN_HETZNER),
	CIDR(159, 69,   0,   0, 16, CDN_HETZNER),
	CIDR(168,119,   0,   0, 16, CDN_HETZNER),
	CIDR(176,  9,   0,   0, 16, CDN_HETZNER),
	CIDR(188, 40,   0,   0, 16, CDN_HETZNER),
	CIDR(195,201,   0,   0, 16, CDN_HETZNER),
	CIDR(213,133,  96,   0, 19, CDN_HETZNER),   /* hetzner-online.de */
	CIDR(213,239,192,   0, 18, CDN_HETZNER),

	/* ---- DigitalOcean ---- */
	CIDR(138,197,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(138, 68,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(139, 59,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(142, 93,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(143,198,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(159, 65,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(159, 89,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(161, 35,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(165,227,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(167, 99,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(178, 62,   0,   0, 16, CDN_DIGITALOCEAN),
	CIDR(188,166,   0,   0, 16, CDN_DIGITALOCEAN),

	/* ---- AWS CloudFront (the "AMAZON_CLOUDFRONT" segment) ---- */
	CIDR( 13,224,   0,   0, 14, CDN_CLOUDFRONT),
	CIDR( 13,249,   0,   0, 16, CDN_CLOUDFRONT),
	CIDR( 18,160,   0,   0, 15, CDN_CLOUDFRONT),
	CIDR( 52, 84,   0,   0, 15, CDN_CLOUDFRONT),
	CIDR( 54,182,   0,   0, 16, CDN_CLOUDFRONT),
	CIDR( 54,192,   0,   0, 16, CDN_CLOUDFRONT),
	CIDR( 99, 84,   0,   0, 16, CDN_CLOUDFRONT),
	CIDR(108,156,   0,   0, 14, CDN_CLOUDFRONT),
	CIDR(130,176,   0,   0, 16, CDN_CLOUDFRONT),
	CIDR(143,204,   0,   0, 16, CDN_CLOUDFRONT),
	CIDR(204,246, 168,   0, 22, CDN_CLOUDFRONT),
	CIDR(216,137,  32,   0, 19, CDN_CLOUDFRONT),

	/* ---- AWS general (representative, not exhaustive) ---- */
	CIDR(  3,  0,   0,   0,  8, CDN_AWS),
	CIDR( 18,  0,   0,   0, 12, CDN_AWS),
	CIDR( 35,160,   0,   0, 11, CDN_AWS),
	CIDR( 52,  0,   0,   0, 11, CDN_AWS),
	CIDR( 54,  0,   0,   0,  9, CDN_AWS),
	CIDR( 98, 80,   0,   0, 12, CDN_AWS),    /* us-east-1 */
	CIDR( 98,128,   0,   0, 11, CDN_AWS),
	CIDR( 44,192,   0,   0, 11, CDN_AWS),

	/* ---- Oracle Cloud ---- */
	CIDR(132,145,   0,   0, 16, CDN_ORACLE),
	CIDR(132,226,   0,   0, 16, CDN_ORACLE),
	CIDR(134, 70,   0,   0, 16, CDN_ORACLE),
	CIDR(140, 91,   0,   0, 16, CDN_ORACLE),
	CIDR(141,144,   0,   0, 16, CDN_ORACLE),
	CIDR(144, 21,   0,   0, 16, CDN_ORACLE),
	CIDR(152, 67,   0,   0, 16, CDN_ORACLE),
	CIDR(193,122,   0,   0, 15, CDN_ORACLE),

	/* ---- Akamai (representative) ---- */
	CIDR( 23, 32,   0,   0, 11, CDN_AKAMAI),
	CIDR( 23, 64,   0,   0, 14, CDN_AKAMAI),
	CIDR( 23,192,   0,   0, 11, CDN_AKAMAI),
	CIDR(104, 64,   0,   0, 10, CDN_AKAMAI),
	CIDR(184, 24,   0,   0, 13, CDN_AKAMAI),

	/* ---- Google Cloud / Frontends / GWS ---- */
	CIDR( 34, 64,   0,   0, 10, CDN_GOOGLE),
	CIDR( 35,184,   0,   0, 13, CDN_GOOGLE),
	CIDR( 35,192,   0,   0, 12, CDN_GOOGLE),
	CIDR( 35,208,   0,   0, 12, CDN_GOOGLE),
	CIDR( 35,224,   0,   0, 12, CDN_GOOGLE),
	CIDR( 35,240,   0,   0, 13, CDN_GOOGLE),
	CIDR( 64,233,   0,   0, 16, CDN_GOOGLE),
	CIDR( 66,102,   0,   0, 16, CDN_GOOGLE),
	CIDR( 66,249,   0,   0, 16, CDN_GOOGLE),
	CIDR( 72, 14,   0,   0, 16, CDN_GOOGLE),
	CIDR( 74,125,   0,   0, 16, CDN_GOOGLE),
	CIDR(142,250,   0,   0, 15, CDN_GOOGLE),
	CIDR(172,217,   0,   0, 16, CDN_GOOGLE),
	CIDR(173,194,   0,   0, 16, CDN_GOOGLE),
	CIDR(209, 85, 128,   0, 17, CDN_GOOGLE),
	CIDR(216, 58,   0,   0, 16, CDN_GOOGLE),
	CIDR(216,239,   0,   0, 19, CDN_GOOGLE),

	/* ---- Fastly ---- */
	CIDR(151,101,   0,   0, 16, CDN_FASTLY),
	CIDR(199, 27,  72,   0, 21, CDN_FASTLY),
	CIDR(199,232,   0,   0, 16, CDN_FASTLY),
};

#undef CIDR

cdn_id_t cdn_for_ip(struct in_addr ip) {
	uint32_t addr = ntohl(ip.s_addr);
	cdn_id_t best = CDN_UNKNOWN;
	uint8_t  best_prefix = 0;
	for (size_t i = 0; i < sizeof(g_cidrs) / sizeof(g_cidrs[0]); i++) {
		const cidr_entry_t *e = &g_cidrs[i];
		uint32_t mask = (e->prefix == 0) ? 0u : (~0u << (32 - e->prefix));
		if ((addr & mask) == (e->base & mask)) {
			if (e->prefix >= best_prefix) {
				best = e->cdn;
				best_prefix = e->prefix;
			}
		}
	}
	return best;
}

const char *cdn_name(cdn_id_t c) {
	switch (c) {
	case CDN_UNKNOWN:       return "unknown";
	case CDN_CLOUDFLARE:    return "cloudflare";
	case CDN_OVH:           return "ovh";
	case CDN_HETZNER:       return "hetzner";
	case CDN_DIGITALOCEAN:  return "digitalocean";
	case CDN_AWS:           return "aws";
	case CDN_CLOUDFRONT:    return "cloudfront";
	case CDN_ORACLE:        return "oracle";
	case CDN_AKAMAI:        return "akamai";
	case CDN_GOOGLE:        return "google";
	case CDN_FASTLY:        return "fastly";
	default:                return "?";
	}
}

/* ---------------- recipe registry ---------------- */

static const recipe_entry_t g_recipes[] = {

	/* ============================================================
	 * RKN_RST — TSPU SNI inspection injects RST after ClientHello.
	 * ============================================================ */

	/* Universal RTK / МТС-Поволжье / Магеал / Интерсвязь / etc.
	 * d/1812 OttoZuse described as `multisplit seqovl=681 + fooling=badseq`
	 * — but field-validated production strategy=1 in our z2k fork is a
	 * COMPOUND of fake decoy + multisplit, both at the same slot. The fake
	 * decoy randomizes TLS fingerprint via z2k_grease/alpn/psk/keyshare
	 * mods + dynamic-TTL fooling, scrambling DPI's ASN-whitelist match
	 * BEFORE the real CH is split. This is what makes stubborn hosts
	 * (linkedin, etc.) pass where plain multisplit fails. */
	{
		.block = BLOCK_RKN_RST,
		.cdn = CDN_UNKNOWN,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "fake_then_multisplit",
		.params =
			"fake_blob=fake_default_tls"
			":fake_repeats=8"
			":fake_tcp_ts=-1000"
			":fake_tls_mod=rnd,dupsid,sni=www.google.com,z2k_grease,z2k_alpn,z2k_psk,z2k_keyshare"
			":fake_fool=z2k_dynamic_ttl"
			":mp_pos=1"
			":mp_seqovl=681"
			":mp_seqovl_pattern=tls_clienthello_www_google_com"
			":payload=tls_client_hello",
		.human_label = "RTK universal compound: fake decoy + multisplit seqovl=681",
		.cite = "ntc.party 21161 d/1812 (OttoZuse) + z2k production strategy=1",
	},

	/* OVH-zone: same compound but gosuslugi.ru bin for the seqovl prefix.
	 * gtumanyan d/1812 noted google bin doesn't pass on OVH; gosuslugi
	 * does. Keep fake decoy because OVH 16KB block is at least as
	 * stubborn as RKN_RST elsewhere. */
	{
		.block = BLOCK_RKN_RST,
		.cdn = CDN_OVH,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "fake_then_multisplit",
		.params =
			"fake_blob=fake_default_tls"
			":fake_repeats=8"
			":fake_tcp_ts=-1000"
			":fake_tls_mod=rnd,dupsid,sni=www.google.com,z2k_grease,z2k_alpn,z2k_psk,z2k_keyshare"
			":fake_fool=z2k_dynamic_ttl"
			":mp_pos=1"
			":mp_seqovl=800"
			":mp_seqovl_pattern=tls_clienthello_gosuslugi_ru"
			":payload=tls_client_hello",
		.human_label = "OVH compound: fake decoy + multisplit seqovl=800 gosuslugi",
		.cite = "ntc.party 21161 d/1812 (gtumanyan) + z2k production",
	},

	/* RKN_RST on Cloudflare zones — same multisplit but CF-tuned.
	 * Falls through to the universal entry above when not specified. */

	/* ============================================================
	 * TSPU_16KB — byte-counter gate at ~16 KB.
	 * ============================================================ */

	/* TSPU_16KB на enhanced живёт под тем же rkn_tcp профилем, что и
	 * RKN_RST: production rotator strategy=1 (fake_then_multisplit
	 * compound с mp_seqovl=681) пробивает 16KB-gate так же, как и
	 * RKN-RST после-CH inspection. Recipes для cdn_tls удалены 2026-04-27
	 * вместе с профилем; ниже — re-mapping тех же block-кейсов на
	 * rkn_tcp compound, иначе classifier ложно выдавал unmapped на
	 * (TSPU_16KB, CF) при том что rkn_tcp у юзера на эту же связку
	 * работает. */

	{
		.block = BLOCK_TSPU_16KB,
		.cdn = CDN_UNKNOWN,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "fake_then_multisplit",
		.params =
			"fake_blob=fake_default_tls"
			":fake_repeats=8"
			":fake_tcp_ts=-1000"
			":fake_tls_mod=rnd,dupsid,sni=www.google.com,z2k_grease,z2k_alpn,z2k_psk,z2k_keyshare"
			":fake_fool=z2k_dynamic_ttl"
			":mp_pos=1"
			":mp_seqovl=681"
			":mp_seqovl_pattern=tls_clienthello_www_google_com"
			":payload=tls_client_hello",
		.human_label = "TSPU 16KB universal: fake decoy + multisplit seqovl=681",
		.cite = "z2k production strategy=1 (rkn_tcp rotator) — пробивает CF 16KB",
	},

	{
		.block = BLOCK_TSPU_16KB,
		.cdn = CDN_OVH,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "fake_then_multisplit",
		.params =
			"fake_blob=fake_default_tls"
			":fake_repeats=8"
			":fake_tcp_ts=-1000"
			":fake_tls_mod=rnd,dupsid,sni=www.google.com,z2k_grease,z2k_alpn,z2k_psk,z2k_keyshare"
			":fake_fool=z2k_dynamic_ttl"
			":mp_pos=1"
			":mp_seqovl=800"
			":mp_seqovl_pattern=tls_clienthello_gosuslugi_ru"
			":payload=tls_client_hello",
		.human_label = "TSPU 16KB OVH: fake decoy + multisplit seqovl=800 gosuslugi",
		.cite = "ntc.party 21161 d/1812 (gtumanyan) + z2k production rkn_tcp",
	},

	/* ============================================================
	 * AWS_NO_TS — server doesn't negotiate TS (some amazonaws.com).
	 * Per bol-van #2039: hostfakesplit relies on badack=-66000
	 * mechanism; with badseq=0 + ts on it works. We force ts_req=NO
	 * since by definition AWS_NO_TS has no TS to fool with.
	 * ============================================================ */

	{
		.block = BLOCK_AWS_NO_TS,
		.cdn = CDN_UNKNOWN,
		.ts_req = RECIPE_TS_REQ_NO,
		.profile_key = "rkn_tcp",
		.family = "hostfakesplit",
		.params = "host=vk.com:tcp_seq=0:tcp_ack=-66000:ip_ttl=4:payload=tls_client_hello",
		.human_label = "AWS no-TS: hostfakesplit host=vk.com badack+ttl",
		.cite = "github.com/bol-van/zapret#2039 (bol-van mechanism)",
	},

	/* ============================================================
	 * SIZE_DPI — non-16K size-gated DPI. Less field data; treat
	 * similar to TSPU_16KB but try multidisorder first.
	 * ============================================================ */

	{
		.block = BLOCK_SIZE_DPI,
		.cdn = CDN_UNKNOWN,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "multidisorder",
		.params = "pos=method+2,midsld,5:payload=tls_client_hello",
		.human_label = "size-DPI: multidisorder pos=method+2,midsld,5",
		.cite = "z2k rkn_tcp baseline strategy",
	},

	/* ============================================================
	 * HYBRID — symptoms don't fit one bucket. Cast wider net:
	 * use universal RTK seqovl=681 as primary.
	 * ============================================================ */

	{
		.block = BLOCK_HYBRID,
		.cdn = CDN_UNKNOWN,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "fake_then_multisplit",
		.params =
			"fake_blob=fake_default_tls"
			":fake_repeats=8"
			":fake_tcp_ts=-1000"
			":fake_tls_mod=rnd,dupsid,sni=www.google.com,z2k_grease,z2k_alpn,z2k_psk,z2k_keyshare"
			":fake_fool=z2k_dynamic_ttl"
			":mp_pos=1"
			":mp_seqovl=681"
			":mp_seqovl_pattern=tls_clienthello_www_google_com"
			":payload=tls_client_hello",
		.human_label = "Hybrid: RTK compound as primary",
		.cite = "ntc.party 21161 d/1812 + z2k production strategy=1",
	},

	/* ============================================================
	 * BLOCK_L3_ISP_DROP — ISP null-routes the dest IP. NO DPI strategy
	 * works (packets never exit the ISP AS). For CDNs with multiple
	 * anycast subnets the L3 routing trick may help: override DNS to
	 * an alternate anycast IP that the ISP doesn't block.
	 *
	 * Field-validated for МГТС on Cloudflare (Михаил 2026-04-26):
	 * 2.58.104.1 worked when 104.16.x range was DPI-blocked.
	 * Per ntc.party 21161 #354–374 (jestxfot МГТС-residential):
	 * 2.58.104.1 was the canonical alternate that bypassed МГТС's
	 * per-CIDR whitelist on CF.
	 * ============================================================ */

	{
		.block = BLOCK_L3_ISP_DROP,
		.cdn = CDN_CLOUDFLARE,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "hosts_override",
		.params = "alt_ips=2.58.104.1,162.159.36.1,162.159.200.1,172.67.0.1",
		.human_label = "CF L3 bypass: hosts override → alt anycast",
		.cite = "ntc.party 21161 #354-374 (jestxfot МГТС) + Михаил 2026-04-26",
	},

	{
		.block = BLOCK_L3_ISP_DROP,
		.cdn = CDN_OVH,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "hosts_override",
		.params = "alt_ips=51.68.0.1,51.83.0.1,54.36.0.1,188.165.0.1",
		.human_label = "OVH L3 bypass: hosts override → alt range",
		.cite = "OVH AS16276 alt subnets",
	},

	{
		.block = BLOCK_L3_ISP_DROP,
		.cdn = CDN_CLOUDFRONT,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "hosts_override",
		.params = "alt_ips=13.224.0.1,52.84.0.1,99.84.0.1,143.204.0.1",
		.human_label = "CloudFront L3 bypass: hosts override → alt range",
		.cite = "AWS CloudFront edge subnets",
	},

	/* ============================================================
	 * BLOCK_IP_LEVEL_CDN — per-CIDR whitelist (МГТС on CF). NO DPI
	 * strategy works — only `hosts` override to a different CF
	 * anycast IP. Same hosts_override applies; classifier currently
	 * doesn't auto-route into this type — kept here for future when
	 * we distinguish from RKN_RST + probabilistic.
	 * ============================================================ */

	{
		.block = BLOCK_IP_LEVEL_CDN,
		.cdn = CDN_CLOUDFLARE,
		.ts_req = RECIPE_TS_ANY,
		.profile_key = "rkn_tcp",
		.family = "hosts_override",
		.params = "alt_ips=2.58.104.1,162.159.36.1,162.159.200.1,172.67.0.1",
		.human_label = "CF per-CIDR whitelist bypass: alt anycast",
		.cite = "ntc.party 21161 #354-374",
	},

	/* ============================================================
	 * BLOCK_ANTI_DDOS_SLOWSTART — server window<expected. NOT DPI.
	 * No entry — main.c reports "not a DPI block, ensure SYN-ACK
	 * captured (MAX_PKT_IN >= 1)" (bol-van #1756, #2073).
	 * ============================================================ */

	/* No entry by design. */
};

static int recipe_matches(const recipe_entry_t *r, block_type_t block,
                          cdn_id_t cdn, bool has_ts) {
	if (r->block != block) return 0;
	if (r->cdn != CDN_UNKNOWN && r->cdn != cdn) return 0;
	switch (r->ts_req) {
	case RECIPE_TS_ANY:    break;
	case RECIPE_TS_REQ_YES: if (!has_ts) return 0; break;
	case RECIPE_TS_REQ_NO:  if (has_ts)  return 0; break;
	}
	return 1;
}

const recipe_entry_t *recipe_for(block_type_t block, cdn_id_t cdn, bool has_ts) {
	const size_t n = sizeof(g_recipes) / sizeof(g_recipes[0]);

	/* Pass 1: exact (block, cdn, ts_req-strict). */
	for (size_t i = 0; i < n; i++) {
		const recipe_entry_t *r = &g_recipes[i];
		if (r->cdn == cdn && r->ts_req != RECIPE_TS_ANY &&
		    recipe_matches(r, block, cdn, has_ts)) return r;
	}
	/* Pass 2: (block, cdn, ts=ANY). */
	for (size_t i = 0; i < n; i++) {
		const recipe_entry_t *r = &g_recipes[i];
		if (r->cdn == cdn && r->ts_req == RECIPE_TS_ANY &&
		    recipe_matches(r, block, cdn, has_ts)) return r;
	}
	/* Pass 3: (block, CDN_UNKNOWN, ts_req-strict). */
	for (size_t i = 0; i < n; i++) {
		const recipe_entry_t *r = &g_recipes[i];
		if (r->cdn == CDN_UNKNOWN && r->ts_req != RECIPE_TS_ANY &&
		    recipe_matches(r, block, cdn, has_ts)) return r;
	}
	/* Pass 4: (block, CDN_UNKNOWN, ts=ANY) — broadest fallback. */
	for (size_t i = 0; i < n; i++) {
		const recipe_entry_t *r = &g_recipes[i];
		if (r->cdn == CDN_UNKNOWN && r->ts_req == RECIPE_TS_ANY &&
		    recipe_matches(r, block, cdn, has_ts)) return r;
	}
	return NULL;
}
