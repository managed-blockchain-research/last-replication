# E-Spill Implementation Guide for Hyperledger Besu

## Overview

This guide explains how to implement e-spill memory management in Besu, test it, and compare results against the baseline.

## Phase 1: Understanding Besu Architecture

### Key Components to Modify

**1. Transaction Pool (`TransactionPool` and related classes)**
- Location: `besu/ethereum/eth/src/main/java/org/hyperledger/besu/ethereum/eth/transactions/`
- This is where pending transactions are stored in memory
- **Target for e-spill**: Spill pending transactions to RocksDB when memory pressure is high

**2. Memory Monitoring**
- Need to add JVM heap monitoring using `MemoryMXBean`
- Track allocation rate and GC frequency
- Trigger spilling before GC overhead exceeds threshold

**3. Persistence Layer (RocksDB Integration)**
- Besu already uses RocksDB for blockchain storage
- Location: `besu/storage/rocksdb/`
- **Extend**: Add a spill storage for transactions

### E-Spill Algorithm Adaptation

From the paper: "Eager Memory Management for In-Memory Data Analytics"

**Core Concept:**
```
Monitor GC overhead continuously
IF (GC_overhead > threshold OR allocation_rate > threshold):
    Spill pending transactions to disk
    Keep only essential transactions in memory
    Mark spilled transactions for later retrieval
END IF
```

**Key Thresholds (from paper):**
- **Optimal GC overhead**: 10%
- **Activation threshold**: 8% (start spilling proactively)
- **Deactivation threshold**: 5% (stop spilling, resume normal operation)

## Phase 2: Implementation Steps

### Step 1: Add Memory Monitoring (Java)

Create a new class to monitor JVM memory and GC:

```java
// File: besu/ethereum/eth/src/main/java/org/hyperledger/besu/ethereum/eth/transactions/MemoryPressureMonitor.java

package org.hyperledger.besu.ethereum.eth.transactions;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.lang.management.MemoryUsage;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class MemoryPressureMonitor {
    private static final Logger LOG = LoggerFactory.getLogger(MemoryPressureMonitor.class);
    
    private static final double ACTIVATION_THRESHOLD = 0.08; // 8% GC overhead
    private static final double DEACTIVATION_THRESHOLD = 0.05; // 5% GC overhead
    
    private final MemoryMXBean memoryBean;
    private final List<GarbageCollectorMXBean> gcBeans;
    
    private long lastGcTime = 0;
    private long lastMeasurementTime;
    private final AtomicLong totalGcTime = new AtomicLong(0);
    
    public MemoryPressureMonitor() {
        this.memoryBean = ManagementFactory.getMemoryMXBean();
        this.gcBeans = ManagementFactory.getGarbageCollectorMXBeans();
        this.lastMeasurementTime = System.currentTimeMillis();
        
        // Initialize GC time
        for (GarbageCollectorMXBean gcBean : gcBeans) {
            lastGcTime += gcBean.getCollectionTime();
        }
    }
    
    /**
     * Calculate current GC overhead ratio
     * @return GC overhead as a fraction (0.0 to 1.0)
     */
    public double getGcOverheadRatio() {
        long currentTime = System.currentTimeMillis();
        long currentGcTime = 0;
        
        for (GarbageCollectorMXBean gcBean : gcBeans) {
            currentGcTime += gcBean.getCollectionTime();
        }
        
        long timeDelta = currentTime - lastMeasurementTime;
        long gcDelta = currentGcTime - lastGcTime;
        
        double gcOverhead = 0.0;
        if (timeDelta > 0) {
            gcOverhead = (double) gcDelta / (double) timeDelta;
        }
        
        // Update state
        lastGcTime = currentGcTime;
        lastMeasurementTime = currentTime;
        totalGcTime.set(currentGcTime);
        
        return gcOverhead;
    }
    
    /**
     * Check if we should activate spilling
     */
    public boolean shouldActivateSpilling() {
        double overhead = getGcOverheadRatio();
        boolean shouldSpill = overhead > ACTIVATION_THRESHOLD;
        
        if (shouldSpill) {
            LOG.info("Memory pressure detected: GC overhead = {:.2f}%, activating spilling", 
                    overhead * 100);
        }
        
        return shouldSpill;
    }
    
    /**
     * Check if we should deactivate spilling
     */
    public boolean shouldDeactivateSpilling() {
        double overhead = getGcOverheadRatio();
        return overhead < DEACTIVATION_THRESHOLD;
    }
    
    /**
     * Get current heap usage ratio
     */
    public double getHeapUsageRatio() {
        MemoryUsage heapUsage = memoryBean.getHeapMemoryUsage();
        long used = heapUsage.getUsed();
        long max = heapUsage.getMax();
        
        return max > 0 ? (double) used / (double) max : 0.0;
    }
}
```

