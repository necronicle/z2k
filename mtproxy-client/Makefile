BINARY=tg-mtproxy-client
GOFLAGS=-ldflags="-s -w"

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
