# Verification of RuTracker retry reliability

Baseline: p-87.13 / fba3c552. Implementation branch: fix/rutracker-retries.
Toolchain: Go 1.25.13. Local macOS verification; no production rollout.

## Requirements → executable evidence

| Requirement | Evidence |
| --- | --- |
| R1: distinct attempts despite concurrent cursor movement/reordering | retry_isolation_test.go: deterministic cursor interleaving, pool reorder, 32 concurrent requests; retry_boundaries_test.go: cap 3 with 5 available nodes, exhaustion with 2 nodes |
| R2: target failures preserve shared health | repeated unsupported target followed by successful ordinary target; existing transport demotion cap; retry_cleanup_test.go proves a clipped request budget cannot demote a healthy node |
| R3: absolute upstream deadline | retry_deadline_test.go: blocked hello write, incomplete CONNECT, 80ms overall budget; retry_cleanup_test.go: real TLS close_notify stall; zero-budget test starts no attempts |
| R4: cleanup, discovery, buffered handoff | initially empty pool populated under mutex; exhausted candidates return promptly; real net.Pipe flight preserved and both read/write work after former deadline; existing resumed/full TLS flight tests |
| R5: preserve routing/fallback | scope of production source changes confined to rt-proxy/main.go retry selection and tunnel setup; existing direct allowlist, sentinel/loop, splice and TLS regression tests retained |
| R6: review/build/checks | independent whole-branch review; both important findings fixed in one pass, with failing reproductions before fixes; race suite and vet pass; five architectures plus mipsle alias rebuilt and 17 binary drift checks pass |

## Independent review resolution

1. Accepted P1: tls.Conn.Close can spend five seconds sending close_notify after the request deadline. Reproduction: 40ms budget took 5.04s. Failed attempts now close the underlying transport; successful handed-off tunnels retain normal lifecycle. Regression now completes in 0.04s.
2. Accepted P2: a healthy proxy was demoted when only 15ms remained for its 40ms TLS handshake. A timeout caused by a shortened overall budget is now neutral. Definitive transport errors and full per-node timeouts remain eligible for the existing bounded demotion policy.
3. Accepted coverage feedback: distinct-candidate cap, zero budget, initial empty-pool recovery, and deadline-free buffered handoff tests added.

No important review findings deferred. Reviewer did not assess live external availability or generated binaries; binaries are covered by rebuild/drift verification. No second review loop was used after the targeted fix pass.

## Evidence artifacts

Local directory: /Library/Zapret2/artifacts/rutracker-retries-implementation-20261104/
- rt-retries-red.log and rt-task1-green.log: original retry/health reproductions.
- rt-deadline-red.log: original blocked write and partial CONNECT failures.
- rt-review-red.log and review-green.log: review reproductions before/after fixes.
- rt-retries-reviewed-module.log: final module race suite, PASS (16.402s).
- vet.log: final go vet, exit 0.
- rt-retries-reviewed-build.log and rt-retries-reviewed-binaries.log: final multi-architecture build and drift checks, 17 passed / 0 failed / 0 skipped.
- full-suite.log: final repository shell suite: 255 suites, 4985 passed, 0 failed, 1 skipped (BSD sed lacks GNU-style `-i`; test_auto_update_toggle). Exit 0.

The shell suite uses a temporary locally generated and signed integrity manifest for the rebuilt artifacts, then restores UPDATES.json, its signature and web index. It does not publish or increment a release.

## Limits and remaining work

This verifies the reproduced retry/health/deadline defects, not every possible reason for intermittent RuTracker access. ECH hidden-host routing through the shared sentinel remains outside scope, as does the availability of third-party proxy nodes. Publication and live rollout require a separate release task; shipped release metadata intentionally stays at the published baseline.
