# z2k-classify

DPI block-type classifier for a single domain, with per-type strategy
recommendation. Purpose: shrink support-chat turnaround from "tell me
your diagnosis + wait for Mark to think" (~30 min) to "run one command,
get a pinned strategy" (~5 min).

## What it does

1. **Resolves** the target domain to IPv4.
2. **Probes** 8 symptoms via a mix of regular sockets and raw AF_PACKET
   capture. Each probe is time-bounded (2-3 s). Total probe time ~1 min.
3. **Classifies** symptoms into one of:
   - `none` — no block detected, domain is reachable normally
   - `transit_drop` — packets don't come back (upstream routing black hole)
   - `rkn_rst` — RKN-style DPI injects RST after ClientHello
   - `tspu_16kb` — flow hangs at ~16 KB boundary (whitelist-SNI throttle)
   - `aws_no_ts` — server doesn't negotiate TCP timestamps (AWS frontend)
   - `mobile_icmp` — ICMP/early-packet quench pattern (Beeline/T2/MF)
   - `size_dpi` — response truncated at specific non-16 KB offset
   - `hybrid` — multiple symptoms at once (rare)
   - `unknown` — failed all classification rules
4. **Picks a template** per-type and either suggests it (`--dry-run`) or
   probes candidate strategies against the target and pins the winner
   in `state.tsv` for the autocircular rotator to honor (`--apply`).

## Usage

```
z2k-classify <domain> [--apply] [--json] [--timeout=SECONDS]

Options:
  --apply       Pin winning strategy in state.tsv (autocircular pick)
  --json        Emit machine-readable result for support-bot piping
  --timeout=N   Total budget in seconds (default 300 = 5 min)
  --verbose     Show per-probe packet trace
```

Examples:
```
# Classify only, print to stdout
z2k-classify habr.com

# Classify, probe templates, save winner
z2k-classify linkedin.com --apply

# Support-bot integration
z2k-classify --json chatgpt.com
```

## Architecture

Single statically-linked C binary, MIPS/ARM/x86 cross-compile via
zapret2-z2k-fork's existing build chain.

```
src/
  main.c        — CLI parsing, phase orchestration, JSON output
  probe.c       — 8-symptom test sequence (socket + AF_PACKET capture)
  classify.c    — symptom → block type decision tree
  templates.c   — per-type strategy template library (Phase 2)
  inject.c      — nfqueue-based strategy injection for candidate probe (Phase 2)
  measure.c     — per-strategy outcome measurement (Phase 2)
  output.c      — JSON / state.tsv serializer
```

## Non-goals

- **Not a replacement** for autocircular — autocircular still runs the
  primary rotator in production. This tool pins per-domain after fault.
- **Not a JA3 impersonator** — we don't ship curl-impersonate. If the
  domain requires real-browser-JA3 to pass DPI, the tool flags it as
  `ja3_filter` and suggests manual browser testing.
- **Not a routing fix** — if the packets don't come back at all
  (`transit_drop`), no DPI strategy helps. The tool honestly says
  "not our scope, try different network path".

## Status

- Phase 1 (probe + classify, standalone binary): in progress
- Phase 2 (strategy template probe): pending
- Phase 3 (z2k integration + --apply): pending
- Phase 4 (nightly drift + TG bot integration): pending
