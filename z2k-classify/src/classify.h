/* z2k-classify — symptom → block type decision. Pure function, no I/O. */
#ifndef Z2K_CLASSIFY_H
#define Z2K_CLASSIFY_H

#include "types.h"

/* Infer block_type from probe result. Fills `out->block_type`,
 * `out->reason`, and `out->recommended`. `out->probe` must already
 * be populated by probe_run() and `out->domain` / `out->resolved_ip`
 * set by the caller. */
void classify_infer(classify_result_t *out);

#endif
