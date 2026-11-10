# Implementation plan / architecture decision

Spec Kit successor to the existing scoped spec/plan/tasks; no project re-init.

Choose independent per-flow transports, the experimentally successful architecture.
A pool saves memory but reintroduces shared TCP loss/retransmission within groups.
The fork's signed DC/media hint is not reliably present in all native transparent
Telegram connections, so content-type pooling cannot be guaranteed here.

Enrollment/route discovery has one owner and uses short-lived authenticated probes.
It closes discovery sockets and snapshots identity+route under routeMu, so slow
network discovery does not block data admission. Each data child owns its own
WS, stream credit, reader/writer and lifetime. No client payload uses the old mux
loop. Transport loss closes only its flow; Telegram reconnects itself.

Client local ceiling64; authenticated server session_limit minus one headroom,
except quota1 stays1. Old servers: conservative allowance48, still clamped by
local ceiling. At most16 concurrent flows per source IP, round-robin pending-device
admission and exactly four concurrent handshakes, as in the successful spike.
There is NO per-second pacing. Only authentication refusal can pause fresh
admissions; a generic transport failure cannot pause other devices. A successful
discovery clears the authentication pause. Readiness wait is bounded.
Full quota rejects promptly, matching the original spike: the first production
candidate held full-quota sockets for45s and FAILED the owner phone test. Already
open flows are not evicted when limits shrink. Existing total connection/FD limit
also bounds queued sockets. Probe reservations share the allowance.

HELLO capability bit2 requests session budget in AUTH_OK text JSON. Existing
AUTH_OK arg remains streams-per-session; old clients get unchanged text. Capacity
GOODBYE11 is not identity refusal and cannot trigger protocol downgrade or key
replacement. No server registration writer is added.

Test source before commit, cross-build using Go1.25.13, review independently.
Separate cgroup-limited loopback load tests on main VPS compare pooled vs dedicated
and TLS; they use synthetic identities/DCs and do not touch live registry/services.
Prepare max-sessions10000 for the main VPS only after validating10000 TLS sessions.
Do not silently apply unrelated nginx drift. Release must rebuild client binaries
and prepare relay capacity before fleet update; a commit or cherry-pick is not rollout. Client binaries are included at the
current manifest version; a version bump requires the normal release rebuild.
