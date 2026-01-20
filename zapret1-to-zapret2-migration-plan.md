# Zapret1 to Zapret2 Migration Plan

## Table of Contents
1. [Migration Overview](#migration-overview)
2. [Key Architectural Differences](#key-architectural-differences)
3. [Parameter Conversion Table](#parameter-conversion-table)
4. [Function Mapping](#function-mapping)
5. [Legacy Compatibility](#legacy-compatibility)
6. [Migration Methodology](#migration-methodology)
7. [Testing Migrated Strategies](#testing-migrated-strategies)
8. [Common Migration Scenarios](#common-migration-scenarios)
9. [Troubleshooting](#troubleshooting)

---

## Migration Overview

**Zapret1 (nfqws1)** and **Zapret2 (nfqws2)** represent different architectural approaches to DPI bypass:

| Aspect | Zapret1 (nfqws1) | Zapret2 (nfqws2) |
|--------|------------------|------------------|
| **Strategy format** | `--dpi-desync=<method>` | `--lua-desync=<function>` |
| **Engine** | Built-in C functions | Lua-based scripting |
| **Flexibility** | Fixed parameter sets | Programmable logic |
| **Multi-profile** | Not supported | Native support via `--new` |
| **Blobs** | External files | Built-in: fake_default_tls, fake_default_quic |
| **Reassembly** | Limited | Advanced reasm support |

**Migration Goal:** Convert existing Zapret1 strategies to Zapret2 without losing functionality, while leveraging new capabilities.

---

## Key Architectural Differences

### 1. Command-Line Interface

**Zapret1:**
```bash
nfqws --qnum=200 --dpi-desync=split2 --dpi-desync-ttl=5
```

**Zapret2:**
```bash
nfqws2 --qnum=200 --lua-desync=multisplit:pos=2:ttl=5
```

### 2. Strategy Definition

**Zapret1:** Fixed desync methods with predefined parameters
- `split`, `split2`, `disorder`, `disorder2`
- Parameters controlled via separate flags

**Zapret2:** Lua functions with inline parameters
- `multisplit`, `multidisorder`, `fake`, `fakedsplit`
- All parameters specified within function call

### 3. Fake Packet Handling

**Zapret1:**
```bash
--dpi-desync=fake --dpi-desync-ttl=5 --dpi-desync-fake-payload=/path/to/fake.bin
```

**Zapret2:**
```bash
--lua-desync=fake:ttl=5:blob=fake_default_tls
# OR
--lua-desync=fake:ttl=5:blob=0x160301...
```

### 4. Multi-Profile Support

**Zapret1:** Single strategy per nfqws instance
```bash
nfqws --qnum=200 --dpi-desync=split2
```

**Zapret2:** Multiple profiles in one instance
```bash
nfqws2 --qnum=200 \
  --lua-desync=profile1 --hostlist=youtube.txt --new \
  --lua-desync=profile2 --hostlist=discord.txt --new \
  --lua-desync=profile3
```

---

## Parameter Conversion Table

### Core Parameters

| Zapret1 | Zapret2 | Notes |
|---------|---------|-------|
| `--dpi-desync=split` | `--lua-desync=multisplit:pos=1` | Basic split at position 1 |
| `--dpi-desync=split2` | `--lua-desync=multisplit:pos=2` | Split at position 2 |
| `--dpi-desync=disorder` | `--lua-desync=multidisorder:pos=1` | Disorder at position 1 |
| `--dpi-desync=disorder2` | `--lua-desync=multidisorder:pos=2` | Disorder at position 2 |
| `--dpi-desync-ttl=N` | `:ttl=N` | Inline TTL parameter |
| `--dpi-desync-fooling=badsum` | `:badsum` | Inline fooling option |
| `--dpi-desync-fooling=md5sig` | `:fooling=md5sig` | MD5 signature fooling |
| `--dpi-desync-fake-payload=<file>` | `:blob=<hex_or_builtin>` | Blob data |

### Fooling Options

| Zapret1 | Zapret2 | Description |
|---------|---------|-------------|
| `--dpi-desync-fooling=ipttl` | `:ipttl=N` | IP TTL manipulation |
| `--dpi-desync-fooling=badsum` | `:badsum` | Bad TCP checksum |
| `--dpi-desync-fooling=ts` | `:tcp_ts_up=N` | TCP timestamp increase |

### Advanced Parameters

| Zapret1 | Zapret2 | Description |
|---------|---------|-------------|
| `--wssize=N:M` | `--lua-desync=wssize:wsize=N:scale=M` | Window size manipulation |
| `--dpi-desync-autottl=N` | Auto-TTL detection (no direct equivalent) | Use blockcheck2 instead |

---

## Function Mapping

### 1. split → multisplit

**Zapret1:**
```bash
--dpi-desync=split2 --dpi-desync-ttl=8
```

**Zapret2:**
```bash
--lua-desync=multisplit:pos=2:ttl=8
```

**Additional Zapret2 options:**
```bash
--lua-desync=multisplit:pos=2:pktlen=1200:ttl=8
```

---

### 2. disorder → multidisorder

**Zapret1:**
```bash
--dpi-desync=disorder2 --dpi-desync-fooling=badsum
```

**Zapret2:**
```bash
--lua-desync=multidisorder:pos=2:badsum
```

**With legacy compatibility:**
```bash
--lua-desync=multidisorder_legacy:pos=2:badsum
```

---

### 3. fake → fake / fakedsplit

**Zapret1 (standalone fake):**
```bash
--dpi-desync=fake --dpi-desync-ttl=5 --dpi-desync-fake-payload=fake_tls.bin
```

**Zapret2:**
```bash
--lua-desync=fake:ttl=5:blob=fake_default_tls
```

**Zapret1 (fake + split):**
```bash
--dpi-desync=fake,split2 --dpi-desync-ttl=5
```

**Zapret2:**
```bash
--lua-desync=fakedsplit:pos=2:fakettl=5
```

---

### 4. syndata → syndata

**Zapret1:**
```bash
--dpi-desync=syndata --dpi-desync-split-tls=1200
```

**Zapret2:**
```bash
--lua-desync=syndata:split=1200
```

---

### 5. wssize → wssize

**Zapret1:**
```bash
--wssize=1:6
```

**Zapret2:**
```bash
--lua-desync=wssize:wsize=1:scale=6
```

---

## Legacy Compatibility

### multidisorder_legacy Function

Zapret2 includes `multidisorder_legacy` specifically for nfqws1 compatibility.

**When to use:**
- Migrating existing disorder/disorder2 strategies
- Need exact same behavior as Zapret1
- Troubleshooting migration issues

**Example:**
```bash
# Zapret1
--dpi-desync=disorder2

# Zapret2 (native)
--lua-desync=multidisorder:pos=2

# Zapret2 (legacy mode)
--lua-desync=multidisorder_legacy:pos=2
```

**Differences:**
- `multidisorder`: Modern implementation with optimizations
- `multidisorder_legacy`: Bug-for-bug compatible with nfqws1

**Recommendation:** Start with `multidisorder_legacy` during migration, then test `multidisorder` for potential improvements.

---

## Migration Methodology

### Phase 1: Inventory

**Step 1.1:** Document all Zapret1 configurations
```bash
# List all nfqws processes
ps aux | grep nfqws

# Check startup scripts
cat /etc/init.d/zapret
cat /opt/zapret/config
```

**Step 1.2:** Extract strategy parameters
For each nfqws instance, note:
- `--dpi-desync=<method>`
- `--dpi-desync-ttl=<N>`
- `--dpi-desync-fooling=<options>`
- `--dpi-desync-fake-payload=<file>`
- Filter parameters (hostlist, ports, etc.)

**Step 1.3:** Create migration spreadsheet

| Instance | Desync Method | TTL | Fooling | Fake Payload | Filters | Priority |
|----------|---------------|-----|---------|--------------|---------|----------|
| youtube | split2 | 8 | badsum | - | youtube.txt | High |
| discord | disorder2 | 5 | - | - | discord.txt | Medium |

---

### Phase 2: Conversion

**Step 2.1:** Convert each strategy using conversion table

**Example conversion:**
```bash
# Zapret1
nfqws --qnum=200 --dpi-desync=split2 --dpi-desync-ttl=8 \
  --dpi-desync-fooling=badsum --hostlist=/opt/zapret/youtube.txt

# Zapret2
nfqws2 --qnum=200 \
  --lua-desync=multisplit:pos=2:ttl=8:badsum \
  --hostlist=/opt/zapret/youtube.txt \
  --payload=tls_client_hello
```

**Step 2.2:** Handle fake payloads

If Zapret1 used custom fake payloads:
```bash
# Convert binary file to hex
xxd -p -c 0 fake_tls.bin > fake_tls.hex

# Use in Zapret2
--lua-desync=fake:ttl=5:blob=0x$(cat fake_tls.hex)
```

Or use built-in blobs:
```bash
--lua-desync=fake:ttl=5:blob=fake_default_tls
```

**Step 2.3:** Consolidate multi-profile setups

If Zapret1 used multiple nfqws instances:
```bash
# Zapret1: 3 separate processes
nfqws --qnum=200 --dpi-desync=split2 --hostlist=youtube.txt
nfqws --qnum=201 --dpi-desync=disorder2 --hostlist=discord.txt
nfqws --qnum=202 --dpi-desync=fake --hostlist=general.txt

# Zapret2: Single process with 3 profiles
nfqws2 --qnum=200 \
  --lua-desync=multisplit:pos=2 --hostlist=youtube.txt --new \
  --lua-desync=multidisorder:pos=2 --hostlist=discord.txt --new \
  --lua-desync=fake:ttl=5:blob=fake_default_tls --hostlist=general.txt
```

---

### Phase 3: Testing

**Step 3.1:** Test each converted strategy individually

```bash
# Stop Zapret1
/etc/init.d/zapret stop

# Test Zapret2 strategy
nfqws2 --qnum=200 --lua-desync=multisplit:pos=2:ttl=8:badsum \
  --hostlist=/opt/zapret/youtube.txt --payload=tls_client_hello &

# Manual test
curl -v https://www.youtube.com

# Automated test
blockcheck2 --strategy="multisplit:pos=2:ttl=8:badsum" \
  --host=www.youtube.com --attempts=10
```

**Step 3.2:** Compare effectiveness

Test both Zapret1 and Zapret2 strategies:
```bash
# Baseline: No bypass
curl -o /dev/null -w "%{http_code}\n" https://blocked-site.com

# Zapret1
# (restart with old config)
curl -o /dev/null -w "%{http_code}\n" https://blocked-site.com

# Zapret2
# (restart with new config)
curl -o /dev/null -w "%{http_code}\n" https://blocked-site.com
```

**Success criteria:**
- Same or better success rate
- No increased latency (>50ms)
- Stable over 24-hour period

---

### Phase 4: Optimization

**Step 4.1:** Leverage Zapret2-specific features

**Add precise positioning:**
```bash
# Before (Zapret1 style)
--lua-desync=multisplit:pos=2

# After (using SNI markers)
--lua-desync=multisplit:pos=sniext+1
```

**Add orchestration:**
```bash
# Automatic strategy rotation on failures
--lua-desync=circular:3:multisplit:pos=2:ttl=8,multidisorder:pos=sniext+1
```

**Step 4.2:** Enable autohostlist
```bash
--autohostlist --autohostlist-fail-threshold=3 \
--autohostlist-file=/tmp/failed_hosts.txt
```

**Step 4.3:** Performance tuning
```bash
# Add pktlen limits if needed
--lua-desync=multisplit:pos=2:pktlen=1200

# Use condition for selective application
--lua-desync=condition:hostlist=aggressive.txt:fakedsplit:pos=2:fakettl=5
```

---

### Phase 5: Deployment

**Step 5.1:** Update startup scripts

Replace nfqws calls with nfqws2:
```bash
# /etc/init.d/zapret (before)
nfqws --qnum=200 --dpi-desync=split2 ...

# /etc/init.d/zapret (after)
nfqws2 --qnum=200 --lua-desync=multisplit:pos=2 ...
```

**Step 5.2:** Gradual rollout

1. **Test environment:** Full testing over 1 week
2. **Canary deployment:** 10% of users
3. **Staged rollout:** 50% → 100%
4. **Monitor:** Track failures, rollback if needed

**Step 5.3:** Documentation

Update configuration docs:
```markdown
# Strategy Configuration (Zapret2)

## YouTube TCP
- **Strategy:** multisplit:pos=2:ttl=8
- **Hostlist:** youtube.txt
- **Success rate:** 98.5%
- **Migrated from:** Zapret1 split2 strategy
```

---

## Testing Migrated Strategies

### Unit Testing with blockcheck2

**Test single strategy:**
```bash
blockcheck2 --strategy="multisplit:pos=2:ttl=8" \
  --host=www.youtube.com \
  --attempts=20 \
  --timeout=10
```

**Test multiple strategies (migration validation):**
```bash
# Create test file with old→new mappings
cat > migration_test.txt << 'EOF'
# Zapret1 equivalent → Zapret2 strategy
split2_ttl8 : multisplit:pos=2:ttl=8
disorder2_badsum : multidisorder:pos=2:badsum
fake_ttl5 : fake:ttl=5:blob=fake_default_tls
EOF

# Run batch test
blockcheck2 --strategy-file=migration_test.txt \
  --host=www.youtube.com \
  --attempts=10
```

### Integration Testing

**Step 1:** Full system test with all profiles
```bash
# Start nfqws2 with migrated config
nfqws2 --qnum=200 \
  --lua-desync=multisplit:pos=2 --hostlist=youtube.txt --new \
  --lua-desync=multidisorder:pos=2 --hostlist=discord.txt --new \
  --lua-desync=fake:ttl=5:blob=fake_default_tls &

# Test each category
curl -v https://www.youtube.com
curl -v https://discord.com
curl -v https://general-blocked-site.com
```

**Step 2:** Load testing
```bash
# Concurrent connections
for i in {1..50}; do
  curl -o /dev/null https://www.youtube.com &
done
wait
```

**Step 3:** Long-term stability test
```bash
# Run every 5 minutes for 24 hours
while true; do
  curl -o /dev/null -w "%{http_code}\n" https://www.youtube.com >> test_log.txt
  sleep 300
done
```

### Regression Testing

Compare Zapret1 vs Zapret2 results:
```bash
# Generate baseline with Zapret1
./run_zapret1_tests.sh > zapret1_baseline.txt

# Test Zapret2 migration
./run_zapret2_tests.sh > zapret2_results.txt

# Compare
diff -u zapret1_baseline.txt zapret2_results.txt
```

**Pass criteria:**
- ≥95% of tests match Zapret1 results
- No new failures
- Latency increase <10%

---

## Common Migration Scenarios

### Scenario 1: Simple Split Strategy

**Zapret1:**
```bash
nfqws --qnum=200 --dpi-desync=split2 --dpi-desync-ttl=8
```

**Zapret2:**
```bash
nfqws2 --qnum=200 --lua-desync=multisplit:pos=2:ttl=8 --payload=tls_client_hello
```

**Enhancements:**
```bash
# Use SNI-relative position for better precision
nfqws2 --qnum=200 --lua-desync=multisplit:pos=sniext+1:ttl=8 --payload=tls_client_hello
```

---

### Scenario 2: Disorder with Fooling

**Zapret1:**
```bash
nfqws --qnum=200 --dpi-desync=disorder2 --dpi-desync-fooling=badsum
```

**Zapret2 (legacy):**
```bash
nfqws2 --qnum=200 --lua-desync=multidisorder_legacy:pos=2:badsum --payload=tls_client_hello
```

**Zapret2 (modern):**
```bash
nfqws2 --qnum=200 --lua-desync=multidisorder:pos=2:badsum --payload=tls_client_hello
```

---

### Scenario 3: Fake + Split Combination

**Zapret1:**
```bash
nfqws --qnum=200 --dpi-desync=fake,split2 --dpi-desync-ttl=5 \
  --dpi-desync-fake-payload=/opt/zapret/fake_tls.bin
```

**Zapret2:**
```bash
nfqws2 --qnum=200 \
  --lua-desync=fakedsplit:pos=2:fakettl=5:blob=fake_default_tls \
  --payload=tls_client_hello
```

**Or with chaining:**
```bash
nfqws2 --qnum=200 \
  --lua-desync=fake:ttl=5:blob=fake_default_tls \
  --lua-desync=multisplit:pos=2 \
  --payload=tls_client_hello
```

---

### Scenario 4: Multi-Instance to Multi-Profile

**Zapret1 (3 instances):**
```bash
# YouTube
nfqws --qnum=200 --dpi-desync=split2 --hostlist=youtube.txt

# Discord
nfqws --qnum=201 --dpi-desync=disorder2 --hostlist=discord.txt

# General
nfqws --qnum=202 --dpi-desync=fake --dpi-desync-ttl=5
```

**Zapret2 (1 instance, 3 profiles):**
```bash
nfqws2 --qnum=200 \
  --lua-desync=multisplit:pos=2 \
  --hostlist=youtube.txt \
  --payload=tls_client_hello \
  --new \
  --lua-desync=multidisorder:pos=2 \
  --hostlist=discord.txt \
  --payload=tls_client_hello \
  --new \
  --lua-desync=fake:ttl=5:blob=fake_default_tls \
  --payload=tls_client_hello
```

**Benefits:**
- Single process (lower resource usage)
- Unified configuration
- Shared hostlist management

---

### Scenario 5: Window Size Manipulation

**Zapret1:**
```bash
nfqws --qnum=200 --wssize=1:6
```

**Zapret2:**
```bash
nfqws2 --qnum=200 --lua-desync=wssize:wsize=1:scale=6 --payload=tls_client_hello
```

**Combine with other strategies:**
```bash
nfqws2 --qnum=200 \
  --lua-desync=wssize:wsize=1:scale=6 \
  --lua-desync=multidisorder:pos=2 \
  --payload=tls_client_hello
```

---

### Scenario 6: SYN Data Strategy

**Zapret1:**
```bash
nfqws --qnum=200 --dpi-desync=syndata --dpi-desync-split-tls=1200
```

**Zapret2:**
```bash
nfqws2 --qnum=200 --lua-desync=syndata:split=1200 --payload=tls_client_hello
```

**Note:** Requires raw socket support and proper TCP reconstruction.

---

## Troubleshooting

### Issue 1: Strategy Not Working After Migration

**Symptoms:** Sites blocked with Zapret2 but worked with Zapret1

**Diagnosis:**
```bash
# Enable debug logging
nfqws2 --qnum=200 --lua-desync=multisplit:pos=2:ttl=8 --debug=all

# Check if packets reaching nfqws2
tcpdump -i any -n 'tcp port 443'

# Verify iptables rules
iptables -L -n -v | grep NFQUEUE
```

**Solutions:**
1. **Use legacy function:**
   ```bash
   # Replace multidisorder with multidisorder_legacy
   --lua-desync=multidisorder_legacy:pos=2
   ```

2. **Add payload filter:**
   ```bash
   # Explicitly specify payload type
   --payload=tls_client_hello
   ```

3. **Check parameter syntax:**
   ```bash
   # Incorrect (Zapret1 style)
   --dpi-desync-ttl=8

   # Correct (Zapret2 style)
   --lua-desync=multisplit:pos=2:ttl=8
   ```

---

### Issue 2: Performance Degradation

**Symptoms:** Increased latency or CPU usage after migration

**Diagnosis:**
```bash
# Monitor CPU usage
top -p $(pgrep nfqws2)

# Check connection count
ss -s

# Measure latency
ping -c 100 www.youtube.com
```

**Solutions:**
1. **Optimize strategy:**
   ```bash
   # Add pktlen limits
   --lua-desync=multisplit:pos=2:pktlen=1200
   ```

2. **Use conditional application:**
   ```bash
   # Only apply to specific hosts
   --lua-desync=condition:hostlist=heavy_strategy.txt:fakedsplit:...
   ```

3. **Reduce Lua overhead:**
   ```bash
   # Use simpler strategies where possible
   # Instead of: fakedsplit:pos=sniext+1:fakettl=8:fakeseq=-10000:badsum
   # Try: multisplit:pos=2:ttl=8
   ```

---

### Issue 3: Inconsistent Results

**Symptoms:** Strategy works sometimes, fails other times

**Diagnosis:**
```bash
# Run repeated tests
for i in {1..20}; do
  curl -o /dev/null -w "%{http_code}\n" https://www.youtube.com
done
```

**Solutions:**
1. **Implement circular strategy rotation:**
   ```bash
   --lua-desync=circular:3:multisplit:pos=2:ttl=8,multidisorder:pos=sniext+1
   ```

2. **Enable autohostlist:**
   ```bash
   --autohostlist --autohostlist-fail-threshold=2
   ```

3. **Test at different times:**
   - DPI behavior may vary by time of day
   - Network routing may change

---

### Issue 4: Fake Payload Not Loading

**Symptoms:** Fake strategies fail, logs show payload errors

**Diagnosis:**
```bash
# Check if blob is valid
nfqws2 --qnum=200 --lua-desync=fake:blob=fake_default_tls --debug=all
```

**Solutions:**
1. **Use built-in blobs:**
   ```bash
   # For TLS
   --lua-desync=fake:ttl=5:blob=fake_default_tls

   # For QUIC
   --lua-desync=fake:ttl=5:blob=fake_default_quic
   ```

2. **Convert custom payload correctly:**
   ```bash
   # Ensure proper hex format
   xxd -p -c 0 fake.bin | tr -d '\n' > fake.hex

   # Use with 0x prefix
   --lua-desync=fake:ttl=5:blob=0x$(cat fake.hex)
   ```

3. **Verify file permissions:**
   ```bash
   ls -l /opt/zapret/fake_tls.bin
   ```

---

### Issue 5: Multi-Profile Conflicts

**Symptoms:** Profiles interfere with each other

**Diagnosis:**
```bash
# Check profile separation
nfqws2 --qnum=200 \
  --lua-desync=multisplit:pos=2 --hostlist=youtube.txt --debug=all --new \
  --lua-desync=multidisorder:pos=2 --hostlist=discord.txt --debug=all
```

**Solutions:**
1. **Verify hostlist separation:**
   ```bash
   # Ensure no overlap
   comm -12 <(sort youtube.txt) <(sort discord.txt)
   ```

2. **Use explicit filters:**
   ```bash
   --filter-tcp=443 --hostlist=youtube.txt --new \
   --filter-tcp=443 --hostlist=discord.txt
   ```

3. **Add catchall profile last:**
   ```bash
   # Specific profiles first
   --lua-desync=strategy1 --hostlist=specific.txt --new \
   # Catchall last
   --lua-desync=strategy2
   ```

---

## Migration Checklist

### Pre-Migration
- [ ] Document all Zapret1 configurations
- [ ] Extract all strategy parameters
- [ ] Backup current configurations
- [ ] Prepare test environment
- [ ] Install nfqws2 and blockcheck2

### Conversion
- [ ] Convert each strategy using conversion table
- [ ] Handle fake payloads (binary → hex or use built-ins)
- [ ] Consolidate multi-instance setups to multi-profile
- [ ] Add payload filters (--payload=tls_client_hello)
- [ ] Review and optimize strategy parameters

### Testing
- [ ] Unit test each converted strategy with blockcheck2
- [ ] Compare Zapret1 vs Zapret2 effectiveness
- [ ] Integration test with full system
- [ ] Load testing (concurrent connections)
- [ ] 24-hour stability test
- [ ] Regression testing against baseline

### Optimization
- [ ] Implement SNI-relative positioning where applicable
- [ ] Add circular strategy rotation for resilience
- [ ] Enable autohostlist for automatic failure handling
- [ ] Optimize performance (pktlen, conditional application)
- [ ] Document optimal configurations

### Deployment
- [ ] Update startup scripts
- [ ] Gradual rollout (test → canary → full)
- [ ] Monitor for issues
- [ ] Update documentation
- [ ] Train team on Zapret2 administration

### Post-Migration
- [ ] Monitor success rates for 1 week
- [ ] Address any issues
- [ ] Decommission Zapret1 instances
- [ ] Archive old configurations
- [ ] Celebrate successful migration! 🎉

---

## Conclusion

Migration from Zapret1 to Zapret2 requires:
1. **Systematic approach:** Inventory, convert, test, optimize, deploy
2. **Thorough testing:** Use blockcheck2 and real-world validation
3. **Leveraging new capabilities:** Multi-profile, markers, orchestration
4. **Patience:** Some strategies may need tuning

**Key Takeaway:** Start with legacy-compatible functions (`multidisorder_legacy`), validate functionality, then explore Zapret2-specific enhancements for improved effectiveness.

With proper planning and testing, migration can achieve equal or better DPI bypass effectiveness while simplifying configuration management.