### Step 2: Add Spill Storage for Transactions

Create a RocksDB-backed spill storage:

```java
// File: besu/ethereum/eth/src/main/java/org/hyperledger/besu/ethereum/eth/transactions/TransactionSpillStorage.java

package org.hyperledger.besu.ethereum.eth.transactions;

import org.hyperledger.besu.ethereum.core.Transaction;
import org.hyperledger.besu.ethereum.rlp.RLP;
import org.hyperledger.besu.storage.KeyValueStorage;
import org.hyperledger.besu.datatypes.Hash;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicLong;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class TransactionSpillStorage {
    private static final Logger LOG = LoggerFactory.getLogger(TransactionSpillStorage.class);
    
    private final KeyValueStorage storage;
    private final AtomicLong spilledCount = new AtomicLong(0);
    private final AtomicLong restoredCount = new AtomicLong(0);
    
    public TransactionSpillStorage(KeyValueStorage storage) {
        this.storage = storage;
    }
    
    /**
     * Spill a transaction to disk
     */
    public void spillTransaction(Transaction transaction) {
        Hash txHash = transaction.getHash();
        byte[] encoded = RLP.encode(transaction::writeTo).toArray();
        
        storage.put(txHash.toArray(), encoded);
        spilledCount.incrementAndGet();
        
        LOG.debug("Spilled transaction {} to disk", txHash);
    }
    
    /**
     * Restore a transaction from disk
     */
    public Optional<Transaction> restoreTransaction(Hash txHash) {
        return storage.get(txHash.toArray())
            .map(bytes -> {
                Transaction tx = Transaction.readFrom(RLP.input(bytes));
                restoredCount.incrementAndGet();
                LOG.debug("Restored transaction {} from disk", txHash);
                return tx;
            });
    }
    
    /**
     * Remove a spilled transaction
     */
    public void removeTransaction(Hash txHash) {
        storage.remove(txHash.toArray());
    }
    
    /**
     * Get statistics
     */
    public long getSpilledCount() {
        return spilledCount.get();
    }
    
    public long getRestoredCount() {
        return restoredCount.get();
    }
}
```

### Step 3: Modify Transaction Pool

Integrate e-spill into the transaction pool:

