#!/usr/bin/env python3
"""
Analyze Nethermind LASS sensitivity from Caliper + dotnet-counters runs.

Usage:
    python3 analyze_nm_sensitivity.py <results_dir>

Reads dotnet_counters.csv and caliper_console.log from each run subdir.
Outputs final_nethermind_evaluation_1GB.md.
"""
import sys
import os
import re
import csv
import math
import json
from pathlib import Path
from datetime import datetime


def parse_dotnet_counters(csv_path):
    """
    Parse dotnet-counters CSV. Returns dict of summary stats:
    gen0_count, gen1_count, gen2_count, max_time_in_gc_pct, avg_time_in_gc_pct,
    peak_heap_mb, total_alloc_gb
    """
    result = {
        'gen0_count': 0,
        'gen1_count': 0,
        'gen2_count': 0,
        'max_time_in_gc_pct': 0.0,
        'avg_time_in_gc_pct': 0.0,
        'peak_heap_mb': 0.0,
        'total_alloc_gb': 0.0,
    }
    if not os.path.exists(csv_path):
        return result

    time_gc_samples = []
    gen0_series = []
    gen1_series = []
    gen2_series = []
    heap_series = []
    alloc_series = []

    try:
        with open(csv_path, newline='') as f:
            reader = csv.DictReader(f)
            # Normalize headers
            fieldnames = [h.lower().strip() for h in (reader.fieldnames or [])]
            name_col = next((reader.fieldnames[i] for i, h in enumerate(fieldnames)
                             if 'counter' in h or 'name' in h), None)
            val_col = next((reader.fieldnames[i] for i, h in enumerate(fieldnames)
                            if 'value' in h or 'mean' in h or 'increment' in h), None)
            if not name_col or not val_col:
                return result

            for row in reader:
                cn = str(row.get(name_col, '')).lower().strip()
                try:
                    v = float(row.get(val_col, 0) or 0)
                except ValueError:
                    continue
                if 'gen-0-gc-count' in cn:
                    gen0_series.append(v)
                elif 'gen-1-gc-count' in cn:
                    gen1_series.append(v)
                elif 'gen-2-gc-count' in cn:
                    gen2_series.append(v)
                elif 'time-in-gc' in cn:
                    time_gc_samples.append(v)
                elif 'gc-heap-size' in cn:
                    heap_series.append(v / (1024 * 1024))  # bytes → MB
                elif 'alloc-rate' in cn:
                    alloc_series.append(v)
    except Exception:
        return result

    # For cumulative counters, take max (last value)
    result['gen0_count'] = int(max(gen0_series)) if gen0_series else 0
    result['gen1_count'] = int(max(gen1_series)) if gen1_series else 0
    result['gen2_count'] = int(max(gen2_series)) if gen2_series else 0
    result['max_time_in_gc_pct'] = max(time_gc_samples) if time_gc_samples else 0.0
    result['avg_time_in_gc_pct'] = sum(time_gc_samples) / len(time_gc_samples) if time_gc_samples else 0.0
    result['peak_heap_mb'] = max(heap_series) if heap_series else 0.0
    # alloc-rate is bytes/sec, sum over 600s ≈ total allocated
    if alloc_series:
        # Average rate * 600s / 1e9 = GB
        result['total_alloc_gb'] = sum(alloc_series) / len(alloc_series) * 600 / 1e9
    return result


