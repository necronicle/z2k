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


def _parse_line(line):
    """One raw.jsonl line -> record, or None if it is not a usable sample.

    RecursionError is caught alongside ValueError on purpose. The collector
    already guards its own json.loads against it, because a deeply-nested
    document under the size cap makes the C scanner blow the recursion limit —
    and RecursionError is a RuntimeError, so `except ValueError` does not see it.
    This file reads the very same format and states three lines below that it
    "must not crash on a tampered data file", but only guarded the SHAPE of a
    row, not the parse. One hand-edited line would take down the daily timer for
    good: it would fail, the summary would silently stop updating, and the timer
    would keep failing every morning with nobody looking.
    """
    line = line.strip()
    if not line:
        return None
    try:
        rec = json.loads(line)
    except (ValueError, RecursionError):
        return None
    if not isinstance(rec, dict):
        return None
    if rec.get("schema") != 1 or not isinstance(rec.get("rows"), list):
        return None
    return rec


def scan_dates(raw_path):
    """First pass: the distinct receive-dates present in the log, sorted.

    Cheap by design — parses each line and keeps only a date string, never the
    record. See iter_samples() for why the log is read twice instead of once.
    """
    dates = set()
    try:
        with open(raw_path, "r", encoding="utf-8") as f:
            for line in f:
                rec = _parse_line(line)
                if rec is not None:
                    dates.add(rec.get("rx_date", ""))
    except FileNotFoundError:
        return []
    return sorted(d for d in dates if d)


def iter_samples(raw_path, keep):
    """Second pass: yield only the records inside the window.

    TWO PASSES, NOT ONE BIG LIST. This used to append every record in the file to
    a list and filter afterwards, so peak memory tracked the whole history rather
    than the 14-day window actually reported on. Measured on the live VPS: an
    87 MB log cost 444 MB of resident memory, on a 2 GB box that also carries the
    Telegram tunnels and the WhatsApp relay — roughly five bytes of RAM per byte
    of log, growing with the log rather than with the window. Streaming keeps
    resident memory proportional to the number of distinct (pool, strategy) keys
    instead, which is bounded by the strategy catalog and does not grow over time.

    Reading the file twice is the cheap half of that trade: the pass is
    sequential I/O against the page cache, while the list it replaces was
    unbounded.
    """
    try:
        with open(raw_path, "r", encoding="utf-8") as f:
            for line in f:
                rec = _parse_line(line)
                if rec is None:
                    continue
                if keep is not None and rec.get("rx_date", "") not in keep:
                    continue
                yield rec
    except FileNotFoundError:
        return


def aggregate(samples):
    """Consumes an ITERABLE of records (see iter_samples) and returns
    (out, pool_samples, pool_strategies, total_samples). It counts the samples
    itself rather than taking len() of a list, so the caller never has to hold
    the log in memory."""
    # per (pool, strategy): list of (dwell, weight=count) + how many samples hit it
    bucket = defaultdict(list)
    hits = defaultdict(int)
    pool_samples = defaultdict(int)
    pool_strategies = defaultdict(set)
    total_samples = 0
    for rec in samples:
        total_samples += 1
        seen_pools = set()
        # ONE UPLOAD COUNTS ONCE PER (pool, strategy), however many rows it sent.
        #
        # This is the invariant the README and the collector header both state —
        # "the aggregator treats each upload as one anonymous device-day sample" —
        # and until now nothing enforced it: `hits` was incremented per ROW. Two
        # consequences, one hostile and one ordinary, and the ordinary one is
        # arguably worse:
        #   * hostile: a single request carrying 400 copies of the same pair, every
        #     value inside its declared bound so not one 422, multiplied that
        #     pair's sample count and score by 400 in the summary humans read when
        #     choosing which strategies to promote for the whole fleet;
        #   * ordinary: the client emits one row per (pool, host), so a router
        #     with five hosts on one strategy already counted as five samples.
        #     Pools with more hosts simply outvoted pools with fewer, for no
        #     reason anyone intended.
        # Counting per upload fixes both. The dwell of every individual row still
        # feeds the percentiles below — nothing is discarded, only the vote is
        # made one-per-device-day as documented.
        seen_keys = set()
        for row in rec.get("rows", []):
            # Defensive: a hand-corrupted raw.jsonl line could be schema-valid
            # yet carry a non-dict / key-missing / unhashable row. The collector
            # never emits such rows, but the aggregator must not crash on a
            # tampered data file — skip anything malformed.
            if not isinstance(row, dict):
                continue
            pool = row.get("pool")
            strat = row.get("strategy")
            dwell = row.get("dwell")
            count = row.get("count", 1)
            if not isinstance(pool, str) or not isinstance(strat, int) or isinstance(strat, bool):
                continue
            if not isinstance(dwell, int) or isinstance(dwell, bool):
                continue
            if not isinstance(count, int) or isinstance(count, bool) or count < 1:
                count = 1
            key = (pool, strat)
            bucket[key].append((dwell, count))
            if key not in seen_keys:
                seen_keys.add(key)
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
    return out, pool_samples, pool_strategies, total_samples


def render(out, pool_samples, pool_strategies, catalog, total_samples, dates):
    pools = sorted(pool_strategies.keys())
    lines = []
    lines.append("# z2k strategy statistics — anonymized aggregate")
    lines.append(f"# device-day samples in window: {total_samples} (NOT unique devices — by design)")
    if dates:
        lines.append(f"# date span: {dates[0]} .. {dates[-1]}")
    lines.append("# metric: stable dwell (proxy for 'works'); NOT a success signal.")
    lines.append("# columns: strategy  samples  slots  dwell_p50(s)  dwell_p75(s)  score")
    lines.append("#   samples = uploads that saw this strategy (one vote per upload)")
    lines.append("#   slots   = individual (host) rows behind those uploads")
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
                raw_cat = json.load(f)
            # Normalize to {str pool: [int strategy, ...]}, dropping anything
            # malformed, so a hand-edited catalog can't crash render() on a
            # non-iterable value.
            if isinstance(raw_cat, dict):
                for pool, slots in raw_cat.items():
                    if isinstance(pool, str) and isinstance(slots, list):
                        catalog[pool] = [s for s in slots if isinstance(s, int) and not isinstance(s, bool)]
        except (OSError, ValueError):
            catalog = {}

    dates = scan_dates(args.raw)
    keep = set(dates[-args.window_days:]) if (args.window_days and dates) else None
    out, pool_samples, pool_strategies, total = aggregate(iter_samples(args.raw, keep))
    txt, summary = render(out, pool_samples, pool_strategies, catalog, total, dates)

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
