# Implementation Plan
Spec Kit official spec/plan/tasks templates read from installed core_pack. Existing project not reinitialized.
Implement inline in isolated worktree fix/redirector-dns.
1. Add tests for exact server hostname allowlist and bounded candidate union; implement host-specific32 cap and no early stop for redirector.
2. Add separate POSIX shell refresher using existing /resolve HMAC and verified HTTPS. Ship official Google IPv4 ranges. Test fetch failures, validation, no probe, retention, rollback, opt-out, repeated refresh.
3. Wire installation, nightly list refresh and successful auto-update background kickoff; test shipping maps and hooks.
4. Run targeted tests, full suite and independent review. Commit feature. Prepare controlled relay deployment with saved sessions/config/binary; owner permits reconnect.
5. Owner approved Marshmalick text and resumed release: update all three donor surfaces; publish p-87.13 after verification and live endpoint rollout. Record deployment evidence.
