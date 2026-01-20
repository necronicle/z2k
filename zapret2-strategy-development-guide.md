# Zapret2 Strategy Development Guide

## Table of Contents
1. [Introduction](#introduction)
2. [Understanding DPI Blocking](#understanding-dpi-blocking)
3. [nfqws2 Architecture](#nfqws2-architecture)
4. [DPI Bypass Techniques](#dpi-bypass-techniques)
5. [Marker System and Positioning](#marker-system-and-positioning)
6. [Parameter Sets](#parameter-sets)
7. [Strategy Composition](#strategy-composition)
8. [Orchestration Functions](#orchestration-functions)
9. [Testing with blockcheck2](#testing-with-blockcheck2)
10. [Best Practices](#best-practices)

---

## Introduction

Zapret2 represents a new generation of DPI bypass tools, utilizing Lua-based strategies through the `nfqws2` engine. Unlike its predecessor (nfqws1 with `--dpi-desync=`), Zapret2 uses `--lua-desync=` for flexible, programmable packet manipulation.

**Key Concepts:**
- All strategies are Lua functions
- Multi-profile support via `--new` parameter
- Built-in blobs: `fake_default_tls`, `fake_default_quic`
- Reassembly support for multi-packet payloads
- Advanced orchestration capabilities

---

## Understanding DPI Blocking

DPI systems analyze packet flows to detect and block specific protocols (HTTPS/TLS, QUIC). They typically:
- Reassemble TCP segments to extract complete TLS ClientHello
- Parse SNI (Server Name Indication) to identify target domains
- Apply blocking rules based on domain lists

**Bypass Strategy:**
- Prevent DPI from correctly reassembling/parsing packets
- Send malformed/fake packets to confuse DPI state machines
- Manipulate TCP/IP headers to make packets "invisible" to DPI

---

## nfqws2 Architecture

### Basic Usage
```bash
nfqws2 --qnum=200 --lua-desync=<function> [options]
```

### Multi-Profile Mode
```bash
nfqws2 --qnum=200 \
  --lua-desync=profile1_func --new \
  --lua-desync=profile2_func --new \
  --lua-desync=profile3_func
```

### Filters
- `--hostlist=<file>` - domain whitelist
- `--hostlist-exclude=<file>` - domain blacklist
- `--ipset=<name>` - IP set filter
- `--filter-tcp=80,443` - port filters
- `--filter-l7=tls,http` - L7 protocol filters

### Payload Specification
- `--payload=tls_client_hello` - TLS ClientHello packets
- `--payload=quic_initial` - QUIC Initial packets
- `--payload=http_request` - HTTP requests

---

## DPI Bypass Techniques

### 1. wssize - Window Size Manipulation
**Purpose:** Reduce TCP window size to force sender segmentation

```lua
wssize:wsize=1:scale=6
```

**Parameters:**
- `wsize` - new window size (1-65535)
- `scale` - window scale factor (0-14)

**How it works:** Modifies TCP window in ACK packets, forcing remote server to send smaller segments that may bypass DPI reassembly.

---

### 2. multidisorder - Packet Reordering
**Purpose:** Send TCP segments in reverse order to confuse DPI

```lua
multidisorder:pos=2:pktlen=1500
```

**Parameters:**
- `pos` - split position (numeric, marker-based)
- `pktlen` - maximum segment size
- `pktlen_method` - sizing algorithm: `DEFAULT`, `TSPACKET`, `TSPACKETMIN`
- `fooling_options` - fake segment parameters

**Order:** Segments sent in **reverse order** (last→first)

**Example:**
```
Original: [seg1][seg2][seg3]
DPI sees: [seg3][seg2][seg1] ← out of order, may fail to reassemble
```

---

### 3. multisplit - Packet Segmentation
**Purpose:** Split payload into multiple sequential segments

```lua
multisplit:pos=2:pktlen=1200
```

**Parameters:** Same as multidisorder

**Order:** Segments sent in **sequential order** (first→last)

**Use case:** When DPI has segment limits or timeout-based reassembly

---

### 4. fakedsplit - Fake + Real Segmentation
**Purpose:** Send fake segments followed by real data in reverse order

```lua
fakedsplit:pos=sniext+1:fakettl=8:fakeseq=-10000
```

**Parameters:**
- All `multidisorder` parameters
- `fake_options` - fake segment manipulation
- `fakettl` - TTL for fake packets (low = won't reach destination)
- `fakeseq` - sequence number offset for fakes
- `badsum` - bad TCP checksum
- `blob=<data>` - custom fake data

**Packet sequence:**
```
1. Fake segment (TTL=8, seq=X-10000)
2. Real segments in reverse order
```

---

### 5. fake - Direct Fake Packet Injection
**Purpose:** Send standalone fake packets before real data

```lua
fake:ttl=8:seq=-10000:blob=fake_default_tls
```

**Parameters:**
- `fake_options` - manipulation parameters
- `blob` - payload data (`fake_default_tls`, `fake_default_quic`, hex string)

**Use case:** Poison DPI state before sending real ClientHello

---

### 6. fakeddisorder - Fake + Disorder Combination
**Purpose:** Fake packets + real packets in reverse order (no splitting)

```lua
fakeddisorder:pos=1:fakettl=8
```

**Difference from fakedsplit:** No actual splitting of real data, just reordering whole payload

---

### 7. syndata - SYN Packet Data
**Purpose:** Send TLS ClientHello data within TCP SYN packet

```lua
syndata:split=1200
```

**Parameters:**
- `split` - size of data to include in SYN
- `reconstruct_options` - reassembly parameters

**Note:** Highly effective but requires raw socket support and proper TCP stack handling

---

### 8. tcpseg - Raw TCP Segmentation
**Purpose:** Fine-grained control over TCP segment construction

```lua
tcpseg:segs=2:pktlen=1200:fooling=ipttl:ttl=8
```

**Parameters:**
- `segs` - number of segments
- `pktlen` - segment size
- `rawsend_options` - raw packet construction
- `fooling=<technique>` - ipttl, tcp_ts_up, badsum, etc.

---

## Marker System and Positioning

### Numeric Positions
- `pos=1` - split at byte 1
- `pos=2` - split at byte 2
- `pos=10` - split at byte 10

### SNI-Relative Markers
- `sniext` - start of SNI extension
- `sniext+1` - 1 byte after SNI start
- `sniext+5` - 5 bytes after SNI start

### Host-Relative Markers (domain name within SNI)
- `host` - start of hostname
- `host+1` - 1 byte after hostname start
- `midsld` - middle of second-level domain
- `endhost-1` - 1 byte before hostname end

### Examples
For domain `www.youtube.com`:
- `host` → start of "www"
- `midsld` → middle of "youtube"
- `endhost-1` → before last char of "com"

---

## Parameter Sets

### fooling_options
Techniques to make fake packets "invisible" to endpoint:
- `ipttl=<N>` - set IP TTL (1-255), low values expire before destination
- `tcp_ts_up=<N>` - increase TCP timestamp
- `tcp_seq=<offset>` - modify sequence number
- `tcp_ack=<offset>` - modify ACK number
- `badsum` - invalid TCP checksum

### ipid_options
IP identification field control:
- `ipid=<N>` - set specific IPID
- `ipid_delta=<N>` - increment IPID

### ipfrag_options
IP fragmentation:
- `ipfrag` - enable fragmentation
- `ipfrag_len=<N>` - fragment size

### rawsend_options
Low-level packet construction:
- `ttl=<N>` - IP TTL
- `minttl=<N>` - minimum TTL
- `tcpopt=<flags>` - TCP options manipulation

### reconstruct_options
Packet reassembly control:
- `mode=NONE|CONNMARK|IPFRAG|UDPENCAP`
- `connmark=<N>` - connection mark value

---

## Strategy Composition

### Single Technique
```lua
--lua-desync=wssize:wsize=1:scale=6 --payload=tls_client_hello
```

### Chained Techniques
```lua
--lua-desync=wssize:wsize=1:scale=6 \
--lua-desync=multidisorder:pos=2
```

### Conditional Application
```lua
--lua-desync=condition:hostlist=youtube.txt \
--lua-desync=fakedsplit:pos=sniext+1:fakettl=8
```

---

## Orchestration Functions

### circular - Strategy Rotation
**Purpose:** Cycle through strategies on failures

```lua
circular:N:strategy1:strategy2:strategy3
```

**Parameters:**
- `N` - number of failures before switching
- Comma-separated strategy list

**Example:**
```lua
circular:3:fakedsplit:pos=2:fakettl=8,multidisorder:pos=sniext+1
```
After 3 failures with fakedsplit, switch to multidisorder

---

### repeater - Repeat Strategy
**Purpose:** Apply strategy multiple times

```lua
repeater:count=3:fake:ttl=8:blob=fake_default_tls
```

---

### condition - Conditional Execution
**Purpose:** Apply strategy only when filter matches

```lua
condition:hostlist=youtube.txt:fakedsplit:pos=2:fakettl=8
```

---

### stopif - Early Exit
**Purpose:** Stop processing if condition met

```lua
stopif:hostlist=whitelist.txt
```

---

## Testing with blockcheck2

### Basic Test
```bash
blockcheck2 --strategy="fakedsplit:pos=2:fakettl=8" --host=www.youtube.com
```

### Test Modes
- `curl_test_https_tls12` - HTTPS test with TLS 1.2
- `curl_test_https_tls13` - HTTPS test with TLS 1.3
- `curl_test_http3` - QUIC/HTTP3 test
- `curl_test_http` - HTTP test

### Automated Testing
```bash
blockcheck2 --auto --hostlist=test_domains.txt
```

**Output:** Success/failure rates, optimal strategies

### Parameters
- `--attempts=N` - number of test attempts
- `--timeout=N` - connection timeout
- `--threads=N` - parallel tests
- `--strategy-file=<path>` - test multiple strategies from file

---

## Best Practices

### 1. Start Simple
Begin with basic techniques:
```lua
wssize:wsize=1:scale=6
multidisorder:pos=2
```

### 2. Understand Your DPI
- Test different positions (pos=1, pos=2, pos=sniext+1)
- Vary fake packet TTL (4, 6, 8)
- Try different segment sizes (pktlen=1200, pktlen=1500)

### 3. Use Markers for Precision
SNI-relative positions are more reliable:
```lua
fakedsplit:pos=sniext+1:fakettl=8
```

### 4. Combine Techniques
```lua
wssize:wsize=1:scale=6
multidisorder:pos=2:pktlen=1200
```

### 5. Test Thoroughly
- Test both IPv4 and IPv6
- Test different domains (YouTube, Discord, etc.)
- Measure success rate over time

### 6. Use Autohostlist
Enable automatic failure detection:
```bash
--autohostlist --autohostlist-fail-threshold=3
```

### 7. Monitor Performance
- Check CPU usage (Lua strategies have overhead)
- Monitor connection delays
- Balance effectiveness vs. performance

### 8. Category-Based Strategies
Different services may need different strategies:
- **YouTube TCP:** Often needs multidisorder
- **QUIC/HTTP3:** May need syndata or specific UDP handling
- **General HTTPS:** fakedsplit with low TTL often works

### 9. Handle Edge Cases
- Large ClientHello (reassembly scenarios)
- ECN-marked packets
- Path MTU issues

### 10. Document Your Findings
Keep a log of:
- ISP/country
- Effective strategies
- Failure patterns
- Performance metrics

---

## Strategy Examples from Practice

### Example 1: YouTube TCP Bypass
```lua
--lua-desync=wssize:wsize=1:scale=6 \
--lua-desync=multidisorder:pos=2 \
--payload=tls_client_hello
```

### Example 2: Aggressive Fake Injection
```lua
--lua-desync=fakedsplit:pos=sniext+1:fakettl=6:fakeseq=-10000:badsum \
--payload=tls_client_hello
```

### Example 3: QUIC Bypass
```lua
--lua-desync=fake:ttl=4:blob=fake_default_quic \
--payload=quic_initial
```

### Example 4: Multi-Profile Setup
```lua
# Profile 1: YouTube
--lua-desync=multidisorder:pos=2 --hostlist=youtube.txt --new \
# Profile 2: Discord
--lua-desync=fakedsplit:pos=sniext+1:fakettl=8 --hostlist=discord.txt --new \
# Profile 3: Everything else
--lua-desync=wssize:wsize=1:scale=6
```

---

## Troubleshooting

### Strategy Not Working
1. **Verify DPI is active:** Test without nfqws2
2. **Check filters:** Ensure hostlist/ipset matches target
3. **Try different positions:** pos=1,2,sniext+1,midsld
4. **Adjust TTL:** Try fakettl=4,6,8,10
5. **Check logs:** `--debug=all` for detailed output

### Performance Issues
1. **Reduce Lua overhead:** Use simpler strategies
2. **Limit hostlists:** Smaller lists = faster matching
3. **Use ipsets:** More efficient than hostlists for large sets
4. **Profile-specific strategies:** Don't apply aggressive techniques to all traffic

### Inconsistent Results
1. **DPI learning:** Some DPIs adapt, rotate strategies
2. **Network path changes:** Different routes = different DPI
3. **Time-based blocking:** Test at different times of day
4. **Use circular:** Automatic strategy rotation on failures

---

## Conclusion

Successful strategy development requires:
- Understanding DPI behavior in your network
- Systematic testing with blockcheck2
- Iterative refinement based on results
- Balance between effectiveness and performance

Start simple, test thoroughly, and adapt based on real-world results.
