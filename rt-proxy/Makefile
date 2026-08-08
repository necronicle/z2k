BINARY=z2k-rt-proxy
# -trimpath is REQUIRED, not cosmetic: without it the build embeds local absolute
# paths, so `make` produced binaries that differed from the shipped ones and the
# release could not be reproduced/verified. Toolchain is pinned for the same reason —
# Go 1.26+ miscompiles MIPS soft-float on these routers.
GO ?= $(HOME)/go/bin/go1.25.12
# -buildvcs=false: without it Go stamps the git revision and dirty-flag INTO the binary,
# so the same source produces different bytes depending on whether it was built before or
# after the commit — which silently defeats "rebuild and compare md5" release verification.
GOFLAGS=-ldflags="-s -w" -trimpath -buildvcs=false

.PHONY: all arm64 arm mipsel mips x86_64 local clean

all: arm64 arm mipsel mips x86_64

arm64:
	GOOS=linux GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BINARY)-linux-arm64

arm:
	GOOS=linux GOARCH=arm GOARM=7 $(GO) build $(GOFLAGS) -o $(BINARY)-linux-arm

mipsel:
	GOOS=linux GOARCH=mipsle GOMIPS=softfloat $(GO) build $(GOFLAGS) -o $(BINARY)-linux-mipsel

mips:
	GOOS=linux GOARCH=mips GOMIPS=softfloat $(GO) build $(GOFLAGS) -o $(BINARY)-linux-mips

x86_64:
	GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BINARY)-linux-amd64

local:
	$(GO) build $(GOFLAGS) -o $(BINARY)

clean:
	rm -f $(BINARY) $(BINARY)-linux-*
