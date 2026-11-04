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

**Independent Test**: Two shell processes concurrently apply the same rule against a deterministic stateful mock. The original code leaves two copies; the fixed code leaves one and does not steal a lock from a live owner.

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
- Busy or stale lock: wait within a bounded timeout; never time-steal a lock. A lock whose numeric owner PID is confirmed dead may be reclaimed; an empty or live-owned lock may not.
- `FW_EXTRA_PRE`/`FW_EXTRA_POST`: preserve their existing word-splitting positions and preserve `"$@"` quoting.

## Requirements

- **FR-001**: All IPv4 and IPv6 checks, inserts, appends, and deletes in `common/ipt.sh` MUST use `-w`.
- **FR-002**: Only check status 0 means present and status 1 means absent; other statuses MUST NOT trigger mutation.
- **FR-003**: Supported z2k processes MUST serialize each check-plus-mutation transaction using a lock distinct from `/tmp/zapret2-restart-fw.lock`.
- **FR-004**: Lock acquisition MUST fail closed after a bounded wait and MUST NOT remove a live-owned or ownerless lock based on age.
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
- Check status 1 is the command's normal rule-absence result. Other statuses are errors; no localized stderr parsing is used.
- Exact duplicates are drained only when the existing explicit deletion path runs. Phase one does not perform active cleanup on working installations.
- The owner explicitly opted out of design questions and requested autonomous inline execution followed by independent review.

## Candidate release wording (not published)

«Исправлено повторное добавление правил межсетевого экрана при временной занятости системной блокировки и одновременных проверках. Уже накопленные одинаковые правила удаляются при штатном снятии правил; обновление само службу не перезапускает.»

The likely later patch is `p-87.16`, subject to checking the latest published release again after review.
