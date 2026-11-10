# Tasks
- [x] Replace rejected opt-in requirement with automatic per-flow transport (R1).
- [x] Preserve identity, route ownership and custom destinations (R2).
- [x] Negotiate session quota; remove permanently occupied control slot (R3).
- [x] Per-device cap and round-robin pending queue; no shared overflow (R4).
- [x] Test independent closure, cancellation, busy vs auth denial, discovery isolation (R5).
- [x] Compare8000 flows as2000 pooled sessions and8000 dedicated sessions on VPS.
- [x] Validate8000 TLS sessions under1GiB/0.5CPU isolated test limit.
- [x] Validate10000 TLS sessions; prepare main-VPS capacity10000 (not applied).
- [x] Both client/relay race suites and quota wire tests; independent code review.
- [x] Router canary: five DCs return matching MTProto resPQ nonce.
- [x] Phone acceptance: first candidate FAILED; fast-capacity rejection improved
  it; restoring the original four-concurrent-handshake scheduler recovered full
  speed. Owner explicitly confirmed “Да, теперь как в первом”.
- [x] Rebuild nine target architectures plus compatibility aliases with production
  credential and pinned Go1.25.13; retain manifest version until release.
- [x] Add private read-only fleet baseline tooling and explicit release gates.
- [x] Final verification and independent review; single replacement commit artifact prepared (R6).
- [ ] Future release: rebuild release artifacts, prepare server capacity, publish
  client update and observe fleet/user traffic. Not claimed by a source commit.