```java
// Modify: besu/ethereum/eth/src/main/java/org/hyperledger/besu/ethereum/eth/transactions/PendingTransactions.java

// Add fields:
private final MemoryPressureMonitor memoryMonitor;
private final TransactionSpillStorage spillStorage;
private volatile boolean spillingActive = false;
private Set<Hash> spilledTransactionHashes = new ConcurrentHashSet<>();

// Add to constructor:
this.memoryMonitor = new MemoryPressureMonitor();
this.spillStorage = new TransactionSpillStorage(spillStorageBackend);

// Start background monitoring thread:
private void startMemoryMonitoring() {
    ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();
    
    scheduler.scheduleAtFixedRate(() -> {
        try {
            // Check if we should activate/deactivate spilling
            if (!spillingActive && memoryMonitor.shouldActivateSpilling()) {
                activateSpilling();
            } else if (spillingActive && memoryMonitor.shouldDeactivateSpilling()) {
                deactivateSpilling();
            }
            
            // If spilling is active, spill some transactions
            if (spillingActive) {
                spillPendingTransactions();
            }
            
        } catch (Exception e) {
            LOG.error("Error in memory monitoring", e);
        }
    }, 1, 1, TimeUnit.SECONDS); // Check every second
}

private void activateSpilling() {
    spillingActive = true;
    LOG.info("E-SPILL ACTIVATED - Memory pressure detected");
}

private void deactivateSpilling() {
    spillingActive = false;
    LOG.info("E-SPILL DEACTIVATED - Memory pressure reduced");
    
    // Optionally restore some spilled transactions
    restoreSpilledTransactions();
}

private void spillPendingTransactions() {
    // Strategy: Spill lowest-priority transactions first
    // Keep high-value, recent transactions in memory
    
    int spillTarget = (int) (pendingTransactions.size() * 0.3); // Spill 30%
    
    pendingTransactions.stream()
        .sorted(Comparator.comparing(PendingTransaction::getGasPrice).reversed())
        .skip(pendingTransactions.size() - spillTarget)
        .limit(spillTarget)
        .forEach(pendingTx -> {
            Transaction tx = pendingTx.getTransaction();
            spillStorage.spillTransaction(tx);
            spilledTransactionHashes.add(tx.getHash());
            pendingTransactions.remove(pendingTx);
        });
    
    LOG.info("Spilled {} transactions to disk, {} remain in memory",
            spillTarget, pendingTransactions.size());
}

private void restoreSpilledTransactions() {
    // Restore spilled transactions when memory pressure is low
    int restored = 0;
    
    for (Hash txHash : spilledTransactionHashes) {
        spillStorage.restoreTransaction(txHash)
            .ifPresent(tx -> {
                // Re-add to pending pool
                addTransaction(tx);
                spillStorage.removeTransaction(txHash);
            });
        restored++;
        
        if (restored >= 100) break; // Restore in batches
    }
    
    LOG.info("Restored {} transactions from disk", restored);
}
```

### Step 4: Build Modified Besu

```bash
cd /home/yeochan.yoon/besu-24.1.1

# Build with Gradle
./gradlew installDist

# The modified Besu will be in:
# build/install/besu/bin/besu
```

## Phase 3: Testing and Comparison

### Test Script for Comparison

Create a script to run both baseline and e-spill versions:

```bash
#!/bin/bash
# File: scripts/run_comparison_test.sh

echo "==============================================="
echo "E-SPILL COMPARISON TEST"
echo "==============================================="

RESULTS_DIR="results/comparison_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Test 1: Baseline (without e-spill)
echo ""
echo "Step 1: Running BASELINE test (without e-spill)..."
./scripts/stop_besu.sh
rm -rf data_bl/*
./scripts/start_besu_small_heap.sh  # 8GB heap

python3 deploy_contract.py
python3 extreme_baseline_test.py --duration 600 --workers 20 --slots 200 \
    --output "$RESULTS_DIR/baseline"

# Save baseline logs
cp baseline_gc_*.log "$RESULTS_DIR/baseline_gc.log"
./scripts/stop_besu.sh

# Test 2: E-Spill version
echo ""
echo "Step 2: Running E-SPILL test (with modifications)..."
rm -rf data_bl/*

# Use modified Besu (update path in start script)
export BESU_BIN="/home/yeochan.yoon/besu-24.1.1/build/install/besu/bin/besu"
./scripts/start_besu_small_heap.sh

python3 deploy_contract.py
python3 extreme_baseline_test.py --duration 600 --workers 20 --slots 200 \
    --output "$RESULTS_DIR/espill"

# Save e-spill logs
cp baseline_gc_*.log "$RESULTS_DIR/espill_gc.log"
./scripts/stop_besu.sh

# Step 3: Analyze and compare
echo ""
echo "Step 3: Analyzing results..."
python3 scripts/compare_results.py "$RESULTS_DIR"

echo ""
echo "==============================================="
echo "COMPARISON TEST COMPLETE"
echo "==============================================="
echo "Results saved to: $RESULTS_DIR"
```

### Comparison Analysis Script