def parse_gc_summary(summary_path):
    """Parse gc_summary.txt written by NettraceGcParser.dll."""
    result = {
        'gen0_count': 0, 'gen1_count': 0, 'gen2_count': 0,
        'total_gc_count': 0, 'total_pause_ms': 0.0, 'avg_pause_ms': 0.0,
        'total_pause_count': 0, 'trace_duration_s': 0.0,
        # legacy compat
        'max_time_in_gc_pct': 0.0, 'avg_time_in_gc_pct': 0.0,
        'peak_heap_mb': 0.0, 'total_alloc_gb': 0.0,
    }
    if not os.path.exists(summary_path):
        return result
    try:
        with open(summary_path) as f:
            for line in f:
                line = line.strip()
                if '=' not in line:
                    continue
                k, v = line.split('=', 1)
                if k == 'gen0_gc_count': result['gen0_count'] = int(v)
                elif k == 'gen1_gc_count': result['gen1_count'] = int(v)
                elif k == 'gen2_gc_count': result['gen2_count'] = int(v)
                elif k == 'total_gc_count': result['total_gc_count'] = int(v)
                elif k == 'total_pause_ms': result['total_pause_ms'] = float(v)
                elif k == 'avg_pause_ms': result['avg_pause_ms'] = float(v)
                elif k == 'total_pause_count': result['total_pause_count'] = int(v)
                elif k == 'trace_duration_s': result['trace_duration_s'] = float(v)
    except Exception:
        pass
    return result


def parse_caliper_results(caliper_log):
    """Parse Caliper console log for TPS and latency."""
    tps = None
    max_lat = None
    avg_lat = None
    if not os.path.exists(caliper_log):
        return None, None, None
    with open(caliper_log) as f:
        for line in f:
            m = re.search(r'\|\s*cliff-probe\s*\|\s*([\d]+)\s*\|\s*([\d]+)\s*\|'
                          r'\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|', line)
            if m:
                max_lat = float(m.group(4))
                avg_lat = float(m.group(6))
                tps = float(m.group(7))
    return tps, max_lat, avg_lat


def load_variant_rows(results_dir, variant_prefix):
    rows = []
    p = Path(results_dir)
    for entry in sorted(p.iterdir()):
        if not entry.is_dir():
            continue
        if not entry.name.startswith(variant_prefix + '_'):
            continue
        # Prefer gc_summary.txt (from dotnet-trace), fall back to dotnet_counters.csv
        gc_summary_path = str(entry / 'gc_summary.txt')
        counters_path = str(entry / 'dotnet_counters.csv')
        if os.path.exists(gc_summary_path):
            gc = parse_gc_summary(gc_summary_path)
        else:
            gc = parse_dotnet_counters(counters_path)
        tps, max_lat, avg_lat = parse_caliper_results(str(entry / 'caliper_console.log'))
        rows.append({
            'run': entry.name,
            'tps': tps,
            'max_lat': max_lat,
            'avg_lat': avg_lat,
            'gen0_count': gc['gen0_count'],
            'gen1_count': gc['gen1_count'],
            'gen2_count': gc['gen2_count'],
            'gc_count': gc.get('total_gc_count', gc['gen0_count'] + gc['gen1_count'] + gc['gen2_count']),
            'total_pause_ms': gc.get('total_pause_ms', 0.0),
            'avg_pause_ms': gc.get('avg_pause_ms', 0.0),
            'max_time_in_gc': gc['max_time_in_gc_pct'],
            'avg_time_in_gc': gc['avg_time_in_gc_pct'],
            'peak_heap_mb': gc['peak_heap_mb'],
            'total_alloc_gb': gc['total_alloc_gb'],
        })
    return rows


def mean(vals):
    return sum(vals) / len(vals) if vals else 0.0


def stdev(vals):
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))


def fmt(rows, key, prec=1):
    vals = [r[key] for r in rows if r[key] is not None]
    if not vals:
        return "N/A"
    return f"{mean(vals):.{prec}f} ± {stdev(vals):.{prec}f}"


def pct_change(base_rows, cmp_rows, key):
    bv = [r[key] for r in base_rows if r[key] is not None]
    cv = [r[key] for r in cmp_rows if r[key] is not None]
    if not bv or not cv:
        return "N/A"
    bm = mean(bv)
    cm = mean(cv)
    if bm == 0:
        return "N/A"
    pct = (cm - bm) / bm * 100
    arrow = "↑" if pct > 0 else "↓"
    return f"{arrow} {abs(pct):.1f}%"


