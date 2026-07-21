# BASELINE vs E-SPILL COMPARISON PLOTS

## Purpose
This document explains the purpose and interpretation of each comparison plot for the
matched baseline and e-spill runs (10 workers, 50 slots/tx, 1000 tx/s, 600s).

## Data Sources
- Baseline latency logs: `results/extreme/baseline_latency.csv`
- E-Spill latency logs: `results/extreme/espill_latency.csv`
- Summary file: `results/extreme/comparison-20260128/latency_summary.json`

## Plot 1: Latency Percentiles
**File:** `results/extreme/comparison-20260128/latency_percentiles.png`

**Purpose:**  
Shows P50, P95, and P99 latencies for baseline vs e-spill. This directly captures
median performance and tail behavior under identical workloads.

**How to read it:**  
- **P50** reflects the typical transaction latency.  
- **P95/P99** highlight tail latency and jitter impact.  
- Lower bars are better; closer P95 and P99 indicate more predictable latency.

**Analysis:**  
- Baseline P50/P95/P99: 95.90 / 371.53 / 548.08 ms  
- E-Spill P50/P95/P99: 94.67 / 351.80 / 515.20 ms  
E-spill shows improved tail latency at P95 and P99 under extreme intensity, with
a small improvement in median as well.

## Plot 2: Average Latency
**File:** `results/extreme/comparison-20260128/latency_average.png`

**Purpose:**  
Shows mean latency for baseline vs e-spill. This summarizes overall time-to-confirm
per transaction for the matched workload.

**How to read it:**  
- Lower bars indicate faster average processing.  
- Differences reflect systemic overhead, batching behavior, or backpressure.

**Analysis:**  
- Baseline avg: 132.40 ms  
- E-Spill avg: 127.77 ms  
E-spill is modestly faster on average in this extreme run, aligning with the tail
latency improvements.

## Notes for Paper
- These plots use **matched extreme workload settings** to avoid confounding variables.
- Consider running 3+ trials and plotting mean + error bars to show stability.

## Additional Extreme Plots (Requested)

### Plot 3: Throughput & Failure Rate (Bar + Line)
**File:** `results/extreme/figures-20260128/throughput_failure_rate.png`  
**Purpose:** Show that e-spill improves throughput under extreme load without hurting reliability.  
**Analysis:** E-spill sustains 113.85 tx/s vs baseline 108.75 tx/s, with similar failure rates (~13.9% vs ~14.5%).

### Plot 4: Latency CDF (Log X)
**File:** `results/extreme/figures-20260128/latency_cdf.png`  
**Purpose:** Visualize tail latency and the “cliff” effect.  
**Analysis:** The e-spill curve stays left of baseline in the tail, reflecting the P99 drop from 548.08 ms to 515.20 ms.

### Plot 5: GC Overhead vs Event Count
**File:** `results/extreme/figures-20260128/gc_overhead_events.png`  
**Purpose:** Show GC overhead reduction and fewer GC events with e-spill.  
**Analysis:** GC overhead drops from 0.24% to 0.02%, and GC events from 837 to 16.

### Plot 6: Jitter (Violin)
**File:** `results/extreme/figures-20260128/jitter_violin.png`  
**Purpose:** Show variance shape and consistency improvements.  
**Analysis:** E-spill’s distribution is tighter, consistent with CV improving from 90.6% to 88.1%.
