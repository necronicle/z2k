/* z2k-classify — strategy string generator.
 *
 * Walks a recipe (one block_type) and emits concrete nfqws2
 * --lua-desync= strategy strings, one at a time. Order: family by
 * family, within each family cartesian product of axis values.
 *
 * The generator is stateful — caller calls gen_init(), then
 * gen_next(buf, sz) repeatedly until it returns 0 (no more).
 *
 * Strategy strings emitted have NO `strategy=N` tag — caller must
 * append one because the actual N depends on the slot used at
 * inject time.
 */
#ifndef Z2K_CLASSIFY_GENERATOR_H
#define Z2K_CLASSIFY_GENERATOR_H

#include "recipe.h"

#include <stdbool.h>

#define GEN_MAX_AXES RECIPE_MAX_AXES

typedef struct {
	const recipe_t *r;
	int family_idx;                    /* current family within r->families */
	int axis_pos[GEN_MAX_AXES];        /* current value index per axis */
	bool exhausted;
} generator_t;

void gen_init(generator_t *g, const recipe_t *r);

/* Emit next strategy string into buf (NUL-terminated, no trailing
 * newline). Returns:
 *   1 — wrote one strategy, family_name set to current family
 *   0 — no more strategies, generator exhausted
 *  -1 — buf too small for output
 *
 * family_name (if non-NULL) gets the family name pointer for logging.
 * The pointer is borrowed from the recipe; do NOT free or strdup.
 */
int gen_next(generator_t *g, char *buf, int bufsz, const char **family_name);

/* How many total strategies will this generator emit? Useful for
 * bounded probe budgets. */
int gen_total_count(const recipe_t *r);

#endif
