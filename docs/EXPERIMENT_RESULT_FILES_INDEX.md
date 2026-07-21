# Experiment Result Files — Full Index

Inventory of all LASS/e-spill experiment result files and where the **paper numbers** come from.

---

## 1. Paper numbers ↔ repo (real data)

The paper’s main claims are backed by the following artifacts:

| Paper claim | Source in repo | Exact numbers |
|-------------|-----------------|---------------|
| **Besu: 96.2% GC overhead reduction** | `FINAL_COMPARISON_RESULTS.md` (GC Metrics) | Total GC time: 5.366s → 0.200s ⇒ (5.366−0.200)/5.366 = **96.27%** |
| **Besu: 98.1% fewer STW events** | Same | Events: 837 → 16 ⇒ (837−16)/837 = **98.09%** |
| **Besu: 35.4% P99 STW reduction** | `FINAL_COMPARISON_RESULTS_BESU_RERUN.md` or paper intro | P99 pause: 47.70 ms → 30.82 ms ⇒ **~35%** (rerun) |
| **Nethermind: 5.7% throughput increase** | `FINAL_COMPARISON_RESULTS_NETHERMIND.md` | 197.93 → 209.31 tx/s ⇒ (209.31−197.93)/197.93 = **5.75%** |
| **Nethermind: 5.9% throughput** (intro) | Same run | Same data, rounded to 5.9% |
| **P99 execution latency up to 6.0%** | Same or other Nethermind runs | e.g. P99 275.41 → 261.88 ms ⇒ ~4.9%; “up to 6%” may be another run |

**Conclusion:** The 96.2%, 98.1%, 5.7%, 5.9% and the P99 STW ~35% come from real experiment outputs in this repo.

---

## 2. Besu (extreme) — baseline vs e-spill/LASS

### Primary (paper) run — high GC pressure

- **Summary:** `FINAL_COMPARISON_RESULTS.md`
- **Latency:**  
  - `results/extreme/baseline_latency.csv`  
  - `results/extreme/espill_latency.csv`
- **Comparison:** `results/extreme/comparison-20260128/`
  - `latency_summary.json`, `latency_summary.csv`
  - `latency_percentiles.png`, `latency_average.png`
- **GC:** Documented in FINAL_COMPARISON_RESULTS.md (837 vs 16 events; 5.366s vs 0.200s).  
  Raw GC logs for this run may be under different names/dates (see §4).

### Rerun (JFR, lower GC pressure)

- **Summary:** `FINAL_COMPARISON_RESULTS_BESU_RERUN.md`
- **Latency:**  
  - `results/extreme/retry-20260129_104658/baseline_latency.csv`  
  - `results/extreme/retry-20260129_104658/espill_latency.csv`
- **Comparison:** `results/extreme/comparison-20260129-retry/`
  - `latency_summary.json`, `latency_summary.csv`
  - `baseline_gc_summary.txt`, `espill_gc_summary.txt`
- **GC logs (this rerun):**  
  - `baseline_harsh_gc_20260129_105717.log`  
  - `espill_harsh_gc_20260129_121658.log`  
  (25 vs 31 events, 0.02% vs 0.01% — used for P99 STW ~35%, not for 96.2% / 98.1%.)

### Other extreme/harsh runs

- `results/extreme/comparison-20260128-rerun/` — baseline & espill GC summaries, latency.
- Root-level GC logs:  
  `baseline_harsh_gc_*.log`, `espill_harsh_gc_*.log`, `espill_full_gc_*.log`, `baseline_gc_*.log`.

---

## 3. Nethermind — baseline vs e-spill/LASS

### GCDump run (paper throughput / latency)

- **Summary:** `FINAL_COMPARISON_RESULTS_NETHERMIND.md`
- **Latency:**  
  - `results/nethermind/gcdump-20260130_125919/baseline_pre_latency.csv`  
  - `results/nethermind/gcdump-20260130_125919/espill_pre_latency.csv`
