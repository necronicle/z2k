/* z2k-classify — entry point.
 *
 * Flow:
 *   1. Multi-shot baseline probe (3 replicas, raw_bypass=true) →
 *      probe_aggregate_t. Surfaces probabilistic RST patterns that
 *      single-shot probing miscalls as block=NONE.
 *   2. classify_aggregate + classify_infer → block_type + reason.
 *      Identifies CDN from resolved IP via cdn_for_ip().
 *   3. Print classification (text or JSON).
 *   4. If --apply and the block is fixable: recipe_for(block, cdn,
 *      has_ts) → composite recipe entry (or NULL = unmapped).
 *      If unmapped: report "no recipe for this (block, cdn, ts) tuple
 *        — escalate to maintainer with pcap. Honest about limits."
 *      Otherwise: inject_apply (writes dynparams + state.tsv pin),
 *        re-probe (raw_bypass=false → through bypass pipeline).
 *      If post-probe is BLOCK_NONE: persist_winner (or revert if
 *        --dry-run). Otherwise: revert + report "tried <recipe>,
 *        didn't pass; for МГТС-style CF cases consider L3 routing
 *        trick (hosts override to alt CF anycast)."
 */
#include "types.h"
#include "probe.h"
#include "classify.h"
#include "recipe.h"
#include "inject.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>

static const char *VERSION = "0.4.0-cookbook";

static void print_usage(FILE *f) {
	fprintf(f,
		"z2k-classify %s — DPI block classifier + cookbook strategy emitter\n"
		"\n"
		"Usage: z2k-classify <domain> [options]\n"
		"\n"
		"Options:\n"
		"  --apply         Look up the field-tested recipe for the detected\n"
		"                  (block, cdn, has_ts) tuple, inject it seamlessly\n"
		"                  (no nfqws2 restart), re-probe THROUGH the bypass\n"
		"                  pipeline. If it passes, persist as a new strategy.\n"
		"                  If unmapped — refuse to invent and escalate.\n"
		"  --dry-run       With --apply: inject + re-probe but never persist.\n"
		"  --replicas=N    Probe replica count (default 3, max 5).\n"
		"  --json          Machine-readable JSON output.\n"
		"  --timeout=N     Per-probe budget in seconds (default 60).\n"
		"  --verbose       Per-probe diagnostic prints.\n"
		"  --version       Show version and exit.\n"
		"  --help          Show this help and exit.\n"
		"\n"
		"Exit codes:\n"
		"  0  classification completed (output may be none/unknown)\n"
		"  1  hard error (bad args, DNS broken)\n"
		"  2  probe internal error\n"
		"  3  with --apply: recipe was tried and didn't pass post-probe\n"
		"  4  with --apply: (block, cdn, ts) tuple is unmapped — no recipe\n",
		VERSION);
}

/* Build the --lua-desync= string for inject helper from a recipe entry. */
static int build_strategy_str(const recipe_entry_t *r, char *buf, size_t bufsz) {
	int n = snprintf(buf, bufsz, "--lua-desync=%s:%s",
	                 r->family ? r->family : "",
	                 r->params ? r->params : "");
	if (n < 0 || (size_t)n >= bufsz) return -1;
	return n;
}

/* hosts_override family is NOT a DPI desync — it's a DNS-resolution
 * override (Keenetic `ip host` / static DNS records). We can't apply
 * it from inside this binary safely (would need ndmsystem CLI access
 * + revert logic), so we emit copy-paste commands for the user.
 * Auto-apply is the Phase-3 task. */
