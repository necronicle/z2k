BINARY=tg-mtproxy-client

# Tunnel secret is injected at BUILD time and is NOT committed to source.
# Provide it on the command line for production builds:
#   make all Z2K_TUNNEL_SECRET=<hex>
# An empty value builds a binary that REQUIRES --tunnel-secret at runtime (the
# router supplies it from /opt/zapret2/config Z2K_RELAY_SECRET when set).
Z2K_TUNNEL_SECRET ?=
GOFLAGS=-ldflags="-s -w -X main.defaultTunnelSecret=$(Z2K_TUNNEL_SECRET)"

.PHONY: all arm64 clean

all: arm64

arm64:
	GOOS=linux GOARCH=arm64 go build $(GOFLAGS) -o $(BINARY)-linux-arm64

arm:
	GOOS=linux GOARCH=arm GOARM=7 go build $(GOFLAGS) -o $(BINARY)-linux-arm

mipsel:
	GOOS=linux GOARCH=mipsle GOMIPS=softfloat go build $(GOFLAGS) -o $(BINARY)-linux-mipsel

mips:
	GOOS=linux GOARCH=mips GOMIPS=softfloat go build $(GOFLAGS) -o $(BINARY)-linux-mips

x86_64:
	GOOS=linux GOARCH=amd64 go build $(GOFLAGS) -o $(BINARY)-linux-amd64

local:
	go build $(GOFLAGS) -o $(BINARY)

clean:
	rm -f $(BINARY) $(BINARY)-linux-*
