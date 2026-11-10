# Dedicated customer relay sizing — 2026-11-10

Read-only audit of45.146.90.136. This server stays dedicated to its customer;
no community clients, registry transfer or shared infrastructure is authorized.
Private raw baseline: /Library/Zapret2/research/tg-dedicated-capacity-20261110/baseline.json.

## Selected initial limits (not applied)

Global4096 sessions,1024 sessions per installation, existing4096 streams per
session retained for old multiplexed clients. Keep GOMEMLIMIT1500MiB,
MemoryHigh1800M, MemoryMax2200M, LimitNOFILE65536 and no swap.

The two current installations have604 streams in total, not604 measured people.
1024 sessions per installation provides room above even this entire current
aggregate; one discovery reservation leaves1023 data sessions. The global cap
allows headroom without adopting the community node's proposed10000 ceiling.
This is a bounded starting budget, not a demonstrated maximum or a bandwidth SLA.

Main-node synthetic10000TLS-session test used about88KiB Go heap per session
including test client. At4096 this is about352MiB heap, but excludes real busy
stream queues, frontend/kernel buffers and Go overhead. It cannot establish
peak live memory. Existing memory guards remain necessary. Current dedicated
relay RSS is63MiB and available host RAM3.44GiB; no evidence currently justifies
buying more RAM/CPU. Bandwidth peaks still need observation.

## Migration gates

The current customer server allows only2 sessions per installation. Do not send
the new per-flow client there before server and customer-client settings agree.
The feature client presently limits its configurable ceiling to64; changing only
the server cap does not solve that. Prepare a dedicated explicit configuration
with a validated1024 ceiling while keeping household defaults. Determine whether
the customer client sees distinct downstream IPs: a gateway aggregating everyone
behind one source would make the per-device16 cap incorrect.

Keep existing4096 stream allowance during transition; lowering it would disrupt
old multiplexed clients. Test both protocol generations and quota advertisement.
Before actual rollout, save current unit/environment configuration privately,
review recycle timer thresholds, prove new connections from customer network,
and validate representative traffic. Do not start a second registry writer.
No live server settings or processes were changed by this sizing task.
