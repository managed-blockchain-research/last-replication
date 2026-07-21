#!/usr/bin/env python3
"""
LASS Sensitivity Analysis Report
Parses GC logs + latency CSVs from a sensitivity analysis run and
produces a paper-ready comparison table.

Usage:
    python3 scripts/analyze_sensitivity.py results/sensitivity_analysis/20260420_XXXXXX
"""
import sys
import os
import re
import csv
import json
import statistics
from pathlib import Path

VARIANTS = ["baseline", "lass60", "lass75", "lass90"]
VARIANT_LABELS = {
    "baseline": "Baseline",
    "lass60":   "LASS-60%",
    "lass75":   "LASS-75%",
    "lass90":   "LASS-90%",
}

# ─────────────────────────────────────────────────────────────
# GC log parser (Besu uses JEP 158 unified GC logging)
# Sample line:
#   [1.234s][info][gc] GC(3) Pause Young (Normal) (G1 Evacuation Pause) 123.4M->45.6M(2500.0M) 12.345ms
#   [2.345s][info][gc] GC(5) Pause Full (System.gc()) 234M->100M(2500M) 45.678ms
# ─────────────────────────────────────────────────────────────
def parse_gc_log(gc_log_path):
    """Returns dict with gc_count, total_gc_ms, max_pause_ms, pauses list, stw_pauses list."""
    if not os.path.exists(gc_log_path):
        return None

    pauses = []
    stw_pauses = []   # Full / Remark / Cleanup (true STW)

    # Pattern: captures pause duration in ms from unified GC log
    # e.g. "12.345ms" at end of pause line
    pause_pattern = re.compile(r'Pause\s+\w+.*?(\d+\.\d+)ms\s*$', re.MULTILINE)
    # Alternatively look for "real=" from verbose GC or "GC(N) Pause ... Xms"
    gc_time_pattern = re.compile(r'\bPause\b.*?(\d+\.?\d*)ms\s*$')
    stw_pattern = re.compile(r'Pause\s+(Full|Remark|Cleanup)', re.IGNORECASE)

    with open(gc_log_path, 'r', errors='replace') as f:
        for line in f:
            m = gc_time_pattern.search(line)
            if m:
                ms = float(m.group(1))
                pauses.append(ms)
                if stw_pattern.search(line):
                    stw_pauses.append(ms)

    if not pauses:
        return {"gc_count": 0, "total_gc_ms": 0, "max_pause_ms": 0,
                "p99_pause_ms": 0, "stw_count": 0, "max_stw_ms": 0,
                "pauses": [], "overhead_pct": 0}

    pauses.sort()
    total_gc_ms = sum(pauses)
    max_pause = max(pauses)
    p99_idx = max(0, int(len(pauses) * 0.99) - 1)
    p99_pause = pauses[p99_idx]

    return {
        "gc_count": len(pauses),
        "total_gc_ms": round(total_gc_ms, 1),
        "max_pause_ms": round(max_pause, 1),
        "p99_pause_ms": round(p99_pause, 1),
        "stw_count": len(stw_pauses),
        "max_stw_ms": round(max(stw_pauses), 1) if stw_pauses else 0,
        "pauses": pauses,
        "overhead_pct": 0,  # filled later
    }

