/* z2k-classify — runtime strategy injection (seamless / no-restart).
 *
 * Mechanism (apply/revert):
 *   1. Helper script writes the parsed family + key=value params to
 *      /tmp/z2k-classify-dynparams (atomic tmp+rename).
 *   2. State.tsv is pinned to (profile_key, domain) → strategy=200.
 *   3. The pre-installed --lua-desync=z2k_dynamic_strategy:strategy=200
 *      slot in the matching autocircular block reads dynparams per-
 *      packet (1-sec TTL cache) and dispatches to fake/multisplit/
 *      hostfakesplit/multidisorder for THIS domain only. No restart.
 *   4. Caller probes the domain via probe_run().
 *   5. inject_revert() truncates dynparams + unpins state.tsv. The
 *      Lua handler becomes a silent no-op for the next packet — other
 *      users' DPI bypass is never interrupted during a generator run.
 *
 * Cost per iteration: ~2 sec (file write + 1-sec settle for cache TTL
 * to roll over + probe). 30-combo run = ~60-90 sec total.
 *
 * Mechanism (persist):
 *   - Promotes the winning strategy from the dynamic slot to the next
 *     free permanent strategy=N in strats_new2.txt and does ONE
 *     regen+restart at the end of the session.
 */
#ifndef Z2K_CLASSIFY_INJECT_H
#define Z2K_CLASSIFY_INJECT_H

#include <stdbool.h>

#define INJECT_DYNAMIC_STRATEGY_ID 200  /* high enough to never clash */

/* Inject one candidate strategy into the live nfqws2 setup (seamless).
 *
 * strategy_str — the --lua-desync= string emitted by the generator
 *                (with or without strategy=N tag — helper strips/ignores).
 * profile_key  — "rkn_tcp" / "google_tls" / "cdn_tls" (matches autocircular block).
 * domain       — host to pin so only THIS domain's flow uses the strategy.
 *
 * Returns 0 on success (strategy active for next flow), -1 on error.
 * Caller should probe the domain and then call inject_revert().
 */
int inject_apply(const char *strategy_str, const char *profile_key,
                 const char *domain);

/* Revert. Truncates the dynparams file and removes the state.tsv pin.
 * No restart. Lua handler becomes a silent no-op for this domain on
 * next packet (cached_at + 1-sec TTL). Always call after inject_apply()
 * (whether probe succeeded or failed). */
int inject_revert(const char *profile_key, const char *domain);

/* Persist a winning strategy: append it to the matching autocircular
 * block in strats_new2.txt as a new permanent strategy=N (next free
 * slot under 200). Updates state.tsv pin to the new ID, clears
 * dynparams, regen+restart ONCE so nfqws2 picks up the new permanent
 * slot. After this call, the strategy survives reboots and the
 * rotator includes it for future hosts.
 *
 * Returns the assigned strategy number on success (>= 1), -1 on
 * error.
 */
int inject_persist_winner(const char *strategy_str, const char *profile_key,
                          const char *domain);

#endif
