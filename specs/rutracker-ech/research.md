# RuTracker ECH investigation — 2026-11-04

Status: investigation complete; no ECH compatibility implementation or deployment.
Baseline: retry-fix branch at 5d32c592. User requested investigation of the remaining ECH problem. This report supersedes the suggestion that per-domain sentinel addresses alone would solve it.

## Reproduced result

Google DNS HTTPS (type 65) response for rutracker.org advertises an ECHConfigList with public name cloudflare-ech.com and Cloudflare address hints. The existing router bridge sends CONNECT using the visible ClientHello SNI. For an ECH client that can be the public name rather than the intended website.

However, retaining the intended domain is insufficient with the tested official proxy path. A Go 1.25.13 probe obtained the current ECH configuration, opened outer TLS to an official proxy IP with SNI ps1.blockme.site, sent CONNECT rutracker.org:443, and ran inner TLS with ServerName rutracker.org. Inner certificate verification was ENABLED in both modes. The only difference was supplying EncryptedClientHelloConfigList for the ECH mode.

| Official proxy IP | Ordinary inner TLS | Inner TLS with ECH |
| --- | --- | --- |
| 82.21.4.208 | verified certificate, HTTP 200 | certificate-name failure: certificate covers rutracker.org and related names, not cloudflare-ech.com |
| 151.242.242.58 | verified certificate, HTTP 200 | same certificate-name failure |
| 193.29.12.104 | verified certificate, HTTP 200 | same certificate-name failure |

All six compared attempts above received CONNECT 200. Thus CONNECT success alone does not prove ECH compatibility. On 82.21.4.208, alternate CONNECT cloudflare-ech.com:443 and CONNECT 104.21.32.39:443 each returned 200 followed by EOF during the inner ECH handshake. Simply allowing the public ECH name or passing a Cloudflare IP to this proxy did not repair the test.

Other probes encountered transport timeouts, and one ordinary TLS session to 135.181.99.133 verified its certificate but timed out reading HTTP. These are recorded, not counted as ECH evidence. This is an observation of the tested nodes/time, not a universal claim about every past/future proxy node.

The user's diagnostic independently shows cloudflare-ech.com reaching rt-proxy and failing. It reports firmware dns-proxy, no AdGuard Home. It does not show which resolver/browser supplied that client's HTTPS record, so that source is not established.

## Protocol interpretation

RFC 9848 section 4 requires endpoints to have the corresponding ECH keys or authority for the ECH public name; otherwise connections fail. RFC 9849 sections 6.1.6 and 8.1.1 forbid unauthenticated downgrade. The observed endpoint cannot authenticate the public name, even though its certificate is valid for ordinary rutracker.org TLS. A retry change, a different sentinel address, or suppressing certificate errors cannot repair that protocol mismatch.

The extension's existing proxyScript.js chooses CONNECT routing from the URL hostname. This differs from SNI inference, but does not by itself prove that the extension can carry ECH successfully. Browser proxy behaviour must not be inferred from a transparent router's behaviour.

## Implementation direction

For retaining the official proxy, the recommended compatibility mode is DNS consistency: for the exact five managed domains, the resolver should not advertise an HTTPS ECH configuration for the Cloudflare endpoint while routing A traffic to an incompatible proxy path. Cloudflare documents returning NOERROR/NODATA for HTTPS queries as a way to disable ECH. Ordinary end-to-end TLS and certificate validation remain enabled. Prefer scoped NODATA over global ECH disablement or NXDOMAIN for the hostname.

Keenetic's documented `ip name-server address[:port] domain` supports domain-scoped DNS forwarding, making a local compatibility responder a candidate integration. The command routes suffixes, so exact-name behaviour and subdomains need explicit tests. Documentation establishes the mechanism, not a verified router integration.

An alternative preserving ECH is a different transport to an ECH-capable public endpoint, combined with retaining destination identity. This would change the official-proxy-only architecture and needs separate endpoint/capacity/access-policy verification. It was not deployed or assumed to work here.

## Remaining implementation requirements / gates

- [ ] Choose and validate a bounded local DNS responder plus firmware integration; do not assume `ip host` alone suppresses type 65.
- [ ] Scope NODATA to intended names/type; preserve unrelated DNS, existing encrypted DNS choices, host overrides and user configuration.
- [ ] Avoid recursive forwarding back to the router for a domain routed to the responder. Test TCP/UDP, EDNS, malformed packets, resource bounds and resolver failures.
- [ ] Account for AAAA/HTTPS address hints and QUIC so they do not bypass the intended path.
- [ ] Prove correct cold-cache browser behaviour and explicitly characterize warm cached ECH records; no forced client downgrade or promise of instant cache eviction.
- [ ] Characterize explicit browser DoH/DoT bypass: a local resolver cannot alter traffic it does not receive. Do not silently disable encrypted DNS globally.
- [ ] Verify startup ordering, failure recovery, restart, rollback/uninstall and ownership of installed settings on supported firmware before publication.
- [ ] Run regression tests and independent implementation review. The earlier retry fix remains useful but is not the completed ECH solution.

## Evidence and reproducibility

