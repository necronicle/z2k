# z2k-verify — проверяльщик подписи манифеста.
#
# Тулчейн пиннится так же, как у остальных модулей: не 1.26.x, там ловили
# _ENOSYS на MIPS (golang/go#77730).
GO ?= $(HOME)/go/bin/go1.25.12
PKG = ./cmd/z2k-verify
OUTDIR = builds

# ARM только GOARM=5. У mtproxy-client стоит 7, и разнобой здесь опаснее, чем
# кажется: собрали бы под 7, а поехало бы на ARMv5 без VFP — и проверяльщик
# падал бы с illegal instruction, что при защёлкнутом храповике означает
# «обновления встали» на всей этой части парка.
ARCHES = linux-amd64 linux-arm64 linux-arm linux-mipsle linux-mips linux-mips64le linux-ppc64 linux-riscv64 linux-386

# -s -w: символы и отладка не нужны, а место на роутере нужно.
# -trimpath -buildvcs=false: сборка воспроизводима — тот же исходник и тот же
# тулчейн дают тот же байт-в-байт файл. Без этого CI-гейт на дайджест
# (см. tests/test_verifier_pin.sh) краснел бы от каждой пересборки.
BUILDFLAGS = -ldflags="-s -w" -trimpath -buildvcs=false

.PHONY: all clean $(ARCHES)

all: $(ARCHES)

linux-amd64:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)
linux-arm64:
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)
linux-arm:
	GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)
linux-mipsle:
	GOOS=linux GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)
linux-mips:
	GOOS=linux GOARCH=mips GOMIPS=softfloat CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)
linux-mips64le:
	GOOS=linux GOARCH=mips64le GOMIPS64=softfloat CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)
linux-ppc64:
	GOOS=linux GOARCH=ppc64 CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)
linux-riscv64:
	GOOS=linux GOARCH=riscv64 CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)
linux-386:
	GOOS=linux GOARCH=386 CGO_ENABLED=0 $(GO) build $(BUILDFLAGS) -o $(OUTDIR)/z2k-verify-$@ $(PKG)

clean:
	rm -f $(OUTDIR)/z2k-verify-linux-*
