BINARY=tg-mtproxy-client
# Сборка идёт СРАЗУ в builds/ — оттуда её качает установщик
# (lib/install.sh: "${GITHUB_RAW}/mtproxy-client/builds/${tg_bin}").
# Раньше вывод падал в текущий каталог, и файл требовалось скопировать в builds/
# руками. Шаг ручной, значит рано или поздно пропускается: на момент правки в
# mtproxy-client/ лежал arm64 от 17 апреля, а в builds/ — от 5 июля, и доезжал
# до людей второй. Тот же дрейф уже ловили у rt-proxy, там на него написан
# сторож tests/test_rt_proxy_binary_drift.sh; здесь такого не было.
OUT=builds

# Tunnel secret is injected at BUILD time and is NOT committed to source.
# Provide it on the command line for production builds:
#   make all Z2K_TUNNEL_SECRET=<hex>
# An empty value builds a binary that REQUIRES --tunnel-secret at runtime (the
# router supplies it from /opt/zapret2/config Z2K_RELAY_SECRET when set).
Z2K_TUNNEL_SECRET ?=

# Тулчейн пинится, как в rt-proxy/Makefile и z2k-detect/Makefile: Go 1.26+
# неверно компилирует MIPS soft-float на этих роутерах. До этой правки здесь
# брался системный go, то есть сборка на машине с новым Go молча выдавала
# битые бинарники под mips/mipsel.
GO ?= $(HOME)/go/bin/go1.25.12

# -trimpath — не косметика: без него в бинарник попадают локальные абсолютные
# пути, сборка перестаёт быть воспроизводимой и «пересобрать и сверить sha»
# как способ проверки релиза не работает.
# -buildvcs=false — иначе Go вшивает ревизию git и признак «грязного» дерева,
# и одни и те же исходники дают разные байты до и после коммита.
GOFLAGS=-ldflags="-s -w -X main.defaultTunnelSecret=$(Z2K_TUNNEL_SECRET)" -trimpath -buildvcs=false

# Список арок совпадает с тем, что реально лежит в builds/ и что умеет
# выбирать установщик (lib/install.sh, map_arch_to_bin_arch → tg_arch).
.PHONY: all arm64 arm mipsel mips mips64el amd64 x86 ppc64 riscv64 local clean

all: arm64 arm mipsel mips mips64el amd64 x86 ppc64 riscv64

arm64:
	GOOS=linux GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-arm64

arm:
	GOOS=linux GOARCH=arm GOARM=7 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-arm

mipsel:
	GOOS=linux GOARCH=mipsle GOMIPS=softfloat $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-mipsel

mips:
	GOOS=linux GOARCH=mips GOMIPS=softfloat $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-mips

mips64el:
	GOOS=linux GOARCH=mips64le GOMIPS64=softfloat $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-mips64el

amd64:
	GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-amd64

x86:
	GOOS=linux GOARCH=386 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-x86

ppc64:
	GOOS=linux GOARCH=ppc64 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-ppc64

riscv64:
	GOOS=linux GOARCH=riscv64 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-riscv64

# Локальная сборка для отладки — намеренно НЕ в builds/, чтобы отладочный
# бинарник не уехал людям.
local:
	$(GO) build $(GOFLAGS) -o $(BINARY)

clean:
	rm -f $(BINARY) $(BINARY)-linux-*
