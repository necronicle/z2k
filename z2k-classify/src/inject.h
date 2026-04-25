/* z2k-classify — runtime strategy injection.
 *
 * Mechanism (restart-cycle):
 *   1. Read /opt/zapret2/strats_new2.txt
 *   2. Find the autocircular block matching profile_key (rkn_tcp / cdn_tls)
 *   3. Append our generated strategy to that block with strategy=N where
 *      N is one slot above the highest existing strategy number
 *   4. Re-write strats_new2.txt atomically
 *   5. Run create_official_config to regenerate /opt/zapret2/config
 *   6. Restart nfqws2 (S99zapret2 restart) — ~3-5 sec
 *   7. Pin our domain to strategy=N via state.tsv (so probe traffic
 *      uses the new strategy regardless of normal autocircular pick)
 *   8. Caller probes domain via probe_run()
 *   9. inject_revert() removes the temp strategy + state.tsv pin and
 *      regenerates+restarts to clean state
 *
 * Why restart-cycle and not zero-downtime: nfqws2 reads strategy
 * definitions at startup. Live editing of strats_new2.txt without
 * restart leaves nfqws2 with old definitions. Restart is ~3-5 sec
 * on Keenetic — total cycle 5-7 sec per probe. For a 30-combination
 * generator run that's 2.5-3.5 minutes — within the "минуты" budget.
 *
 * Side effect during the restart: ALL DPI bypass is briefly off for
 * other users on the router. Acceptable trade-off for support tool
 * one-off run.
 */
#ifndef Z2K_CLASSIFY_INJECT_H
#define Z2K_CLASSIFY_INJECT_H

#include <stdbool.h>

#define INJECT_DYNAMIC_STRATEGY_ID 200  /* high enough to never clash */

/* Inject one candidate strategy into the live nfqws2 setup.
 *
 * strategy_str — the --lua-desync= string emitted by the generator
 *                (without strategy=N tag — we add it).
 * profile_key  — "rkn_tcp" or "cdn_tls" (matches autocircular block).
 * domain       — host to pin so probe targets this strategy.
 *
 * Returns 0 on success (strategy active), -1 on error. After success,
 * caller should probe the domain and then call inject_revert().
 *
 * Internal steps:
 *   - rewrite strats_new2.txt with our strategy appended
 *   - run /opt/zapret2/z2k.sh "regenerate" via internal helper
 *   - restart S99zapret2
 *   - pin (profile_key, domain, INJECT_DYNAMIC_STRATEGY_ID) in state.tsv
 */
int inject_apply(const char *strategy_str, const char *profile_key,
                 const char *domain);

/* Revert. Removes the dynamic-slot strategy from strats_new2.txt and
 * the state.tsv pin, regenerates config, restarts nfqws2. Always
 * call after inject_apply() (whether probe succeeded or failed). */
int inject_revert(const char *profile_key, const char *domain);

/* Persist a winning strategy: PROMOTE the temporary dynamic-slot
 * entry to a "real" strategy in strats_new2.txt with the next
 * available strategy=N number. Domain pin in state.tsv is updated
 * to the new ID. After this call, the strategy survives nfqws2
 * restarts, and the rotator includes it for future hosts.
 *
 * Returns the assigned strategy number on success (>= 1), -1 on
 * error.
 */
int inject_persist_winner(const char *strategy_str, const char *profile_key,
                          const char *domain);

#endif
