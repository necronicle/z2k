/* z2k-classify — field-tested strategy registry.
 *
 * Replaces the prior "axis-rotation" recipe model. There is NO
 * cartesian sweep here. For each (block_type × cdn × ts-availability)
 * tuple, the registry holds ONE composite strategy known from field
 * reports to work, with a verbatim cite to its source.
 *
 * Selection rule (recipe_for):
 *   1. Exact match (block, cdn, ts_req).
 *   2. (block, cdn, ts_req=ANY).
 *   3. (block, CDN_UNKNOWN, ts_req).
 *   4. (block, CDN_UNKNOWN, ts_req=ANY).
 *   5. NULL → "unmapped, escalate to maintainer with pcap".
 *
 * No on-the-fly synthesis. If the registry has no entry, the tool
 * REFUSES to invent one — see ntc.party 21161 + bol-van's stance:
 * "Что не будет вам одной кнопки никакой и никогда" (d/1990).
 */
#ifndef Z2K_CLASSIFY_RECIPE_H
#define Z2K_CLASSIFY_RECIPE_H

#include "types.h"

typedef enum {
	RECIPE_TS_ANY = 0,
	RECIPE_TS_REQ_YES,    /* only when probe sees server TS negotiated */
	RECIPE_TS_REQ_NO,     /* only when probe sees TS NOT negotiated */
} recipe_ts_req_t;

typedef struct {
	block_type_t   block;
	cdn_id_t       cdn;            /* CDN_UNKNOWN = wildcard */
	recipe_ts_req_t ts_req;
	const char *profile_key;       /* "rkn_tcp" / "cdn_tls" / "google_tls" */
	const char *family;            /* "multisplit" / "fake" / "hostfakesplit" / "multidisorder" / "syndata" / "fakedsplit" */
	const char *params;            /* verbatim, written to /tmp/z2k-classify-dynparams */
	const char *human_label;
	const char *cite;              /* source ref (ntc.party / GH issue / discussion) */
} recipe_entry_t;

/* Pick the most specific recipe for the (block, cdn, has_ts) tuple.
 * Returns NULL if the tuple is unmapped — caller MUST report
 * "unmapped, need pcap, escalate" instead of fabricating. */
const recipe_entry_t *recipe_for(block_type_t block, cdn_id_t cdn, bool has_ts);

/* Identify CDN/hosting from resolved IPv4 address. Returns CDN_UNKNOWN
 * if address falls outside the curated CIDR table. */
cdn_id_t cdn_for_ip(struct in_addr ip);

/* Human-readable CDN name. */
const char *cdn_name(cdn_id_t c);

#endif
