BINARY=z2k-warpd
# -trimpath и -buildvcs=false обязательны: без них в бинарь попадают локальные
# пути и git-ревизия, и сверка отгруженных байтов с пересборкой не сходится.
# Тулчейн пинован: Go 1.26+ неверно собирает MIPS soft-float под эти роутеры.
GO ?= $(HOME)/go/bin/go1.25.12
GOFLAGS=-ldflags="-s -w" -trimpath -buildvcs=false
PKG=./cmd/z2k-warpd

.PHONY: all arm64 arm mipsel mips x86_64 local test clean

all: arm64 arm mipsel mips x86_64

arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-arm64 $(PKG)

arm:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-arm $(PKG)

mipsel:
	CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-mipsel $(PKG)

mips:
	CGO_ENABLED=0 GOOS=linux GOARCH=mips GOMIPS=softfloat $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-mips $(PKG)

x86_64:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -o builds/$(BINARY)-linux-amd64 $(PKG)

local:
	$(GO) build $(GOFLAGS) -o $(BINARY) $(PKG)

test:
	$(GO) test ./...

clean:
	rm -f $(BINARY) builds/$(BINARY)-linux-*
