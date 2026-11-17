# Retire static redirector DNS

Date: 2026-11-18. Branch: z2k-staging. Owner authorized urgent p-88 release.

## User scenario and requirements

- R1: remove VPS resolve/pinning; never add redirector DNS records again.
- R2: delete and save all `ip host redirector.googlevideo.com ADDRESS` records,
  irrespective of the obsolete opt-out; preserve every other hostname.
- R3: coordinate with a legacy writer using its existing flock, verify reads
  and deletion, restore records on failure, make repeated runs harmless.
- R4: install, nightly task and old-updater post-success delivery run cleanup.
  Keep the old worker pathname only as a cleanup compatibility entrypoint;
  the old config key cannot enable pinning.
- R5: signed release, rehearsal, full suite, CI, publication and public signature
  verification. No service restart or relay/infrastructure change.
- R6: copy a read-only Instagram/fbcdn address probe into the clipboard.

## Acceptance and verification

R1-R3: real shell worker and recording NDM boundary; multiple IPv4/IPv6 records,
other Googlevideo and Instagram records, read/delete/save failures, lock and repeat.
R4: old-updater delivery test plus existing installer/nightly hooks.
R5: release script/rehearsal, suite, CI/publication and public signed files.
R6: shell syntax and clipboard readback. No promise that removing old pins fixes
every YouTube issue; actual client behavior needs a separate comparison.
