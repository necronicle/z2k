module github.com/necronicle/z2k/z2k-warpd

go 1.25.12

require (
	github.com/florianl/go-nflog/v2 v2.3.0
	github.com/florianl/go-nfqueue/v2 v2.1.0
	golang.org/x/crypto v0.55.0
	golang.org/x/net v0.58.0
	golang.zx2c4.com/wireguard v0.0.0-20260522210424-ecfc5a8d5446
)

require (
	github.com/google/go-cmp v0.7.0 // indirect
	github.com/mdlayher/netlink v1.11.2 // indirect
	github.com/mdlayher/socket v0.6.0 // indirect
	golang.org/x/sync v0.22.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.41.0 // indirect
	golang.zx2c4.com/wintun v0.0.0-20230126152724-0fa3db229ce2 // indirect
)

// Копия с двумя правками про память; см. third_party/wireguard/Z2K-PATCHES.md.
replace golang.zx2c4.com/wireguard => ./third_party/wireguard
