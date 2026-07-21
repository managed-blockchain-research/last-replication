# Unified Result Summary (Retry Run)

| Metric (Standardized) | Besu (JVM) | Nethermind (CLR) |
|---|---|---|
| Trigger Mechanism | G1GC Occupancy Threshold | Gen 2 / LOH Fragmentation |
| Sustained Throughput (tx/s) | 103.87 -> 59.16 | 197.93 -> 209.31 |
| Success vs Failure Count | 62,368/15,125 -> 35,537/12,663 | 118,785/3,363 -> 125,616/3,333 |
| Maximum LOH Size | N/A (JVM) | 3,959,362 -> 3,690,858 bytes (>=100KB objects) |
| Gen 2 GC Events | N/A (JVM) | N/A (gcdump does not report) |
| Percent Time in GC | 0.02% -> 0.01% | N/A (not captured) |
| Gen 2 Size (proxy) | N/A (JVM) | 113,159,000 -> 129,795,954 bytes (GC heap bytes) |
| STW Reduction | 47.70 ms -> 30.82 ms (P99 pause) | 0.00 ms -> 0.00 ms (no GC events captured) |
| Overhead Delta | 0.02% -> 0.01% (GC overhead) | N/A (not captured) |
| Determinism (CV) | 91.29% -> 91.72% | 87.70% -> 87.42% |

## Source Notes
- Besu metrics from: `results/extreme/comparison-20260129-retry/latency_summary.json`, `baseline_gc_summary.txt`, `espill_gc_summary.txt`.
- Nethermind metrics from: `results/nethermind/gcdump-20260130_125919/*_latency.csv`.
- Nethermind LOH/Gen2 approximations from gcdump reports:
  - `results/nethermind/gcdump-20260130_125919/baseline_pre_post_gcdump_report.txt`
  - `results/nethermind/gcdump-20260130_125919/espill_pre_post_gcdump_report.txt`
  LOH size is approximated as sum of objects marked "Bytes > 100K".