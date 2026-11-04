# Tasks
- [x] T1 server tests and resolver change (R2,R5): race tests; isolated VPS preflight returns 18 redirector IPv4s, Meta unchanged, other googlevideo rejected.
- [x] T2 client tests, refresher and ranges (R2-R4): malformed/fetch/rollback/lock/opt-out; BusyBox/Entware fixture on router applies 24 records, preserves unrelated record, repeat is idempotent. Fixture only, real router DNS untouched.
- [x] T3 lifecycle wiring and delivery checks (R1): actual published p-87.12 updater delivers worker and launches success-marker wait; failed updates do not start DNS changes.
- [x] T4 code verification: final full suite passes (suite-4), race tests, shellcheck, review; new deliverables present in install_map and signed hash map. Release metadata still verified again at cut.
- [ ] T5 controlled VPS rollout and verification: preflight done, production unchanged; baseline/backup saved; nginx drift is two blank lines only.
- [x] Donor Marshmalick added to README/menu/panel with approved text (R6). Owner approved joint release p-87.13.
- [ ] T6 publish p-87.13 and verify public signed manifest, assets and CI.
