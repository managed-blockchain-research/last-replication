# LAST vs LASS Head-to-Head Evaluation @ 1GB Heap (Besu)

**Generated:** 2026-08-31 21:50:15
**Results dir:** `/home/yeochan.yoon/caliper-stress-test/results/last_vs_lass_4g/20260831_123554_last_vs_lass_4g`

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
| baseline_1 | N/A | N/A | N/A | 6232 | 1563 | 895547 | 972 | 0 |
| baseline_2 | N/A | N/A | N/A | 2990 | 1385 | 574277 | 619 | 0 |
| baseline_3 | N/A | N/A | N/A | 5302 | 1278 | 762966 | 915 | 0 |
| baseline_4 | N/A | N/A | N/A | 10085 | 1039 | 1152808 | 3368 | 0 |
| baseline_5 | N/A | N/A | N/A | 4034 | 1356 | 793748 | 757 | 0 |

### LASS-75 only

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| lass75_1 | N/A | N/A | N/A | 4620 | 1704 | 938796 | 867 | 0 |
| lass75_2 | N/A | N/A | N/A | 4440 | 1435 | 823026 | 841 | 0 |
| lass75_3 | N/A | N/A | N/A | 5323 | 1351 | 889237 | 988 | 0 |
| lass75_4 | N/A | N/A | N/A | 5329 | 1016 | 597120 | 1040 | 0 |
| lass75_5 | N/A | N/A | N/A | 4281 | 1208 | 948314 | 1272 | 0 |

### LAST-AL only

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| last_al_1 | N/A | N/A | N/A | 4024 | 2222 | 958882 | 591 | 0 |
| last_al_2 | N/A | N/A | N/A | 5761 | 2229 | 799123 | 1620 | 0 |
| last_al_3 | N/A | N/A | N/A | 6150 | 1975 | 837016 | 1309 | 0 |
| last_al_4 | N/A | N/A | N/A | 845 | 1644 | 233038 | 167 | 0 |
| last_al_5 | N/A | N/A | N/A | 2443 | 2081 | 485498 | 300 | 0 |

### LAST-AL + LASS-75

| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |
|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|
| last_lass75_1 | N/A | N/A | N/A | 1846 | 1751 | 192921 | 118 | 0 |
| last_lass75_2 | N/A | N/A | N/A | 3309 | 2016 | 720552 | 402 | 0 |
| last_lass75_3 | N/A | N/A | N/A | 3322 | 2006 | 847710 | 530 | 0 |
| last_lass75_4 | N/A | N/A | N/A | 5600 | 2151 | 782234 | 1149 | 0 |
| last_lass75_5 | N/A | N/A | N/A | 2847 | 2002 | 271715 | 181 | 0 |

## Summary Statistics (mean ± stdev, measure round only)

| Metric | Baseline (FIFO) | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |
|--------|----------------|-------------|-------------|------------------|
| TPS | N/A | N/A | N/A | N/A |
| Max Latency (s) | N/A | N/A | N/A | N/A |
| Avg Latency (s) | N/A | N/A | N/A | N/A |
| GC Event Count | 5729 ± 2729 | 4799 ± 496 | 3845 ± 2235 | 3385 ± 1376 |
| Max GC Pause (ms) | 1324 ± 190 | 1343 ± 257 | 2030 ± 240 | 1985 ± 145 |
| Total GC Time (ms) | 835869 ± 211856 | 839299 ± 144216 | 662712 ± 296956 | 563026 ± 306493 |
| Full GC Count | 1326 ± 1150 | 1002 ± 172 | 797 ± 638 | 476 ± 411 |
| LASS Activations | 0 ± 0 | 0 ± 0 | 0 ± 0 | 0 ± 0 |

## Change vs Baseline (mean)

| Metric | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |
|--------|-------------|-------------|------------------|
| TPS | N/A | N/A | N/A |
| Max Latency (s) | N/A | N/A | N/A |
| GC Event Count | ↓ 16.2% | ↓ 32.9% | ↓ 40.9% |
| Max GC Pause (ms) | ↑ 1.4% | ↑ 53.3% | ↑ 49.9% |
| Total GC Time (ms) | ↑ 0.4% | ↓ 20.7% | ↓ 32.6% |
| Full GC Count | ↓ 24.5% | ↓ 39.9% | ↓ 64.1% |

## Interpretation

### Hypothesis Validation

**LASS-75 only**: Total GC ↑ 0.4% (835869ms→839299ms), Max GC pause ↑ 1.4%, Full GC ↓ 24.5%, TPS N/A (0→0).
**LAST-AL only**: Total GC ↓ 20.7% (835869ms→662712ms), Max GC pause ↑ 53.3%, Full GC ↓ 39.9%, TPS N/A (0→0).
**LAST-AL + LASS-75 (Synergy)**: Total GC ↓ 32.6% (835869ms→563026ms), Max GC pause ↑ 49.9%, Full GC ↓ 64.1%, TPS N/A (0→0).

### Notes
- Metrics from the **measure** round (300s) only; warmup (120s) excluded.
- GC metrics span the entire node lifetime per run (warmup + measure),
  providing a conservative view of steady-state GC behaviour.
- `Max Latency` is the worst single-transaction confirmed latency (Caliper).
- `LASS Activations` counts E-Spill trigger events logged in Besu console.

---
*Report generated by analyze_last_vs_lass.py*