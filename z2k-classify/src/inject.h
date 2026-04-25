/* z2k-classify — runtime strategy injection (seamless / no-restart).
 *
 * Architecture:
 *
 *   /opt/zapret2/lists/z2k-classify-strategies.tsv  — strategy catalog
 *       # id  family  params
 *       1     multisplit     pos=1,sniext+1:seqovl=1:seqovl_pattern=...
 *       2     fake           blob=...:repeats=6:tcp_seq=2:tcp_ack=-66000:...
 *
 *   /opt/zapret2/lists/z2k-classify-domains.tsv     — host → strategy id
 *       # host         strategy_id
 *       proton.me      1
 *       linkedin.com   1     (deduped: same strategy as proton.me)
 *       discord.com    2
 *
 *   /tmp/z2k-classify-dynparams                     — transient generator slot
 *       # one-shot test channel; only active during a --apply run.
 *
 *   state.tsv pin                                   — routes flows to slot
 *       (profile_key, host) → handler slot id  (sequential :strategy=N+1
 *       added by config_official.sh, e.g. 48 in rkn_tcp).
 *
 * Op semantics:
 *
 *   inject_apply      — write transient dynparams + pin state.tsv to
 *                       handler slot. NO DB write.
 *   inject_revert     — clear dynparams. Unpin ONLY if domain has no
 *                       persistent DB entry (otherwise keep pin so the
 *                       handler keeps serving its persisted strategy).
 *   inject_persist    — dedupe-aware DB write: lookup or assign id for
 *                       (family, params), upsert host→id row, pin
 *                       state.tsv. NO restart, NO regen.
 *
 * Cost per iteration: ~1 sec (file write + 1-sec TTL settle + probe).
 * 12-candidate run = ~15-25 sec. Persist is millisecond-scale.
 */
#ifndef Z2K_CLASSIFY_INJECT_H
#define Z2K_CLASSIFY_INJECT_H

#include <stdbool.h>

/* Sentinel returned in apply_note when a winner ended up in the
 * transient dynparams slot rather than the persistent DB (e.g.
 * helper script failure during persist). The actual handler slot
 * number is dynamic — read from /opt/zapret2/dynamic-slots.conf. */
#define INJECT_DYNAMIC_STRATEGY_ID 0

/* Inject one candidate strategy into the live nfqws2 setup (transient).
 *
 * strategy_str — the --lua-desync= string emitted by the generator
 *                (with or without strategy=N tag — helper strips it).
 * profile_key  — "rkn_tcp" / "google_tls" / "cdn_tls" (matches a key
 *                in /opt/zapret2/dynamic-slots.conf).
 * domain       — host to pin so only THIS domain's flow uses the
 *                strategy during the test.
 *
 * Returns 0 on success (strategy active on next flow), -1 on error.
 * Caller should probe the domain and then call inject_revert().
 */
int inject_apply(const char *strategy_str, const char *profile_key,
                 const char *domain);

/* Revert. Truncates the dynparams file. Unpins state.tsv only if the
 * domain has no entry in the persistent DB (otherwise the handler
 * needs the pin to keep serving the persisted strategy). Always call
 * after inject_apply(), whether probe succeeded or failed. */
int inject_revert(const char *profile_key, const char *domain);

/* Persist a winning strategy: dedupe-lookup (family, params) in
 * strategies.tsv → reuse existing id or append new sequential id;
 * upsert (host, id) row in domains.tsv; pin state.tsv to handler slot.
 * NO regen, NO restart — the Lua handler picks up DB changes within
 * its 5-sec TTL cache window.
 *
 * Returns the assigned strategy_id (>= 1), -1 on error.
 */
int inject_persist_winner(const char *strategy_str, const char *profile_key,
                          const char *domain);

#endif
