# Feature Specification: prevent duplicate z2k iptables rules

**Feature Branch**: `fix/iptables-duplicates-20261104`
**Created**: 2026-11-04
**Status**: Phase one — implementation and independent review, not publication
**Input**: `/Library/Zapret2/artifacts/iptables-kimi-20261104/HANDOFF.md`

## User Scenarios & Testing

### User Story 1 — Lock contention does not create duplicates (P1)

A router already has the requested rule when another firewall writer holds the xtables lock. The z2k check waits and observes the real state instead of interpreting contention as absence.

**Independent Test**: Stateful mocked IPv4/IPv6 commands return lock error 4 to a non-waiting check and success to `-w`; the original code inserts a second copy and the fixed code does not.

### User Story 2 — Concurrent recovery remains idempotent (P1)

Direct service commands, the NDM hook, and NFQUEUE self-healing can overlap. Every z2k-owned check-plus-insert/delete transaction is serialized without nesting the existing recovery lock.

**Independent Test**: Two shell processes concurrently apply the same rule against a deterministic stateful mock. The original code leaves two copies; the fixed code leaves one. After a holder dies mid-transaction, two simultaneous contenders never run a transaction at the same time.

### User Story 3 — Existing installations and fresh installs receive the same shell fix (P1)

The normal signed z2k patch updater replaces `common/ipt.sh`; fresh installation deploys that same file after unpacking the fork. No engine binary rebuild or service restart is needed for delivery.

**Independent Test**: Release-map and installer tests show one source file mapped to `/opt/zapret2/common/ipt.sh`, with matching bytes in the z2k and fork worktrees.

### User Story 4 — Explicit removal drains only exact owned duplicates (P2)

Already accumulated copies are not cleaned by an update or add-only recovery. When the existing deletion operation is explicitly requested, it removes every exact copy of that owned rule and leaves unrelated rules untouched.

**Independent Test**: A stateful table starts with three matching copies and one unrelated rule; deletion leaves zero matching copies and the unrelated rule in place. Add-only operations do not delete or reorder existing rules.

## Edge Cases

- Ordinary missing rule: insert/append exactly once; ordinary existing rule: no mutation.
- Check errors other than the normal absence status 1: return the error and never insert/delete.
- Mutation failure: return its status and release the transaction lock.
- Busy lock: wait within a bounded timeout (util-linux `flock -w`; BusyBox `flock` without `-w` is polled once a second), then fail closed with status 4 and no mutation.
- Holder death (SIGTERM, SIGKILL, crash): the kernel drops the flock when the last descriptor closes. There is no owner record, no reclamation and no age-based stealing. An in-flight iptables child keeps the lock until it exits.
- `flock` absent (installs from before the p-87.13 installer dependency) or lock file not openable: run the transaction unserialised but still with `-w` and strict statuses; never provision packages from the helpers.
- `set -e` callers: every status is captured in a conditional, so absent/existing rules never abort the caller and errors never leave a lock behind.
- The caller's own descriptor 8 is saved and restored around the transaction.
- `FW_EXTRA_PRE`/`FW_EXTRA_POST`: preserve their existing word-splitting positions and preserve `"$@"` quoting.

## Requirements

- **FR-001**: All IPv4 and IPv6 checks, inserts, appends, and deletes in `common/ipt.sh` MUST use `-w`.
- **FR-002**: Only check status 0 means present and status 1 means absent; other statuses MUST NOT trigger mutation.
- **FR-003**: Supported z2k processes MUST serialize each check-plus-mutation transaction using a kernel `flock` on `/tmp/zapret2-ipt.flock`, distinct from the xtables lock and from `/tmp/zapret2-restart-fw.lock`. The lock MUST be released by the kernel on descriptor close or process death; no PID/mkdir ownership protocol.
- **FR-004**: Lock acquisition MUST fail closed after a bounded wait (`Z2K_IPT_LOCK_TIMEOUT`, default 30 s) and MUST NOT remove or steal any lock.
- **FR-004a**: Without `flock`, helpers MUST still apply rules (unserialised, with `-w` and strict statuses) and MUST NOT install packages.
- **FR-004b**: Helpers MUST be safe under `set -e` and MUST preserve the caller's file descriptors.
- **FR-004c**: Patch updates MUST provision `flock` on installs lacking it after the update is committed, independent of optional features, with no restart and no package work during rollback; failure MUST be logged as degraded protection and visible in diagnostics.
- **FR-005**: Existing add-only recovery MUST NOT become restart/teardown and MUST NOT clean duplicates implicitly.
- **FR-006**: Explicit deletion MUST drain exact duplicate copies while preserving unrelated rules and the insertion/append semantics of additions.
- **FR-007**: z2k MUST ship `common/ipt.sh` through the signed patch map and deploy it on fresh install; the fork MUST carry the same fix for future engine releases.
- **FR-008**: Tests MUST provide observed RED then GREEN evidence for contention, missing/existing rules, concurrency, errors, duplicate deletion, unrelated rules, argument passing, and both families.
- **FR-009**: Phase one MUST NOT push, tag, publish, restart services, or mutate a live firewall.
- **FR-010**: Release notes MUST be short, honest Russian text and MUST NOT claim that all firewall races or existing live duplicates are universally fixed.

