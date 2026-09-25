# Automatic Foreign WARP Edge Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** By default, WARP on a Keenetic router chooses the best verified Cloudflare WG edge outside Russia and falls back to a working domestic edge or the existing transport ladder.

**Architecture:** A bounded, sequential scan runs inside `z2k-warpd` before it declares the tunnel ready. It reuses the existing device key and TUN, probes each candidate through that tunnel, persists verified results per uplink, and feeds ranked WG steps into the existing ladder. A failed or cancelled scan leaves the original ladder and fail-open routing available.

**Tech Stack:** Go 1.25.12, wireguard-go, Linux TUN and `SO_BINDTODEVICE`, POSIX shell, existing webpanel JavaScript and shell tests.

**Spec:** `docs/superpowers/specs/2026-09-25-warp-foreign-edge-selection-design.md`

## Global Constraints

- No new WARP control or button; the automatic transport gets the new preference, and manual `h2` stays `h2` only.
- Foreign means Cloudflare `/meta` reports `colo.cca2 != RU` through the candidate tunnel. It does not promise a foreign website-facing IP.
- Scan budget is 60 seconds total, with a hard candidate and port cap; no parallel sessions using one WG key.
- Never mark `ready` or install the WARP policy route from a handshake, cache record, or location alone; existing `warp=on` health proof remains mandatory.
- Failed scan, missing metadata, malformed cache, or changed WAN must preserve the existing WG/MASQUE fallback and fail-open route behavior.
- Do not change `device.json`, the domain/IP routing rules, or the current 48 MiB Go memory ceiling.
- Build targets include arm64, arm, mipsel, mips, amd64, 386, mips64el, ppc64, and riscv64.

## Review Focus

1. A cached foreign edge reached through another WAN must be rechecked, not trusted; Task 3 tests this.
2. A handshake that passes but cannot carry HTTP must never become `ready`; Tasks 2 and 4 test this.
3. A metadata timeout or unknown country must not disable a working domestic WARP; Tasks 2 and 4 test this.
4. Disable/restart during the scan must stop quickly without leaving a route or half-written cache; Tasks 3 and 4 test this.
5. A preferred foreign endpoint that later fails must fall through to the domestic WG and h2 ladder without a hot retry loop; Task 4 tests this.

## File map

- `z2k-warpd/internal/edgepick/candidates.go`, `rank.go`, tests: bounded candidate generation and pure ranking.
- `z2k-warpd/internal/edgepick/probe.go`, tests: Cloudflare metadata parsing and in-tunnel measurement; uses the existing TUN and no second daemon.
- `z2k-warpd/internal/edgepick/cache.go`, `wan.go`, tests: atomic persistent results and uplink fingerprint.
- `z2k-warpd/internal/engine/engine.go`, `internal/ladder/ladder.go`, tests: sequential startup scan, preferred steps, failover, cancellation.
- `z2k-warpd/cmd/z2k-warpd/main.go`, `files/lists/warp-scan-pools.txt`, `lib/install.sh`: candidate file loading and installation beside the existing endpoint list.
- `z2k-warpd/internal/status/status.go`, `files/z2k-warp.sh`, `webpanel/cgi/api.sh`, `webpanel/www/js/pages/warp.js`, tests: diagnostics and existing status view; no controls.

---

### Task 1: Generate and rank bounded WG candidates

**Files:**
- Create: `z2k-warpd/internal/edgepick/candidates.go`, `rank.go`, `candidates_test.go`, `rank_test.go`
- Create: `files/lists/warp-scan-pools.txt`
- Modify: `z2k-warpd/cmd/z2k-warpd/main.go` (read the new data file, rejecting non-WARP or oversized networks)
- Modify: `lib/install.sh` (deliver the file beside `warp-endpoints.txt`)

**Interfaces:**
- Produces: `edgepick.Result{Step account.Step, Colo string, Country string, RTT time.Duration, LossPct int, CheckedAt time.Time, WAN string}`.
- Produces: `edgepick.Candidates(ep account.Endpoint, fallback []string, pools []netip.Prefix, limit int, seed uint64) []account.Step` and `edgepick.Rank([]edgepick.Result) []edgepick.Result`.
- Produces: `edgepick.ReadPools(path string) []netip.Prefix` for the shipped list; the empty result is safe.
- The pool reader accepts only IPv4 WARP /24s from the shipped file, removes duplicates, and caps the file size and count. User-edited bad lines are skipped with a log entry; they do not prevent WARP startup.

