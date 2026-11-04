# Feature: automatic redirector DNS candidates
Date: 2026-11-04. User reports success after installing24 real Google IPv4 candidates collected on VPS. Wants the same automatic mechanism in z2k. Release resumed by owner after approval of Marshmalick donor text.
## User scenarios and acceptance
R1. Fresh install, successful patch update and nightly refresh obtain alternative IPv4 records for exactly redirector.googlevideo.com from existing authenticated VPS /resolve.
R2. Collect system+Google+Cloudflare+Quad9 candidates, deduplicate up to32, without the Instagram8-address early cutoff. No router reachability probes for this hostname; preserve all received valid candidates.
R3. Client validates every address against shipped Google IPv4 ranges, rejects malformed/empty/untrusted/oversized responses without removing previous records. Add replacement addresses before deleting stale ones; rollback on failure. No other host altered, no conntrack flush.
R4. Use kernel flock, provisioned from Entware when absent (failed provisioning preserves DNS). Separate Z2K_REDIRECTOR_DNS=0 opt-out; Instagram flags and probes unchanged. Lock concurrent refreshes. Failed fetch is nonfatal to install/update.
R5. VPS deployment retains endpoint/auth semantics; explicit owner permission allows one Telegram-relay reconnect. Capture baseline, backup, validate binary and health; measure sessions after deployment. No IP migration.
R6. Add Marshmalick to README, terminal credits and web credits with the exact approved paragraph; release donor and resolver together. Preserve manual router pins during preparation.
## Approaches
Reuse existing /resolve and add independent router refresher (selected: user explicitly wants Instagram-style resolution). Separate resolver service considered only to avoid session interruption, unnecessary after explicit reconnect permission. Static shipped IPs rejected: no automatic freshness. Proxying video or redirector excluded.
## Success criteria
Unit and shell integration tests prove R1-R4, live authenticated endpoint returns candidates, router refresh retains candidates despite no HTTP probe, evidence records deployment state and unperformed checks.
