# FINAL COMPARISON RESULTS - Baseline vs E-Spill

## Test Configuration (Summary)

**Baseline (Extreme Intensity):**
- Workers: 20
- Slots per tx: 200
- Duration: 600s
- Rate control: none (max throughput)
- Source: `FINAL_BASELINE_RESULTS.md`

**E-Spill (Extreme Intensity, Matched):**
- Workers: 20
- Slots per tx: 200
- Duration: 600s
- Rate control: none (max throughput)
- Source: `results/extreme/espill_latency.csv`

> Note: This is a matched extreme workload comparison.

## Key Results

### Throughput Summary
```
Baseline: 108.75 tx/s sustained, 65,362 success, 10,849 fail
E-Spill:  113.85 tx/s sustained, 68,426 success, 11,062 fail
```

### Latency Distribution (milliseconds, successful tx)
```
Metric   | Baseline | E-Spill
---------|----------|---------
Min      |   6.88   |   6.82
Avg      | 132.40   | 127.77
Median   |  95.90   |  94.67
P95      | 371.53   | 351.80
P99      | 548.08   | 515.20
Max      | 1170.09  | 1075.71
StdDev   | 119.93   | 112.59
CV       | 90.6%    | 88.1%
```

### Jitter (Consistency Metric)
```
Baseline CV: 90.6%
E-Spill CV:  88.1%
```

## Comparison Plots (Extreme Matched Workload)

Generated plots with legends:
- `results/extreme/comparison-20260128/latency_percentiles.png`
- `results/extreme/comparison-20260128/latency_average.png`

### Plot 1: Latency Percentiles
**Purpose:** Compare P50/P95/P99 tail behavior under identical extreme workloads.  
**Analysis:** Baseline P50/P95/P99 is 95.90 / 371.53 / 548.08 ms, while e-spill is
94.67 / 351.80 / 515.20 ms. E-spill improves tail latency at P95 and P99 and slightly
improves the median.

### Plot 2: Average Latenc
**Purpose:** Compare mean end-to-end latency under identical extreme workloads.  
**Analysis:** Baseline avg is 132.40 ms vs e-spill 127.77 ms, so e-spill is modestly
faster on average in this run.

## Files Generated
```
results/extreme/baseline_latency.csv
results/extreme/espill_latency.csv
results/extreme/comparison-20260128/latency_summary.json
results/extreme/comparison-20260128/latency_summary.csv
results/extreme/comparison-20260128/latency_percentiles.png
results/extreme/comparison-20260128/latency_average.png
results/extreme/baseline_gc_events.csv
results/extreme/espill_gc_events.csv
```

## GC Metrics (Extreme Runs)
```
Baseline GC Overhead: 0.24% (837 events, 5.366s total GC time)
E-Spill  GC Overhead: 0.02% (16 events, 0.200s total GC time)
Baseline GC P95/P99 Pause: 8.21 / 10.25 ms (max 19.74 ms)
E-Spill  GC P95/P99 Pause: 23.92 / 23.92 ms (max 23.92 ms)
```
Note: GC pause times above are STW (stop-the-world) durations from the GC logs.

## Notes for Paper
- The latency distribution for the e-spill run is based on `results/extreme/espill_latency.csv`.
- This section reflects a strict apples-to-apples extreme comparison (same workers, slots, duration).