static void emit_hosts_override(classify_result_t *res,
                                 const recipe_entry_t *r, bool quiet) {
	const char *params = r->params ? r->params : "";
	const char *p = strstr(params, "alt_ips=");
	if (!p) {
		snprintf(res->apply_note, sizeof(res->apply_note),
		         "hosts_override recipe missing alt_ips param");
		return;
	}
	p += 8;

	if (!quiet) {
		fprintf(stderr,
		        "\nL3 routing trick — DPI bypass won't help here.\n"
		        "%s anycasts the same SNI to many IPs; the ISP blocks\n"
		        "some subnets but not others. Override DNS to an alt\n"
		        "anycast that's reachable.\n\n"
		        "On Keenetic CLI try alt IPs in order until one works:\n",
		        cdn_name(res->cdn));
	}

	int n = 0;
	const char *start = p;
	char buf[3072];
	size_t blen = 0;
	blen += snprintf(buf + blen, sizeof(buf) - blen,
	                 "Try each alt-IP until cloudflare opens in browser. "
	                 "After each, run `system configuration save` to "
	                 "persist. Alt-IPs to try: ");
	while (*start && blen + 32 < sizeof(buf)) {
		const char *comma = strchr(start, ',');
		size_t len = comma ? (size_t)(comma - start) : strlen(start);
		char ip[32];
		if (len >= sizeof(ip)) len = sizeof(ip) - 1;
		memcpy(ip, start, len); ip[len] = '\0';

		if (!quiet) {
			fprintf(stderr,
			        "  ip host %s %s\n"
			        "  ip host www.%s %s\n"
			        "  system configuration save\n"
			        "  (then clear browser DNS cache and retest)\n\n",
			        res->domain, ip, res->domain, ip);
		}
		blen += snprintf(buf + blen, sizeof(buf) - blen,
		                 "%s%s", n > 0 ? ", " : "", ip);
		n++;
		if (!comma) break;
		start = comma + 1;
	}

	res->apply_succeeded = true;   /* recommendation emitted; user acts */
	res->winner_strategy = -2;     /* sentinel for "manual L3 trick" */
	snprintf(res->apply_note, sizeof(res->apply_note),
	         "MANUAL: %s. %s",
	         r->human_label, buf);
}

/* Phase 2 — single composite recipe lookup + apply + post-probe. */
static void apply_phase(classify_result_t *res, bool dry_run, bool quiet) {
	res->apply_attempted = true;
	res->apply_succeeded = false;
	res->unmapped = false;
	res->winner_strategy = 0;
	res->winner_profile[0] = '\0';
	res->winner_family[0] = '\0';
	res->winner_label[0] = '\0';
	res->winner_cite[0] = '\0';

	bool has_ts = res->agg.server_ts_negotiated;

	const recipe_entry_t *r = recipe_for(res->block_type, res->cdn, has_ts);
	if (!r) {
		res->unmapped = true;
		snprintf(res->apply_note, sizeof(res->apply_note),
		         "unmapped tuple (block=%s, cdn=%s, has_ts=%d) — registry "
		         "has no entry. Refusing to invent. Escalate to maintainer "
		         "with tcpdump+nfqws2 debug log.",
		         block_type_name(res->block_type), cdn_name(res->cdn), has_ts);
		return;
	}

	snprintf(res->winner_profile, sizeof(res->winner_profile),
	         "%s", r->profile_key);
	snprintf(res->winner_family, sizeof(res->winner_family),
	         "%s", r->family);
	snprintf(res->winner_label, sizeof(res->winner_label),
	         "%s", r->human_label);
	snprintf(res->winner_cite, sizeof(res->winner_cite),
	         "%s", r->cite);

	/* Special path: hosts_override is a manual L3 routing trick, not a
	 * lua-handler family. Emit instructions, no inject/probe. */
	if (strcmp(r->family, "hosts_override") == 0) {
		emit_hosts_override(res, r, quiet);
		(void)dry_run;
		return;
	}

	char strategy_str[2048];
	if (build_strategy_str(r, strategy_str, sizeof(strategy_str)) < 0) {
		snprintf(res->apply_note, sizeof(res->apply_note),
		         "internal: strategy string overflowed buffer");
		return;
	}

	if (!quiet) {
		fprintf(stderr, "selected: %s/%s → %s (%s)\n",
		        block_type_name(res->block_type), cdn_name(res->cdn),
		        r->family, r->human_label);
		fprintf(stderr, "          cite: %s\n", r->cite);
		fprintf(stderr, "applying ... ");
		fflush(stderr);
	}

	if (inject_apply(strategy_str, r->profile_key, res->domain) != 0) {
		snprintf(res->apply_note, sizeof(res->apply_note),
		         "inject_apply failed (helper script error). "
		         "Strategy: %s", strategy_str);
		if (!quiet) { fprintf(stderr, "INJECT FAIL\n"); fflush(stderr); }
		return;
	}

	/* Post-probe through normal pipeline (raw_bypass=false). */
	probe_aggregate_t post = {0};
	struct in_addr ip;
	int rc = probe_run(res->domain, 30, 3, &post, &ip, false);
	if (rc < 0) {
		inject_revert(r->profile_key, res->domain);
		snprintf(res->apply_note, sizeof(res->apply_note),
		         "post-inject probe failed (probe internals broken)");
		if (!quiet) { fprintf(stderr, "PROBE FAIL\n"); fflush(stderr); }
		return;
	}

	classify_aggregate(&post);
	classify_result_t after = {0};
	snprintf(after.domain, sizeof(after.domain), "%s", res->domain);
	after.resolved_ip = ip;
	after.cdn = res->cdn;
	after.agg = post;
	classify_infer(&after);

	if (after.block_type == BLOCK_NONE) {
		res->apply_succeeded = true;
		if (!quiet) { fprintf(stderr, "PASSED\n"); fflush(stderr); }

		if (dry_run) {
			inject_revert(r->profile_key, res->domain);
			res->winner_strategy = -1;
			snprintf(res->apply_note, sizeof(res->apply_note),
			         "WINNER (dry-run, reverted): %s — %s",
			         r->human_label, strategy_str);
		} else {
			int new_id = inject_persist_winner(strategy_str, r->profile_key,
			                                   res->domain);
			if (new_id < 0) {
				res->winner_strategy = 0;
				snprintf(res->apply_note, sizeof(res->apply_note),
				         "WINNER but persist failed — strategy active "
				         "transiently only (won't survive reboot). %s",
				         r->human_label);
			} else {
				res->winner_strategy = new_id;
				snprintf(res->apply_note, sizeof(res->apply_note),
				         "WINNER persisted as strategy_id=%d. %s",
				         new_id, r->human_label);
			}
		}
		return;
	}

	/* Did not pass. Revert and explain. */
	inject_revert(r->profile_key, res->domain);
	if (!quiet) {
		fprintf(stderr, "STILL BLOCKED (block=%s)\n",
		        block_type_name(after.block_type));
		fflush(stderr);
	}

	/* Cascade: stubborn CF/OVH/CloudFront cases (МГТС-residential
	 * pattern, ntc.party 21161 #354-374) — DPI cookbook is exhausted,
	 * automatically fall through to hosts_override emission. We use
	 * BLOCK_L3_ISP_DROP × cdn lookup to fetch the curated alt-anycast
	 * list. */
	if (res->cdn == CDN_CLOUDFLARE || res->cdn == CDN_OVH ||
	    res->cdn == CDN_CLOUDFRONT) {
		const recipe_entry_t *fb = recipe_for(BLOCK_L3_ISP_DROP,
		                                       res->cdn, has_ts);
		if (fb && strcmp(fb->family, "hosts_override") == 0) {
			if (!quiet) {
				fprintf(stderr,
				        "DPI exhausted — cascading to hosts_override "
				        "(stubborn-CDN fallback)\n");
				fflush(stderr);
			}
			emit_hosts_override(res, fb, quiet);
			return;
		}
	}

	snprintf(res->apply_note, sizeof(res->apply_note),
	         "Tried %s but post-probe still %s. Recipe was the best "
	         "field-validated entry for (block=%s, cdn=%s); failure "
	         "suggests local TSPU variant — escalate with pcap.",
	         r->human_label, block_type_name(after.block_type),
	         block_type_name(res->block_type), cdn_name(res->cdn));
}

