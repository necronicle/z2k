# z2k-classify — Linux-only, static, for Keenetic MIPS/ARM/x86 deploy.
#
# Build for specific target with cross toolchain (bol-van/musl-cross):
#   make CC=mipsel-linux-musl-gcc           # Keenetic MT7621
#   make CC=aarch64-linux-musl-gcc          # Keenetic KN-1010/KN-3610 ARM64
#   make CC=mips-linux-muslsf-gcc           # Keenetic KN-1910/2910 MIPS soft-float
#   make CC=arm-linux-musleabi-gcc          # older ARM Keenetics
#
# Binary is statically linked (needed for some Keenetic/Entware combos
# where glibc versions diverge) and stripped. Target size ≤ 60 KB.

BIN       := z2k-classify
SRC       := src/main.c src/probe.c src/classify.c src/templates.c src/state.c
INCLUDES  := -Isrc

CC        ?= cc
STRIP     ?= strip
OPTIMIZE  ?= -Os -flto=auto -ffunction-sections -fdata-sections
CFLAGS    += -std=c99 -Wall -Wextra -Wno-unused-parameter $(OPTIMIZE) $(INCLUDES)
LDFLAGS   += -static -Wl,--gc-sections -flto=auto

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)
	$(STRIP) $@ 2>/dev/null || true
	@ls -la $@

clean:
	rm -f $(BIN)

.PHONY: all clean
