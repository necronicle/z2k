#!/usr/bin/env python3
# z2k-stats-aggregate.py — turn the raw anonymized snapshot log into a
# per-(pool, strategy) ranking we can consult when deciding which strategies to
# promote toward the front of a rotation profile and which to demote.
#
# Metric rationale: state.tsv records WHERE rotation landed, not directly WHETHER
# it worked. The proxy we trust is *stable dwell*: how long a (pool, host) slot
# stayed on a strategy without the rotator moving it. A strategy that many
# samples land on AND hold for a long time is genuinely carrying traffic; one
# that churns (short dwell, frequent re-rotation) is not.
#
# Caveats this script makes explicit in its output, never hides:
#   * a stuck-but-broken strategy (rotator never rotates away despite breakage)
#     also shows long dwell — without a success signal we cannot separate it.
#     That is the known limitation of snapshot-only collection; the event-counter
#     upgrade (ok/fail per strategy, archived telemetry subsystem) would fix it.
#   * we only ever see strategies that were OBSERVED; "never played" strategies
#     are reported as a gap relative to the supplied catalog, not invented.
#
# NO device identifier exists in the data (privacy-by-design): each upload is one
# anonymous "device-day sample". Uploads are ~1/day/device, so within the window
# every consistent device contributes uniformly — relative rankings and dwell
# percentiles are valid; we report sample counts, NOT unique-device counts
# (which are deliberately unknowable).

import argparse
import json
import sys
from collections import defaultdict


def weighted_percentile(pairs, pct):
    """pairs: list of (value, weight). Returns the value at the given percentile
    of the weight-expanded distribution. pct in [0,100]."""
    if not pairs:
        return 0
    pairs = sorted(pairs, key=lambda x: x[0])
    total = sum(w for _, w in pairs)
    if total <= 0:
        return 0
    target = pct / 100.0 * total
    acc = 0
    for value, weight in pairs:
        acc += weight
        if acc >= target:
            return value
    return pairs[-1][0]


def load_samples(raw_path, window_days):
    """Read raw.jsonl, return (samples, dates). Each upload line is one sample.
    If window_days is set, keep only samples from the most recent N distinct
    receive-dates (we only store coarse dates, never times)."""
    samples = []
    dates = set()
    try:
        with open(raw_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("schema") != 1 or not isinstance(rec.get("rows"), list):
                    continue
                dates.add(rec.get("rx_date", ""))
                samples.append(rec)
    except FileNotFoundError:
        return [], []

    if window_days and dates:
        keep = set(sorted(d for d in dates if d)[-window_days:])
        samples = [r for r in samples if r.get("rx_date", "") in keep]
    return samples, sorted(d for d in dates if d)


def aggregate(samples):
    # per (pool, strategy): list of (dwell, weight=count) + how many samples hit it
    bucket = defaultdict(list)
    hits = defaultdict(int)
    pool_samples = defaultdict(int)
    pool_strategies = defaultdict(set)
    for rec in samples:
        seen_pools = set()
        for row in rec.get("rows", []):
            pool = row["pool"]
            strat = row["strategy"]
            dwell = row["dwell"]
            count = row.get("count", 1)
            key = (pool, strat)
            bucket[key].append((dwell, count))
            hits[key] += 1
            pool_strategies[pool].add(strat)
            seen_pools.add(pool)
        for pool in seen_pools:
            pool_samples[pool] += 1

    out = {}
    for (pool, strat), pairs in bucket.items():
        n_hits = hits[(pool, strat)]
        total_count = sum(w for _, w in pairs)
        p50 = weighted_percentile(pairs, 50)
        p75 = weighted_percentile(pairs, 75)
        # stability-adoption score: how many samples land here × how long they
        # hold it (median dwell in minutes). Higher = more widely + stably used.
        score = n_hits * (p50 // 60)
        out[(pool, strat)] = {
            "pool": pool,
            "strategy": strat,
            "samples": n_hits,
            "slots": total_count,
            "dwell_p50": p50,
            "dwell_p75": p75,
            "score": score,
        }
    return out, pool_samples, pool_strategies


def render(out, pool_samples, pool_strategies, catalog, total_samples, dates):
    pools = sorted(pool_strategies.keys())
    lines = []
    lines.append("# z2k strategy statistics — anonymized aggregate")
    lines.append(f"# device-day samples in window: {total_samples} (NOT unique devices — by design)")
    if dates:
        lines.append(f"# date span: {dates[0]} .. {dates[-1]}")
    lines.append("# metric: stable dwell (proxy for 'works'); NOT a success signal.")
    lines.append("# columns: strategy  samples  slots  dwell_p50(s)  dwell_p75(s)  score")
    lines.append("")
    summary = {"total_samples": total_samples, "date_span": dates, "pools": {}}
    for pool in pools:
        rows = [v for (p, s), v in out.items() if p == pool]
        rows.sort(key=lambda v: (-v["score"], -v["dwell_p50"], v["strategy"]))
        lines.append(f"== {pool}  ({pool_samples[pool]} samples) ==")
        for v in rows:
            lines.append(
                f"  #{v['strategy']:<4} n={v['samples']:<5} slots={v['slots']:<5} "
                f"p50={v['dwell_p50']:<7} p75={v['dwell_p75']:<7} score={v['score']}"
            )
        observed = pool_strategies[pool]
        if catalog and pool in catalog:
            never = sorted(set(catalog[pool]) - observed)
            if never:
                lines.append(f"  NEVER PLAYED (in catalog, no sample landed): {never}")
        lines.append("")
        summary["pools"][pool] = {
            "samples": pool_samples[pool],
            "strategies": rows,
            "never_played": sorted(set(catalog.get(pool, [])) - observed) if catalog else [],
        }
    return "\n".join(lines), summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default="/var/lib/z2k-stats/raw.jsonl")
    ap.add_argument("--out-json", default="/var/lib/z2k-stats/summary.json")
    ap.add_argument("--out-txt", default="/var/lib/z2k-stats/summary.txt")
    ap.add_argument("--window-days", type=int, default=14)
    ap.add_argument("--catalog", default="", help="optional JSON {pool:[strategy,...]} of known slots")
    args = ap.parse_args()

    catalog = {}
    if args.catalog:
        try:
            with open(args.catalog, "r", encoding="utf-8") as f:
                catalog = json.load(f)
        except (OSError, ValueError):
            catalog = {}

    samples, dates = load_samples(args.raw, args.window_days)
    out, pool_samples, pool_strategies = aggregate(samples)
    txt, summary = render(out, pool_samples, pool_strategies, catalog, len(samples), dates)

    try:
        with open(args.out_txt, "w", encoding="utf-8") as f:
            f.write(txt + "\n")
        with open(args.out_json, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, sort_keys=True)
    except OSError as e:
        sys.stderr.write(f"write failed: {e}\n")
        sys.exit(1)
    sys.stdout.write(txt + "\n")


if __name__ == "__main__":
    main()
