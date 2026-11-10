# Dedicated Telegram transport — production replacement

Owner requirement, clarified 2026-11-10: reproduce the successful phone experiment
as the normal transport for all updated clients, without an enable switch. Support
households with multiple phones/PCs; choose architecture from evidence. Owner also
authorized VPS experimental reconnects. This supersedes the opt-in design in
cfcfb383; publication is now explicitly authorized as a separate Telegram-only patch.

## Requirements
- R1: Every accepted application TCP flow uses its own authenticated relay
  transport by default. No overflow into the old shared data WebSocket.
- R2: Preserve enrollment, installation identity, original destination, custom URL
  and validated assigned-route selection. One owner writes identity/route state.
- R3: Bound sessions using the authenticated server quota and local ceiling.
  No permanent control session consuming a custom server's only slot.
- R4: Distribute pending admissions between source devices; one device must not
  consume the whole normal shared-server allowance. Keep existing flows intact.
- R5: Failure/close of one data session must not close neighboring sessions;
  no payload replay. Background discovery must not block new healthy data flows.
- R6: Verify household queuing, authentication, quota negotiation, reconnect and
  resource capacity. Record limitations rather than equating a phone test with
  guaranteed fleet-wide speed. Commit for inclusion in the upcoming update.

## Scope
Router Go client, compatible relay quota extension, main-VPS capacity config,
tests and operational evidence. No Telegram content inspection, calls fix,
unsupported media classification or unrelated component changes. Existing configs, keys
and custom endpoints stay intact. A server limiting an installation to one session
can support only one isolated flow concurrently; its operator must increase that
quota to serve multiple simultaneous independent flows. This physical constraint
cannot be hidden by returning to shared transport.

## R7: native relay connectivity
The owned relay 85.192.60.175 must bypass nfqws desynchronization on every firewall seed. Preserve existing sessions and user exclusions. Do not exclude shared CDN ranges. Validate new TLS connections from the affected router, not only VPS health.

## Authorized release requirements (2026-11-10)
- R8: Existing v1/v2 multiplexed clients must continue to authenticate and carry
  multiple streams; no forced client update or key rotation.
- R9: Dedicated server grants1024 sessions per installation for its two existing
  installations, total4096. New clients honor that grant without household16 cap
  on an aggregated source; main server remains64 per installation, total10000.
- R10: Publish only Telegram changes through z2k-staging, scripts/release.sh,
  signed tag and atomic push, then robot CI/publish. No new development branches.
- R11: Preserve other ongoing work; release patch delivers only Telegram client
  binaries and S98, not S99/config generators/YouTube/other binaries.
