# Verification status —2026-11-10

**PHONE ACCEPTED; FLEET RELEASE NOT PERFORMED.** The first production candidate
regressed. Restoring exact original spike restored speed. Prompt capacity rejection
helped but did not fully restore it. Removing per-second pacing and restoring the
original four simultaneous handshakes did: owner confirmed “Да, теперь как в первом”.
This sequence establishes field acceptance of the restored scheduler; it does not
promise identical throughput on every external network.

## Functional evidence
- Client final full race suite PASS41.346s; relay full race suite PASS4.674s; vet PASS.
- Signed v2 auth, independent flow echo/neighbor closure/parent cancellation and
  zero leaked budgets covered by TestIsolatedFlowsSurviveNeighborClose.
- Auth refusal closes without retry/downgrade; capacity GOODBYE11 classified
  separately in TestBusyIsNotIdentityRefusal.
- Server quota encoding tested end-to-end: capability1 retains old response;
  capability3 adds session_limit; AUTH_OK arg remains maxStreamsPerSession.
- Round-robin source-device admission, per-device cap, server clamp, quota1 probe
  reservation and discovery-network-lock independence have regression coverage.
- TestFullCapacityRejectsPromptly prevents the observed long-wait admission design.
- TestHandshakeGateAllowsBurstAndBoundsConcurrency starts actual local HTTP
  handshakes: four must start immediately, fifth waits for a released slot.
- TestTransientHandshakeFailureKeepsOtherAdmissionsReady was RED on global cooldown
  after HTTP502, GREEN after limiting that pause to actual authentication refusal.
- Shell config test covers valid ceilings, invalid input and old binary gate.

## Controlled capacity measurements on the actual main VPS
Private loopback test process, synthetic identities/DCs, no live registry writes,
0.5CPU quota, bounded memory; production relay PID1987495 remained unchanged.

| Shape | Process memory ceiling | Measured Go heap | Echo p95 | Wall time |
|---|---|---|---|---|
|2000 WS ×4 flows|768MiB|87KiB/session incl.mock client|224µs|9.84s|
|8000 WS ×1 flow|768MiB|61KiB/session incl.mock client|163µs|20.84s|
|8000 TLS ×1 flow|1GiB|86KiB/session incl.mock TLS client|1.47ms|59.23s|
|10000 TLS ×1 flow|1280MiB|88KiB/session incl.mock TLS client|700µs|75.16s|

Tests used raised ceilings only in their own process. They do NOT model Internet
loss, media throughput, noisy neighbors, peak churn or the entire nginx path.
Do not equate heap measurements with process RSS or total host memory.
Live sample after tests:~3170 sessions/~7340 streams,~2.3GiB memory available.
Live global cap6000 and per-install cap64 verified from actual executable/args.
Prepared main-VPS config10000; live cap not changed.

## Network / phone
Pinned Go1.25.13 arm64 candidate on separate router port16443: all five native DCs
returned validated MTProto resPQ nonce (0.84–1.90s). Phone rule hit27 new connections;
owner reported regression. Log reached16 concurrent phone data flows; two later
flows opened only when the app closed its earlier flows. No handshake failure was
logged. Phone feedback confirmed partial improvement from prompt rejection; the scheduler
change was additionally needed to recover the original subjective performance.

Exact original spike on15443 restored at17:30MSK; owner confirmed fast again.
Follow-up on17443 passed five-DC canary (0.61–1.35s), phone selected17:39MSK. Its
20-minute guard restores the original spike, not the stock shared tunnel.
Restored four-concurrent-handshake candidate on18443 selected17:47MSK; all5 DC
canaries passed (0.60–1.53s); owner confirmed full original speed. No mixed old
connections remained during the last check. Failed candidate processes were stopped
only after they had zero established local data connections.
Installation identity SHA256 remained dfe70a50…3e throughout; stock PID19869 unchanged.

## Deployment boundary
Release binaries rebuilt for9 architectures plus aliases, at current manifest
version p-87.25. No release or fleet publication performed. Main VPS config verification
found pre-existing nginx.conf drift; that file was not overwritten. The earlier
cfcfb383 opt-in commit is superseded and must not be presented as the final solution.

## Fleet baseline and remaining release gates
Read-only snapshot at14:59UTC:3162 live installations,3171 authenticated sessions;
3156 installations had one session,4 had two,1 had three,1 had four. These are
NOT person counts. Relay RSS~694MiB. Snapshot is private research evidence, not
committed installation data. Current API has no complete build/architecture census.
See release-checklist.md; cross-compilation is not physical MIPS/ARM router testing.

Final independent review found no production blocker. It caught standalone-test
setup reliance on a prior semaphore initializer; fixed and the three selected
regressions passed independently with race detection. Shell regressions:12 stability,
17 TLS roots,17 watchdog,11 pair gating,7 single-process,8 binary-drift checks PASS,
plus config-limit/old-binary compatibility checks. Final release artifacts include
all9 architectures and3 name aliases, built from the verified source with Go1.25.13.
