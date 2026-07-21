# FINAL COMPARISON RESULTS - Besu Rerun (Baseline vs LASS)

## Test Configuration (Summary)

**Baseline (Extreme Intensity, JFR enabled):**
- Workers: 30
- Slots per tx: 200
- Duration: 600s
- Rate control: none (max throughput)
- Warm-up: 1800s, 400 slots/tx
- Source: `results/extreme/retry-20260129_104658/baseline_latency.csv`
- GC Log: `baseline_harsh_gc_20260129_105717.log`
- JFR: `data_baseline_harsh/besu_20260129_105717.jfr`

**LASS (Extreme Intensity, JFR enabled):**
- Workers: 30
- Slots per tx: 200
- Duration: 600s
- Rate control: none (max throughput)
- Warm-up: 1800s, 400 slots/tx
- Source: `results/extreme/retry-20260129_104658/espill_latency.csv`
- GC Log: `espill_harsh_gc_20260129_121658.log`
- JFR: `data_espill_harsh/besu_20260129_121658.jfr`

> Note: This is a matched extreme workload comparison from the rerun after enabling JFR.

## Key Results

### Throughput Summary
```
Baseline: 103.87 tx/s sustained, 62,368 success, 15,125 fail
LASS:   59.16 tx/s sustained, 35,537 success, 12,663 fail
```

### Latency Distribution (milliseconds, successful tx)
```
Metric   | Baseline | LASS
---------|----------|---------
Min      |   7.06   |  13.92
Avg      | 185.69   | 267.85
Median   | 136.72   | 194.05
P95      | 522.10   | 757.01
P99      | 756.96   | 1098.37
Max      | 1728.49  | 2440.51
StdDev   | 169.53   | 245.66
CV       | 91.3%    | 91.7%
```

### Jitter (Consistency Metric)
```
Baseline CV: 91.3%
LASS CV:  91.7%
```

## Comparison Plots (Rerun)

Generated plots with legends:
- `results/extreme/comparison-20260129-retry/latency_percentiles.png`
- `results/extreme/comparison-20260129-retry/latency_average.png`

## Files Generated
```
results/extreme/retry-20260129_104658/baseline_latency.csv
results/extreme/retry-20260129_104658/espill_latency.csv
results/extreme/comparison-20260129-retry/latency_summary.json
results/extreme/comparison-20260129-retry/latency_summary.csv
results/extreme/comparison-20260129-retry/latency_percentiles.png
results/extreme/comparison-20260129-retry/latency_average.png
results/extreme/comparison-20260129-retry/baseline_gc_summary.txt
results/extreme/comparison-20260129-retry/espill_gc_summary.txt
```

## GC Metrics (Rerun)
```
Baseline GC Overhead: 0.02% (25 events, 0.611s total GC time)
LASS  GC Overhead: 0.01% (31 events, 0.472s total GC time)
Baseline GC P95/P99 Pause: 42.20 / 47.70 ms (max 47.70 ms)
LASS  GC P95/P99 Pause: 21.10 / 30.82 ms (max 30.82 ms)
```
Note: GC pause times above are STW (stop-the-world) durations from the GC logs.

## Notes
- Latency stats are computed from `results/extreme/comparison-20260129-retry/latency_summary.json`.
- GC summaries are in `results/extreme/comparison-20260129-retry/*_gc_summary.txt`.
