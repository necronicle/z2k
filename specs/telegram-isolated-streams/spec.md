# Dedicated Telegram transport — production replacement

Owner requirement, clarified 2026-11-10: reproduce the successful phone experiment
as the normal transport for all updated clients, without an enable switch. Support
households with multiple phones/PCs; choose architecture from evidence. Owner also
authorized VPS experimental reconnects. This supersedes the opt-in design in
cfcfb383; no fleet publication is requested by the source-commit task.

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
unsupported media classification or release publication. Existing configs, keys
and custom endpoints stay intact. A server limiting an installation to one session
can support only one isolated flow concurrently; its operator must increase that
quota to serve multiple simultaneous independent flows. This physical constraint
cannot be hidden by returning to shared transport.