- [ ] **Step 1: Write failing pure tests.** Cover deduplication, varied /24 sampling, a fixed seed, `limit=12`, RU/unknown/foreign ordering, loss before median RTT, and stable ties. Use `account.Endpoint{V4:"8.6.112.1", Ports:[]int{2408}}` and results `FI:40ms/0%`, `DE:25ms/0%`, `RU:5ms/0%`, `SE:12ms/20%`; expect DE before FI before SE before RU. Representative assertion:

```go
got := Rank([]Result{{Country:"RU", RTT:5*time.Millisecond}, {Country:"FI", RTT:40*time.Millisecond}, {Country:"DE", RTT:25*time.Millisecond}})
if got[0].Country != "DE" || got[1].Country != "FI" || got[2].Country != "RU" { t.Fatalf("order: %+v", got) }
```
- [ ] **Step 2: Run the focused tests to establish red.** `cd z2k-warpd && go test ./internal/edgepick -run 'TestCandidates|TestRank' -count=1`; expected: package or symbols missing.
- [ ] **Step 3: Implement the data model, sampler and stable rank.** Keep the registered endpoint and existing fallback IPs first in the candidate set, then one or two deterministic samples from each approved pool until the cap. Example core ordering:

```go
func tier(r Result) int {
    if r.Country != "" && r.Country != "RU" { return 0 }
    if r.Country == "RU" { return 1 }
    return 2
}
sort.SliceStable(results, func(i, j int) bool {
    a, b := results[i], results[j]
    if tier(a) != tier(b) { return tier(a) < tier(b) }
    if a.LossPct != b.LossPct { return a.LossPct < b.LossPct }
    return a.RTT < b.RTT
})
```

  Add the verified pool prefixes as **data** with source and update date in comments; do not copy Warpscout's scanner or add its runtime dependencies. Ensure the installer copies the file to `/opt/zapret2/lists/warp-scan-pools.txt`, outside `lists/warp/` so endpoints never enter the destination ipset.
- [ ] **Step 4: Run focused tests and install mapping checks.** `cd z2k-warpd && go test ./internal/edgepick -count=1`; then `sh tests/test_manifest_install_map.sh`. Both must pass.
- [ ] **Step 5: Commit.** `git add z2k-warpd/internal/edgepick files/lists/warp-scan-pools.txt z2k-warpd/cmd/z2k-warpd/main.go lib/install.sh && git commit -m 'feat(warp): prepare bounded edge candidates and ranking'`.

### Task 2: Prove a candidate and measure its Cloudflare edge

**Files:**
- Create: `z2k-warpd/internal/edgepick/probe.go`, `probe_test.go`
- Modify: `z2k-warpd/internal/health/health.go` only if a shared bound-to-TUN HTTP helper removes duplicate socket code without changing `TraceProbe` semantics.

**Interfaces:**
- Produces: `edgepick.Probe(ctx context.Context, iface string) (edgepick.Meta, time.Duration, int, error)` where `Meta{Colo, Country string}` is parsed from `/meta`.
- The engine calls `health.TraceProbe` separately to prove `warp=on` before it accepts a candidate. `Probe` resolves `speed.cloudflare.com` through the same TUN, sets its required `Referer`, caps response at 4 KiB, measures at least three short in-tunnel requests, and returns median RTT and integer loss percentage.

- [ ] **Step 1: Write failing tests.** With an injected HTTP client and resolver, assert parsing of `{"colo":{"iata":"FRA","cca2":"DE"}}`, rejection of an empty `cca2`, `403`/truncated/malformed JSON behavior, use of `Referer: https://speed.cloudflare.com`, and that socket/dial selection is bound to the test interface. Use a context that expires during a simulated request and assert immediate cancellation. Representative parser assertion:

