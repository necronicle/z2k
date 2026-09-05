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

.PHONY: all arm64 arm mipsel mips x86_64 local clean aliases

all: arm64 arm mipsel mips x86_64 aliases

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

# ВРЕМЕННЫЕ СИНОНИМЫ ИМЁН (05.09.2026, подлежат удалению).
#
# Шаг обновления бинарников до p-82.8 искал сборки по ГОШНОМУ написанию арки
# (mipsle, mips64le, 386), а файлы названы по-энтварному. На этих арках он не
# находил ничего, и бинарники не обновлялись никогда. Исправленный апдейтер
# приезжает роутерам только сейчас, а применять обновление будет ещё старый —
# поэтому те же файлы отгружаются вторым именем, тем, которое он ищет.
#
# КОПИРУЕМ, А НЕ ПЕРЕСОБИРАЕМ: содержимое обязано совпадать побайтово, иначе
# сверка воспроизводимости в CI покраснеет.
#
# Удалить вместе со строками в build-matrix.tsv, когда исправленный апдейтер
# будет у всех.
aliases: mipsel
	@echo "  синонимы имён (временно)"
	@cp -f $(BINARY)-linux-mipsel $(BINARY)-linux-mipsle
