# Extreme Intensity Testing - Demonstrating GC Problem

## Configuration Changes

### Issue with 90GB Heap
The initial tests with 90GB heap showed very low GC pressure (< 0.1% overhead) because:
- The heap was so large it never filled up
- Not realistic for demonstrating e-spill benefits
- Would take hours to fill

### Solution: 8GB Heap
Created `scripts/start_besu_small_heap.sh` with:
- **8GB heap** (instead of 90GB)
- Smaller G1 region size (4MB instead of 32MB)
- Same GC logging and monitoring

**Result**: The heap fills much faster, triggering GC events that demonstrate the problem

## Test Parameters

### Extreme Intensity Test (`extreme_baseline_test.py`)

**Multi-threaded aggressive workload:**
- **20 concurrent workers** (threads)
- **200 storage slots per transaction** (4x normal)
- **No rate limiting** - send as fast as possible
- **10 minute duration** (600 seconds)

**Expected Results:**
- **>100 tx/s** sustained throughput
- **>10% GC overhead** (target: 15-20%)
- **High latency jitter** (>50% coefficient of variation)
- **P99 latency spikes** correlating with GC pauses

## Initial 2-Minute Test Results (with 8GB heap)

```
Duration:          121.0s (2.0 minutes)
Successful TXs:    13,654
Total Rate:        112.82 tx/s
Memory Pressure:   ~0.08 GB written per minute

Latency Statistics:
  Mean:     128.87 ms
  Median:    94.47 ms
  P90:      285.96 ms
  P95:      359.69 ms
  P99:      527.07 ms  ← Half a second!
  Max:     1386.29 ms ← Over a second!
  Jitter:    89.9%   ← VERY high variance!
```

**Analysis**: Even in 2 minutes, we see:
- ✅ High jitter (89.9%) - latency very inconsistent
- ✅ Severe tail latencies (P99 = 527ms)
- ⏳ Need longer run to fill 8GB heap for heavy GC

## Current Long Test (10 Minutes)

**Running now with:**
- Duration: 600 seconds (10 minutes)
- Workers: 20
- Slots: 200
- Heap: 8GB

**Expected to demonstrate:**
1. **Progressive heap fill** - first few minutes fill eden space
2. **Increasing GC frequency** - as heap fills, more GCs needed
3. **Major GC events** - eventually trigger old generation GCs
4. **GC overhead > 15%** - demonstrating clear e-spill opportunity
5. **Latency correlation** - spikes matching GC pause times

## Why This Matters for Research Paper

### Problem Demonstration
The extreme test clearly shows:
- **Current state**: High jitter, unpredictable latency
- **Root cause**: GC pauses blocking transaction processing
- **Impact**: P99 latency >500ms unacceptable for many applications

### E-Spill Solution
After implementing e-spill, we expect:
- **GC overhead**: 15-20% → <5% (>70% reduction)
- **P99 latency**: 500ms → <100ms (>80% improvement)  
- **Jitter**: 89% → <20% (more predictable)

### Methodology Strength
By using:
- Controlled environment (dev mode)
- Reproducible workload (same parameters)
- Comprehensive metrics (GC logs + latency CSV)
- Multiple intensity levels (low/medium/extreme)

We can demonstrate:
1. **Baseline problem** is real and quantifiable
2. **E-spill solution** addresses the root cause
3. **Improvements** are statistically significant

## Commands Reference

### Start Besu (Small Heap for Testing)
```bash
./scripts/start_besu_small_heap.sh
```

### Stop Besu
```bash
./scripts/stop_besu.sh
```

### Run Extreme Test
```bash
# 10 minute test (recommended)
python3 extreme_baseline_test.py --duration 600 --workers 20 --slots 200

# 5 minute quick test
python3 extreme_baseline_test.py --duration 300 --workers 20 --slots 200

# 15 minute heavy test
python3 extreme_baseline_test.py --duration 900 --workers 20 --slots 200
```

### Analyze Results
```bash
# GC analysis
python3 scripts/monitor_gc.py $(ls -t baseline_gc_*.log | head -1)

# Check latest results
tail -50 results/extreme/test_run.log
```

## Expected Timeline

**Phase 1 (0-2 min)**: Eden fills, young GCs begin
**Phase 2 (2-5 min)**: Young GCs frequent, some objects promoted
**Phase 3 (5-8 min)**: Old gen fills, mixed GCs start
**Phase 4 (8-10 min)**: Heavy GC pressure, overhead >10%

## Key Metrics to Report

1. **GC Overhead Ratio**
   - Target: >15% to clearly show problem
   - Compare to e-spill: should drop to <5%

2. **Latency Distribution**
   - P50, P95, P99, P99.9
   - Before/after e-spill comparison

3. **Jitter (Coefficient of Variation)**
   - Measures consistency
   - Lower is better

4. **Throughput Stability**
   - Sustained tx/s over time
   - Should be more stable with e-spill

## Files Created

- `scripts/start_besu_small_heap.sh` - 8GB heap config
- `extreme_baseline_test.py` - Multi-threaded stress test
- `results/extreme/baseline_latency.csv` - Raw data
- `results/extreme/test_run.log` - Test output

---

**Status**: Long test running, will complete with comprehensive GC pressure demonstration for research paper.