def main():
    if len(sys.argv) < 2:
        print("Usage: analyze_nm_sensitivity.py <results_dir>")
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    ctrl_rows   = load_variant_rows(results_dir, 'ctrl')
    lass60_rows = load_variant_rows(results_dir, 'lass60')
    lass75_rows = load_variant_rows(results_dir, 'lass75')
    lass90_rows = load_variant_rows(results_dir, 'lass90')

    lines = []
    lines.append("# Nethermind LASS Sensitivity Report: ctrl vs LASS-60 vs LASS-75 vs LASS-90")
    lines.append("")
    lines.append(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"**Results dir:** `{results_dir}`")
    lines.append("")
    lines.append("## Configuration")
    lines.append("")
    lines.append("| Parameter | Value |")
    lines.append("|-----------|-------|")
    lines.append("| Runtime | .NET CLR (Nethermind) |")
    lines.append("| Caliper workers | 30 |")
    lines.append("| Rate control | fixed-rate tps=1500 |")
    lines.append("| Duration | 600s |")
    lines.append("| Slots/tx | 200 |")
    lines.append("| ctrl | no heap limit, default GC |")
    lines.append("| LASS-60 | GCHeapHardLimit=1GB, GCHighMemPercent=60 |")
    lines.append("| LASS-75 | GCHeapHardLimit=1GB, GCHighMemPercent=75 |")
    lines.append("| LASS-90 | GCHeapHardLimit=1GB, GCHighMemPercent=90 |")
    lines.append("| Replications | 5 per variant |")
    lines.append("")

    variants = [
        ('ctrl', ctrl_rows, 'ctrl (stock NM)'),
        ('lass60', lass60_rows, 'lass60 (LASS-60)'),
        ('lass75', lass75_rows, 'lass75 (LASS-75)'),
        ('lass90', lass90_rows, 'lass90 (LASS-90)'),
    ]

    lines.append("## Per-Run Data")
    lines.append("")
    for vkey, rows, vname in variants:
        lines.append(f"### {vname}")
        lines.append("")
        lines.append("| Run | TPS | Max Lat (s) | Gen0 GC | Gen1 GC | Gen2 GC | Total GC | Total Pause (ms) | Avg Pause (ms) | Max time-in-GC% | Peak Heap (MB) |")
        lines.append("|-----|-----|-------------|---------|---------|---------|----------|-----------------|----------------|-----------------|----------------|")
        for r in rows:
            tps_s = f"{r['tps']:.1f}" if r['tps'] is not None else "N/A"
            lat_s = f"{r['max_lat']:.2f}" if r['max_lat'] is not None else "N/A"
            lines.append(f"| {r['run']} | {tps_s} | {lat_s} "
                         f"| {r['gen0_count']} | {r['gen1_count']} | {r['gen2_count']} "
                         f"| {r['gc_count']} | {r['total_pause_ms']:.1f} | {r['avg_pause_ms']:.1f} "
                         f"| {r['max_time_in_gc']:.1f} | {r['peak_heap_mb']:.1f} |")
        lines.append("")

    lines.append("## Summary Statistics (mean ± stdev)")
    lines.append("")
    lines.append("| Metric | ctrl | LASS-60 | LASS-75 | LASS-90 |")
    lines.append("|--------|------|---------|---------|---------|")

    metrics = [
        ('TPS', 'tps', 1),
        ('Max Latency (s)', 'max_lat', 2),
        ('Avg Latency (s)', 'avg_lat', 2),
        ('Gen0 GC Count', 'gen0_count', 0),
        ('Gen1 GC Count', 'gen1_count', 0),
        ('Gen2 GC Count', 'gen2_count', 0),
        ('Total GC Events', 'gc_count', 0),
        ('Total Pause (ms)', 'total_pause_ms', 0),
        ('Avg Pause/event (ms)', 'avg_pause_ms', 1),
        ('Max time-in-GC %', 'max_time_in_gc', 1),
        ('Avg time-in-GC %', 'avg_time_in_gc', 1),
        ('Peak Heap (MB)', 'peak_heap_mb', 0),
    ]
    for label, key, prec in metrics:
        c  = fmt(ctrl_rows,   key, prec)
        l6 = fmt(lass60_rows, key, prec)
        l7 = fmt(lass75_rows, key, prec)
        l9 = fmt(lass90_rows, key, prec)
        lines.append(f"| {label} | {c} | {l6} | {l7} | {l9} |")
    lines.append("")

    lines.append("## Change vs Ctrl (mean)")
    lines.append("")
    lines.append("| Metric | LASS-60 | LASS-75 | LASS-90 |")
    lines.append("|--------|---------|---------|---------|")
    change_metrics = [
        ('Total GC Events', 'gc_count'),
        ('Gen2 GC Count', 'gen2_count'),
        ('Total Pause (ms)', 'total_pause_ms'),
        ('Avg Pause/event (ms)', 'avg_pause_ms'),
        ('Max time-in-GC %', 'max_time_in_gc'),
        ('Avg time-in-GC %', 'avg_time_in_gc'),
        ('Peak Heap (MB)', 'peak_heap_mb'),
    ]
    for label, key in change_metrics:
        c60 = pct_change(ctrl_rows, lass60_rows, key)
        c75 = pct_change(ctrl_rows, lass75_rows, key)
        c90 = pct_change(ctrl_rows, lass90_rows, key)
        lines.append(f"| {label} | {c60} | {c75} | {c90} |")
    lines.append("")

    lines.append("## Interpretation")
    lines.append("")
    lines.append("### GC Event Count and Pause vs Ctrl")
    for vkey, rows, vname in [('lass60', lass60_rows, 'LASS-60'), ('lass75', lass75_rows, 'LASS-75'), ('lass90', lass90_rows, 'LASS-90')]:
        if not rows or not ctrl_rows:
            continue
        gc_red = pct_change(ctrl_rows, rows, 'gc_count')
        gen2_red = pct_change(ctrl_rows, rows, 'gen2_count')
        pause_chg = pct_change(ctrl_rows, rows, 'total_pause_ms')
        time_chg = pct_change(ctrl_rows, rows, 'max_time_in_gc')
        c_gc = mean([r['gc_count'] for r in ctrl_rows])
        l_gc = mean([r['gc_count'] for r in rows])
        c_g2 = mean([r['gen2_count'] for r in ctrl_rows])
        l_g2 = mean([r['gen2_count'] for r in rows])
        c_pause = mean([r['total_pause_ms'] for r in ctrl_rows])
        l_pause = mean([r['total_pause_ms'] for r in rows])
        lines.append(f"**{vname}**: Total GC {gc_red} ({c_gc:.0f}→{l_gc:.0f}), "
                     f"Gen2 GC {gen2_red} ({c_g2:.0f}→{l_g2:.0f}), "
                     f"Total Pause {pause_chg} ({c_pause:.0f}ms→{l_pause:.0f}ms), "
                     f"Max time-in-GC {time_chg}.")

    lines.append("")
    lines.append("### Notes")
    lines.append("- `Gen2 GC` is analogous to Besu's Full GC (major collection).")
    lines.append("- `time-in-gc` is sampled at 1s intervals; `Max time-in-GC%` is the worst 1s sample.")
    lines.append("- A lower `GCHighMemPercent` triggers more frequent GC, reducing peak heap but increasing GC overhead.")
    lines.append("")
    lines.append("---")
    lines.append("*Report generated by analyze_nm_sensitivity.py*")

    report_text = "\n".join(lines)

    report_path = results_dir / "final_nethermind_evaluation_1GB.md"
    with open(report_path, 'w') as f:
        f.write(report_text)

    cwd_copy = Path("/home/yeochan.yoon/caliper-stress-test/final_nethermind_evaluation_1GB.md")
    with open(cwd_copy, 'w') as f:
        f.write(report_text)

    print(report_text)
    print(f"\nReport: {report_path}")


if __name__ == '__main__':
    main()