# ─────────────────────────────────────────────────────────────
# Latency CSV parser
# ─────────────────────────────────────────────────────────────
def parse_latency_csv(csv_path):
    """Returns dict with tps, p50, p95, p99, p999, max, stdev, cv, success_count, error_count."""
    if not os.path.exists(csv_path):
        # Try alternate naming
        return None

    latencies = []
    success_count = 0
    error_count = 0
    timestamps = []

    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                lat = float(row.get('latency_ms', 0))
                ts = float(row.get('timestamp', 0))
                success = str(row.get('success', 'true')).lower() == 'true'
                if success:
                    latencies.append(lat)
                    success_count += 1
                    timestamps.append(ts)
                else:
                    error_count += 1
            except (ValueError, KeyError):
                pass

    if not latencies:
        return {"tps": 0, "p50": 0, "p95": 0, "p99": 0, "p999": 0, "max": 0,
                "stdev": 0, "cv": 0, "success_count": 0, "error_count": error_count}

    latencies.sort()
    n = len(latencies)

    # TPS from timestamp range
    if len(timestamps) > 1:
        duration_s = (max(timestamps) - min(timestamps))
        tps = n / duration_s if duration_s > 0 else 0
    else:
        tps = 0

    def pct(arr, p):
        idx = max(0, int(len(arr) * p / 100) - 1)
        return arr[idx]

    mean = statistics.mean(latencies)
    stdev = statistics.stdev(latencies) if len(latencies) > 1 else 0
    cv = (stdev / mean * 100) if mean > 0 else 0

    return {
        "tps": round(tps, 1),
        "p50": round(pct(latencies, 50), 1),
        "p95": round(pct(latencies, 95), 1),
        "p99": round(pct(latencies, 99), 1),
        "p999": round(pct(latencies, 99.9), 1),
        "max": round(max(latencies), 1),
        "stdev": round(stdev, 1),
        "cv": round(cv, 1),
        "success_count": success_count,
        "error_count": error_count,
    }

