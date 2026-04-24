# z2k-classify Makefile — native + static cross builds.
#
# Native (on macOS/Linux dev host):
#   make
#
# Cross build (one arch, assumes toolchain on PATH):
#   make CC=mipsel-linux-musl-gcc STATIC=1
#
# All-arch release (via GitHub Actions, see .github/workflows/build.yml
# in this repo — Phase 3 integration).

BIN       := z2k-classify
SRC       := src/main.c src/probe.c src/classify.c
INCLUDES  := -Isrc

CC        ?= cc
OPTIMIZE  ?= -Os -flto=auto -ffunction-sections -fdata-sections
CFLAGS    += -std=c99 -Wall -Wextra -Wno-unused-parameter $(OPTIMIZE) $(INCLUDES)

# Linux toolchains support --gc-sections + -static. macOS ld does not.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
  LDFLAGS += -Wl,--gc-sections
  ifeq ($(STATIC),1)
    LDFLAGS += -static
  endif
endif

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)
	@if command -v strip >/dev/null 2>&1; then strip $@ || true; fi
	@ls -la $@

# quick smoke test — probe a known-reachable domain (example.com)
test: $(BIN)
	./$(BIN) example.com
	./$(BIN) --json example.com

clean:
	rm -f $(BIN)

.PHONY: all clean test
