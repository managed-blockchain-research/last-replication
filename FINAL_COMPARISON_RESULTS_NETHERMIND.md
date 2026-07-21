# FINAL COMPARISON RESULTS - Nethermind (Baseline vs E-Spill)

## Test Configuration (Summary)

**Baseline (High Slots, GCDump Run):**
- Workers: 14
- Slots per tx: 300
- Duration: 600s
- Rate control: none (max throughput)
- Source: `results/nethermind/gcdump-20260130_125919/baseline_pre_latency.csv`

**E-Spill (High Slots, GCDump Run):**
- Workers: 14
- Slots per tx: 300
- Duration: 600s
- Rate control: none (max throughput)
- Source: `results/nethermind/gcdump-20260130_125919/espill_pre_latency.csv`

> Note: This is a matched high-slots workload comparison using gcdump snapshots.

## Key Results

### Throughput Summary
```
Baseline: 197.93 tx/s sustained, 118,785 success, 3,363 fail
E-Spill:  209.31 tx/s sustained, 125,616 success, 3,333 fail
```

### Latency Distribution (milliseconds, successful tx)
```
Metric   | Baseline | E-Spill
---------|----------|---------
Min      |   4.33   |   4.15
Avg      |  67.61   |  63.99
Median   |  50.29   |  47.88
P95      | 186.26   | 176.11
P99      | 275.41   | 261.88
Max      | 648.62   | 627.84
StdDev   |  59.96   |  56.76
CV       | 88.7%    | 88.7%
```

### Jitter (Consistency Metric)
```
Baseline CV: 88.7%
E-Spill CV:  88.7%
```

## Comparison Plots

Generated plots with legends:
- `results/nethermind/comparison-20260130-gcdump/latency_percentiles.png`
- `results/nethermind/comparison-20260130-gcdump/latency_average.png`

## Files Generated
```
results/nethermind/gcdump-20260130_125919/baseline_pre_latency.csv
results/nethermind/gcdump-20260130_125919/espill_pre_latency.csv
results/nethermind/comparison-20260130-gcdump/latency_summary.json
results/nethermind/comparison-20260130-gcdump/latency_summary.csv
results/nethermind/comparison-20260130-gcdump/latency_percentiles.png
results/nethermind/comparison-20260130-gcdump/latency_average.png
```

## GC / LOH Metrics
GCDump-based approximations:
```
Baseline GC heap bytes (post): 113,159,000
E-Spill  GC heap bytes (post): 129,795,954
Baseline LOH >=100KB objects: 3,959,362 bytes
E-Spill  LOH >=100KB objects: 3,690,858 bytes
```
Note: gcdump reports do not expose Gen2 event counts or time-in-GC.

## Notes
- Latency stats are computed from `results/nethermind/comparison-20260130-gcdump/latency_summary.json`.
