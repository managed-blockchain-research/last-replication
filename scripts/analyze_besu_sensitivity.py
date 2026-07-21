#!/usr/bin/env python3
"""
Analyze Besu LASS sensitivity: ctrl, lass60, lass75, lass90.

Usage:
    python3 analyze_besu_sensitivity.py \
        --prev <ctrl+lass75 dir> \
        --new  <lass60+lass90 dir>

Reads GC logs and Caliper/LASS console logs from each run dir.
Outputs final_besu_sensitivity_1GB.md to --new dir (and cwd copy).
"""
import sys
import os
import re
import math
import argparse
from pathlib import Path
from datetime import datetime


def parse_gc_log(gc_log_path):
    gc_pauses = []
    full_gc_pauses = []
    mixed_gc_count = 0
    if not os.path.exists(gc_log_path):
        return 0, 0.0, 0.0, 0, 0, 0
    with open(gc_log_path) as f:
        for line in f:
            m = re.search(r'GC\(\d+\)\s+Pause\s+(Full|Young|Mixed|Cleanup).*\s+([\d.]+)ms\s*$', line)
            if not m:
                continue
            gc_type = m.group(1).strip()
            try:
                pause_ms = float(m.group(2))
            except ValueError:
                continue
            if gc_type == 'Full':
                full_gc_pauses.append(pause_ms)
            elif gc_type == 'Mixed':
                mixed_gc_count += 1
                gc_pauses.append(pause_ms)
            else:
                gc_pauses.append(pause_ms)
    all_pauses = gc_pauses + full_gc_pauses
    gc_count = len(all_pauses)
    max_gc_ms = max(all_pauses) if all_pauses else 0.0
    total_gc_ms = sum(all_pauses)
    full_gc_count = len(full_gc_pauses)
    return gc_count, max_gc_ms, total_gc_ms, full_gc_count, mixed_gc_count, 0


def parse_lass_events(besu_console_path):
    max_activations = 0
    peak_heap_pct = 0.0
    if not os.path.exists(besu_console_path):
        return 0, 0.0
    with open(besu_console_path) as f:
        for line in f:
            if 'E-SPILL TRAJECTORY' not in line and 'E-SPILL STATS' not in line:
                continue
            m_act = re.search(r'activations=(\d+)', line)
            if m_act:
                max_activations = max(max_activations, int(m_act.group(1)))
            m_heap = re.search(r'heap=([\d.]+)%', line)
            if m_heap:
                peak_heap_pct = max(peak_heap_pct, float(m_heap.group(1)))
    return max_activations, peak_heap_pct


