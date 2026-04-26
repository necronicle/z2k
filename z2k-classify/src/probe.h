/* z2k-classify — active probe interface. */
#ifndef Z2K_CLASSIFY_PROBE_H
#define Z2K_CLASSIFY_PROBE_H

#include "types.h"

/* Single-replica probe — populates one probe_replica_t.
 *
 * `raw_bypass`:
 *   true  — set SO_MARK = 0x40000000 on probe socket so packets are
 *           EXCLUDED from the nfqws2 NFQUEUE pipeline (the same fwmark
 *           the daemon uses to break recursive-inject). Used for the
 *           BASELINE — measure raw TSPU block, not bypass-corrected.
 *   false — packets follow normal pipeline. Used for POST-INJECT probes
 *           so the dynamic-strategy slot handler runs against the test.
 *
 * Returns 0 on success (probe completed; output may report block).
 * -1 on hard errors (socket API broken). DNS failures populate dns_ok=false
 * and return 0. */
int probe_run_replica(const char *domain, int timeout_sec, probe_replica_t *out,
                      struct in_addr *resolved_ip, bool raw_bypass);

/* Multi-replica probe — runs probe_run_replica() N times back-to-back
 * with small jitter and aggregates into agg. N is clamped to
 * [1, PROBE_REPLICAS_MAX] (default 3 if 0).
 *
 * For probabilistic blocks (RST in some flows not all — typical МГТС
 * cloudflare pattern), single-shot probing miscalls block=NONE. This
 * wrapper exists exactly to surface that signal. */
int probe_run(const char *domain, int timeout_sec, int replicas,
              probe_aggregate_t *agg, struct in_addr *resolved_ip,
              bool raw_bypass);

/* Path probe — spawn `/opt/bin/traceroute` (BusyBox) against dest IP,
 * parse hop list, populate agg->trace_*. Reverse-DNS lookup on last
 * live hop. ISP detection by revdns suffix match. No-op (sets
 * trace_attempted=false) if traceroute binary not available. */
int probe_trace_path(struct in_addr dest, probe_aggregate_t *agg);

#endif
