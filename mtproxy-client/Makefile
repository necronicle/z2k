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

# ФОРМА СЕКРЕТА ПРОВЕРЯЕТСЯ ДО СБОРКИ.
#
# Значение подставляется прямо внутрь -ldflags="..." и дальше разбирается
# шеллом. Пробел, кавычка или точка с запятой внутри него разваливают команду,
# а в худшем случае исполняют её хвост. Секрет по контракту шестнадцатеричный,
# поэтому проверить это дешевле, чем экранировать: непохожее на hex значение —
# почти наверняка опечатка (лишний перевод строки из буфера обмена, кавычки от
# копирования), и остановиться на ней лучше, чем собрать нерабочее.
ifneq ($(Z2K_TUNNEL_SECRET),)
ifneq ($(shell printf '%s' '$(Z2K_TUNNEL_SECRET)' | grep -cE '^[0-9a-fA-F]+$$'),1)
$(error Z2K_TUNNEL_SECRET должен быть шестнадцатеричной строкой без пробелов и кавычек)
endif
endif

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
# Версия для HELLO релею: по умолчанию текущая из UPDATES.json (при релизе
# передавать явно: make all Z2K_BUILD_VERSION=r-82 Z2K_TUNNEL_SECRET=…).
Z2K_BUILD_VERSION ?= $(shell sed -n 's/.*"current": *"\([^"]*\)".*/\1/p' ../UPDATES.json 2>/dev/null | head -1)
GOFLAGS=-ldflags="-s -w -X main.defaultTunnelSecret=$(Z2K_TUNNEL_SECRET) -X main.buildVersion=$(Z2K_BUILD_VERSION)" -trimpath -buildvcs=false

# РЕЦЕПТЫ ПРИГЛУШЕНЫ (@) НЕ РАДИ ТИШИНЫ, А РАДИ СЕКРЕТА.
#
# make по умолчанию печатает команду перед исполнением — вместе с полностью
# раскрытым $(GOFLAGS), то есть с секретом туннеля открытым текстом. Отсюда он
# попадает в терминал, в скроллбэк, в журнал сборки и в лог CI, если сборка
# когда-нибудь туда переедет. Секрет один на весь флот: утёк — Telegram у всех
# надо перевыпускать.
#
# Поэтому каждый рецепт ниже начинается с @ и сам печатает, что собирает.
# Посмотреть настоящую команду по-прежнему можно: `make -n arm64` показывает
# всё как есть, но это осознанное действие, а не побочный эффект сборки.

# Список арок совпадает с тем, что реально лежит в builds/ и что умеет
# выбирать установщик (lib/install.sh, map_arch_to_bin_arch → tg_arch).
.PHONY: all arm64 arm mipsel mips mips64el amd64 x86 ppc64 riscv64 local clean

all: arm64 arm mipsel mips mips64el amd64 x86 ppc64 riscv64

arm64:
	@echo "  сборка arm64"
	@GOOS=linux GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-arm64

arm:
	@echo "  сборка arm"
	@GOOS=linux GOARCH=arm GOARM=7 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-arm

mipsel:
	@echo "  сборка mipsel"
	@GOOS=linux GOARCH=mipsle GOMIPS=softfloat $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-mipsel

mips:
	@echo "  сборка mips"
	@GOOS=linux GOARCH=mips GOMIPS=softfloat $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-mips

mips64el:
	@echo "  сборка mips64el"
	@GOOS=linux GOARCH=mips64le GOMIPS64=softfloat $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-mips64el

amd64:
	@echo "  сборка amd64"
	@GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-amd64

x86:
	@echo "  сборка x86"
	@GOOS=linux GOARCH=386 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-x86

ppc64:
	@echo "  сборка ppc64"
	@GOOS=linux GOARCH=ppc64 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-ppc64

riscv64:
	@echo "  сборка riscv64"
	@GOOS=linux GOARCH=riscv64 $(GO) build $(GOFLAGS) -o $(OUT)/$(BINARY)-linux-riscv64

# Локальная сборка для отладки — намеренно НЕ в builds/, чтобы отладочный
# бинарник не уехал людям.
#
# ВАЖНО: «не уехал» держится на .gitignore, и до 2026-08-15 НЕ держалось.
# Коммит 7a566cc сузил правило с `tg-mtproxy-client*` до
# `tg-mtproxy-client-linux-*` (чтобы разрешить коммит сборок в builds/), и
# голое имя, которое выпускает эта цель, выпало из покрытия. В корневом
# .gitignore при этом лежало правило под СТАРЫМ именем бинарника. То есть
# файл был просто untracked, и `git add -A` забрал бы его в публичный
# репозиторий — вместе с секретом, который сюда вшивается теми же GOFLAGS,
# если он экспортирован в окружении (`?=` унаследованное значение не
# перекрывает). У соседнего rt-proxy правило написано правильно, здесь —
# восстановлено.
local:
	@echo "  локальная отладочная сборка $(BINARY)"
	@$(GO) build $(GOFLAGS) -o $(BINARY)

clean:
	rm -f $(BINARY) $(BINARY)-linux-*
