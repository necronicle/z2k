/* z2k-classify — strategy emitter.
 *
 * No more axis-rotation. Given a recipe_entry_t (single composite
 * strategy chosen by recipe_for()), build the strategy string ready
 * for the Lua handler's dynparams channel.
 */
#ifndef Z2K_CLASSIFY_GENERATOR_H
#define Z2K_CLASSIFY_GENERATOR_H

#include "recipe.h"

/* Build a one-line strategy descriptor "family=X:params" suitable for
 * /tmp/z2k-classify-dynparams (the lua handler reads `family` and
 * everything else as flat params). Returns bytes written, -1 if buf
 * too small. */
int gen_strategy_string(const recipe_entry_t *r, char *buf, int bufsz);

#endif
