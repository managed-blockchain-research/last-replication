#!/usr/bin/env python3
"""
Generate journal-quality figures for LAST vs LASS evaluation.

Reads:
  - results/last_vs_lass/<RUN_ID>/final_LAST_vs_LASS_1GB_Evaluation.md  (Besu 1GB)
  - results/last_vs_lass_4g/<RUN_ID>/final_LAST_vs_LASS_4GB_Evaluation.md (Besu 4GB)
  - results/last_vs_lass_nm/<RUN_ID>/final_NM_LAST_vs_LASS_1GB_Evaluation.md (NM 1GB)

Outputs:
  - fig_besu_1gb_eval.pdf / .png
  - fig_besu_4gb_eval.pdf / .png
  - fig_nethermind_1gb_eval.pdf / .png
  - fig_last_evaluation_all.pdf / .png  (2×2 grid)
"""

import sys
import os
import re
import math
import json
from pathlib import Path

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    import numpy as np
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print('WARNING: matplotlib not available — skipping plot generation')

VARIANTS = ['baseline', 'lass75', 'last_al', 'last_lass75']
VARIANT_LABELS = ['Baseline\n(FIFO)', 'LASS-75\nonly', 'LAST-AL\nonly', 'LAST-AL\n+LASS-75']
COLORS = ['#d62728', '#ff7f0e', '#1f77b4', '#2ca02c']

RESULTS_BASE = Path('/home/yeochan.yoon/caliper-stress-test/results')


def find_latest_run(subdir):
    """Find the most recent run directory."""
    p = RESULTS_BASE / subdir
    if not p.exists():
        return None
    runs = sorted([d for d in p.iterdir() if d.is_dir()], reverse=True)
    return runs[0] if runs else None


def parse_summary_md(md_path):
    """
    Extract mean TPS, max latency, and GC metrics from the final markdown report.
    Returns dict keyed by variant name.
    """
    if not os.path.exists(md_path):
        return {}

    data = {}
    in_summary = False
    header_cols = []

    with open(md_path, errors='replace') as f:
        for line in f:
            if '## Summary Statistics' in line:
                in_summary = True
                continue
            if in_summary and line.startswith('| Metric'):
                # parse header: | Metric | Baseline | LASS-75 | LAST-AL | LAST+LASS |
                parts = [p.strip() for p in line.split('|') if p.strip()]
                header_cols = parts[1:]  # skip 'Metric' col
                continue
            if in_summary and line.startswith('|---'):
                continue
            if in_summary and line.startswith('| ') and '|' in line:
                parts = [p.strip() for p in line.split('|') if p.strip()]
                if not parts:
                    continue
                metric = parts[0]
                vals = parts[1:]
                variant_map = {
                    'Baseline (FIFO)': 'baseline',
                    'LASS-75 only': 'lass75',
                    'LAST-AL only': 'last_al',
                    'LAST-AL + LASS-75': 'last_lass75',
                }
                for i, col in enumerate(header_cols):
                    if i >= len(vals):
                        break
                    vkey = None
                    for k, v in variant_map.items():
                        if k.lower() in col.lower() or col.lower() in k.lower():
                            vkey = v
                            break
                    if vkey is None:
                        # try positional mapping
                        pos_map = ['baseline', 'lass75', 'last_al', 'last_lass75']
                        vkey = pos_map[i] if i < len(pos_map) else None
                    if vkey is None:
                        continue
                    raw = vals[i]
                    # parse "mean ± stdev" or plain number
                    m = re.match(r'([\d.]+)\s*(?:±\s*([\d.]+))?', raw)
                    if not m:
                        continue
                    mean_val = float(m.group(1))
                    std_val = float(m.group(2)) if m.group(2) else 0.0
                    if vkey not in data:
                        data[vkey] = {}
                    # Store by metric name (simplified)
                    mkey = metric.lower()
                    if 'tps' in mkey and 'send' not in mkey:
                        data[vkey]['tps'] = (mean_val, std_val)
                    elif 'max lat' in mkey or 'max_lat' in mkey:
                        data[vkey]['max_lat'] = (mean_val, std_val)
                    elif 'avg lat' in mkey or 'avg_lat' in mkey:
                        data[vkey]['avg_lat'] = (mean_val, std_val)
                    elif 'total pause' in mkey or 'total_pause' in mkey:
                        data[vkey]['gc_pause_ms'] = (mean_val, std_val)
                    elif 'gen2' in mkey:
                        data[vkey]['gen2_gc'] = (mean_val, std_val)
            elif in_summary and line.startswith('## ') and 'Summary' not in line:
                in_summary = False

    return data


