# LAST vs LASS Head-to-Head Evaluation @ 1GB Heap (Besu)

**Generated:** 2026-04-24 03:51:48
**Results dir:** `/home/yeochan.yoon/caliper-stress-test/results/last_vs_lass/20260423_203708_last_vs_lass`

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
| baseline_1 | N/A | N/A | N/A | 50 | 43 | 546 | 0 | 4 |
| baseline_2 | N/A | N/A | N/A | 5730 | 782 | 509905 | 1949 | 25 |
| baseline_3 | N/A | N/A | N/A | 3030 | 315 | 228041 | 918 | 30 |
| baseline_4 | N/A | N/A | N/A | 3893 | 612 | 190191 | 1216 | 181 |
| baseline_5 | N/A | N/A | N/A | 4403 | 203 | 250224 | 2011 | 23 |

### LASS-75 only

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| lass75_1 | N/A | N/A | N/A | 5100 | 150 | 302366 | 2685 | 40 |
| lass75_2 | N/A | N/A | N/A | 2020 | 1238 | 552334 | 741 | 109 |
| lass75_3 | N/A | N/A | N/A | 1652 | 254 | 141628 | 702 | 33 |
| lass75_4 | N/A | N/A | N/A | 3926 | 169 | 241682 | 1967 | 50 |
| lass75_5 | N/A | N/A | N/A | 3724 | 1764 | 1131569 | 1253 | 185 |

### LAST-AL only

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| last_al_1 | N/A | N/A | N/A | 5645 | 1581 | 1117826 | 2014 | 39 |
| last_al_2 | N/A | N/A | N/A | 5159 | 1714 | 1119342 | 1602 | 76 |
| last_al_3 | N/A | N/A | N/A | 5169 | 1079 | 1113512 | 2011 | 104 |
| last_al_4 | N/A | N/A | N/A | 5700 | 1001 | 1110625 | 2215 | 109 |
| last_al_5 | N/A | N/A | N/A | 2743 | 970 | 416316 | 774 | 35 |

### LAST-AL + LASS-75

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| last_lass75_1 | N/A | N/A | N/A | 2974 | 1219 | 830063 | 1268 | 72 |
| last_lass75_2 | N/A | N/A | N/A | 3677 | 1651 | 1126053 | 1379 | 11 |
| last_lass75_3 | N/A | N/A | N/A | 2574 | 1452 | 758413 | 919 | 10 |
| last_lass75_4 | N/A | N/A | N/A | 1675 | 1445 | 456615 | 607 | 82 |
| last_lass75_5 | N/A | N/A | N/A | 1331 | 1074 | 312914 | 530 | 95 |

## Summary Statistics (mean ± stdev, measure round only)

| Metric | Baseline (FIFO) | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |
|--------|----------------|-------------|-------------|------------------|
| TPS | N/A | N/A | N/A | N/A |
| Max Latency (s) | N/A | N/A | N/A | N/A |
| Avg Latency (s) | N/A | N/A | N/A | N/A |
| GC Event Count | 3421 ± 2123 | 3284 ± 1429 | 4883 ± 1223 | 2446 ± 955 |
| Max GC Pause (ms) | 391 ± 302 | 715 ± 743 | 1269 ± 351 | 1368 ± 225 |
| Total GC Time (ms) | 235781 ± 182227 | 473916 ± 397629 | 975524 ± 312626 | 696812 ± 320496 |
| Full GC Count | 1219 ± 827 | 1470 ± 850 | 1723 ± 576 | 941 ± 381 |
| LASS Activations | 53 ± 72 | 83 ± 64 | 73 ± 35 | 54 ± 41 |

## Change vs Baseline (mean)

| Metric | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |
|--------|-------------|-------------|------------------|
| TPS | N/A | N/A | N/A |
| Max Latency (s) | N/A | N/A | N/A |
| GC Event Count | ↓ 4.0% | ↑ 42.7% | ↓ 28.5% |
| Max GC Pause (ms) | ↑ 82.9% | ↑ 224.6% | ↑ 250.0% |
| Total GC Time (ms) | ↑ 101.0% | ↑ 313.7% | ↑ 195.5% |
| Full GC Count | ↑ 20.6% | ↑ 41.4% | ↓ 22.8% |

## Interpretation

### Hypothesis Validation

**LASS-75 only**: Total GC ↑ 101.0% (235781ms→473916ms), Max GC pause ↑ 82.9%, Full GC ↑ 20.6%, TPS N/A (0→0).
**LAST-AL only**: Total GC ↑ 313.7% (235781ms→975524ms), Max GC pause ↑ 224.6%, Full GC ↑ 41.4%, TPS N/A (0→0).
**LAST-AL + LASS-75 (Synergy)**: Total GC ↑ 195.5% (235781ms→696812ms), Max GC pause ↑ 250.0%, Full GC ↓ 22.8%, TPS N/A (0→0).

### Notes
- Metrics from the **measure** round (300s) only; warmup (120s) excluded.
- GC metrics span the entire node lifetime per run (warmup + measure),
  providing a conservative view of steady-state GC behaviour.
- `Max Latency` is the worst single-transaction confirmed latency (Caliper).
- `LASS Activations` counts E-Spill trigger events logged in Besu console.

---
*Report generated by analyze_last_vs_lass.py*