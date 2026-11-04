# Feature specification: reliable RuTracker proxy retries
Created: 2026-11-04. Branch: fix/rutracker-retries. Baseline: p-87.13.
User requests implementation through superpowers after two deterministic failures were reproduced. Existing preference: implement without asking users to run tests. This work prepares a fix, not a new publication or production deployment.

## User scenarios and acceptance
R1 (P1): A request encountering a failing proxy tries distinct IPs, even when other requests advance the shared round-robin cursor or health checks reorder the pool. Each IP is attempted at most once per request, with existing max-tries=4 preserved.
R2 (P1): A proxy successfully reached but unable to serve a particular TLS target is not removed from the global live pool based on that request. Repeated hidden/unsupported-host failures cannot starve ordinary RuTracker requests. Target-independent transport failures retain existing at-most-one demotion per request; periodic end-to-end health checks still remove/re-admit unhealthy nodes.
R3 (P1): The upstream retry operation respects one absolute pick-wait deadline (default 15s), including dial, proxy TLS, CONNECT headers, ClientHello write and server-flight read. Existing per-stage limits are capped by remaining time; deadlines are cleared only when handing back a verified tunnel. Direct fallback retains its existing independent budget and allowlist.
R4 (P2): Exhausted distinct candidates fail promptly. A genuinely empty initial pool may wait within the same deadline for discovery. Failure closes connections; successful TLS flight bytes remain buffered for the client. Existing TLS 1.2 resumed and TLS 1.3 tests remain green.
R5: Preserve exact routing, DNS pins, allowed direct fallback domains, client limits and persistent identity/configuration. Do not claim this implements ECH routing: a hidden hostname still cannot be recovered from the shared sentinel.
R6: Regression tests fail on original code, pass on implementation; module race tests, isolated real TCP/TLS checks, router binary rebuild/reproducibility checks, full shell suite and independent code review supply evidence. No user-assisted testing, release or service restart.

## Approaches and decision
Selected by agent within user's implementation mandate: per-request exclusion set plus evidence-based global health changes and propagated deadlines. Small change to existing Go relay, no dependencies or DNS migration.
Alternative: leave counters and only increase max-tries/timeouts. Rejected: still retries the same IP and still drains the pool on unrelated target failures.
Alternative: per-domain sentinel addresses/ECH routing redesign. Deferred as separate functionality; does not itself fix shared retry selection or health inference.

## Success criteria and limits
Reproductions demonstrate both bugs and their fixes, including deterministic interleavings and concurrent requests. Bounded network tests exercise real deadlines, not only mocks. This establishes code correctness for these mechanisms, not proof that every reported intermittent failure has the same root cause or that external proxies never fail.
