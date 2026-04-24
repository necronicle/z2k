/* z2k-classify — entry point.
 *
 * Phase 1: argparse + orchestrate probe + classify + text/JSON output.
 * Phase 2 will add the strategy-probe step under --apply.
 */
#include "types.h"
#include "probe.h"
#include "classify.h"
#include "templates.h"
#include "state.h"

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

static const char *VERSION = "0.2.0-phase2";

static void print_usage(FILE *f) {
	fprintf(f,
		"z2k-classify %s — DPI block-type classifier + strategy pin\n"
		"\n"
		"Usage: z2k-classify <domain> [options]\n"
		"\n"
		"Options:\n"
		"  --apply         After classify, probe template strategies and\n"
		"                  pin the winning one in autocircular state.tsv\n"
		"                  (survives nfqws2 restart)\n"
		"  --dry-run       With --apply: probe but don't keep pin (revert\n"
		"                  state.tsv to original at end)\n"
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

/* Phase 2 — probe per-template strategies, pin winner.
 *
 * For each candidate strategy in the block-type template:
 *   1. Write state.tsv pin for (profile_key, domain, strategy_num)
 *   2. Sleep briefly so autocircular picks up the pin on next flow
 *   3. Re-probe the domain
 *   4. If block_type now == NONE → winner. Pin stays (unless --dry-run).
 *   5. Else continue to next strategy.
 *
 * Leaves state.tsv in one of three end states:
 *   - winner strategy pinned (default --apply behavior)
 *   - pinned with original pin (or none) restored (--dry-run, or no winner)
 *
 * Side effect: may temporarily alter autocircular pin state for other
 * users during the probe. z2k-probe.sh has the same limitation.
 */
static void phase2_apply(classify_result_t *res, bool dry_run, bool verbose) {
	res->apply_attempted = true;
	res->apply_succeeded = false;
	res->winner_strategy = 0;
	res->winner_profile[0] = '\0';
	res->strategies_tried = 0;

	const template_t *t = template_for_block(res->block_type);
	if (!t) {
		snprintf(res->apply_note, sizeof(res->apply_note),
		         "no template for block_type=%s — try manual z2k-probe",
		         block_type_name(res->block_type));
		return;
	}

	const char *state_path = state_path_pick();
	snprintf(res->winner_profile, sizeof(res->winner_profile), "%s", t->profile_key);

	if (verbose) {
		fprintf(stderr, "phase2: probing %d strategies for %s (profile=%s, path=%s)\n",
		        t->count, res->domain, t->profile_key, state_path);
	}

	for (int i = 0; i < t->count; i++) {
		int s = t->strategy_nums[i];
		res->strategies_tried = i + 1;

		if (state_pin(state_path, t->profile_key, res->domain, s) != 0) {
			snprintf(res->apply_note, sizeof(res->apply_note),
			         "state_pin failed for strategy=%d (errno?)", s);
			return;
		}
		/* Let autocircular pick up the pin on next flow. Short sleep
		 * matches z2k-probe.sh's 0.2-1 s gap. */
		sleep_ms(400);

		probe_result_t post = {0};
		struct in_addr ip;
		if (probe_run(res->domain, 15, &post, &ip) != 0) {
			if (verbose) fprintf(stderr, "  strategy=%d: probe failed\n", s);
			continue;
		}

		/* Reinterpret post-pin symptoms. Use a throwaway result so we
		 * don't clobber the baseline saved in *res. */
		classify_result_t after = {0};
		snprintf(after.domain, sizeof(after.domain), "%s", res->domain);
		after.resolved_ip = ip;
		after.probe = post;
		classify_infer(&after);

		if (verbose) {
			fprintf(stderr, "  strategy=%d: block_type=%s size=%u rst=%d\n",
			        s, block_type_name(after.block_type),
			        post.size_final, post.server_rst_received);
		}

		if (after.block_type == BLOCK_NONE) {
			res->apply_succeeded = true;
			res->winner_strategy = s;

			if (dry_run) {
				state_unpin(state_path, t->profile_key, res->domain);
				snprintf(res->apply_note, sizeof(res->apply_note),
				         "strategy=%d would work — state.tsv reverted (--dry-run)", s);
			} else {
				snprintf(res->apply_note, sizeof(res->apply_note),
				         "strategy=%d pinned in state.tsv (profile=%s)",
				         s, t->profile_key);
			}
			return;
		}
	}

	/* No strategy worked — revert our probing pin, leave autocircular
	 * to resume normal rotation on next flow. */
	state_unpin(state_path, t->profile_key, res->domain);
	snprintf(res->apply_note, sizeof(res->apply_note),
	         "no template strategy worked — state.tsv unpinned, manual investigation needed");
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

	int rc = probe_run(domain, timeout_sec, &res.probe, &res.resolved_ip);
	if (rc < 0) {
		fprintf(stderr, "probe_run: internal error\n");
		return 2;
	}

	classify_infer(&res);

	if (want_apply && res.block_type != BLOCK_NONE &&
	    res.block_type != BLOCK_TRANSIT_DROP &&
	    res.block_type != BLOCK_MOBILE_ICMP) {
		phase2_apply(&res, dry_run, verbose);
	}

	if (want_json) print_json_result(&res);
	else print_text_result(&res);

	if (want_apply && res.apply_attempted && !res.apply_succeeded) {
		return 3;
	}
	return 0;
}
