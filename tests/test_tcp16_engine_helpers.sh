#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
"${LUA:-lua}" tests/test_tcp16_engine_helpers.lua