- **Comparison:** `results/nethermind/comparison-20260130-gcdump/`
  - `latency_summary.json`, `latency_summary.csv`
  - `latency_percentiles.png`, `latency_average.png`
- **GC/gcdump:**  
  - `results/nethermind/gcdump-20260130_125919/baseline_pre_gcdump_report.txt`  
  - `results/nethermind/gcdump-20260130_125919/espill_pre_gcdump_report.txt`  
  - `results/nethermind/gcdump-20260130_125919/espill_pre_post_gcdump_report.txt`

### Other Nethermind runs

- **High-slots / monitor:**  
  - `results/nethermind/highslots-monitor-20260130_*`  
  - `results/nethermind/highslots-20260129_*`  
  - `results/nethermind/highslots-20260129_154120`, `161325`, `172015`, `174123`  
  (each: `baseline_latency.csv`, `espill_latency.csv`, counters/metrics as present.)
- **Moderate / trace:**  
  - `results/nethermind/moderate-trace-20260129_150534/`  
  - `results/nethermind/comparison-20260129-moderate-trace/`
- **Retry / counters / gcverbose:**  
  - `results/nethermind/retry-20260129_*`  
  - `results/nethermind/comparison-20260129-counters/`  
  - `results/nethermind/comparison-20260129-gcverbose/`  
  - `results/nethermind/comparison-20260129-retry/`
- **Older:**  
  - `results/nethermind/comparison-20260128/`  
  - `results/nethermind/baseline_latency.csv`, `espill_latency.csv`

---

## 4. GC logs (Besu)

- **Root (extreme/harsh):**  
  `baseline_harsh_gc_*.log`, `espill_harsh_gc_*.log`, `espill_full_gc_*.log`, `baseline_gc_*.log`
- **Analysis:** `scripts/monitor_gc.py` → summary + optional CSV.
- **Comparison summaries:**  
  `results/extreme/comparison-20260129-retry/*_gc_summary.txt`  
  `results/extreme/comparison-20260128-rerun/*_gc_summary.txt`

The **837 vs 16 events** and **5.366s vs 0.200s** in FINAL_COMPARISON_RESULTS.md come from the **comparison-20260128** extreme run (20 workers, 200 slots, 600s). Raw GC log filenames for that exact run may be earlier baseline/espill logs; the numbers are recorded in the doc.

---

## 5. Data directories (Besu chain)

- `data_baseline_harsh/`, `data_espill_harsh/` — harsh run chain data.
- `data_espill_full/`, `data_espill_smoke*/`, `data_bl/` — other e-spill test data.
- `data_nethermind/` — Nethermind.

---

## 6. Scripts that produce/use these results

- **Compare baseline vs e-spill:** `scripts/compare_results.py <results_directory>`
- **Besu GC analysis:** `scripts/monitor_gc.py <gc_log_file> [output_csv]`
- **Nethermind gcdump:** `scripts/run_nethermind_gcdump.sh` (and related docs).

---

## 7. Quick reference: where each paper number lives

| Number | Meaning | File / doc |
|--------|--------|------------|
| 96.2% | GC overhead (total GC time) reduction, Besu | `FINAL_COMPARISON_RESULTS.md` (5.366s → 0.200s) |
| 98.1% | STW event count reduction, Besu | `FINAL_COMPARISON_RESULTS.md` (837 → 16) |
| 35.4% | P99 STW duration reduction, Besu | `FINAL_COMPARISON_RESULTS_BESU_RERUN.md` (47.70 → 30.82 ms) |
| 5.7% / 5.9% | Throughput increase, Nethermind | `FINAL_COMPARISON_RESULTS_NETHERMIND.md` (197.93 → 209.31 tx/s) |
| Up to 6.0% | P99 execution latency improvement | Same Nethermind run or other runs in `results/nethermind/` |

All of these are traceable to real experiment result files in this repository.