Local artifacts: `/Library/Zapret2/artifacts/rutracker-ech-20261104/`.
`https-record.json`, `probe.log`, `compare.log`, `confirm.log`, `alternative.log` contain the observations. `probe.go`, `confirm.go`, `alternative.go` are throwaway, read-only network probes, not production software. Run one explicitly with `/Users/mark/go/bin/go1.25.13 run <file>`; results depend on the then-current DNS configuration and proxy reachability. No credentials are used. Outer TLS verification is disabled, matching the existing CONNECT transport; inner website TLS verification remains enabled. No router or VPS configuration was changed.

Sources:
- https://www.rfc-editor.org/rfc/rfc9848.html#section-4
- https://www.rfc-editor.org/rfc/rfc9849.html#section-8.1.1
- https://developers.cloudflare.com/ssl/edge-certificates/ech/ (network operators section)
- https://storage.googleapis.com/docs.help.keenetic.com/cli/4.1/en/cli_manual_kn-2410.pdf (section 3.61, ip name-server, printed pp. 365–366)
- https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.6

## Chrome follow-up

Fetched Chromium main `net/socket/ssl_connect_job.cc` on 2026-11-04. Its DoSSLConnect path loads ECHConfigList from endpoint DNS metadata and, if nonempty, asserts `SSLSocketParams::DIRECT`; the adjacent comment explicitly says other connection types do not support ECH. This independently supports the distinction between an explicit browser HTTPS proxy and transparent router interception. Chromium issue 546370261 reports the same limitation; a Chromium developer confirms it is known. This does not prove all extension users never encounter other failures.

The known official Chrome extension ID is fddjpichkajmnkjhcmpbbjdmmcodnkej. The Google CRX update endpoint again returned HTTP 204 / zero bytes. Therefore its currently distributed code/version was not inspected; the unofficial Chromium port found on GitHub is not substituted as evidence of the official binary. Raw fetched Chromium sources are in `/Library/Zapret2/artifacts/rutracker-chrome-20261104/`.

Sources:
- https://chromium.googlesource.com/chromium/src/+/main/net/socket/ssl_connect_job.cc
- https://issues.chromium.org/issues/546370261

An explicit PAC/HTTPS proxy configuration for the browser is a closer architectural match to the extension, but requires client-side proxy configuration; publishing a PAC file on a router alone does not make every browser use it. Transparent operation without client configuration still needs the scoped DNS compatibility work described above, or an independently validated ECH-capable transport.

## Full-pool falsification check (2026-11-04, 18:24 UTC snapshot)

The owner challenged whether the proxy already supports the desired path and the earlier test was incomplete. Expanded the read-only spike to all 9 IPv4 nodes returned for ps1.blockme.site, with a single saved DNS/ECH snapshot and identical Go 1.25.13 client. Explicitly set outer ALPN http/1.1 (matching production); parse the CONNECT response using net/http; retain buffered bytes; bound each operation. Inner certificate verification remains enabled. Record ECH acceptance, certificate names/fingerprint, stage-specific errors, exact CONNECT target, timestamps and configuration hash.

Positive controls: connect directly to BOTH advertised public RuTracker IPs (104.21.32.39 and 172.67.182.196) using that ECH configuration. Both succeeded with ECHAccepted=true, verified certificate and HTTP 200, from both the owner's machine and VPS 85.192.60.175. Thus the ECH client/configuration demonstrably works.

From the VPS, ordinary TLS through all 9 proxy nodes returned verified HTTP 200. ECH through CONNECT rutracker.org:443 returned the same wrong-public-name certificate on 8 nodes; the ninth initially timed out during CONNECT, then returned the same certificate-name failure on the targeted retry. All 9 therefore reproduced the ECH mismatch. All 27 alternative ECH connections (9 nodes × CONNECT cloudflare-ech.com or either public IP) received CONNECT 200 and then EOF at inner TLS.

From the owner's machine: both direct ECH controls passed; 5/9 ordinary proxy requests returned HTTP 200, other attempts had transport failures. No proxied ECH success. Transport failures are not interpreted as evidence of ECH rejection.

The public CF endpoint's leaf SHA256 was 4a98323fe1c8a6d9e44fa9fa5081f6bcdb389e533002798190729e1f45e3c23d; the proxy path's leaf was afb6436c75d36fa32de9d6696deee6923eec955f9e046540ff234453b8897ab9. This establishes different observed TLS endpoints; it does not expose or prove the proxy operator's internal routing configuration.

Conclusion: the previously suggested ECH path does not work through the currently discovered ps1.blockme.site IPv4 pool with these valid CONNECT targets. This is stronger than the earlier three-node observation, but is not a claim about unknown proxy services/options or an unavailable current Chrome extension binary. No DNS-filter or VPS-routing implementation follows automatically from this result.

Artifacts: /Library/Zapret2/artifacts/rutracker-ech-audit-20261104/{matrix.go,snapshot.json,local.jsonl,vps.jsonl,retry-snapshot.json,vps-retry.jsonl}. 47 cases per location plus 3 targeted retry cases. Remote probe used a unique temporary directory and at most 3 simultaneous connections; it made no service/configuration changes and its temporary files were removed afterward.
