# Tasks: prevent duplicate z2k iptables rules

**Input**: `specs/iptables-duplicates/spec.md` and `plan.md`
**Tests**: Explicitly required; every behavioral change follows observed RED then GREEN.

## Phase 1 — Foundation

- [x] T001 Read handoff, repository guidance, official Spec Kit templates, release workflow, helper call paths, installer, and existing recovery tests.
- [x] T002 Create isolated worktrees from z2k `589db328df4a01d365fbbeda82a32db3690d817c` and fork `ac943df3d7c8dab1901cd76bb480db0be7d44914`; verify clean state and targeted baseline.

## Phase 2 — US1/US2/US4: safe rule transactions

- [x] T003 [US1][US2][US4] Write deterministic stateful IPv4/IPv6 transaction tests and capture RED for contention, concurrency, errors, deletion, unrelated rules, quoting, and lock ownership.
- [x] T004 [US1][US2][US4] Implement `-w`, non-mutating error handling, bounded transaction serialization, and exact-duplicate draining in fork `common/ipt.sh`; run GREEN, syntax, and shellcheck; commit e8257f3.

## Phase 3 — US3: delivery

- [x] T005 [US3] Add failing z2k shipped-file and delivery-map/fresh-install tests.
- [x] T006 [US3] Ship byte-identical `common/ipt.sh`, add signed-updater mapping and critical fresh-install deployment, generate candidate maps in a temporary clone without release metadata changes, record Russian candidate changelog; run GREEN.

## Phase 4 — Verification and review gate

- [ ] T007 Run focused and full suites, syntax/lint, applicable mutation tests, and local delivery rehearsal; preserve exact logs.
- [ ] T008 Obtain independent whole-change review; fix any Critical/Important findings with TDD and rerun the suite.
- [ ] T009 Save `IMPLEMENTATION-REPORT.md` with findings, commits, evidence, release mapping, and limitations. Do not push/tag/publish; await Codex follow-up.

## Dependencies

T003 -> T004 -> T005 -> T006 -> T007 -> T008 -> T009. The two repositories have separate commits but one byte-identical runtime file. No publication task belongs to this phase.
