#!/bin/sh
# Local checks only: writes status.json and prints each alert once per half hour.
exec python3 "$(dirname "$0")/monitor.py" "$@"