```python
# File: scripts/compare_results.py

import sys
import json
import csv
import statistics
from pathlib import Path

def analyze_latency_file(csv_file):
    """Analyze latency CSV file"""
    latencies = []
    
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row['success'] == 'True':
                latencies.append(float(row['latency_ms']))
    
    if not latencies:
        return None
    
    latencies.sort()
    n = len(latencies)
    
    return {
        'count': n,
        'min': min(latencies),
        'mean': statistics.mean(latencies),
        'median': statistics.median(latencies),
        'p90': latencies[int(n * 0.90)],
        'p95': latencies[int(n * 0.95)],
        'p99': latencies[int(n * 0.99)],
        'max': max(latencies),
        'stdev': statistics.stdev(latencies),
        'jitter_cv': (statistics.stdev(latencies) / statistics.mean(latencies)) * 100
    }

def main(results_dir):
    results_dir = Path(results_dir)
    
    print("=" * 70)
    print("E-SPILL VS BASELINE COMPARISON")
    print("=" * 70)
    
    # Analyze baseline
    baseline_stats = analyze_latency_file(results_dir / "baseline_latency.csv")
    espill_stats = analyze_latency_file(results_dir / "espill_latency.csv")
    
    print("\nLATENCY COMPARISON (ms):")
    print(f"{'Metric':<15} {'Baseline':>12} {'E-Spill':>12} {'Improvement':>15}")
    print("-" * 70)
    
    metrics = ['mean', 'median', 'p95', 'p99', 'max', 'jitter_cv']
    for metric in metrics:
        baseline_val = baseline_stats[metric]
        espill_val = espill_stats[metric]
        improvement = ((baseline_val - espill_val) / baseline_val) * 100
        
        print(f"{metric.upper():<15} {baseline_val:>12.2f} {espill_val:>12.2f} {improvement:>14.1f}%")
    
    print("\n" + "=" * 70)
    print("KEY FINDINGS:")
    print("=" * 70)
    
    jitter_improvement = ((baseline_stats['jitter_cv'] - espill_stats['jitter_cv']) / 
                          baseline_stats['jitter_cv']) * 100
    p99_improvement = ((baseline_stats['p99'] - espill_stats['p99']) / 
                       baseline_stats['p99']) * 100
    
    print(f"✓ Jitter reduced by {jitter_improvement:.1f}%")
    print(f"✓ P99 latency improved by {p99_improvement:.1f}%")
    print(f"✓ Max latency reduced from {baseline_stats['max']:.0f}ms to {espill_stats['max']:.0f}ms")

if __name__ == '__main__':
    main(sys.argv[1])
```

## Phase 4: Workflow Summary

### Complete Implementation Workflow

```bash
# 1. Implement e-spill in Besu (modify Java files as shown above)
cd /home/yeochan.yoon/besu-24.1.1
# Edit the files, add the classes

# 2. Build modified Besu
./gradlew clean installDist

# 3. Run comparison tests
cd /home/yeochan.yoon/caliper-stress-test
chmod +x scripts/run_comparison_test.sh
./scripts/run_comparison_test.sh

# 4. Analyze results
python3 scripts/compare_results.py results/comparison_TIMESTAMP

# 5. Generate plots for paper
python3 scripts/generate_plots.py results/comparison_TIMESTAMP
```

## Expected Results After E-Spill

Based on the e-spill paper and your baseline:

**Latency Improvements:**
- Mean: 132ms → ~80ms (40% improvement)
- P99: 548ms → ~150ms (73% improvement)
- Jitter: 90.6% → ~25% (72% reduction)

**GC Improvements:**
- GC overhead: Should stay below 5%
- Fewer GC pauses during transaction processing
- More predictable throughput

## Next Steps

1. **Review Besu codebase** to understand transaction pool structure
2. **Implement monitoring** (MemoryPressureMonitor class)
3. **Add spill storage** (TransactionSpillStorage class)
4. **Modify transaction pool** to use e-spill logic
5. **Build and test** modified version
6. **Run comparison tests** and measure improvements
7. **Document findings** for research paper

---

**Note**: The Java code above is pseudocode showing the approach. You'll need to adapt it to Besu's actual API and architecture. Let me know if you want help with specific Besu classes!
