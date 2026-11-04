# Prevent Duplicate z2k iptables Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop z2k's IPv4/IPv6 helpers from turning lock contention or concurrent checks into duplicate rules, and make the shell fix deliverable without binary or service changes.

**Architecture:** Keep the existing public helper signatures in the fork's `common/ipt.sh`; add `-w`, explicit status handling, and a separate bounded kernel `flock` transaction lock (amended 2026-11-05, see below). Ship the identical file from z2k over the existing signed patch mechanism and deploy it after fork extraction on fresh installs. Drain duplicates only through explicit deletion.

**Tech Stack:** POSIX shell/BusyBox ash, deterministic shell mocks, Spec Kit Markdown, existing z2k release-map/update rehearsal tooling.

**Spec:** `specs/iptables-duplicates/spec.md`

## Global Constraints

- No push, tag, publication, live network/service/firewall mutation, or unrelated feature changes in phase one.
- Preserve `FW_EXTRA_PRE`/`FW_EXTRA_POST`, `"$@"`, `-I` versus `-A`, both families, and add-only recovery.
- Never broadly flush rules, delete unrelated rules, or restart a service merely to clean duplicates.
- No new dependency or engine binary rebuild; use existing shell/update tooling. `flock` is an existing installer dependency (lib/install.sh, since p-87.13); it is used when present and never installed by the helpers.
- Official Spec Kit templates were read from installed `specify_cli/core_pack/templates`; existing specs are preserved and the project is not reinitialized.

## Review Focus

- A crashed process between lock creation and owner-PID recording leaves an ownerless lock: expected behavior is fail-closed timeout, never unsafe time-based stealing; test this in Task 1.
- PID reuse can make a dead owner look live: expected behavior is no reclamation, sacrificing liveness rather than breaking mutual exclusion; test live-owner preservation in Task 1.
- Check status 1 is ambiguous on some non-target implementations: expected target behavior is normal absence, while statuses 2/4 are non-mutating errors; test 2 and 4 in Task 1.
- A fresh-install staging copy can be absent during updater-driven reinstall: expected behavior is `deploy_critical_file` fallback and failure propagation; test mapping and installer usage in Task 2.
- Mocks do not measure router latency or prove every external firewall writer is serialized: final review must keep release wording and claims within that limit.

---

### Task 1: Transaction-safe fork helpers

**Files:**
- Modify: `common/ipt.sh` in `/Library/Zapret2/.worktrees/iptables-kimi-20261104-fork`
- Create: `tests/test_ipt_transactions.sh` in the fork worktree

**Interfaces:**
- Consumes: existing `ipt`, `ipta`, `ipt_del`, `ipt6`, `ipt6a`, `ipt6_del` signatures and `on_off_function` wrappers.
- Produces: the same six signatures; `Z2K_IPT_LOCK` path override and `Z2K_IPT_LOCK_TIMEOUT` bounded-wait override for isolation/testing; status 0 present and 1 absent, other statuses non-mutating errors.

- [ ] **Step 1: Write the failing stateful regression suite.** Test all six commands for `-w`; contention on existing rules; ordinary missing/existing; statuses 2/4; concurrent `ipt` and `ipta`; exact duplicate draining; unrelated-rule preservation; extra-argument and quoted-rule-argument preservation; live/ownerless lock non-stealing.
- [ ] **Step 2: Run RED.** Run `sh tests/test_ipt_transactions.sh`; Expected: deterministic contention and concurrency failures against original functions, with no live iptables invocation.
- [ ] **Step 3: Implement the minimal helpers.** Add a distinct atomic mkdir transaction lock, bounded wait, dead-numeric-owner reclamation only, explicit check-status cases, `-w` on every mutation, and deletion draining exact copies.
- [ ] **Step 4: Run GREEN and lint.** Run `sh tests/test_ipt_transactions.sh && sh -n common/ipt.sh && shellcheck common/ipt.sh tests/test_ipt_transactions.sh`; Expected: all assertions pass and tools exit 0.
- [ ] **Step 5: Commit fork task.** Commit only `common/ipt.sh` and `tests/test_ipt_transactions.sh` with message `fix: serialize iptables rule transactions`.

### Task 2: Signed updater and fresh-install delivery

**Files:**
- Create: `common/ipt.sh` in `/Library/Zapret2/.worktrees/iptables-kimi-20261104-z2k`, byte-identical to Task 1's file.
- Create: `tests/test_ipt_transactions.sh` in z2k, running the same behavior suite against the shipped copy.
- Modify: `lib/release_map.sh`, `lib/install.sh`, and `tests/test_manifest_install_map.sh`; generate the candidate manifest only in a temporary clone.
- Include: `specs/iptables-duplicates/{spec,plan,tasks}.md` and Russian changelog scope in the z2k commit.