def load_variant_rows(results_dir, variant_prefix):
    rows = []
    p = Path(results_dir)
    for entry in sorted(p.iterdir()):
        if not entry.is_dir():
            continue
        if not entry.name.startswith(variant_prefix + '_'):
            continue
        gc_log = entry / 'gc.log'
        besu_log = entry / 'besu_console.log'
        gc_count, max_gc_ms, total_gc_ms, full_gc_count, mixed_gc_count, _ = parse_gc_log(str(gc_log))
        lass_act, peak_heap = parse_lass_events(str(besu_log))
        rows.append({
            'run': entry.name,
            'gc_count': gc_count,
            'max_gc_ms': max_gc_ms,
            'total_gc_ms': total_gc_ms,
            'full_gc_count': full_gc_count,
            'mixed_gc_count': mixed_gc_count,
            'lass_activations': lass_act,
            'peak_heap': peak_heap,
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
    vals = [r[key] for r in rows]
    if not vals:
        return "N/A"
    return f"{mean(vals):.{prec}f} ± {stdev(vals):.{prec}f}"


def pct_change(base_rows, cmp_rows, key):
    bv = [r[key] for r in base_rows]
    cv = [r[key] for r in cmp_rows]
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
    parser = argparse.ArgumentParser()
    parser.add_argument('--prev', required=True, help='Dir with ctrl_* and lass75_* subdirs')
    parser.add_argument('--new', required=True, help='Dir with lass60_* and lass90_* subdirs')
    args = parser.parse_args()

    ctrl_rows   = load_variant_rows(args.prev, 'ctrl')
    lass75_rows = load_variant_rows(args.prev, 'lass75')
    lass60_rows = load_variant_rows(args.new,  'lass60')
    lass90_rows = load_variant_rows(args.new,  'lass90')

    lines = []
    lines.append("# Besu LASS Sensitivity Report: ctrl vs LASS-60 vs LASS-75 vs LASS-90")
    lines.append("")
    lines.append(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"**ctrl/lass75 dir:** `{args.prev}`")
    lines.append(f"**lass60/lass90 dir:** `{args.new}`")
    lines.append("")
    lines.append("## Configuration")
    lines.append("")
    lines.append("| Parameter | Value |")
    lines.append("|-----------|-------|")
    lines.append("| JVM Heap | 1g (Xms1g Xmx1g) |")
    lines.append("| GC | G1GC MaxGCPauseMillis=200 |")
    lines.append("| Eden sizing | G1MaxNewSizePercent=90 G1NewSizePercent=20 |")
    lines.append("| Caliper workers | 30 |")
    lines.append("| Rate control | fixed-rate tps=1500 |")
    lines.append("| Duration | 600s |")
    lines.append("| Slots/tx | 200 |")
    lines.append("| LASS-60 | activation=0.60, deactivation=0.45, consecutive_samples=1 |")
    lines.append("| LASS-75 | activation=0.75, deactivation=0.60, consecutive_samples=1 |")
    lines.append("| LASS-90 | activation=0.90, deactivation=0.75, consecutive_samples=1 |")
    lines.append("| Replications | 5 per variant |")
    lines.append("")

    # Per-run tables
    variants = [
        ('ctrl', ctrl_rows, 'ctrl (stock Besu 24.1.1)'),
        ('lass60', lass60_rows, 'lass60 (LASS-60)'),
        ('lass75', lass75_rows, 'lass75 (LASS-75)'),
        ('lass90', lass90_rows, 'lass90 (LASS-90)'),
    ]

    lines.append("## Per-Run Data")
    lines.append("")
    for vkey, rows, vname in variants:
        lines.append(f"### {vname}")
        lines.append("")
        lines.append("| Run | GC count | Max GC (ms) | Total GC (ms) | Full GC | Mixed GC | LASS act. | Peak heap % |")
        lines.append("|-----|----------|-------------|---------------|---------|----------|-----------|-------------|")
        for r in rows:
            peak = f"{r['peak_heap']:.1f}" if r['peak_heap'] > 0 else "—"
            lines.append(f"| {r['run']} | {r['gc_count']} | {r['max_gc_ms']:.1f} "
                         f"| {r['total_gc_ms']:.0f} | {r['full_gc_count']} "
                         f"| {r['mixed_gc_count']} | {r['lass_activations']} | {peak} |")
        lines.append("")

    # Summary table
    lines.append("## Summary Statistics (mean ± stdev)")
    lines.append("")
    lines.append("| Metric | ctrl | LASS-60 | LASS-75 | LASS-90 |")
    lines.append("|--------|------|---------|---------|---------|")

    metrics = [
        ('GC Event Count', 'gc_count', 0),
        ('Max GC Pause (ms)', 'max_gc_ms', 1),
        ('Total GC Time (ms)', 'total_gc_ms', 0),
        ('Full GC Count', 'full_gc_count', 0),
        ('Mixed GC Count', 'mixed_gc_count', 0),
    ]
    for label, key, prec in metrics:
        c  = fmt(ctrl_rows,   key, prec)
        l6 = fmt(lass60_rows, key, prec)
        l7 = fmt(lass75_rows, key, prec)
        l9 = fmt(lass90_rows, key, prec)
        lines.append(f"| {label} | {c} | {l6} | {l7} | {l9} |")

    lass_act_ctrl = "0"
    lass_act_60  = fmt(lass60_rows, 'lass_activations', 1) if lass60_rows else "N/A"
    lass_act_75  = fmt(lass75_rows, 'lass_activations', 1) if lass75_rows else "N/A"
    lass_act_90  = fmt(lass90_rows, 'lass_activations', 1) if lass90_rows else "N/A"
    lines.append(f"| LASS activations | {lass_act_ctrl} | {lass_act_60} | {lass_act_75} | {lass_act_90} |")

    peak_60 = fmt(lass60_rows, 'peak_heap', 1) if lass60_rows else "N/A"
    peak_75 = fmt(lass75_rows, 'peak_heap', 1) if lass75_rows else "N/A"
    peak_90 = fmt(lass90_rows, 'peak_heap', 1) if lass90_rows else "N/A"
    lines.append(f"| Peak heap % | — | {peak_60} | {peak_75} | {peak_90} |")
    lines.append("")

    # Change table vs ctrl
    lines.append("## Change vs Ctrl (mean)")
    lines.append("")
    lines.append("| Metric | LASS-60 | LASS-75 | LASS-90 |")
    lines.append("|--------|---------|---------|---------|")
    for label, key, _ in metrics:
        c60 = pct_change(ctrl_rows, lass60_rows, key)
        c75 = pct_change(ctrl_rows, lass75_rows, key)
        c90 = pct_change(ctrl_rows, lass90_rows, key)
        lines.append(f"| {label} | {c60} | {c75} | {c90} |")
    lines.append("")

    # Interpretation
    lines.append("## Interpretation")
    lines.append("")
    lines.append("### GC Event Reduction vs Ctrl")
    for vkey, rows, vname in [('lass60', lass60_rows, 'LASS-60'), ('lass75', lass75_rows, 'LASS-75'), ('lass90', lass90_rows, 'LASS-90')]:
        if not rows or not ctrl_rows:
            continue
        gc_red = pct_change(ctrl_rows, rows, 'gc_count')
        full_red = pct_change(ctrl_rows, rows, 'full_gc_count')
        maxgc_chg = pct_change(ctrl_rows, rows, 'max_gc_ms')
        c_gc = mean([r['gc_count'] for r in ctrl_rows])
        l_gc = mean([r['gc_count'] for r in rows])
        c_full = mean([r['full_gc_count'] for r in ctrl_rows])
        l_full = mean([r['full_gc_count'] for r in rows])
        lines.append(f"**{vname}**: GC events {gc_red} ({c_gc:.0f}→{l_gc:.0f}), "
                     f"Full GC {full_red} ({c_full:.0f}→{l_full:.0f}), "
                     f"Max GC pause {maxgc_chg}.")

    lines.append("")
    lines.append("### LASS Activation Frequency")
    for vkey, rows, vname in [('lass60', lass60_rows, 'LASS-60'), ('lass75', lass75_rows, 'LASS-75'), ('lass90', lass90_rows, 'LASS-90')]:
        if not rows:
            continue
        avg_act = mean([r['lass_activations'] for r in rows])
        lines.append(f"**{vname}** activated on average **{avg_act:.1f}** times per run.")

    lines.append("")
    ctrl_full_total = sum(r['full_gc_count'] for r in ctrl_rows)
    if ctrl_full_total > 0:
        lines.append("### Full GC Cliff")
        lines.append(f"ctrl: **{ctrl_full_total}** Full GC events total across {len(ctrl_rows)} runs.")
        for vkey, rows, vname in [('lass60', lass60_rows, 'LASS-60'), ('lass75', lass75_rows, 'LASS-75'), ('lass90', lass90_rows, 'LASS-90')]:
            if not rows:
                continue
            total = sum(r['full_gc_count'] for r in rows)
            lines.append(f"{vname}: **{total}** Full GC events total.")

    lines.append("")
    lines.append("---")
    lines.append("*Report generated by analyze_besu_sensitivity.py*")

    report_text = "\n".join(lines)

    out_dir = Path(args.new)
    report_path = out_dir / "final_besu_sensitivity_1GB.md"
    with open(report_path, 'w') as f:
        f.write(report_text)

    cwd_copy = Path("/home/yeochan.yoon/caliper-stress-test/final_besu_sensitivity_1GB.md")
    with open(cwd_copy, 'w') as f:
        f.write(report_text)

    print(report_text)
    print(f"\nReport written to: {report_path}")
    print(f"Copy: {cwd_copy}")


if __name__ == '__main__':
    main()