```go
meta, err := parseMeta([]byte(`{"colo":{"iata":"FRA","cca2":"DE"}}`))
if err != nil || meta.Colo != "FRA" || meta.Country != "DE" { t.Fatalf("meta=%+v err=%v", meta, err) }
```
- [ ] **Step 2: Run red tests.** `cd z2k-warpd && go test ./internal/edgepick -run 'TestMeta|TestProbe' -count=1`; expected: missing probe implementation.
- [ ] **Step 3: Implement the probe with one bounded HTTP path.** Put the HTTP and resolver behind injected dial functions so tests do not contact Cloudflare. The production resolver dials `1.1.1.1:53` through the TUN; the HTTPS socket also binds to the TUN. Use this parsing boundary:

```go
var body struct {
    Colo struct {
        IATA string `json:"iata"`
        CCA2 string `json:"cca2"`
    } `json:"colo"`
}
if err := json.Unmarshal(raw, &body); err != nil { return Meta{}, err }
if len(body.Colo.CCA2) != 2 { return Meta{}, errUnknownCountry }
return Meta{Colo: body.Colo.IATA, Country: strings.ToUpper(body.Colo.CCA2)}, nil
```

  A metadata failure returns an error to the selector but never declares the underlying WG unusable. Avoid public DNS or HTTPS probes that can escape over WAN.
- [ ] **Step 4: Run the focused tests and existing health tests.** `cd z2k-warpd && go test ./internal/edgepick ./internal/health -count=1`; expected: pass.
- [ ] **Step 5: Commit.** `git add z2k-warpd/internal/edgepick z2k-warpd/internal/health && git commit -m 'feat(warp): measure edge location inside proven tunnel'`.

### Task 3: Persist only verified results for the current uplink

**Files:**
- Create: `z2k-warpd/internal/edgepick/cache.go`, `wan.go`, `cache_test.go`, `wan_test.go`
- Modify: `z2k-warpd/cmd/z2k-warpd/main.go` (default cache path `/opt/etc/z2k-warp/edge-cache.json`)

**Interfaces:**
- Produces: `edgepick.LoadCache(path, wan string, now time.Time) []edgepick.Result`, `edgepick.SaveCache(ctx context.Context, path, wan string, results []edgepick.Result) error`, `edgepick.WANFor(host string) (string, error)`.
- `WANFor` returns `interface-name|local-source-IP` for the route to the candidate, without sending a packet. Cache TTL is 24 hours. Malformed, stale, different-WAN and partial files yield an empty result, not startup failure.

- [ ] **Step 1: Write failing tests.** Save/load two records; assert atomic rename and `0600` permissions; fail a write before rename and preserve the old valid file; load with a different WAN and after 24 hours and expect no hit; corrupt JSON and expect no hit; cancel a save and assert no partial new cache. Test WAN identity from an injected route lookup rather than the host machine's network. Representative cache assertion:

```go
if err := SaveCache(context.Background(), path, "wan0|192.0.2.2", []Result{{Country:"DE", CheckedAt:now}}); err != nil { t.Fatal(err) }
if got := LoadCache(path, "wan1|192.0.2.3", now); len(got) != 0 { t.Fatalf("cross-WAN cache: %+v", got) }
```
- [ ] **Step 2: Run red tests.** `cd z2k-warpd && go test ./internal/edgepick -run 'TestCache|TestWAN' -count=1`; expected: missing cache/WAN functions.
- [ ] **Step 3: Implement versioned JSON cache and WAN identity.** Keep only `Result` fields and a version number; never serialize the private key or account token. Use a temporary file in the cache directory, `Sync`, `Close`, `Rename`, and directory sync where supported. Compute source address/interface from a UDP route lookup to the candidate and revalidate a cached endpoint with live `warp=on` on every use. The write must check cancellation before replacing the old file:

```go
if err := tmp.Sync(); err != nil { return err }
if err := tmp.Close(); err != nil { return err }
if err := ctx.Err(); err != nil { return err }
if err := os.Rename(tmp.Name(), path); err != nil { return err }
```
- [ ] **Step 4: Run tests.** `cd z2k-warpd && go test ./internal/edgepick -count=1`; expected: pass.
- [ ] **Step 5: Commit.** `git add z2k-warpd/internal/edgepick z2k-warpd/cmd/z2k-warpd/main.go && git commit -m 'feat(warp): cache verified edge choices per WAN'`.

### Task 4: Integrate sequential selection with the existing engine and ladder

**Files:**
- Modify: `z2k-warpd/internal/engine/engine.go`, `engine_test.go`
- Modify: `z2k-warpd/internal/ladder/ladder.go`, `ladder_test.go`
- Modify: `z2k-warpd/cmd/z2k-warpd/main.go`

