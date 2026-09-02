#!/bin/sh
# Reproducible static build of the z2k VPS relay for the Aeza box (linux/amd64).
#
# The relay is deployed BY HAND on the VPS — it is NOT shipped to the router
# fleet via UPDATES.json / auto-update (only the client binaries are). See
# README.md in this dir for the full deploy steps.
#
#   sh vps-relay/deploy/build.sh   ->   vps-relay/z2k-vps-relay  (linux/amd64 static)
set -e

cd "$(dirname "$0")/.."   # -> vps-relay/

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOTOOLCHAIN=local \
	go build -trimpath -ldflags="-s -w -X main.buildVersion=$(git describe --tags --always --dirty 2>/dev/null || echo unknown)" -o z2k-vps-relay .

echo "built: $(pwd)/z2k-vps-relay"
ls -la z2k-vps-relay
file z2k-vps-relay 2>/dev/null || true
