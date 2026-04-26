/* z2k-classify — strategy emitter (single composite, no iteration). */
#include "generator.h"

#include <stdio.h>

int gen_strategy_string(const recipe_entry_t *r, char *buf, int bufsz) {
	if (!r) return -1;
	int n = snprintf(buf, bufsz, "family=%s:%s",
	                 r->family ? r->family : "",
	                 r->params ? r->params : "");
	if (n < 0 || n >= bufsz) return -1;
	return n;
}
