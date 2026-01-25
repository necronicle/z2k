# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**z2k (Zapret2 for Keenetic)** is a modular installer for zapret2 DPI bypass system, specifically designed for Keenetic routers running Entware on ARM64 architecture. This is a PRE-ALPHA project actively under development.

**Core Technology:**
- zapret2 (nfqws2) - DPI bypass using Lua-based packet manipulation strategies
- Multi-profile support with `--lua-desync=` functions
- Strategy database with 458 tested configurations
- Automated testing with blockcheck2 tool

**Target Platform:**
- Keenetic routers (ARM64/aarch64)
- Entware package system
- Shell scripts (POSIX sh)

## Build and Development Commands

### Running the Installer

```bash
# Quick install (downloads from GitHub)
curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/test/z2k.sh | sh

# Or locally
sh z2k.sh install

# Interactive menu
sh z2k.sh menu

# System status
sh z2k.sh status
```

### Testing

No formal test suite exists. Testing is done via:

```bash
# Test a specific strategy using blockcheck2
blockcheck2 --strategy="multisplit:pos=2:ttl=8" --host=www.youtube.com

# Run automated top-20 strategy test
# (via menu option [3])
sh z2k.sh menu
```

### Service Management

```bash
# Control zapret2 service
/opt/etc/init.d/S99zapret2 start|stop|restart|status

# Check running processes
ps | grep nfqws2

# View logs
tail -f /opt/var/log/zapret2.log
```

## Architecture

### Bootstrap System (z2k.sh)

The entry point (`z2k.sh`) is a lightweight bootstrap that:
1. Validates environment (Entware, architecture, curl)
2. Downloads all modules from GitHub to `/tmp/z2k/lib/`
3. Sources modules into memory
4. Downloads strategy databases and fake packet blobs
5. Handles command-line arguments

**Key Design:** Always downloads fresh modules from GitHub - ensures up-to-date code.

### Installation Strategy (Branch: install_easy)

**NEW APPROACH:** Uses official zapret2 installation scripts instead of duplicating logic:

1. **Download Full Release:** Downloads `openwrt-embedded.tar.gz` from GitHub releases
2. **Use install_bin.sh:** Calls official `install_bin.sh` for binary installation
   - Automatic architecture detection (via ELF header analysis, bash/zsh tests)
   - Binary validation (runs test before installation)
   - Installs all binaries: nfqws2, ip2net, mdig with proper symlinks
3. **Preserve Full Structure:** Keeps common/, lua/, files/, docs/ from official release
4. **Add z2k Customizations:** Overlays strats_new2.txt, quic_strats.ini, custom init script

**Why This Is Better:**
- ✅ No duplicated architecture detection logic
- ✅ Binary validation before installation (prevents "Illegal instruction")
- ✅ All tools installed (ip2net, mdig) not just nfqws2
- ✅ Access to common/ modules (base.sh, installer.sh) for future features
- ✅ Easier to maintain (updates track official zapret2)
- ✅ Backup/restore compatible with official scripts

### Module System

Six independent shell modules in `lib/`:

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| `utils.sh` | System utilities, checks, logging | `check_entware()`, `print_*()`, signal handlers |
| `install.sh` | 9-step installation process | `run_full_install()`, `step_install_zapret2()` |
| `strategies.sh` | Strategy parsing, testing, application | `generate_strategies_conf()`, `test_strategy()`, `apply_strategy()` |
| `config.sh` | Configuration management | Backup/restore, config file handling |
| `menu.sh` | Interactive TUI | Main menu, user interaction |
| `discord.sh` | Discord voice/video setup | UDP profile configuration |

**Module Loading:** All modules are loaded via `. ${LIB_DIR}/${module}.sh` in `z2k.sh`

### Strategy System

**Strategy Database Format (`strategies.conf`):**
```
NUMBER|TYPE|PARAMETERS
1|https|--lua-desync=multisplit:pos=2 --payload=tls_client_hello
341|https|--lua-desync=fakedsplit:pos=sniext+1:fakettl=8
```

**Source:** Generated from `strats_new2.txt` (458 real blockcheck2 test results for rutracker.org)

**QUIC Strategies:** Separate database in `quic_strategies.conf` from `quic_strats.ini`

**Application Flow:**
1. User selects strategy by number (1-458) or runs auto-test
2. Strategy parameters fetched from database
3. TCP + UDP profiles generated (multi-profile)
4. Injected into init script between markers
5. Service restarted

### Init Script Injection

The init script (`/opt/etc/init.d/S99zapret2`) uses marker-based injection:

```bash
# STRATEGY_MARKER_START
# TCP and UDP profiles injected here by strategies.sh
# STRATEGY_MARKER_END

# DISCORD_MARKER_START
# Discord-specific config (if enabled)
# DISCORD_MARKER_END
```

**Critical:** Always use markers - direct editing breaks automation.

### Multi-Profile Architecture

zapret2 supports multiple profiles in a single process:

```bash
nfqws2 --qnum=200 \
  # Profile 1: YouTube
  --lua-desync=multisplit:pos=2 --hostlist=youtube.txt --new \
  # Profile 2: Discord
  --lua-desync=fakedsplit:pos=sniext+1:fakettl=8 --hostlist=discord.txt --new \
  # Profile 3: Default
  --lua-desync=fake:ttl=5:blob=fake_default_tls
```

