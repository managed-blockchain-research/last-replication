#!/usr/bin/env python3
"""
Parser 2 — LASTMetrics CSV Summarizer (Scenario A)
Reads per-block last_metrics.csv files written by Besu's LASTMetricsLogger
and produces a Markdown summary of warm_hit_rate, scheduler_overhead_us,
and per-block GC deltas aggregated across all reps.

LASTMetricsLogger CSV header:
  timestamp_ms,block_number,last_variant,tx_count,warm_hits,cold_misses,
  warm_set_size,warm_hit_rate,scheduler_overhead_us,block_duration_ms,
  gc_young_delta_count,gc_old_delta_count,gc_young_delta_ms,gc_old_delta_ms,
  gc_total_delta_ms,gc_pause_ratio

Usage:
  python3 summarize_last_metrics.py --results-dir results/scenario_a_besu_4g/<RUN_ID>
  python3 summarize_last_metrics.py --csv-files baseline_1/last_metrics.csv last_al_1/last_metrics.csv
"""

import argparse
import csv
import os
import sys
from collections import defaultdict

import numpy as np

METRICS_FILENAME = "last_metrics.csv"

COLUMNS = [
    "warm_hit_rate",
    "scheduler_overhead_us",
    "gc_total_delta_ms",
    "gc_old_delta_count",
    "tx_count",
]


def parse_one_csv(csv_path: str, variant: str, rep: int) -> list[dict]:
    rows = []
    try:
        with open(csv_path, newline="") as f:
            for row in csv.DictReader(f):
                try:
                    rows.append({
                        "variant": variant,
                        "run": rep,
                        "warm_hit_rate":       float(row.get("warm_hit_rate", 0) or 0),
                        "scheduler_overhead_us": float(row.get("scheduler_overhead_us", 0) or 0),
                        "gc_total_delta_ms":   float(row.get("gc_total_delta_ms", 0) or 0),
                        "gc_old_delta_count":  float(row.get("gc_old_delta_count", 0) or 0),
                        "tx_count":            int(row.get("tx_count", 0) or 0),
                    })
                except (ValueError, KeyError):
                    pass
    except OSError as e:
        print(f"  WARNING: cannot read {csv_path}: {e}", file=sys.stderr)
    return rows


def discover_csvs(results_dir: str) -> list[tuple[str, int, str]]:
    found = []
    for entry in sorted(os.listdir(results_dir)):
        run_dir = os.path.join(results_dir, entry)
        if not os.path.isdir(run_dir):
            continue
        parts = entry.rsplit("_", 1)
        if len(parts) != 2 or not parts[1].isdigit():
            continue
        variant, rep = parts[0], int(parts[1])
        csv_path = os.path.join(run_dir, METRICS_FILENAME)
        if os.path.exists(csv_path):
            found.append((variant, rep, csv_path))
        else:
            print(f"  MISSING: {csv_path}", file=sys.stderr)
    return found


def aggregate(rows: list[dict]) -> dict:
    if not rows:
        return {}
    def _s(col):
        vals = [r[col] for r in rows]
        if not vals:
            return dict(mean=0, p50=0, p95=0, p99=0, max=0, n=0)
        return dict(
            n=len(vals),
            mean=float(np.mean(vals)),
            p50=float(np.percentile(vals, 50)),
            p95=float(np.percentile(vals, 95)),
            p99=float(np.percentile(vals, 99)),
            max=float(max(vals)),
        )
    return {c: _s(c) for c in COLUMNS}


def print_markdown(per_variant: dict[str, list[dict]]):
    variants = list(per_variant.keys())

    print("\n## Scenario A — LASTMetrics Summary (per-block, all reps pooled)\n")
    header = [
        "Variant", "Blocks", "Warm-Hit Rate (mean)", "Warm-Hit Rate (p50)",
        "Warm-Hit Rate (p95)", "Sched Overhead (µs mean)",
        "Sched Overhead (µs p99)", "GC Time/block (ms mean)", "Old-Gen GC/block (mean)",
    ]
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["-" * (len(h) + 2) for h in header]) + "|")

    for v in variants:
        rows = per_variant[v]
        if not rows:
            continue
        a = aggregate(rows)
        cells = [
            v,
            str(len(rows)),
            f"{a['warm_hit_rate']['mean']:.4f}",
            f"{a['warm_hit_rate']['p50']:.4f}",
            f"{a['warm_hit_rate']['p95']:.4f}",
            f"{a['scheduler_overhead_us']['mean']:.1f}",
            f"{a['scheduler_overhead_us']['p99']:.1f}",
            f"{a['gc_total_delta_ms']['mean']:.2f}",
            f"{a['gc_old_delta_count']['mean']:.3f}",
        ]
        print("| " + " | ".join(cells) + " |")

    # Per-rep summary
    print("\n## Scenario A — Per-Rep Warm-Hit Rate Summary\n")
    print("| Run | Blocks | Mean Warm-Hit Rate | Mean Sched Overhead (µs) |")
    print("|-----|--------|-------------------|--------------------------|")
    for v in variants:
        rep_groups: dict[int, list] = defaultdict(list)
        for row in per_variant[v]:
            rep_groups[row["run"]].append(row)
        for rep in sorted(rep_groups):
            rows = rep_groups[rep]
            mean_hr = np.mean([r["warm_hit_rate"] for r in rows])
            mean_oh = np.mean([r["scheduler_overhead_us"] for r in rows])
            print(f"| {v}_{rep} | {len(rows)} | {mean_hr:.4f} | {mean_oh:.1f} |")


def main():
    p = argparse.ArgumentParser(description="Summarize LASTMetricsLogger CSV files")
    p.add_argument("--results-dir", help="Directory with <variant>_<rep>/ subdirs")
    p.add_argument("--csv-files",   nargs="+", help="Explicit CSV file paths")
    p.add_argument("--variants",    nargs="+", help="Variant labels (paired with --csv-files)")
    args = p.parse_args()

    if args.results_dir:
        entries = discover_csvs(args.results_dir)
    elif args.csv_files:
        labels = args.variants or [f"v{i}" for i in range(len(args.csv_files))]
        entries = [(labels[i], i + 1, p) for i, p in enumerate(args.csv_files)]
    else:
        sys.exit("ERROR: provide --results-dir or --csv-files")

    per_variant: dict[str, list[dict]] = defaultdict(list)
    for variant, rep, csv_path in entries:
        print(f"  Loading {variant}_{rep}: {csv_path}", file=sys.stderr)
        rows = parse_one_csv(csv_path, variant, rep)
        per_variant[variant].extend(rows)
        if rows:
            mean_hr = np.mean([r["warm_hit_rate"] for r in rows])
            print(f"    → {len(rows)} blocks, mean warm_hit_rate={mean_hr:.4f}", file=sys.stderr)
        else:
            print(f"    → 0 blocks (empty or missing CSV)", file=sys.stderr)

    print_markdown(per_variant)


if __name__ == "__main__":
    main()
