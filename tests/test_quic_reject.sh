#!/bin/sh
# tests/test_quic_reject.sh — отказ QUIC для «YouTube без QUIC» / «Весь QUIC через TCP»
# (files/lua/z2k-quic-reject.lua), обёртка над tests/test_quic_reject_lua.lua.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
"${LUA:-lua}" tests/test_quic_reject_lua.lua