Each `--new` separator creates an independent profile with its own filters and strategy.

## Key Technical Concepts

### Zapret1 vs Zapret2

**Zapret1 (nfqws1):** Used `--dpi-desync=split2` with fixed C functions
**Zapret2 (nfqws2):** Uses `--lua-desync=multisplit:pos=2` with Lua-programmable strategies

**Migration:** See `zapret1-to-zapret2-migration-plan.md` for conversion table

### DPI Bypass Techniques

Core techniques in zapret2:

- **wssize** - TCP window size manipulation to force segmentation
- **multisplit** - Sequential packet segmentation
- **multidisorder** - Reverse-order packet sending
- **fakedsplit** - Fake packets + real data in reverse order
- **fake** - Standalone fake packet injection
- **syndata** - Data in TCP SYN packet

### Positioning Markers

Strategies use position markers for precise splitting:

- **Numeric:** `pos=1`, `pos=2` - byte offset
- **SNI-relative:** `sniext`, `sniext+1` - relative to SNI extension start
- **Host-relative:** `host`, `midsld`, `endhost-1` - relative to domain name

Example: `pos=sniext+1` splits 1 byte after SNI extension start

### Fake Packet Blobs

zapret2 has built-in fake packet payloads:
- `fake_default_tls` - TLS ClientHello for HTTPS
- `fake_default_quic` - QUIC Initial for HTTP/3

Custom blobs: `blob=0x<hexdata>` or `blob=<path>`

## File Structure

```
/opt/zapret2/              # Main installation
├── nfq2/nfqws2           # Core binary
├── lua/                  # Lua libraries for nfqws2
├── files/fake/           # Fake packet blobs (~45 .bin files)
└── lists/                # Domain lists (from zapret4rocket)
    ├── discord.txt
    ├── youtube.txt
    └── custom.txt

/opt/etc/zapret2/         # Configuration
├── strategies.conf       # 458 TCP strategies
├── quic_strategies.conf  # QUIC/UDP strategies
├── current_strategy      # Active strategy number
└── backups/              # Config backups

/opt/etc/init.d/S99zapret2  # Service init script
```

## Important Constraints

### Platform-Specific

- **ARM64 only:** Pre-built binaries for aarch64
- **Entware required:** Package manager must be installed
- **Keenetic-specific:** Hardware NAT disable, system checks

### Strategy Database

- **458 strategies:** All HTTPS strategies from blockcheck2 rutracker.org tests
- **Source file:** `strats_new2.txt` format: `curl_test_https_tls13 ipv4 rutracker.org : nfqws2 <params>`
- **Parsing:** Delimiter is ` : ` (space-colon-space), not `:` alone (parameters contain colons)

### Init Script Markers

**NEVER** manually edit between markers - use `apply_strategy()` function:

```bash
# Correct
apply_strategy "$strategy_num"

# Wrong - breaks automation
vi /opt/etc/init.d/S99zapret2
```

## Common Development Tasks

### Adding a New Strategy

1. Add to `strats_new2.txt` or `quic_strats.ini`
2. Regenerate config: `generate_strategies_conf()`
3. Test: `test_strategy "$num"`
4. Apply: `apply_strategy "$num"`

### Adding a New Module

1. Create `lib/newmodule.sh`
2. Add to `MODULES` variable in `z2k.sh:18`
3. Bootstrap will auto-download and source

### Modifying Init Script Template

Template is in `lib/install.sh:create_init_script_template()`

Markers to preserve:
- `# STRATEGY_MARKER_START` / `# STRATEGY_MARKER_END`
- `# DISCORD_MARKER_START` / `# DISCORD_MARKER_END`

### Testing Strategy Changes

```bash
# Manual test
nfqws2 --qnum=200 --lua-desync=<your_strategy> --payload=tls_client_hello &
curl -v https://rutracker.org

# Automated test
blockcheck2 --strategy="<your_strategy>" --host=rutracker.org --attempts=10
```

## Git Workflow

Current branch: `test` (development)
Main branch: `master` (stable releases)

This is PRE-ALPHA - active development on `test` branch.

## Critical Files to Understand

1. **z2k.sh** - Bootstrap entry point, module loading
2. **lib/strategies.sh** - Strategy database parsing and application logic
3. **lib/install.sh** - 9-step installation, init script template
4. **strats_new2.txt** - Source database of 458 strategies
5. **zapret2-strategy-development-guide.md** - Deep dive into zapret2 Lua functions

## Related Documentation

- `README.md` - User-facing documentation
- `zapret1-to-zapret2-migration-plan.md` - Zapret1 → Zapret2 migration guide
- `zapret2-strategy-development-guide.md` - Strategy development reference
- `manual.en.md` - Full zapret2 manual

## External Dependencies

- **zapret2 upstream:** https://github.com/bol-van/zapret2
- **zapret4rocket (z4r):** https://github.com/IndeecFOX/zapret4rocket (domain lists source)
- **blockcheck2:** Testing tool (from zapret2 repo)
