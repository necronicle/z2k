# RuTracker retry reliability implementation plan
> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Work inline, final independent review.
**Goal:** remove repeated-node retries and target-driven pool starvation, with bounded upstream I/O.
**Architecture:** retain shared health pool; atomically choose an untried candidate using request-owned set. Demote only target-independent connection failures. Propagate one absolute deadline through real I/O helpers.
**Tech stack:** Go 1.25.13, existing rt-proxy module, six distribution names across five architectures.
**Spec:** specs/rutracker-retries/spec.md

## Global constraints
R1-R6 from spec apply. No production writes or release. Keep existing routing and fallback budgets. No new dependencies.
## Review focus
- Concurrent cursor advancement and pool reorder must not repeat a candidate (T1).
- Failed target after successful CONNECT must not poison other targets (T1).
- Blackholed ClientHello writes / partial CONNECT headers must end within upstream budget (T2).
- Initial empty pool versus exhausted candidates; zero remaining budget, connection cleanup (T1/T2).
- Resumed TLS short flights and buffered data must still pass (T2 existing regressions).

## Task 1: distinct retries and health isolation
Files: rt-proxy/main.go, rt-proxy/dialupstream_test.go, new rt-proxy/retry_isolation_test.go.
Interfaces: pool.pickUntried(tried map[string]bool) string; pick() compatibility wrapper. Existing dialUpstream public signature retained.
- [x] Import reproductions; add reorder, exhaustion and target-isolation baseline tests; run and observe intended failures.
- [x] Implement atomic selection with local tried set; remove target-flight demotion; preserve bounded transport demotion. Replace old tests asserting target-driven demotion with new health-isolation contract.
- [x] Run module tests with race detector; commit.

## Task 2: bounded network operations and verification
Files: rt-proxy/main.go, rt-proxy/dialupstream_test.go, new rt-proxy/retry_deadline_test.go; shipped rt-proxy binaries.
Interfaces: openTunnelUntil(ip,target string,deadline time.Time); verifyFirstByteUntil(ip string,up net.Conn,br *bufio.Reader,hello []byte,deadline time.Time). Existing wrappers preserve direct call sites and independent fallback budget. Adapt I/O seams/test helper to deadlines.
- [x] Real socket tests: stalled CONNECT response, stalled hello write, no server flight; RED before implementation. Expired deadline starts no I/O.
- [x] Pass absolute deadlines; cap existing stage budgets; clear deadline on successful handoff. Run all module race tests and vet.
- [x] Build all five architectures and mipsle alias per build-matrix.tsv. Verify reproducibility and full shell suite; do not regenerate/publish a new release.
- [x] Independent whole-branch review; fix important findings with RED→GREEN tests; commit final code and evidence.
