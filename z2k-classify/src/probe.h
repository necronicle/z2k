/* z2k-classify — active probe interface. Phase 1 uses sockets only
 * (no raw AF_PACKET capture yet); Phase 2 will add nfqueue inject.
 */
#ifndef Z2K_CLASSIFY_PROBE_H
#define Z2K_CLASSIFY_PROBE_H

#include "types.h"

/* Run the full 8-symptom probe sequence against `domain`. Populates
 * every field of `out`. Total wall clock should stay under
 * `timeout_sec` seconds; exceeds may indicate transit loss.
 *
 * Returns 0 on success (probe completed, output populated), -1 on
 * hard errors (DNS fail, socket API broken). A successful probe may
 * report block symptoms — that's normal, the classifier interprets.
 */
int probe_run(const char *domain, int timeout_sec, probe_result_t *out,
              struct in_addr *resolved_ip);

/* Phase 2 will add: probe_with_strategy(...) to test a candidate
 * strategy via nfqueue injection. Declared here for forward compat. */

#endif
