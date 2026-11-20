# Tasks

- [x] T1 Locate original writer and all lifecycle entrypoints.
- [x] T2 Copy probe, check shell syntax and clipboard readback (R6).
- [x] T3 Observe failing retirement tests (R1-R3).
- [x] T4 Implement retirement and callers (R1-R4).
- [ ] T5 Targeted tests passed. Initial full run: 5599 pass, 1 fail, 1 macOS skip.
  The failure was the production-function name audit: generic `fail()` collided
  with a test helper. Renamed it to `redirector_cleanup_fail`; targeted audit
  and retirement tests now pass. Fresh release suite and rehearsal pending.
- [ ] T6 Release, publish and public verification (R5).
