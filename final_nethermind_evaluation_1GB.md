# Nethermind LASS Sensitivity Report: ctrl vs LASS-60 vs LASS-75 vs LASS-90

**Generated:** 2026-04-23 15:58:15
**Results dir:** `results/validation_nethermind/20260423_114856_nm_sensitivity`

## Configuration

| Parameter | Value |
|-----------|-------|
| Runtime | .NET CLR (Nethermind) |
| Caliper workers | 30 |
| Rate control | fixed-rate tps=1500 |
| Duration | 600s |
| Slots/tx | 200 |
| ctrl | no heap limit, default GC |
| LASS-60 | GCHeapHardLimit=1GB, GCHighMemPercent=60 |
| LASS-75 | GCHeapHardLimit=1GB, GCHighMemPercent=75 |
| LASS-90 | GCHeapHardLimit=1GB, GCHighMemPercent=90 |
| Replications | 5 per variant |

## Per-Run Data

### ctrl (stock NM)

| Run | TPS | Max Lat (s) | Gen0 GC | Gen1 GC | Gen2 GC | Total GC | Total Pause (ms) | Avg Pause (ms) | Max time-in-GC% | Peak Heap (MB) |
|-----|-----|-------------|---------|---------|---------|----------|-----------------|----------------|-----------------|----------------|
| ctrl_1 | 149.0 | 7.96 | 13 | 8 | 11 | 32 | 25384.2 | 668.0 | 0.0 | 0.0 |
| ctrl_2 | 149.2 | 7.06 | 16 | 7 | 11 | 34 | 24102.2 | 618.0 | 0.0 | 0.0 |
| ctrl_3 | 149.1 | 7.63 | 15 | 9 | 12 | 36 | 25708.8 | 642.7 | 0.0 | 0.0 |
| ctrl_4 | 148.4 | 9.74 | 14 | 9 | 11 | 34 | 22559.1 | 593.7 | 0.0 | 0.0 |
| ctrl_5 | 149.2 | 9.59 | 13 | 7 | 13 | 33 | 20901.1 | 550.0 | 0.0 | 0.0 |

### lass60 (LASS-60)

| Run | TPS | Max Lat (s) | Gen0 GC | Gen1 GC | Gen2 GC | Total GC | Total Pause (ms) | Avg Pause (ms) | Max time-in-GC% | Peak Heap (MB) |
|-----|-----|-------------|---------|---------|---------|----------|-----------------|----------------|-----------------|----------------|
| lass60_1 | 149.3 | 6.10 | 12 | 8 | 11 | 31 | 13481.4 | 374.5 | 0.0 | 0.0 |
| lass60_2 | 149.5 | 9.81 | 13 | 9 | 12 | 34 | 14505.0 | 337.3 | 0.0 | 0.0 |
| lass60_3 | 149.5 | 7.49 | 11 | 10 | 11 | 32 | 16108.4 | 447.5 | 0.0 | 0.0 |
| lass60_4 | 149.3 | 7.72 | 11 | 9 | 11 | 31 | 14606.1 | 394.8 | 0.0 | 0.0 |
| lass60_5 | 143.7 | 29.57 | 13 | 8 | 13 | 34 | 16440.7 | 411.0 | 0.0 | 0.0 |

### lass75 (LASS-75)

| Run | TPS | Max Lat (s) | Gen0 GC | Gen1 GC | Gen2 GC | Total GC | Total Pause (ms) | Avg Pause (ms) | Max time-in-GC% | Peak Heap (MB) |
|-----|-----|-------------|---------|---------|---------|----------|-----------------|----------------|-----------------|----------------|
| lass75_1 | 144.9 | 25.86 | 11 | 9 | 12 | 32 | 17538.5 | 438.5 | 0.0 | 0.0 |
| lass75_2 | 147.3 | 18.00 | 13 | 8 | 12 | 33 | 15496.7 | 407.8 | 0.0 | 0.0 |
| lass75_3 | 147.5 | 14.77 | 12 | 8 | 12 | 32 | 15022.7 | 385.2 | 0.0 | 0.0 |
| lass75_4 | 144.7 | 25.30 | 12 | 8 | 12 | 32 | 15254.9 | 381.4 | 0.0 | 0.0 |
| lass75_5 | 146.1 | 18.76 | 13 | 8 | 14 | 35 | 17304.5 | 432.6 | 0.0 | 0.0 |

### lass90 (LASS-90)

