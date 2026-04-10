# Upstream Proposals for zapret2 (bol-van)

Issues and improvements discovered during z2k development that could benefit
the upstream zapret2 project.

## 1. Native circular persistence (HIGH priority)

**Current state:** z2k implements `z2k-autocircular.lua` (~1300 lines) to persist
per-host `nstrategy` across nfqws2 restarts. This is critical for autocircular
stability — without it, every restart resets all domains to strategy 1.

**Proposal:** Add built-in `--circular-state-file=PATH` option to nfqws2 core.
The Lua overlay approach works but adds complexity, file locking concerns, and
makes debugging harder.

**Implementation sketch:**
- On circular rotation: write `askey\thost\tstrategy\ttimestamp` to state file
- On startup: read state file, seed autostate table
- Rate-limit writes (2s interval, like z2k does)
- Use atomic write-to-tmp + rename pattern

## 2. `--dry-run` / `--validate` flag for nfqws2 (HIGH priority)

**Current state:** No way to validate NFQWS2_OPT before starting the daemon.
Invalid options cause nfqws2 to crash at startup, breaking the service.

**Proposal:** Add `--dry-run` flag that parses all options, validates hostlist
paths, blob file existence, and Lua script loading — then exits with 0/1.

**Use case:** z2k-config-validator.sh currently does regex-based validation
which can't catch all issues. A native dry-run would be authoritative.

## 3. Lua API documentation (MEDIUM priority)

**Current state:** The Lua API for desync actions is undocumented. Functions
like `DLOG`, `l3_len`, `l4_len`, `deepcopy`, `rawsend_dissect`,
`rawsend_payload_segmented`, `rawsend_dissect_ipfrag`, `tls_dissect`,
`tls_reconstruct`, `direction_check`, `payload_check`, `instance_cutoff_shim`,
`replay_first`, `replay_drop`, `replay_drop_set`, `resolve_pos`,
`http_dissect_reply`, `array_field_search`, `is_dpi_redirect`,
`standard_failure_detector`, `standard_success_detector` are discovered
only by reading zapret-auto.lua source code.

**Proposal:** Add `docs/lua-api.md` documenting:
- Available global functions and their signatures
- `desync` table structure (fields: dis, arg, track, outgoing, l7payload, etc.)
- `ctx` table structure
- Available constants (VERDICT_DROP, VERDICT_MODIFY, IP_MF, etc.)
- Lifecycle: when each callback is invoked

## 4. install_bin.sh checksum verification (MEDIUM priority)

**Current state:** `install_bin.sh` downloads and installs binaries without
SHA256 verification. In countries with state-level DPI/MITM capabilities,
this is a real attack surface.

**Proposal:** Ship `SHA256SUMS` file alongside releases. Verify after download.

## 5. standard_failure_detector enhancement: HTTP 301/303/308 (LOW priority)

**Current state:** `standard_failure_detector` only checks HTTP 302/307
redirects for DPI detection. Russian ISPs increasingly use 301 and 308
redirects to block pages (observed with Ertelecom/Dom.ru).

**Proposal:** Extend redirect code list to include 301, 303, 308.
z2k implements this in `z2k_tls_alert_fatal` as a custom failure detector.

## 6. ECH-aware desync bypass (LOW priority, future)

**Current state:** When a client sends TLS ClientHello with ECH extension,
the real SNI is encrypted. DPI cannot see it, so desync is unnecessary.
Currently nfqws2 applies desync to all TLS regardless of ECH.

**Proposal:** Add `--filter-l7=tls_no_ech` filter that skips packets
containing ECH extension. This avoids unnecessary desync overhead and
reduces the chance of breaking ECH handshakes.

z2k implements `z2k_ech_passthrough` Lua action as a proof of concept.
