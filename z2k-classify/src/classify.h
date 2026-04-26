/* z2k-classify — symptom → block type decision. Pure function, no I/O. */
#ifndef Z2K_CLASSIFY_H
#define Z2K_CLASSIFY_H

#include "types.h"

/* Aggregate raw replicas into derived signals. Pure. */
void classify_aggregate(probe_aggregate_t *agg);

/* Infer block_type from `out->agg` + `out->cdn`. Fills `out->block_type`,
 * `out->reason`, `out->recommended`. Caller must set `out->domain`,
 * `out->resolved_ip`, `out->cdn`, and `out->agg`. */
void classify_infer(classify_result_t *out);

#endif