## Success Criteria

- **SC-001**: Deterministic original-code reproductions fail for lock contention and concurrent apply; the fixed implementations pass the same tests.
- **SC-002**: Targeted suites, shell syntax/lint, relevant delivery tests, and the full z2k shell suite pass on the final worktree, with all skips/failures reported.
- **SC-003**: `common/ipt.sh` is byte-identical in both worktrees and appears in the generated signed-updater `install_map` and `files_sha256` scope prepared for the later release phase.
- **SC-004**: A fresh independent reviewer receives exact commits, diffs, logs, limitations, and release scope before any publication.

## Assumptions

- Target iptables supports `-w`, as already required by shipped z2k recovery and NDM code; no non-waiting fallback is safe for this bug.
- `flock` is the Entware util-linux package listed in `lib/install.sh` `step_install_dependencies` since e55116a3 (p-87.13). Older patch installs get it from the post-commit worker in `au_run_steps` (`au_provision_flock`), which the published old updater runs from the delivered `lib/auto_update.sh` after the success marker, whatever the redirector settings. If `opkg install flock` fails, the update stays committed, the log says protection is degraded, and `z2k-diag` shows «Очередь правил: flock НЕТ»; the next update tries again.
- Check status 1 is the command's normal rule-absence result. Other statuses are errors; no localized stderr parsing is used.
- Exact duplicates are drained only when the existing explicit deletion path runs. Phase one does not perform active cleanup on working installations.
- The owner explicitly opted out of design questions and requested autonomous inline execution followed by independent review.

## Candidate release wording (not published)

«Исправлено повторное добавление правил межсетевого экрана при временной занятости системной блокировки и одновременных проверках. Уже накопленные одинаковые правила удаляются при штатном снятии правил; обновление само службу не перезапускает.»

The likely later patch is `p-87.16`, subject to checking the latest published release again after review.

## Amendment 2026-11-05 — independent review findings

The first implementation (fork e8257f3) used an mkdir lock with dead-PID reclamation. The independent review reproduced two blocking defects, and the final suite confirms both against e8257f3 (`claude-red-kimi-e8257f3.log`):

1. Two contenders that both observe the same dead owner both reclaim, and the second removes the first one's fresh lock: `two contenders after a dead holder never overlap (want=0 got=1)`.
2. A bare `iptables -C` followed by `rc=$?` aborts a `set -e` caller before insert and unlock: `set -e caller survives absent-then-existing rules (want=reached got=)`.

Resolution: the kernel `flock` design in FR-003/FR-004/FR-004a/FR-004b. RED against the original helpers: `claude-red-original.log` (36 failures); GREEN: `claude-green-*.log`.

### Amendment 2026-11-05 (2) — flock delivery to old installs

The independent review found that the redirector refresher exits before its own flock provisioning when `Z2K_REDIRECTOR_DNS=0`, ndmc is absent, etc., so it cannot be the delivery path. FR-004c adds a dedicated post-commit provisioning step in the existing `au_run_steps` worker; the refresher now runs after it in the same worker, so two `opkg` never contend. Evidence: `tests/test_flock_update_provisioning.sh` with published p-87.12 and p-87.15 updaters, redirector off and flock hidden (RED `claude-red-flock-provisioning.log`, GREEN `claude-green-flock-provisioning.log`).