def load_per_run_data(results_dir, prefix, caliper_key='tps'):
    """Load raw per-run Caliper data directly from run directories."""
    rows = []
    if not results_dir or not results_dir.exists():
        return rows

    for entry in sorted(results_dir.iterdir()):
        if not entry.is_dir() or not entry.name.startswith(prefix + '_'):
            continue
        log = entry / 'caliper_console.log'
        if not log.exists():
            continue
        tps = max_lat = avg_lat = succ = fail = None
        with open(log, errors='replace') as f:
            for line in f:
                m = re.search(
                    r'\|\s*measure\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|'
                    r'\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|',
                    line
                )
                if m:
                    succ = int(m.group(1))
                    fail = int(m.group(2))
                    max_lat = float(m.group(4))
                    avg_lat = float(m.group(6))
                    tps = float(m.group(7))
        # Also compute throughput as succ/300s
        succ_tps = succ / 300.0 if succ is not None else None
        rows.append({
            'run': entry.name,
            'tps': tps,
            'succ_tps': succ_tps,
            'max_lat': max_lat,
            'avg_lat': avg_lat,
            'succ': succ,
            'fail': fail,
        })
    return rows


def mean_std(rows, key):
    vals = [r[key] for r in rows if r.get(key) is not None]
    if not vals:
        return 0.0, 0.0
    m = sum(vals) / len(vals)
    s = math.sqrt(sum((v - m) ** 2 for v in vals) / max(len(vals) - 1, 1))
    return m, s


def make_bar_figure(results_dir, title, heap_label, out_prefix):
    """Create 1×3 subplot figure: Succ TPS, Max Latency, GC Pause."""
    if not HAS_MATPLOTLIB:
        return

    # Load per-run data
    all_rows = {}
    for v in VARIANTS:
        rows = load_per_run_data(results_dir, v)
        all_rows[v] = rows

    # Load GC pause from analysis md if available
    md_path = results_dir / f'final_LAST_vs_LASS_{heap_label}_Evaluation.md'
    if not md_path.exists():
        # Try NM naming
        md_path = results_dir / f'final_NM_LAST_vs_LASS_{heap_label}_Evaluation.md'
    md_data = parse_summary_md(str(md_path)) if md_path.exists() else {}

    fig, axes = plt.subplots(1, 3, figsize=(14, 5))
    fig.suptitle(title, fontsize=14, fontweight='bold', y=1.02)

    x = np.arange(len(VARIANTS))
    bar_w = 0.6

    # ── Panel 1: Confirmed TPS (Succ/300s) ─────────────────────────────────────
    ax = axes[0]
    means, stds = [], []
    for v in VARIANTS:
        m, s = mean_std(all_rows[v], 'succ_tps')
        means.append(m)
        stds.append(s)
    bars = ax.bar(x, means, bar_w, yerr=stds, capsize=4, color=COLORS,
                  edgecolor='black', linewidth=0.8)
    ax.set_xticks(x)
    ax.set_xticklabels(VARIANT_LABELS, fontsize=9)
    ax.set_ylabel('Confirmed TPS (Succ/300s)', fontsize=10)
    ax.set_title('Throughput', fontsize=11)
    ax.set_ylim(bottom=0)
    ax.grid(axis='y', alpha=0.3)
    for bar, m in zip(bars, means):
        if m > 0:
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                    f'{m:.0f}', ha='center', va='bottom', fontsize=8)

    # ── Panel 2: Max Latency (s) ────────────────────────────────────────────────
    ax = axes[1]
    means, stds = [], []
    for v in VARIANTS:
        m, s = mean_std(all_rows[v], 'max_lat')
        means.append(m)
        stds.append(s)
    bars = ax.bar(x, means, bar_w, yerr=stds, capsize=4, color=COLORS,
                  edgecolor='black', linewidth=0.8)
    ax.set_xticks(x)
    ax.set_xticklabels(VARIANT_LABELS, fontsize=9)
    ax.set_ylabel('Max Latency (s)', fontsize=10)
    ax.set_title('Max Confirmation Latency', fontsize=11)
    ax.set_ylim(bottom=0)
    ax.grid(axis='y', alpha=0.3)
    for bar, m in zip(bars, means):
        if m > 0:
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                    f'{m:.1f}s', ha='center', va='bottom', fontsize=8)

    # ── Panel 3: GC Pause (from md or gc.log) ──────────────────────────────────
    ax = axes[2]
    # Try to get total GC pause from md_data, fall back to gc.log parsing
    gc_means, gc_stds = [], []
    for v in VARIANTS:
        if v in md_data and 'gc_pause_ms' in md_data[v]:
            m, s = md_data[v]['gc_pause_ms']
        else:
            # fallback: parse gc.log for full GC count as proxy
            pause_vals = []
            for row in all_rows[v]:
                run_name = row['run']
                gc_log = results_dir / run_name / 'gc.log'
                if gc_log.exists():
                    total_ms = 0.0
                    with open(gc_log, errors='replace') as f:
                        for line in f:
                            m2 = re.search(r'Pause\s+\w+.*?\s+([\d.]+)ms', line)
                            if m2:
                                total_ms += float(m2.group(1))
                    pause_vals.append(total_ms)
            if pause_vals:
                m = sum(pause_vals) / len(pause_vals)
                s = math.sqrt(sum((v2 - m) ** 2 for v2 in pause_vals) / max(len(pause_vals) - 1, 1))
            else:
                m, s = 0.0, 0.0
        gc_means.append(m)
        gc_stds.append(s)

    bars = ax.bar(x, gc_means, bar_w, yerr=gc_stds, capsize=4, color=COLORS,
                  edgecolor='black', linewidth=0.8)
    ax.set_xticks(x)
    ax.set_xticklabels(VARIANT_LABELS, fontsize=9)
    ax.set_ylabel('Total GC Pause (ms)', fontsize=10)
    ax.set_title('GC Pause Time', fontsize=11)
    ax.set_ylim(bottom=0)
    ax.grid(axis='y', alpha=0.3)
    if max(gc_means) > 0:
        ax.set_yscale('symlog', linthresh=100)
    for bar, m in zip(bars, gc_means):
        if m > 0:
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() * 1.05,
                    f'{m:.0f}', ha='center', va='bottom', fontsize=8)

    legend_handles = [mpatches.Patch(color=COLORS[i], label=VARIANT_LABELS[i].replace('\n', ' '))
                      for i in range(len(VARIANTS))]
    fig.legend(handles=legend_handles, loc='lower center', ncol=4,
               bbox_to_anchor=(0.5, -0.08), fontsize=9, framealpha=0.9)

    plt.tight_layout()
    for ext in ['pdf', 'png']:
        path = f'/home/yeochan.yoon/caliper-stress-test/{out_prefix}.{ext}'
        plt.savefig(path, dpi=200, bbox_inches='tight')
        print(f'Saved: {path}')
    plt.close()


