# E-Spill Implementation Workflow - Quick Reference

## Complete Step-by-Step Process

### Phase 1: Understand What You Have ✅ DONE

**Status**: Baseline complete with clear problem demonstration
- 90.6% jitter (extreme latency variance)
- 548ms P99 latency (unacceptable)
- 65,362 transactions tested

### Phase 2: Locate Besu Transaction Pool Code

```bash
cd /home/yeochan.yoon/besu-24.1.1

# Find transaction pool files
find . -name "*TransactionPool*" -o -name "*PendingTransactions*" | grep -v build | grep -v .git
```

**Key files to modify:**
```
ethereum/eth/src/main/java/org/hyperledger/besu/ethereum/eth/transactions/
├── PendingTransactions.java          # Main class to modify
├── TransactionPool.java               # Pool interface
├── TransactionPoolConfiguration.java  # Add e-spill config
└── layered/                          # Layered pool implementation
```

### Phase 3: Add E-Spill Classes

**Create these new files:**

1. **MemoryPressureMonitor.java**
   - Location: `ethereum/eth/src/main/java/org/hyperledger/besu/ethereum/eth/transactions/`
   - Purpose: Monitor JVM heap and GC overhead
   - Code: See E_SPILL_IMPLEMENTATION_GUIDE.md

2. **TransactionSpillStorage.java**
   - Location: Same as above
   - Purpose: RocksDB-backed spill storage
   - Code: See E_SPILL_IMPLEMENTATION_GUIDE.md

### Phase 4: Modify Existing Code

**Modify `PendingTransactions.java`:**

```java
// Add imports
import java.lang.management.*;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.Executors;

// Add fields
private final MemoryPressureMonitor memoryMonitor;
private final TransactionSpillStorage spillStorage;
private volatile boolean spillingActive = false;

// Modify constructor to initialize
public PendingTransactions(...) {
    // ... existing code ...
    
    // Add e-spill components
    this.memoryMonitor = new MemoryPressureMonitor();
    this.spillStorage = new TransactionSpillStorage(createSpillStorage());
    
    // Start monitoring
    startMemoryMonitoring();
}

// Add monitoring method (see implementation guide for full code)
private void startMemoryMonitoring() { ... }
private void spillPendingTransactions() { ... }
private void restoreSpilledTransactions() { ... }
```

### Phase 5: Build Modified Besu

```bash
cd /home/yeochan.yoon/besu-24.1.1

# Clean previous builds
./gradlew clean

# Build with e-spill modifications
./gradlew installDist

# Verify build succeeded
ls -l build/install/besu/bin/besu
```

**Expected build time**: 5-10 minutes

### Phase 6: Test Modified Besu

**Option A: Quick Smoke Test (2 minutes)**

```bash
cd /home/yeochan.yoon/caliper-stress-test

# Stop current Besu
./scripts/stop_besu.sh

# Update Besu path to use modified version
export BESU_BIN="/home/yeochan.yoon/besu-24.1.1/build/install/besu/bin/besu"

# Start modified Besu
./scripts/start_besu_small_heap.sh

# Deploy contract
python3 deploy_contract.py

# Run quick test (2 minutes)
python3 extreme_baseline_test.py --duration 120 --workers 20 --slots 200

# Check logs for e-spill messages
grep -i "spill" data_bl/besu_console.log
```

Look for log messages like:
- "E-SPILL ACTIVATED - Memory pressure detected"
- "Spilled  XX transactions to disk"
- "Restored XX transactions from disk"

**Option B: Full Comparison Test (20 minutes)**

```bash
# Run automated comparison
./scripts/run_comparison_test.sh

# This will:
# 1. Run 10-min baseline test (original Besu)
# 2. Run 10-min e-spill test (modified Besu)
# 3. Compare results automatically
```

### Phase 7: Analyze Results

```bash
# After comparison test completes
python3 scripts/compare_results.py results/comparison_TIMESTAMP

# Expected output:
# ✅ Jitter reduction: ~60-70%
# ✅ P99 improvement: ~50-70%
# ✅ Mean latency: ~30-40% faster
```

### Phase 8: Generate Research Paper Plots

```bash
# Create comparison plots
python3 scripts/generate_plots.py results/comparison_TIMESTAMP

# This generates:
# - latency_distribution.png
# - jitter_comparison.png
# - tail_latency_comparison.png
# - gc_overhead_comparison.png
```

## Troubleshooting

### Build Fails

```bash
# Check Java version
java -version  # Should be 17 or later

# If build fails, check specific error
./gradlew installDist --stacktrace
```

### E-Spill Not Activating

**Check logs:**
```bash
tail -100 data_bl/besu_console.log | grep -i "spill\|memory\|gc"
```

**Possible reasons:**
1. Memory pressure not high enough (increase test intensity)
2. Monitoring not initialized (check for errors in log)
3. Thresholds too high (lower from 8% to 5%)

**Fix**: Modify `MemoryPressureMonitor.java`:
```java
private static final double ACTIVATION_THRESHOLD = 0.05; // Lower to 5%
```

### No Improvement Seen

**Possible reasons:**
1. Spilling not aggressive enough
2. Restore happening too quickly
3. Workload not memory-intensive enough

**Tuning options:**
- Spill more transactions (change 30% to 50% in spillPendingTransactions)
- Increase test duration (600s → 900s)
- Add more workers (20 → 30)

## Expected Timeline

```
Implementation:    2-4 hours (if familiar with Java/Besu)
                  4-8 hours (if learning as you go)

Build & Test:     30 minutes

Full Comparison:  30 minutes (includes 2x 10-minute tests)

Analysis:         30 minutes

Total:            4-10 hours
```

## Quick Commands Cheat Sheet

```bash
# Build modified Besu
cd /home/yeochan.yoon/besu-24.1.1 && ./gradlew installDist

# Run quick test with modified Besu
cd /home/yeochan.yoon/caliper-stress-test
export BESU_BIN="/home/yeochan.yoon/besu-24.1.1/build/install/besu/bin/besu"
./scripts/stop_besu.sh
rm -rf data_bl/*
./scripts/start_besu_small_heap.sh
python3 deploy_contract.py
python3 extreme_baseline_test.py --duration 120 --workers 20 --slots 200

# Check if e-spill is working
grep -i "spill" data_bl/besu_console.log

# Run full comparison
./scripts/run_comparison_test.sh

# Analyze results
python3 scripts/compare_results.py results/comparison_TIMESTAMP
```

## Files Reference

**Implementation Guide:**
- `E_SPILL_IMPLEMENTATION_GUIDE.md` - Detailed Java code and architecture

**Test Scripts:**
- `extreme_baseline_test.py` - Stress test (already working)
- `scripts/compare_results.py` - Comparison analyzer (ready)
- `scripts/run_comparison_test.sh` - Automated workflow (to be created)

**Results:**
- `FINAL_BASELINE_RESULTS.md` - Your baseline (already collected)
- `results/comparison_*/` - Comparison results (after e-spill tests)

## Next Actions

1. ☐ Read Besu transaction pool code
2. ☐ Add MemoryPressureMonitor class
3. ☐ Add TransactionSpillStorage class  
4. ☐ Modify PendingTransactions integration
5. ☐ Build modified Besu
6. ☐ Run quick smoke test
7. ☐ Run full comparison
8. ☐ Analyze and document improvements
9. ☐ Write research paper section

**Ready to start? Begin with:**
```bash
cd /home/yeochan.yoon/besu-24.1.1
find . -name "PendingTransactions.java" | grep -v build
# Open that file and start reading!
```