**Interfaces:**
- Consumes: Task 1's exact six helper signatures and byte-identical `common/ipt.sh`.
- Produces: `z2k_install_paths common/ipt.sh` -> `/opt/zapret2/common/ipt.sh`; no release step or service restart; fresh-install `deploy_critical_file common/ipt.sh ... 644` after fork extraction.

- [ ] **Step 1: Write failing delivery and shipped-behavior tests.** Assert the shipped copy passes the Task 1 behaviors, release map has the exact runtime target and no automatic restart, fresh install uses critical deployment, and both worktree files are byte-identical.
- [ ] **Step 2: Run RED.** Run the focused z2k tests before adding/mapping the shipped file; Expected: missing mapping/file/install deployment failures.
- [ ] **Step 3: Implement delivery.** Copy the tested fork shell file, add its map/install path, generate and consume a temporary candidate `UPDATES.json`, and add a short Russian candidate changelog in the spec/release-scope notes. Do not alter the currently signed manifest or signature before a release is authorized.
- [ ] **Step 4: Run GREEN.** Run focused behavior/delivery tests, `test_nfqueue_selfheal.sh`, `test_warp_ndm_hook.sh`, manifest/release-map tests, shell syntax and shellcheck; Expected: all pass, no unrelated manifest changes.
- [ ] **Step 5: Commit z2k task.** Commit the reviewable implementation/spec/test/map changes with message `fix: prevent duplicate iptables rules`.

### Task 3: Whole-change verification and review gate

**Files:**
- Create requested report: `/Library/Zapret2/artifacts/iptables-kimi-20261104/IMPLEMENTATION-REPORT.md`.
- Store logs in `/Library/Zapret2/artifacts/iptables-kimi-20261104/`.

**Interfaces:**
- Consumes: committed Tasks 1 and 2 and their exact bases.
- Produces: independent-review package, complete evidence, remaining risks, and concrete later release scope; no release commit/tag/push.

- [ ] **Step 1: Run final verification.** Run both transaction suites, relevant self-heal/hook/delivery tests, shellcheck, `sh tests/run_all.sh`, and mutation testing if the existing harness covers the affected shell file. Save full logs and inspect summaries.
- [ ] **Step 2: Exercise delivery end-to-end locally.** Use the existing rehearsal/map mechanisms with the candidate file; Expected: an old tree gains the exact new `common/ipt.sh`, with no service restart or binary churn.
- [ ] **Step 3: Independent whole-change review.** Give a fresh reviewer both diffs, spec, plan, tests, RED/GREEN logs, and review focus. Fix Critical/Important findings once via RED/GREEN; defer Minor findings explicitly.
- [ ] **Step 4: Save report and stop before publication.** Record exact worktrees/commits, commands/results/log paths, release files and likely `p-87.16` subject to revalidation, limitations, and review verdict. Expected: ready for independent review, not released.

---

## Amendment 2026-11-05 — kernel flock instead of mkdir/PID lock

Independent review rejected Task 1's lock (non-exclusive dead-owner reclamation; `set -e` leak). Superseding design, implemented in fork commit `c87d46c` and z2k follow-up commit:

- `_ipt_locked` opens `/tmp/zapret2-ipt.flock` on descriptor 8 with a compound redirection `{ …; } 8>>file || :` scoped to one transaction. The caller's descriptor 8 is saved/restored by the shell; the kernel releases the lock on close or process death. The file is never unlinked.
- `_ipt_flock_wait`: `flock -n` fast path; then `flock -w $Z2K_IPT_LOCK_TIMEOUT` if `flock --help` advertises `--timeout` (util-linux, Entware), else a one-second `flock -n` poll (BusyBox). Timeout → status 4, no iptables call.
- `_ipt_add`/`_ipt_del` capture every status in `if …; then …; else rc=$?; fi`; only status 1 means absent; deletion drains exact copies and returns 1 only if none existed.
- No `flock` or unopenable lock path → same transaction without serialisation (still `-w`, strict statuses); no package provisioning in the helpers.
- Delivery test compares the override to the fork outside the helper block, and fully once the fork contains `_ipt_locked`. CI checks out fork `z2k-master`, so this stays green before and after the fork branch is merged.
- Portability lint now scans `common/`; `common/ipt.sh` and its suite are exempt for `flock` only.

Review focus replacing the Task 1 items above: holder death and lock release, two contenders after a dead holder, `set -e`, caller descriptors, the no-`flock` fleet share, BusyBox polling latency, and the lock file in world-writable `/tmp` (single-user router; same class as the existing `/tmp/zapret2-restart-fw.lock`).