def make_2x2_figure(dirs_labels):
    """2×2 subplot: rows=Besu/NM, cols=1GB/4GB (or available combos)."""
    if not HAS_MATPLOTLIB:
        return
    if not dirs_labels:
        return

    n = len(dirs_labels)
    rows = 2 if n > 2 else 1
    cols = 2
    fig, axes = plt.subplots(rows, cols, figsize=(14, 8))
    if rows == 1:
        axes = [axes]
    axes = [ax for row in axes for ax in row]

    for idx, (results_dir, label, heap_label) in enumerate(dirs_labels[:4]):
        if idx >= len(axes):
            break
        ax = axes[idx]
        all_rows = {v: load_per_run_data(results_dir, v) for v in VARIANTS}
        x = np.arange(len(VARIANTS))
        bar_w = 0.6
        means = [mean_std(all_rows[v], 'succ_tps')[0] for v in VARIANTS]
        stds  = [mean_std(all_rows[v], 'succ_tps')[1] for v in VARIANTS]
        ax.bar(x, means, bar_w, yerr=stds, capsize=3, color=COLORS, edgecolor='black', lw=0.7)
        ax.set_title(label, fontsize=11, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels(VARIANT_LABELS, fontsize=8)
        ax.set_ylabel('Confirmed TPS', fontsize=9)
        ax.set_ylim(bottom=0)
        ax.grid(axis='y', alpha=0.3)

    legend_handles = [mpatches.Patch(color=COLORS[i], label=VARIANT_LABELS[i].replace('\n', ' '))
                      for i in range(len(VARIANTS))]
    fig.legend(handles=legend_handles, loc='lower center', ncol=4,
               bbox_to_anchor=(0.5, -0.04), fontsize=9)
    fig.suptitle('LAST vs LASS Evaluation — Confirmed Throughput', fontsize=13, fontweight='bold')
    plt.tight_layout()

    for ext in ['pdf', 'png']:
        path = f'/home/yeochan.yoon/caliper-stress-test/fig_last_evaluation_all.{ext}'
        plt.savefig(path, dpi=200, bbox_inches='tight')
        print(f'Saved: {path}')
    plt.close()


def main():
    runs_to_plot = []

    besu_1g = find_latest_run('last_vs_lass')
    if besu_1g:
        print(f'Besu 1GB: {besu_1g}')
        make_bar_figure(besu_1g, 'LAST vs LASS @ 1GB Heap (Besu)', '1GB', 'fig_besu_1gb_eval')
        runs_to_plot.append((besu_1g, 'Besu 1GB', '1GB'))

    besu_4g = find_latest_run('last_vs_lass_4g')
    if besu_4g:
        print(f'Besu 4GB: {besu_4g}')
        make_bar_figure(besu_4g, 'LAST vs LASS @ 4GB Heap (Besu)', '4GB', 'fig_besu_4gb_eval')
        runs_to_plot.append((besu_4g, 'Besu 4GB', '4GB'))

    nm_1g = find_latest_run('last_vs_lass_nm')
    if nm_1g:
        print(f'Nethermind 1GB: {nm_1g}')
        make_bar_figure(nm_1g, 'LAST vs LASS @ 1GB Heap (Nethermind)', '1GB', 'fig_nethermind_1gb_eval')
        runs_to_plot.append((nm_1g, 'Nethermind 1GB', '1GB'))

    if len(runs_to_plot) >= 2:
        make_2x2_figure(runs_to_plot)

    if not runs_to_plot:
        print('No completed experiment results found. Run experiments first.')


if __name__ == '__main__':
    main()
