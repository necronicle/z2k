/* z2k-classify — per-block-type strategy templates.
 *
 * Each block type maps to a shortlist of strategy numbers from one of
 * our existing autocircular profiles. The classifier narrows the
 * search from "try all 47 rkn_tcp strategies" down to "try these 5
 * that are known to help for THIS block type".
 *
 * Phase 2 scope: templates for block types that we can auto-pin via
 * state.tsv. Types whose traffic doesn't flow through an autocircular
 * profile (transit_drop, mobile_icmp, etc.) are deliberately absent —
 * probe + recommend-only, no auto-apply.
 */
#ifndef Z2K_CLASSIFY_TEMPLATES_H
#define Z2K_CLASSIFY_TEMPLATES_H

#include "types.h"

typedef struct {
	block_type_t block;
	const char *profile_key;   /* matches circular "key=" arg in strategy string */
	int strategy_nums[16];     /* strategies to probe, in priority order */
	int count;
} template_t;

/* Lookup template for a block type. Returns NULL if no template
 * (caller should fall back to Phase 1 recommendation text only). */
const template_t *template_for_block(block_type_t t);

#endif
