#!/bin/sh
# z2k-fix-tg-watchdog.sh
#
# HISTORICAL HOTFIX — NOW A NO-OP.
#
# This was a standalone one-shot `curl | sh` patcher that, back when it
# shipped, upgraded an existing z2k install to the active-probe Telegram
# watchdog and added the OUTPUT-chain REDIRECT rules.
#
# Its embedded heredoc copies of S98tg-tunnel and the watchdog have since
# fallen FAR behind the shipped files and are now strictly WORSE:
#   - raw iptables WITHOUT the -w lock-wait flag (silent EBUSY under NDM
#     netfilter regen → a rule is dropped, TG falls off ~30 min later);
#   - per-CIDR REDIRECT rules instead of the ipset path that survives an
#     NDM chain wipe (project_tg_redirect_ipset);
#   - `killall -9 tg-mtproxy-client` that also kills the cdnbase
#     http-tunnel sibling on :1444 (reference_cdnbase_http_tunnel);
#   - no supervisor respawn loop (the shipped S98tg-tunnel has one).
#
# Running the old heredocs would DOWNGRADE a healthy install. So this
# script no longer overwrites anything — it just tells the user to update
# z2k through the normal path, which ships the current, correct files.
#
# Usage (kept for the published `curl | sh` URL, now harmless):
#   curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/files/z2k-fix-tg-watchdog.sh | sh

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

say() { printf '%s\n' "$*"; }

say "z2k-fix-tg-watchdog.sh is no longer needed and does nothing."
say ""
say "The Telegram-tunnel watchdog and S98tg-tunnel fixes it used to apply"
say "are now part of the normal z2k release. This one-shot patcher carried"
say "stale copies that would DOWNGRADE a current install (raw iptables"
say "without -w, per-CIDR REDIRECT instead of ipset, and a killall that"
say "also kills the cdnbase :1444 tunnel), so it has been disabled."
say ""
say "To pick up the latest fixes, update z2k the normal way:"
say "  - menu:     run z2k and press [U] (Update)"
say "  - webpanel: click the Update button in the header"
say ""
say "No files were changed."
exit 0
