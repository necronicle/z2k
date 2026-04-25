/* z2k-classify — strategy string generator. */
#include "generator.h"

#include <stdio.h>
#include <string.h>

void gen_init(generator_t *g, const recipe_t *r) {
	memset(g, 0, sizeof(*g));
	g->r = r;
	g->family_idx = 0;
	g->exhausted = (r == NULL || r->family_count == 0);
}

/* Increment the multi-dimensional axis position counter for the
 * current family. Returns 0 if rolled over (need next family),
 * 1 if there are still combinations left in this family. */
static int gen_advance(generator_t *g) {
	const recipe_family_t *f = &g->r->families[g->family_idx];
	int n = f->axis_count;
	for (int i = n - 1; i >= 0; i--) {
		g->axis_pos[i]++;
		if (g->axis_pos[i] < f->axes[i].count) return 1;
		g->axis_pos[i] = 0;  /* roll over to next outer axis */
	}
	return 0;
}

int gen_total_count(const recipe_t *r) {
	if (!r) return 0;
	int total = 0;
	for (int i = 0; i < r->family_count; i++) {
		const recipe_family_t *f = &r->families[i];
		int product = 1;
		for (int j = 0; j < f->axis_count; j++) {
			product *= f->axes[j].count;
		}
		total += product;
	}
	return total;
}

int gen_next(generator_t *g, char *buf, int bufsz, const char **family_name) {
	if (!g->r || g->exhausted) return 0;
	if (g->family_idx >= g->r->family_count) {
		g->exhausted = true;
		return 0;
	}

	const recipe_family_t *f = &g->r->families[g->family_idx];

	/* Build current strategy string from CURRENT axis_pos[] before
	 * advancing. Format:
	 *   --lua-desync=<action>:<fixed_args>[:<axis>=<value>]+   */
	int written = snprintf(buf, bufsz,
		"--lua-desync=%s:%s",
		f->action,
		f->fixed_args ? f->fixed_args : "");
	if (written < 0 || written >= bufsz) return -1;
	int pos = written;

	for (int i = 0; i < f->axis_count && i < GEN_MAX_AXES; i++) {
		const recipe_axis_t *a = &f->axes[i];
		const char *val = a->values[g->axis_pos[i]];

		int n;
		if (val == NULL || val[0] == '\0') {
			/* Fixed-flag axis (e.g. badsum) — emit just the
			 * name, no `=value`. */
			n = snprintf(buf + pos, bufsz - pos, ":%s", a->name);
		} else {
			n = snprintf(buf + pos, bufsz - pos, ":%s=%s",
			             a->name, val);
		}
		if (n < 0 || n >= bufsz - pos) return -1;
		pos += n;
	}

	if (family_name) *family_name = f->family_name;

	/* Advance for NEXT call. If this family is exhausted, move to
	 * next family with reset axis positions. */
	if (!gen_advance(g)) {
		g->family_idx++;
		memset(g->axis_pos, 0, sizeof(g->axis_pos));
		if (g->family_idx >= g->r->family_count) {
			g->exhausted = true;
		}
	}

	return 1;
}
