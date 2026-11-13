#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 tests/test_broad_udp_delivery.py