/* ---------------- output formatters ---------------- */

static void print_text_result(const classify_result_t *r) {
	char ipbuf[INET_ADDRSTRLEN];
	inet_ntop(AF_INET, &r->resolved_ip, ipbuf, sizeof(ipbuf));
	const probe_aggregate_t *a = &r->agg;

	printf("domain:           %s\n", r->domain);
	printf("resolved_ip:      %s\n", a->dns_ok ? ipbuf : "(dns failed)");
	printf("cdn:              %s\n", cdn_name(r->cdn));
	printf("probe (%d replicas, %d ms total):\n",
	       a->replica_count, a->total_duration_ms);
	printf("  dns_ok:               %s\n", a->dns_ok ? "yes" : "no");
	printf("  icmp_reachable:       %s\n", a->icmp_reachable ? "yes" : "no");
	printf("  tcp_connect:          %d/%d\n",
	       a->tcp_connect_success_count, a->replica_count);
	printf("  rst_observed:         %d/%d%s\n",
	       a->rst_observed_count, a->replica_count,
	       a->is_probabilistic ? " (PROBABILISTIC)" : "");
	if (a->rst_observed_count > 0) {
		printf("  rst_after_bytes_med:  %d\n", a->median_rst_after_bytes);
	}
	printf("  size_final_max:       %u\n", a->max_size_final);
	if (a->any_stalled_at_16kb) {
		printf("  stalled_at_16kb:      yes (%u bytes, %s)\n",
		       a->max_size_before_stall,
		       a->all_stalled_at_16kb ? "all replicas" : "some replicas");
	}
	printf("  server_ts_negotiated: %s\n",
	       a->server_ts_negotiated ? "yes" : "no");
	if (a->min_server_winsize > 0) {
		printf("  server_snd_mss:       %u\n", a->min_server_winsize);
	}
	if (a->trace_attempted) {
		printf("path:\n");
		printf("  reaches_dest:         %s (last live hop %d/%d)\n",
		       a->trace_reaches_dest ? "yes" : "no",
		       a->trace_last_live_ttl, a->trace_max_ttl_tried);
		if (a->trace_last_live_ttl > 0) {
			char hopbuf[INET_ADDRSTRLEN];
			inet_ntop(AF_INET, &a->trace_last_live_ip, hopbuf, sizeof(hopbuf));
			printf("  last_hop_ip:          %s\n", hopbuf);
			if (a->trace_last_revdns[0]) {
				printf("  last_hop_revdns:      %s\n", a->trace_last_revdns);
			}
			if (a->trace_isp_name[0]) {
				printf("  isp_match:            %s\n", a->trace_isp_name);
			}
		}
	}

	printf("block_type:       %s\n", block_type_name(r->block_type));
	printf("reason:           %s\n", r->reason);
	if (r->recommended[0]) {
		printf("recommended:      %s\n", r->recommended);
	}

	if (r->apply_attempted) {
		printf("apply:\n");
		printf("  recipe:             %s\n",
		       r->winner_label[0] ? r->winner_label : "(none)");
		if (r->winner_cite[0]) {
			printf("  cite:               %s\n", r->winner_cite);
		}
		printf("  unmapped:           %s\n", r->unmapped ? "yes" : "no");
		printf("  succeeded:          %s\n", r->apply_succeeded ? "yes" : "no");
		if (r->apply_succeeded && r->winner_strategy != 0) {
			if (r->winner_strategy == -1) {
				printf("  winner:             reverted (--dry-run)\n");
			} else if (r->winner_strategy == -2) {
				printf("  winner:             MANUAL — see commands above\n");
			} else {
				printf("  winner_strategy:    %d\n", r->winner_strategy);
				printf("  winner_profile:     %s\n", r->winner_profile);
			}
		}
		printf("  note:               %s\n", r->apply_note);
	}
}

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
	if (r->agg.dns_ok)
		inet_ntop(AF_INET, &r->resolved_ip, ipbuf, sizeof(ipbuf));
	const probe_aggregate_t *a = &r->agg;
	char reason_esc[1024], rec_esc[1536], domain_esc[512], note_esc[512];
	char label_esc[256], cite_esc[256];
	json_escape(r->reason, reason_esc, sizeof(reason_esc));
	json_escape(r->recommended, rec_esc, sizeof(rec_esc));
	json_escape(r->domain, domain_esc, sizeof(domain_esc));
	json_escape(r->apply_note, note_esc, sizeof(note_esc));
	json_escape(r->winner_label, label_esc, sizeof(label_esc));
	json_escape(r->winner_cite, cite_esc, sizeof(cite_esc));

	printf("{"
	       "\"domain\":\"%s\","
	       "\"resolved_ip\":\"%s\","
	       "\"cdn\":\"%s\","
	       "\"block_type\":\"%s\","
	       "\"reason\":\"%s\","
	       "\"recommended\":\"%s\","
	       "\"probe\":{"
	       "\"replica_count\":%d,"
	       "\"dns_ok\":%s,"
	       "\"icmp_reachable\":%s,"
	       "\"tcp_connect_success\":%d,"
	       "\"rst_observed\":%d,"
	       "\"is_probabilistic\":%s,"
	       "\"median_rst_after_bytes\":%d,"
	       "\"size_final_max\":%u,"
	       "\"size_before_stall_max\":%u,"
	       "\"any_stalled_at_16kb\":%s,"
	       "\"all_stalled_at_16kb\":%s,"
	       "\"server_ts_negotiated\":%s,"
	       "\"server_mss_proxy\":%u,"
	       "\"total_duration_ms\":%d"
	       "},"
	       "\"apply\":{"
	       "\"attempted\":%s,"
	       "\"succeeded\":%s,"
	       "\"unmapped\":%s,"
	       "\"winner_strategy\":%d,"
	       "\"winner_profile\":\"%s\","
	       "\"winner_family\":\"%s\","
	       "\"recipe_label\":\"%s\","
	       "\"recipe_cite\":\"%s\","
	       "\"note\":\"%s\""
	       "}"
	       "}\n",
	       domain_esc, ipbuf, cdn_name(r->cdn),
	       block_type_name(r->block_type),
	       reason_esc, rec_esc,
	       a->replica_count,
	       a->dns_ok ? "true" : "false",
	       a->icmp_reachable ? "true" : "false",
	       a->tcp_connect_success_count,
	       a->rst_observed_count,
	       a->is_probabilistic ? "true" : "false",
	       a->median_rst_after_bytes,
	       a->max_size_final, a->max_size_before_stall,
	       a->any_stalled_at_16kb ? "true" : "false",
	       a->all_stalled_at_16kb ? "true" : "false",
	       a->server_ts_negotiated ? "true" : "false",
	       a->min_server_winsize,
	       a->total_duration_ms,
	       r->apply_attempted ? "true" : "false",
	       r->apply_succeeded ? "true" : "false",
	       r->unmapped ? "true" : "false",
	       r->winner_strategy,
	       r->winner_profile, r->winner_family,
	       label_esc, cite_esc, note_esc);
}