| Run | TPS | Max Lat (s) | Gen0 GC | Gen1 GC | Gen2 GC | Total GC | Total Pause (ms) | Avg Pause (ms) | Max time-in-GC% | Peak Heap (MB) |
|-----|-----|-------------|---------|---------|---------|----------|-----------------|----------------|-----------------|----------------|
| lass90_1 | 144.1 | 27.12 | 11 | 10 | 12 | 33 | 15640.5 | 401.0 | 0.0 | 0.0 |
| lass90_2 | 145.4 | 22.97 | 12 | 8 | 12 | 32 | 16516.1 | 412.9 | 0.0 | 0.0 |
| lass90_3 | 146.5 | 20.23 | 11 | 9 | 12 | 32 | 17125.3 | 450.7 | 0.0 | 0.0 |
| lass90_4 | 145.9 | 21.50 | 14 | 6 | 13 | 33 | 15070.9 | 367.6 | 0.0 | 0.0 |
| lass90_5 | 145.7 | 20.92 | 12 | 9 | 12 | 33 | 17842.8 | 435.2 | 0.0 | 0.0 |

## Summary Statistics (mean ± stdev)

| Metric | ctrl | LASS-60 | LASS-75 | LASS-90 |
|--------|------|---------|---------|---------|
| TPS | 149.0 ± 0.3 | 148.3 ± 2.6 | 146.1 ± 1.3 | 145.5 ± 0.9 |
| Max Latency (s) | 8.40 ± 1.20 | 12.14 ± 9.83 | 20.54 ± 4.84 | 22.55 ± 2.75 |
| Avg Latency (s) | 3.08 ± 0.10 | 3.25 ± 0.94 | 5.92 ± 0.83 | 5.97 ± 0.98 |
| Gen0 GC Count | 14 ± 1 | 12 ± 1 | 12 ± 1 | 12 ± 1 |
| Gen1 GC Count | 8 ± 1 | 9 ± 1 | 8 ± 0 | 8 ± 2 |
| Gen2 GC Count | 12 ± 1 | 12 ± 1 | 12 ± 1 | 12 ± 0 |
| Total GC Events | 34 ± 1 | 32 ± 2 | 33 ± 1 | 33 ± 1 |
| Total Pause (ms) | 23731 ± 2010 | 15028 ± 1225 | 16123 ± 1200 | 16439 ± 1113 |
| Avg Pause/event (ms) | 614.5 ± 45.4 | 393.0 ± 41.0 | 409.1 ± 26.3 | 413.5 ± 32.1 |
| Max time-in-GC % | 0.0 ± 0.0 | 0.0 ± 0.0 | 0.0 ± 0.0 | 0.0 ± 0.0 |
| Avg time-in-GC % | 0.0 ± 0.0 | 0.0 ± 0.0 | 0.0 ± 0.0 | 0.0 ± 0.0 |
| Peak Heap (MB) | 0 ± 0 | 0 ± 0 | 0 ± 0 | 0 ± 0 |

## Change vs Ctrl (mean)

| Metric | LASS-60 | LASS-75 | LASS-90 |
|--------|---------|---------|---------|
| Total GC Events | ↓ 4.1% | ↓ 3.0% | ↓ 3.6% |
| Gen2 GC Count | ↓ 0.0% | ↑ 6.9% | ↑ 5.2% |
| Total Pause (ms) | ↓ 36.7% | ↓ 32.1% | ↓ 30.7% |
| Avg Pause/event (ms) | ↓ 36.0% | ↓ 33.4% | ↓ 32.7% |
| Max time-in-GC % | N/A | N/A | N/A |
| Avg time-in-GC % | N/A | N/A | N/A |
| Peak Heap (MB) | N/A | N/A | N/A |

## Interpretation

### GC Event Count and Pause vs Ctrl
**LASS-60**: Total GC ↓ 4.1% (34→32), Gen2 GC ↓ 0.0% (12→12), Total Pause ↓ 36.7% (23731ms→15028ms), Max time-in-GC N/A.
**LASS-75**: Total GC ↓ 3.0% (34→33), Gen2 GC ↑ 6.9% (12→12), Total Pause ↓ 32.1% (23731ms→16123ms), Max time-in-GC N/A.
**LASS-90**: Total GC ↓ 3.6% (34→33), Gen2 GC ↑ 5.2% (12→12), Total Pause ↓ 30.7% (23731ms→16439ms), Max time-in-GC N/A.

### Notes
- `Gen2 GC` is analogous to Besu's Full GC (major collection).
- `time-in-gc` is sampled at 1s intervals; `Max time-in-GC%` is the worst 1s sample.
- A lower `GCHighMemPercent` triggers more frequent GC, reducing peak heap but increasing GC overhead.

---
*Report generated by analyze_nm_sensitivity.py*