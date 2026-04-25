/* z2k-classify — per-block-type primitive recipe library.
 *
 * A recipe is a set of "axes" (parameter dimensions), each with a list
 * of values to try. The generator (generator.c) takes the cartesian
 * product (or filtered subset) of axis values and produces concrete
 * nfqws2 --lua-desync= strategy strings to probe.
 *
 * Each block_type has one or more *families* (e.g. "multisplit-based",
 * "fake-with-decoy-SNI"). Families are tried in priority order — the
 * first family whose enumeration yields a working strategy wins, and
 * we don't bother with the rest.
 */
#ifndef Z2K_CLASSIFY_RECIPE_H
#define Z2K_CLASSIFY_RECIPE_H

#include "types.h"

/* Maximum sizes — recipe library is hand-curated and small. */
#define RECIPE_MAX_VALUES   16
#define RECIPE_MAX_AXES      6
#define RECIPE_MAX_FAMILIES  4

typedef struct {
	const char *name;                  /* axis name, e.g. "pos" */
	const char *values[RECIPE_MAX_VALUES];
	int count;
} recipe_axis_t;

typedef struct {
	const char *family_name;           /* e.g. "multisplit", "fake-decoy" */
	const char *action;                /* e.g. "multisplit", "fake", "hostfakesplit" */
	const char *fixed_args;            /* always-present args, e.g. "payload=tls_client_hello:dir=out" */
	recipe_axis_t axes[RECIPE_MAX_AXES];
	int axis_count;
} recipe_family_t;

typedef struct {
	block_type_t block;
	const char *profile_key;           /* matches autocircular "key=" in resulting strategy */
	recipe_family_t families[RECIPE_MAX_FAMILIES];
	int family_count;
} recipe_t;

/* Lookup recipe for a block type. Returns NULL if no recipe (caller
 * should report "no generator coverage" to user). */
const recipe_t *recipe_for_block(block_type_t t);

#endif
