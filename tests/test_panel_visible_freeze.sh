#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
node tests/test_panel_visible_freeze.js
