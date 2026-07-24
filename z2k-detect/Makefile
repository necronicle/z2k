# z2k-detect cross-compile Makefile.
# Builds stripped, trimpath'd binaries for every OpenWrt arch we ship.

GO         ?= $(HOME)/go/bin/go1.22.12
BUILDFLAGS = -ldflags="-s -w" -trimpath
PKG        = ./cmd/z2k-detect
OUTDIR     = builds

ARCHES = linux-amd64 linux-arm64 linux-arm linux-mipsle linux-mips linux-mips64le linux-ppc64 linux-riscv64 linux-386

.PHONY: all clean $(ARCHES)

all: $(ARCHES)

$(OUTDIR):
	mkdir -p $(OUTDIR)

linux-amd64: | $(OUTDIR)
	GOOS=linux GOARCH=amd64 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

linux-arm64: | $(OUTDIR)
	GOOS=linux GOARCH=arm64 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

linux-arm: | $(OUTDIR)
	GOOS=linux GOARCH=arm GOARM=5 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

linux-mipsle: | $(OUTDIR)
	GOOS=linux GOARCH=mipsle GOMIPS=softfloat $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

linux-mips: | $(OUTDIR)
	GOOS=linux GOARCH=mips GOMIPS=softfloat $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

linux-mips64le: | $(OUTDIR)
	GOOS=linux GOARCH=mips64le GOMIPS64=softfloat $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

linux-ppc64: | $(OUTDIR)
	GOOS=linux GOARCH=ppc64 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

linux-riscv64: | $(OUTDIR)
	GOOS=linux GOARCH=riscv64 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

linux-386: | $(OUTDIR)
	GOOS=linux GOARCH=386 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-detect-$@ $(PKG)

clean:
	rm -rf $(OUTDIR)
