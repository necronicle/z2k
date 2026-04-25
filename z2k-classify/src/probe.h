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
 * `raw_bypass`:
 *   true  — set SO_MARK = 0x40000000 on the probe socket so its
 *           packets are EXCLUDED from the nfqws2 NFQUEUE pipeline
 *           (the same fwmark the daemon uses to break the recursive-
 *           inject loop). Used for the BASELINE probe — we want to
 *           see the raw TSPU block, not the bypass-corrected handshake.
 *   false — no mark, packets follow the normal pipeline. Used for
 *           POST-INJECT probes during the generator loop, so the
 *           dynamic-strategy slot=48 handler actually runs against
 *           the test connection.
 *
 * Returns 0 on success (probe completed, output populated), -1 on
 * hard errors (DNS fail, socket API broken). A successful probe may
 * report block symptoms — that's normal, the classifier interprets.
 */
int probe_run(const char *domain, int timeout_sec, probe_result_t *out,
              struct in_addr *resolved_ip, bool raw_bypass);

/* Phase 2 will add: probe_with_strategy(...) to test a candidate
 * strategy via nfqueue injection. Declared here for forward compat. */

#endif
