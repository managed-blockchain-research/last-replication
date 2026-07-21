# LAST vs LASS Head-to-Head Evaluation @ 1GB Heap (Besu)

**Generated:** 2026-04-24 09:32:30
**Results dir:** `/home/yeochan.yoon/caliper-stress-test/results/last_vs_lass_4g/20260424_045512_last_vs_lass_4g`

## Configuration

| Parameter | Value |
|-----------|-------|
| Client | Hyperledger Besu 24.1.1 |
| JVM Heap | `-Xms1g -Xmx1g` (fixed, no expansion) |
| GC | G1GC, MaxGCPauseMillis=200 |
| Eden sizing | G1MaxNewSizePercent=90, G1NewSizePercent=20 |
| TxPool | Uncapped (`--tx-pool-max-size=1000000`) |
| Caliper TPS | 1500 (fixed-rate) |
| Warmup | 120s (excluded from measurement) |
| Measure | 300s |
| Workers | 30 |
| Workload | stateBloat, 200 slots/tx |
| Replications | 5 per variant |
| Baseline binary | besu-24.1.1 (`-Dlast.variant=DISABLED`) |
| LASS-75 binary | besu-source (E-Spill, activation=0.75, deact=0.60) |
| LAST-AL binary | besu-24.1.1 + LAST patch (`-Dlast.variant=ADDRESS_LOCALITY`) |
| LAST+LASS-75 binary | besu-source + LAST patch + LASS-75 opts |

## Per-Run Data

### Baseline (FIFO)

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| baseline_1 | N/A | N/A | N/A | 6 | 8 | 18 | 0 | 2 |
| baseline_2 | N/A | N/A | N/A | 358 | 275 | 11309 | 0 | 31 |
| baseline_3 | N/A | N/A | N/A | 1659 | 2153 | 500521 | 399 | 72 |
| baseline_4 | N/A | N/A | N/A | 1829 | 7290 | 866681 | 223 | 74 |
| baseline_5 | N/A | N/A | N/A | 1927 | 4183 | 981130 | 258 | 72 |

### LASS-75 only

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| lass75_1 | N/A | N/A | N/A | 511 | 222 | 27954 | 0 | 504 |
| lass75_2 | N/A | N/A | N/A | 1653 | 4529 | 1155387 | 390 | 681 |
| lass75_3 | N/A | N/A | N/A | 451 | 294 | 21363 | 0 | 472 |
| lass75_4 | N/A | N/A | N/A | 587 | 1304 | 17360 | 1 | 347 |
| lass75_5 | N/A | N/A | N/A | 1975 | 4216 | 280539 | 62 | 1159 |

### LAST-AL only

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| last_al_1 | N/A | N/A | N/A | 10560 | 1504 | 515680 | 3036 | 180 |
| last_al_2 | N/A | N/A | N/A | 2206 | 2977 | 127466 | 36 | 114 |
| last_al_3 | N/A | N/A | N/A | 542 | 142 | 16154 | 0 | 93 |
| last_al_4 | N/A | N/A | N/A | 76 | 90 | 2735 | 0 | 71 |
| last_al_5 | N/A | N/A | N/A | 84 | 71 | 2427 | 0 | 78 |

### LAST-AL + LASS-75

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| last_lass75_1 | N/A | N/A | N/A | 26 | 91 | 892 | 0 | 168 |
| last_lass75_2 | N/A | N/A | N/A | 22 | 127 | 775 | 0 | 174 |
| last_lass75_3 | N/A | N/A | N/A | 23 | 101 | 651 | 0 | 188 |
| last_lass75_4 | 0.1 | 2.35 | 2.11 | 23 | 92 | 584 | 0 | 166 |
| last_lass75_5 | N/A | N/A | N/A | 23 | 119 | 744 | 0 | 184 |

## Summary Statistics (mean ± stdev, measure round only)

| Metric | Baseline (FIFO) | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |
|--------|----------------|-------------|-------------|------------------|
| TPS | N/A | N/A | N/A | 0.1 ± 0.0 |
| Max Latency (s) | N/A | N/A | N/A | 2.35 ± 0.00 |
| Avg Latency (s) | N/A | N/A | N/A | 2.11 ± 0.00 |
| GC Event Count | 1156 ± 903 | 1035 ± 721 | 2694 ± 4484 | 23 ± 2 |
| Max GC Pause (ms) | 2782 ± 3027 | 2113 ± 2109 | 957 ± 1283 | 106 ± 16 |
| Total GC Time (ms) | 471932 ± 461195 | 300521 ± 490815 | 132892 ± 220310 | 729 ± 118 |
| Full GC Count | 176 ± 174 | 91 ± 169 | 614 ± 1354 | 0 ± 0 |
| LASS Activations | 50 ± 32 | 633 ± 318 | 107 ± 44 | 176 ± 10 |

## Change vs Baseline (mean)

| Metric | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |
|--------|-------------|-------------|------------------|
| TPS | N/A | N/A | N/A |
| Max Latency (s) | N/A | N/A | N/A |
| GC Event Count | ↓ 10.4% | ↑ 133.1% | ↓ 98.0% |
| Max GC Pause (ms) | ↓ 24.0% | ↓ 65.6% | ↓ 96.2% |
| Total GC Time (ms) | ↓ 36.3% | ↓ 71.8% | ↓ 99.8% |
| Full GC Count | ↓ 48.5% | ↑ 249.1% | ↓ 100.0% |

## Interpretation

### Hypothesis Validation

**LASS-75 only**: Total GC ↓ 36.3% (471932ms→300521ms), Max GC pause ↓ 24.0%, Full GC ↓ 48.5%, TPS N/A (0→0).
**LAST-AL only**: Total GC ↓ 71.8% (471932ms→132892ms), Max GC pause ↓ 65.6%, Full GC ↑ 249.1%, TPS N/A (0→0).
**LAST-AL + LASS-75 (Synergy)**: Total GC ↓ 99.8% (471932ms→729ms), Max GC pause ↓ 96.2%, Full GC ↓ 100.0%, TPS N/A (0→0).

### Notes
- Metrics from the **measure** round (300s) only; warmup (120s) excluded.
- GC metrics span the entire node lifetime per run (warmup + measure),
  providing a conservative view of steady-state GC behaviour.
- `Max Latency` is the worst single-transaction confirmed latency (Caliper).
- `LASS Activations` counts E-Spill trigger events logged in Besu console.

---
*Report generated by analyze_last_vs_lass.py*