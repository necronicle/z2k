# Verification: redirector DNS retirement

Release: p-88.7, signed manifest sequence 188.
Runtime commit: 028faaebccbb2292beed7ef57c7bb9e24bca3547.

- R1-R3: retirement regression observed failing against the old worker because
  it attempted a network operation; replacement passes exact-host cleanup,
  both legacy toggle values, empty repeat, read/delete/save failure, rollback,
  kernel-lock contention and post-success marker tests.
- R4: published p-87.12 updater delivers the new runner and worker. Provisioning
  tests cover p-87.12 and p-87.15 with/without flock and package failure (21/21).
  Install/nightly entrypoints retain the old pathname solely for cleanup.
- R5: local release suite passed after resolving a function-name audit collision;
  isolated p-88.6 -> p-88.7 rehearsal converged, five files, steps `[]`.
  [CI](https://github.com/necronicle/z2k/actions/runs/44178826615) and
  [publication](https://github.com/necronicle/z2k/actions/runs/44180186229)
  both succeeded. Public tag, raw production and jsDelivr production manifest
  signatures verified with the shipped Ed25519 public key; seq=188. Public
  worker SHA-256 matches the manifest.
- Real Keenetic: executing the candidate cleanup removed 18 legacy records;
  other ip-host rows and nfqws2/Telegram PIDs were unchanged. Subsequently the
  normal signed updater installed p-88.6 -> p-88.7 from the public channel;
  health check passed. Final state: no redirector pins, other hosts unchanged,
  original process PIDs retained. No service restart was requested.
- R6: read-only probe copied with shell syntax/readback checks; after discovering
  terminal line truncation, probes and the separately authorized Instagram repair
  were split into complete lines. Final repair has 22 lines, maximum 171 chars,
  validated with simulated working/unavailable candidates. Candidate Meta IPs
  were probed from the owner's router before being offered to the user.

Public GitHub Raw briefly served p-88.6 after branch promotion. It subsequently
served p-88.7; both main delivery endpoints and the ordinary control update were
verified after that refresh. No unresolved release requirement remains.