# ─────────────────────────────────────────────────────────────
# LASS-specific stats from besu_console.log
# ─────────────────────────────────────────────────────────────
def parse_lass_stats(console_log_path):
    """Extract LASS activation count, spill events, total spilled from trajectory log."""
    if not os.path.exists(console_log_path):
        return {"activations": 0, "spill_events": 0, "total_spilled": 0,
                "peak_heap_pct": 0, "final_heap_pct": 0}

    activations = 0
    spill_events = 0
    total_spilled = 0
    heap_pcts = []

    traj_pattern = re.compile(
        r'TRAJECTORY: heap=(\d+\.?\d*)%.*activations=(\d+)\s+spillEvents=(\d+)\s+totalSpilled=(\d+)')

    with open(console_log_path, 'r', errors='replace') as f:
        for line in f:
            m = traj_pattern.search(line)
            if m:
                heap_pcts.append(float(m.group(1)))
                activations = int(m.group(2))
                spill_events = int(m.group(3))
                total_spilled = int(m.group(4))

    return {
        "activations": activations,
        "spill_events": spill_events,
        "total_spilled": total_spilled,
        "peak_heap_pct": round(max(heap_pcts), 1) if heap_pcts else 0,
        "final_heap_pct": round(heap_pcts[-1], 1) if heap_pcts else 0,
    }

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
def main():
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/analyze_sensitivity.py <results_dir>")
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    if not results_dir.exists():
        print(f"ERROR: {results_dir} not found")
        sys.exit(1)

    print(f"\n{'='*70}")
    print(f"LASS SENSITIVITY ANALYSIS REPORT")
    print(f"Results dir: {results_dir}")
    print(f"{'='*70}\n")

    # Load provenance
    prov_file = results_dir / "provenance.txt"
    if prov_file.exists():
        print("PROVENANCE:")
        print(prov_file.read_text())

    # Collect per-variant data
    data = {}
    for variant in VARIANTS:
        gc_log = results_dir / f"gc_{variant}.log"
        # latency CSV: extreme_baseline_test.py saves as <output_prefix>_latency.csv
        latency_csv = results_dir / f"{variant}_latency.csv"
        console_log = results_dir / f"{variant}_besu_console.log"

        gc = parse_gc_log(str(gc_log))
        lat = parse_latency_csv(str(latency_csv))
        lass = parse_lass_stats(str(console_log))

        data[variant] = {"gc": gc, "lat": lat, "lass": lass,
                         "present": gc is not None or lat is not None}

    # ── Table 1: Throughput & Latency ──────────────────────
    print(f"\n{'─'*70}")
    print(f"TABLE 1: Throughput & Latency")
    print(f"{'─'*70}")

    hdr = f"{'Variant':<12} {'TPS':>8} {'P50(ms)':>9} {'P95(ms)':>9} {'P99(ms)':>9} {'P99.9(ms)':>10} {'CV%':>7}"
    print(hdr)
    print("─" * 68)

    baseline_tps = None
    baseline_p99 = None
    for v in VARIANTS:
        lat = data[v]["lat"]
        if lat:
            tps = lat["tps"]
            if v == "baseline":
                baseline_tps = tps
                baseline_p99 = lat["p99"]
            tps_delta = f"({(tps/baseline_tps-1)*100:+.1f}%)" if baseline_tps and v != "baseline" else ""
            p99_delta = f"({(lat['p99']/baseline_p99-1)*100:+.1f}%)" if baseline_p99 and v != "baseline" else ""
            print(f"{VARIANT_LABELS[v]:<12} {tps:>8.1f}{tps_delta:<10} {lat['p50']:>9.1f} "
                  f"{lat['p95']:>9.1f} {lat['p99']:>9.1f}{p99_delta:<10} {lat['p999']:>10.1f} {lat['cv']:>7.1f}")
        else:
            print(f"{VARIANT_LABELS[v]:<12} {'N/A':>8}")

    # ── Table 2: GC Metrics ────────────────────────────────
    print(f"\n{'─'*70}")
    print(f"TABLE 2: GC Metrics (600s window)")
    print(f"{'─'*70}")

    hdr2 = f"{'Variant':<12} {'GC Count':>10} {'Total GCms':>12} {'Max Pause':>10} {'P99 Pause':>10} {'STW Count':>10}"
    print(hdr2)
    print("─" * 68)

    for v in VARIANTS:
        gc = data[v]["gc"]
        if gc:
            print(f"{VARIANT_LABELS[v]:<12} {gc['gc_count']:>10} {gc['total_gc_ms']:>12.1f} "
                  f"{gc['max_pause_ms']:>10.1f} {gc['p99_pause_ms']:>10.1f} {gc['stw_count']:>10}")
        else:
            print(f"{VARIANT_LABELS[v]:<12} {'N/A':>10}")

    # ── Table 3: LASS-specific metrics ────────────────────
    print(f"\n{'─'*70}")
    print(f"TABLE 3: LASS Activation Metrics")
    print(f"{'─'*70}")

    hdr3 = f"{'Variant':<12} {'Activations':>12} {'SpillEvents':>12} {'TotalSpilled':>13} {'PeakHeap%':>10} {'FinalHeap%':>11}"
    print(hdr3)
    print("─" * 70)

    for v in VARIANTS:
        lass = data[v]["lass"]
        print(f"{VARIANT_LABELS[v]:<12} {lass['activations']:>12} {lass['spill_events']:>12} "
              f"{lass['total_spilled']:>13} {lass['peak_heap_pct']:>10.1f} {lass['final_heap_pct']:>11.1f}")

    # ── Summary: vs Baseline ──────────────────────────────
    print(f"\n{'─'*70}")
    print(f"SUMMARY vs BASELINE")
    print(f"{'─'*70}")

    bl_lat = data["baseline"]["lat"]
    bl_gc  = data["baseline"]["gc"]

    for v in ["lass60", "lass75", "lass90"]:
        lat = data[v]["lat"]
        gc  = data[v]["gc"]
        label = VARIANT_LABELS[v]

        if lat and bl_lat and bl_lat["tps"] > 0:
            tps_chg = (lat["tps"] / bl_lat["tps"] - 1) * 100
            p99_chg = (lat["p99"] / bl_lat["p99"] - 1) * 100 if bl_lat["p99"] > 0 else 0
            print(f"  {label}: TPS {tps_chg:+.1f}%, P99 {p99_chg:+.1f}%", end="")

        if gc and bl_gc and bl_gc["total_gc_ms"] > 0:
            gc_chg = (gc["total_gc_ms"] / bl_gc["total_gc_ms"] - 1) * 100
            pause_chg = (gc["max_pause_ms"] / bl_gc["max_pause_ms"] - 1) * 100 if bl_gc["max_pause_ms"] > 0 else 0
            print(f", GC-time {gc_chg:+.1f}%, MaxPause {pause_chg:+.1f}%", end="")
        print()

    # Save JSON report
    report_file = results_dir / "sensitivity_report.json"
    with open(report_file, 'w') as f:
        json.dump({v: {k: data[v][k] for k in data[v] if k != 'present'}
                   for v in VARIANTS}, f, indent=2, default=str)

    print(f"\nJSON report saved: {report_file}")
    print()


if __name__ == '__main__':
    main()
