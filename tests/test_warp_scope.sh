#!/bin/sh
# Run the actual shell/NDM policy against a stateful netfilter adapter on macOS
# and CI; packet fixtures evaluate the installed rules, not source text.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || {
    printf '[SKIP] WARP policy packet fixtures (нет python3)\nPASSED: 0\nFAILED: 0\nSKIPPED: 1\n'
    exit 0
}
python3 "$ROOT/tests/warp_scope_test.py" "$ROOT"