**Interfaces:**
- `engine.Config` receives candidate steps, cache path and injected `GeoProbe`/WAN lookup for tests. The engine owns the scan and uses `e.open(ctx, step, e.tunDev.Handle())` sequentially; after each candidate it closes the transport before opening another.
- Add `ladder.NewPreferred(ep account.Endpoint, start *account.Step, mode string, preferred []account.Step) *ladder.Ladder`. It prepends deduplicated verified foreign WG steps, then verified domestic/unknown WG steps, preserving the original ladder's early h2 position and subsequent ports. Manual `h2` ignores `preferred`; diagnostic `ForceStep` bypasses scanning.

- [ ] **Step 1: Write failing engine/ladder tests.** In `engine_test.go` use the existing fake transport harness to assert serialized `Open`/`Close`, first foreign choice despite a faster RU edge, `ready=false` while scanning, cancellation without cache write, metadata failure falling back to a proven RU step, cached foreign live recheck, changed WAN forcing new scan, and foreign death advancing to RU then h2. In `ladder_test.go` assert no duplicate step and the existing early h2 placement after the first WG fallback steps. Representative ladder assertion:

```go
l := NewPreferred(ep, nil, ModeAuto, []account.Step{{Transport:"wg", Host:"188.114.96.23", Port:2408}})
if got := l.Current(); got.Host != "188.114.96.23" { t.Fatalf("preferred step: %+v", got) }
```
- [ ] **Step 2: Run red tests.** `cd z2k-warpd && go test ./internal/engine ./internal/ladder -run 'TestForeign|TestPreferred' -count=1`; expected: missing integration/constructor.
- [ ] **Step 3: Add the scan and ladder integration.** Use one 60-second parent context and a maximum of 12 candidates; no probe starts after the deadline. Candidate flow:

```go
for _, step := range candidates {
    if scanCtx.Err() != nil { break }
    tr, err := e.open(scanCtx, step, e.tunDev.Handle())
    if err != nil { continue }
    proofErr := e.cfg.Probe(scanCtx, e.iface)
    if proofErr != nil { _ = tr.Close(); continue }
    meta, rtt, loss, geoErr := e.cfg.GeoProbe(scanCtx, e.iface)
    _ = tr.Close()
    result := edgepick.Result{Step:step, RTT:rtt, LossPct:loss, CheckedAt:e.cfg.Now()}
    if geoErr == nil { result.Colo, result.Country = meta.Colo, meta.Country }
    results = append(results, result)
}
```

  Implement the complete branch without leaving a comment-only stub. Reopen the chosen step and let the existing health monitor prove readiness before routing. Preserve `LastGood`, full-pass cooldown, `wgReachable`, manual modes, and `ForceStep` semantics. Do not add a concurrent scanner or a second registration.
- [ ] **Step 4: Run focused and full Go tests.** `cd z2k-warpd && go test ./internal/engine ./internal/ladder -count=1 && go test ./...`; expected: pass. Review test assertions for no hot retry loop and h2 reachability.
- [ ] **Step 5: Commit.** `git add z2k-warpd/internal/engine z2k-warpd/internal/ladder z2k-warpd/cmd/z2k-warpd/main.go && git commit -m 'feat(warp): prefer verified foreign edges with safe failover'`.

### Task 5: Expose selection and preserve startup/fail-open contracts

**Files:**
- Modify: `z2k-warpd/internal/status/status.go`, `status_test.go`
- Modify: `files/z2k-warp.sh`, `tests/test_warp_script.sh`
- Modify: `webpanel/cgi/api.sh`, `tests/test_webpanel_api_contract.sh`
- Modify: `webpanel/www/js/pages/warp.js`, `tests/test_panel_frontend_contract.sh`
- Modify: diagnostics only where WARP status is already rendered.

**Interfaces:**
- Status fields: `edge_colo`, `edge_country`, `edge_rtt_ms`, `edge_checked_at`, `edge_selection` (`foreign`, `domestic`, `unknown`, `fallback`, `scanning`). API keeps existing fields and adds these as data only.
- The webpanel adds one compact read-only status cell or subordinate line for selected edge and measured delay; no switch or action endpoint.

