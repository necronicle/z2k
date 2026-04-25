/* z2k-classify — entry point.
 *
 * Phase 1: argparse + orchestrate probe + classify + text/JSON output.
 * Phase 2 will add the strategy-probe step under --apply.
 */
#include "types.h"
#include "probe.h"
#include "classify.h"
#include "recipe.h"
#include "generator.h"
#include "inject.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>

/* Portable sub-second sleep — avoids usleep's _XOPEN_SOURCE dance. */
static void sleep_ms(int ms) {
	struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

static const char *VERSION = "0.3.0-generator";

static void print_usage(FILE *f) {
	fprintf(f,
		"z2k-classify %s — DPI block-type classifier + strategy generator\n"
		"\n"
		"Usage: z2k-classify <domain> [options]\n"
		"\n"
		"Options:\n"
		"  --apply         Generator mode: synthesize fresh strategies from\n"
		"                  per-block-type primitive recipes, inject each\n"
		"                  seamlessly (no nfqws2 restart, only THIS domain's\n"
		"                  flow is affected), find a winner, persist it as\n"
		"                  a new strategy=N in strats_new2.txt.\n"
		"  --dry-run       With --apply: synthesize and probe, but revert all\n"
		"                  changes when done (don't persist the winner)\n"
		"  --json          Machine-readable JSON output\n"
		"  --timeout=N     Total probe budget in seconds (default 60)\n"
		"  --verbose       Per-probe diagnostic prints\n"
		"  --version       Show version and exit\n"
		"  --help          Show this help and exit\n"
		"\n"
		"Exit codes:\n"
		"  0  — classification completed (output may be none/unknown)\n"
		"  1  — hard error (bad args, DNS failure to get any IP)\n"
		"  2  — probe internal error (socket API broken etc.)\n"
		"  3  — with --apply: no template strategy worked\n",
		VERSION);
}

/* Phase 2 generator — synthesize fresh strategies from primitive
 * recipes and probe each one until we find a winner.
 *
 * For each generated strategy:
 *   1. inject_apply() writes the parsed family + key=value params to
 *      /tmp/z2k-classify-dynparams and pins (profile_key, domain) →
 *      strategy=200 in state.tsv. NO nfqws2 restart. The pre-installed
 *      z2k_dynamic_strategy slot in the matching autocircular block
 *      reads dynparams per-packet (1-sec TTL cache) and dispatches
 *      to fake/multisplit/hostfakesplit/multidisorder for ONLY the
 *      pinned domain. Other users' DPI bypass keeps running normally.
 *   2. probe_run() retests the domain.
 *   3. classify_infer() on the post-inject result. If block_type
 *      flipped to BLOCK_NONE, this strategy is the winner.
 *   4a. Winner + !dry_run: inject_persist_winner() promotes the
 *       strategy to next-available permanent slot (e.g. strategy=48
 *       in rkn_tcp), updates state.tsv pin, regen+restart ONCE.
 *       Survives reboots; rotator picks it up for future hosts too.
 *   4b. Winner + dry_run: inject_revert() truncates dynparams +
 *       unpins state.tsv. Nothing persists.
 *   5. No winner after exhausting recipe: inject_revert() to clean
 *      slate, report failure to caller.
 *
 * Cost: each iteration ≈ 2 s (file write ~10 ms + 1-s TTL settle +
 * probe ~1 s). 30-combo run = ~60-90 s total. Persist adds ~5 s once.
 */
static void phase2_generate(classify_result_t *res, bool dry_run, bool verbose,
                            int max_attempts) {
	res->apply_attempted = true;
	res->apply_succeeded = false;
	res->winner_strategy = 0;
	res->winner_profile[0] = '\0';
	res->strategies_tried = 0;

	const recipe_t *r = recipe_for_block(res->block_type);
	if (!r) {
		snprintf(res->apply_note, sizeof(res->apply_note),
		         "no recipe for block_type=%s — generator cannot synthesize",
		         block_type_name(res->block_type));
		return;
	}

	snprintf(res->winner_profile, sizeof(res->winner_profile), "%s", r->profile_key);

	int total = gen_total_count(r);
	if (verbose) {
		fprintf(stderr, "phase2 generator: %d candidate(s) across %d famil(ies) for block_type=%s, profile=%s\n",
		        total, r->family_count, block_type_name(res->block_type),
		        r->profile_key);
	}

	if (max_attempts > 0 && total > max_attempts) {
		if (verbose) fprintf(stderr, "phase2 generator: capping attempts at %d (recipe has %d)\n",
		                     max_attempts, total);
		total = max_attempts;
	}

	generator_t g;
	gen_init(&g, r);

	char strategy_buf[2048];
	const char *family = NULL;

	for (int i = 0; i < total; i++) {
		int gen_rc = gen_next(&g, strategy_buf, sizeof(strategy_buf), &family);
		if (gen_rc <= 0) break;
		res->strategies_tried = i + 1;

		if (verbose) {
			fprintf(stderr, "  [%d/%d] family=%s\n    %s\n",
			        i + 1, total, family ? family : "?", strategy_buf);
		}

		/* Inject + restart cycle. */
		if (inject_apply(strategy_buf, r->profile_key, res->domain) != 0) {
			if (verbose) fprintf(stderr, "    inject_apply failed, skipping\n");
			continue;
		}

		/* Re-probe THROUGH the bypass pipeline so the slot=48 handler
		 * runs against this connection. raw_bypass=false. */
		probe_result_t post = {0};
		struct in_addr ip;
		if (probe_run(res->domain, 15, &post, &ip, false) != 0) {
			if (verbose) fprintf(stderr, "    probe_run failed\n");
			inject_revert(r->profile_key, res->domain);
			continue;
		}

		classify_result_t after = {0};
		snprintf(after.domain, sizeof(after.domain), "%s", res->domain);
		after.resolved_ip = ip;
		after.probe = post;
		classify_infer(&after);

		if (verbose) {
			fprintf(stderr, "    post-inject: block_type=%s size=%u rst=%d\n",
			        block_type_name(after.block_type),
			        post.size_final, post.server_rst_received);
		}

		if (after.block_type == BLOCK_NONE) {
			/* Winner found. */
			res->apply_succeeded = true;

			if (dry_run) {
				inject_revert(r->profile_key, res->domain);
				snprintf(res->apply_note, sizeof(res->apply_note),
				         "WINNER: family=%s — but reverted (--dry-run). "
				         "Strategy: %s",
				         family ? family : "?", strategy_buf);
				res->winner_strategy = -1;  /* not persisted */
			} else {
				int new_id = inject_persist_winner(strategy_buf,
				                                    r->profile_key,
				                                    res->domain);
				if (new_id < 0) {
					snprintf(res->apply_note, sizeof(res->apply_note),
					         "WINNER family=%s but persist failed; "
					         "kept as dynamic slot 200. Strategy: %s",
					         family ? family : "?", strategy_buf);
					res->winner_strategy = INJECT_DYNAMIC_STRATEGY_ID;
				} else {
					snprintf(res->apply_note, sizeof(res->apply_note),
					         "WINNER persisted as strategy=%d in profile=%s "
					         "(family=%s). Future hosts get rotator coverage too.",
					         new_id, r->profile_key,
					         family ? family : "?");
					res->winner_strategy = new_id;
				}
			}
			return;
		}

		/* Not a winner — revert and continue. */
		inject_revert(r->profile_key, res->domain);
	}

	snprintf(res->apply_note, sizeof(res->apply_note),
	         "exhausted %d candidate(s) without a winner — recipe needs widening "
	         "OR domain is blocked at L3 (transit drop, not DPI)",
	         res->strategies_tried);
}

static void print_text_result(const classify_result_t *r) {
	char ipbuf[INET_ADDRSTRLEN];
	inet_ntop(AF_INET, &r->resolved_ip, ipbuf, sizeof(ipbuf));

	printf("domain:           %s\n", r->domain);
	printf("resolved_ip:      %s\n", r->probe.dns_ok ? ipbuf : "(dns failed)");
	printf("probe:\n");
	printf("  dns_ok:             %s\n", r->probe.dns_ok ? "yes" : "no");
	printf("  icmp_reachable:     %s\n", r->probe.icmp_reachable ? "yes" : "no");
	printf("  tcp_connect_ok:     %s\n", r->probe.tcp_connect_ok ? "yes" : "no");
	printf("  tls_handshake_ok:   %s\n", r->probe.tls_handshake_ok ? "yes" : "no");
	printf("  server_ts_negotiated: %s\n", r->probe.server_ts_negotiated ? "yes" : "no");
	printf("  server_rst_received: %s (at byte %d)\n",
	       r->probe.server_rst_received ? "yes" : "no", r->probe.rst_after_bytes);
	printf("  size_before_stall:  %u\n", r->probe.size_before_stall);
	printf("  size_final:         %u\n", r->probe.size_final);
	printf("  duration_ms:        %d\n", r->probe.duration_ms);
	printf("block_type:       %s\n", block_type_name(r->block_type));
	printf("reason:           %s\n", r->reason);
	if (r->recommended[0]) {
		printf("recommended:      %s\n", r->recommended);
	}
	if (r->apply_attempted) {
		printf("apply:\n");
		printf("  strategies_tried:   %d\n", r->strategies_tried);
		printf("  succeeded:          %s\n", r->apply_succeeded ? "yes" : "no");
		if (r->apply_succeeded) {
			printf("  winner_strategy:    %d\n", r->winner_strategy);
			printf("  winner_profile:     %s\n", r->winner_profile);
		}
		printf("  note:               %s\n", r->apply_note);
	}
}

/* Emit JSON. Escape only quotes and backslashes — we control input
 * sources, so no full escaper needed. */
static void json_escape(const char *in, char *out, size_t outlen) {
	size_t j = 0;
	for (size_t i = 0; in[i] && j + 2 < outlen; i++) {
		if (in[i] == '"' || in[i] == '\\') {
			if (j + 3 >= outlen) break;
			out[j++] = '\\';
		}
		out[j++] = in[i];
	}
	out[j] = '\0';
}

static void print_json_result(const classify_result_t *r) {
	char ipbuf[INET_ADDRSTRLEN] = {0};
	if (r->probe.dns_ok)
		inet_ntop(AF_INET, &r->resolved_ip, ipbuf, sizeof(ipbuf));
	char reason_esc[1024], rec_esc[1536], domain_esc[512], note_esc[512];
	json_escape(r->reason, reason_esc, sizeof(reason_esc));
	json_escape(r->recommended, rec_esc, sizeof(rec_esc));
	json_escape(r->domain, domain_esc, sizeof(domain_esc));
	json_escape(r->apply_note, note_esc, sizeof(note_esc));

	printf("{"
	       "\"domain\":\"%s\","
	       "\"resolved_ip\":\"%s\","
	       "\"block_type\":\"%s\","
	       "\"reason\":\"%s\","
	       "\"recommended\":\"%s\","
	       "\"probe\":{"
	       "\"dns_ok\":%s,"
	       "\"icmp_reachable\":%s,"
	       "\"tcp_connect_ok\":%s,"
	       "\"tls_handshake_ok\":%s,"
	       "\"server_ts_negotiated\":%s,"
	       "\"server_rst_received\":%s,"
	       "\"rst_after_bytes\":%d,"
	       "\"size_before_stall\":%u,"
	       "\"size_final\":%u,"
	       "\"duration_ms\":%d"
	       "},"
	       "\"apply\":{"
	       "\"attempted\":%s,"
	       "\"succeeded\":%s,"
	       "\"winner_strategy\":%d,"
	       "\"winner_profile\":\"%s\","
	       "\"strategies_tried\":%d,"
	       "\"note\":\"%s\""
	       "}"
	       "}\n",
	       domain_esc,
	       ipbuf,
	       block_type_name(r->block_type),
	       reason_esc,
	       rec_esc,
	       r->probe.dns_ok ? "true" : "false",
	       r->probe.icmp_reachable ? "true" : "false",
	       r->probe.tcp_connect_ok ? "true" : "false",
	       r->probe.tls_handshake_ok ? "true" : "false",
	       r->probe.server_ts_negotiated ? "true" : "false",
	       r->probe.server_rst_received ? "true" : "false",
	       r->probe.rst_after_bytes,
	       r->probe.size_before_stall,
	       r->probe.size_final,
	       r->probe.duration_ms,
	       r->apply_attempted ? "true" : "false",
	       r->apply_succeeded ? "true" : "false",
	       r->winner_strategy,
	       r->winner_profile,
	       r->strategies_tried,
	       note_esc);
}

int main(int argc, char **argv) {
	const char *domain = NULL;
	bool want_json = false;
	bool verbose = false;
	bool want_apply = false;
	bool dry_run = false;
	int timeout_sec = 60;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
			print_usage(stdout); return 0;
		}
		if (!strcmp(a, "--version") || !strcmp(a, "-V")) {
			printf("z2k-classify %s\n", VERSION); return 0;
		}
		if (!strcmp(a, "--json")) { want_json = true; continue; }
		if (!strcmp(a, "--apply")) { want_apply = true; continue; }
		if (!strcmp(a, "--dry-run")) { dry_run = true; want_apply = true; continue; }
		if (!strcmp(a, "--verbose") || !strcmp(a, "-v")) {
			verbose = true; continue;
		}
		if (!strncmp(a, "--timeout=", 10)) {
			timeout_sec = atoi(a + 10);
			if (timeout_sec < 5) timeout_sec = 5;
			continue;
		}
		if (a[0] == '-') {
			fprintf(stderr, "unknown option: %s\n", a);
			print_usage(stderr); return 1;
		}
		if (!domain) { domain = a; continue; }
		fprintf(stderr, "extra positional arg: %s\n", a);
		return 1;
	}
	if (!domain) {
		fprintf(stderr, "error: missing domain argument\n");
		print_usage(stderr);
		return 1;
	}

	classify_result_t res = {0};
	snprintf(res.domain, sizeof(res.domain), "%s", domain);

	if (verbose && !want_json) {
		fprintf(stderr, "probing %s (budget %d s)...\n", domain, timeout_sec);
	}

	/* Baseline probe with SO_MARK so packets bypass the nfqws2
	 * pipeline and we measure the RAW TSPU block, not whatever the
	 * existing rotator already managed to bypass. raw_bypass=true. */
	int rc = probe_run(domain, timeout_sec, &res.probe, &res.resolved_ip, true);
	if (rc < 0) {
		fprintf(stderr, "probe_run: internal error\n");
		return 2;
	}

	classify_infer(&res);

	if (want_apply && res.block_type != BLOCK_NONE &&
	    res.block_type != BLOCK_TRANSIT_DROP &&
	    res.block_type != BLOCK_MOBILE_ICMP) {
		/* max_attempts=0 → unlimited (use full recipe size) */
		phase2_generate(&res, dry_run, verbose, 0);
	}

	if (want_json) print_json_result(&res);
	else print_text_result(&res);

	if (want_apply && res.apply_attempted && !res.apply_succeeded) {
		return 3;
	}
	return 0;
}
