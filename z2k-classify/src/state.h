/* z2k-classify — autocircular state.tsv manipulation.
 *
 * Format of /opt/zapret2/extra_strats/cache/autocircular/state.tsv:
 *   # z2k autocircular state (persisted circular nstrategy)
 *   # key<TAB>host<TAB>strategy<TAB>ts
 *   rkn_tcp<TAB>habr.com<TAB>3<TAB>1777009996
 *
 * We write-through to that file so the LIVE z2k-autocircular.lua picks
 * up our pin on its next 2-second save tick. That means our classifier
 * shares the primary state file with production autocircular — care
 * required to not corrupt when both write concurrently.
 *
 * Strategy: copy → modify → atomic rename. The Lua writer also uses
 * atomic rename (see z2k-autocircular.lua save_state), so the worst
 * case is one update racing the other; last-writer-wins is acceptable
 * for our 10-second probe cycles.
 */
#ifndef Z2K_CLASSIFY_STATE_H
#define Z2K_CLASSIFY_STATE_H

#include <stdbool.h>

#define STATE_FILE_PRIMARY  "/opt/zapret2/extra_strats/cache/autocircular/state.tsv"
#define STATE_FILE_FALLBACK "/tmp/z2k-autocircular-state.tsv"

/* Write or update a pin for (key, host). Returns 0 on success, -1 on
 * I/O error. If the key+host already exists, the strategy number is
 * replaced; otherwise a new row is appended. Timestamp is set to the
 * current unix time. Atomic via temp-file + rename. */
int state_pin(const char *state_path, const char *key, const char *host,
              int strategy_num);

/* Remove any pin for (key, host). Returns 0 on success (including
 * "row wasn't there"), -1 on I/O error. Used to clean up a probed
 * strategy that didn't win, so autocircular can resume normal rotation. */
int state_unpin(const char *state_path, const char *key, const char *host);

/* Return the active state file path (primary if writable, fallback
 * otherwise). Never fails — returns a valid pointer to a static string. */
const char *state_path_pick(void);

#endif