- [ ] **Step 1: Write failing contract tests.** Round-trip new status fields. Stub `warp_status_info` with `edge_colo=FRA edge_country=DE edge_rtt_ms=28`; assert JSON escaping and numeric type, and verify the frontend displays `FRA · DE · 28 мс` without a new input/button. In shell tests simulate a scan longer than the old wait but shorter than the new bound, and assert no policy route appears before `ready=true`. Representative API assertion:

```sh
assert_eq "страна узла" "DE" "$(jget "$OUT" 'd["edge_country"]')"
assert_eq "задержка узла" "28" "$(jget "$OUT" 'd["edge_rtt_ms"]')"
```
- [ ] **Step 2: Run red tests.** `cd z2k-warpd && go test ./internal/status -run TestEdge -count=1`; `sh tests/test_webpanel_api_contract.sh`; `sh tests/test_warp_script.sh`; expected: new assertions fail.
- [ ] **Step 3: Wire status, API and UI.** Pass the new fields through `warp_status()` and `GET /warp/status`; use existing `json_string` for text and strict numeric validation for RTT/timestamp. Increase `WARP_READY_WAIT` only enough to cover 60-second scan plus current ladder startup; keep the route gate on proven `ready`. Show empty or stale data as `—`, and distinguish a domestic fallback from foreign selection in diagnostics. Use existing status escaping, for example:

```sh
printf ',"edge_colo":'; json_string "$(_wf edge_colo)"
printf ',"edge_country":'; json_string "$(_wf edge_country)"
printf ',"edge_rtt_ms":%s' "$(_wf edge_rtt_ms | grep -E '^[0-9]+$' || echo 0)"
```
- [ ] **Step 4: Run UI and shell checks.** `cd z2k-warpd && go test ./...`; `sh tests/test_warp_script.sh`; `sh tests/test_webpanel_api_contract.sh`; `sh tests/test_panel_frontend_contract.sh`; `sh scripts/ci_local.sh` if its prerequisites are present. All must pass.
- [ ] **Step 5: Commit.** `git add z2k-warpd/internal/status files/z2k-warp.sh webpanel/cgi/api.sh webpanel/www/js/pages/warp.js tests/test_warp_script.sh tests/test_webpanel_api_contract.sh tests/test_panel_frontend_contract.sh && git commit -m 'feat(warp): show chosen edge and keep fail-open startup'`.

### Task 6: Cross-build and verify on the owner's router before release

**Files:**
- Modify: `scripts/warp_e2e.sh` (read-only assertions for `edge_colo`, `edge_country`, status, and fallback; preserve its existing lifecycle cleanup)
- Build outputs: `z2k-warpd/builds/` (normal architecture artifacts; do not commit binaries unless the repository's binary delivery workflow requires them)

**Interfaces:** Consumes the completed binary and status contract. No new public API.

- [ ] **Step 1: Extend the router smoke assertions.** Add checks that `ready=1` still implies `warp=on`, edge metadata came from the tunnel, and the route disappears before forcing a dead endpoint in a controlled test. Compare the router's `curl --interface <tun> https://speed.cloudflare.com/meta` result with `status.json`; do not infer a foreign website IP from the edge country. Example router assertion:

```sh
ssh_r "curl -sS -m 10 --interface $IF -H 'Referer: https://speed.cloudflare.com' https://speed.cloudflare.com/meta" \
  | grep -q '"colo"' || fail "нет метаданных Cloudflare через TUN"
```
- [ ] **Step 2: Run local tests and cross-builds.** `cd z2k-warpd && go test ./... && make all`; run `sh tests/test_warp_arch_parity.sh` and relevant manifest/install checks. Record architecture sizes and memory change against the current binary.
- [ ] **Step 3: Deploy to the owner's router for a controlled measurement.** Back up the existing binary and endpoint data, install the matching architecture build, restart WARP through `z2k-warp.sh`, and capture chosen endpoint, country, latency, time to ready, RSS, and route behavior. Test a foreign candidate when found and the domestic fallback by disabling just that test candidate; restore the normal state afterwards.
- [ ] **Step 4: Re-run failed checks after any correction, then commit the smoke script.** `git add scripts/warp_e2e.sh && git commit -m 'test(warp): verify automatic edge selection on router'`. Report measured results and any limitations. Do not publish a release as part of this plan.