int main(int argc, char **argv) {
	const char *domain = NULL;
	bool want_json = false;
	bool verbose = false;
	bool want_apply = false;
	bool dry_run = false;
	int timeout_sec = 60;
	int replicas = 3;

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
		if (!strncmp(a, "--replicas=", 11)) {
			replicas = atoi(a + 11);
			if (replicas < 1) replicas = 1;
			if (replicas > PROBE_REPLICAS_MAX) replicas = PROBE_REPLICAS_MAX;
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
	bool quiet = want_json;

	if (!quiet) {
		fprintf(stderr, "probing %s (%d replicas, raw_bypass)... ",
		        domain, replicas);
		fflush(stderr);
	}

	struct in_addr ip = {0};
	int rc = probe_run(domain, timeout_sec, replicas, &res.agg, &ip, true);
	if (rc < 0) {
		fprintf(stderr, "probe_run: internal error\n");
		return 2;
	}
	res.resolved_ip = ip;
	classify_aggregate(&res.agg);
	res.cdn = res.agg.dns_ok ? cdn_for_ip(ip) : CDN_UNKNOWN;

	/* Path discovery (one-shot). Surfaces L3 ISP null-route vs DPI block. */
	if (res.agg.dns_ok) {
		if (!quiet) { fprintf(stderr, "tracing path... "); fflush(stderr); }
		probe_trace_path(ip, &res.agg);
		if (!quiet) {
			if (!res.agg.trace_attempted) {
				fprintf(stderr, "(no traceroute binary)\n");
			} else if (res.agg.trace_reaches_dest) {
				fprintf(stderr, "reaches dest in %d hops\n",
				        res.agg.trace_last_live_ttl);
			} else if (res.agg.trace_isp_name[0]) {
				fprintf(stderr, "stops at %s (hop %d)\n",
				        res.agg.trace_isp_name, res.agg.trace_last_live_ttl);
			} else {
				fprintf(stderr, "stops mid-path at hop %d\n",
				        res.agg.trace_last_live_ttl);
			}
			fflush(stderr);
		}
	}

	classify_infer(&res);

	if (!quiet) {
		fprintf(stderr, "block=%s cdn=%s%s\n",
		        block_type_name(res.block_type), cdn_name(res.cdn),
		        res.agg.is_probabilistic ? " (probabilistic)" : "");
		fflush(stderr);
	}

	if (want_apply &&
	    res.block_type != BLOCK_NONE &&
	    res.block_type != BLOCK_TRANSIT_DROP &&
	    res.block_type != BLOCK_MOBILE_ICMP &&
	    res.block_type != BLOCK_ANTI_DDOS_SLOWSTART) {
		/* L3_ISP_DROP gets a recipe lookup too — for CDN matches, the
		 * cookbook returns a hosts_override entry that emits manual
		 * `ip host` instructions instead of running DPI inject. */
		apply_phase(&res, dry_run, quiet);
	} else if (want_apply && !quiet) {
		fprintf(stderr,
		        "no apply: block_type=%s%s\n",
		        block_type_name(res.block_type),
		        res.block_type == BLOCK_NONE
		            ? " (already reachable from raw probe)"
		            : "");
		fflush(stderr);
	}

	(void)verbose;

	if (want_json) print_json_result(&res);
	else print_text_result(&res);

	if (want_apply && res.apply_attempted) {
		if (res.unmapped) return 4;
		if (!res.apply_succeeded) return 3;
	}
	return 0;
}
