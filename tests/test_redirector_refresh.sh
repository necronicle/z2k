#!/bin/sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 "$ROOT/tests/redirector_refresh_cases.py" "$ROOT"
