#!/usr/bin/env python3
"""
RAAC visualization: GC pause CDF + AI anomaly score scatter.

Usage:
  python3 scripts/plot_raac_scatter_cdf.py \
    --gc-csv results/raac_eval/<RUN_ID>/gc_all.csv \
    --raac-logs results/raac_eval/<RUN_ID>/raac_besu_1/raac_logs/ \
    --out-prefix figures/raac

Produces:
  figures/raac_gc_cdf.pdf   — GC pause CDF: baseline vs RAAC (Besu + NM)
  figures/raac_scatter.pdf  — Anomaly score scatter (normal vs attack, accept vs reject)
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mticker
    from matplotlib.lines import Line2D
except ImportError:
    print('matplotlib not found: pip install matplotlib', file=sys.stderr)
    sys.exit(1)

try:
    import pandas as pd
except ImportError:
    print('pandas not found: pip install pandas', file=sys.stderr)
    sys.exit(1)

COLORS = {
    'baseline_besu': '#2166ac',
    'raac_besu':     '#d73027',
    'baseline_nm':   '#4dac26',
    'raac_nm':       '#f1a340',
}
LABELS = {
    'baseline_besu': 'Besu Baseline',
    'raac_besu':     'Besu + RAAC',
    'baseline_nm':   'NM Baseline',
    'raac_nm':       'NM + RAAC',
}


def plot_cdf(gc_csv: Path, out_prefix: Path):
    df = pd.read_csv(gc_csv)
    fig, ax = plt.subplots(figsize=(6, 4))

    for client in ('besu', 'nm'):
        for variant in ('baseline', 'raac'):
            key = f'{variant}_{client}'
            sub = df[(df['variant'] == variant) & (df['client'] == client)]['pause_ms'].dropna()
            if sub.empty:
                continue
            vals = np.sort(sub.values)
            cdf = np.arange(1, len(vals) + 1) / len(vals)
            ax.plot(vals, cdf,
                    color=COLORS[key],
                    label=LABELS[key],
                    linewidth=1.5,
                    linestyle='-' if client == 'besu' else '--')

    ax.set_xlabel('GC Pause (ms)', fontsize=11)
    ax.set_ylabel('CDF', fontsize=11)
    ax.set_title('GC Pause CDF: Baseline vs RAAC (1 GB / 1500 TPS DDoS)', fontsize=10)
    ax.set_xlim(left=0)
    ax.set_ylim(0, 1.02)
    ax.xaxis.set_major_formatter(mticker.FuncFormatter(lambda x, _: f'{x:.0f}'))
    ax.legend(fontsize=9, loc='lower right')
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out = out_prefix.parent / (out_prefix.name + '_gc_cdf.pdf')
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, bbox_inches='tight')
    plt.close(fig)
    print(f'CDF plot: {out}')


def load_raac_logs(raac_log_dirs):
    records = []
    for d in raac_log_dirs:
        d = Path(d)
        if not d.exists():
            continue
        for jsonl in sorted(d.glob('worker*_raac.jsonl')):
            with open(jsonl) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    records.append(rec)
    return records


def plot_scatter(raac_log_dirs, out_prefix: Path):
    records = load_raac_logs(raac_log_dirs)
    if not records:
        print('No RAAC log records found for scatter plot.', file=sys.stderr)
        return

    normal_accept = [r.get('anomaly_score', 0) for r in records
                     if r.get('type') == 'normal' and r.get('submitted', True)]
    normal_reject = [r.get('anomaly_score', 0) for r in records
                     if r.get('type') == 'normal' and not r.get('submitted', True)]
    attack_accept = [r.get('anomaly_score', 0) for r in records
                     if r.get('type') == 'attack' and r.get('submitted', True)]
    attack_reject = [r.get('anomaly_score', 0) for r in records
                     if r.get('type') == 'attack' and not r.get('submitted', True)]

    # Use jitter on x axis: normal=0, attack=1
    rng = np.random.default_rng(42)

    fig, ax = plt.subplots(figsize=(5, 4))

    def jitter(center, n, spread=0.12):
        return rng.uniform(center - spread, center + spread, n)

    if normal_accept:
        ax.scatter(jitter(0, len(normal_accept)), normal_accept,
                   color='#2166ac', alpha=0.3, s=4, label='Normal / Accepted')
    if normal_reject:
        ax.scatter(jitter(0, len(normal_reject)), normal_reject,
                   color='#abd9e9', alpha=0.6, s=12, marker='x', label='Normal / Blocked (FP)')
    if attack_accept:
        ax.scatter(jitter(1, len(attack_accept)), attack_accept,
                   color='#fdae61', alpha=0.4, s=4, label='Attack / Accepted (FN)')
    if attack_reject:
        ax.scatter(jitter(1, len(attack_reject)), attack_reject,
                   color='#d73027', alpha=0.4, s=4, label='Attack / Blocked (TP)')

    # Dynamic threshold line (use median of logged threshold)
    thresholds = [r.get('dyn_threshold') for r in records if r.get('dyn_threshold') is not None]
    if thresholds:
        med_thr = float(np.median(thresholds))
        ax.axhline(med_thr, color='black', linestyle='--', linewidth=1,
                   label=f'Threshold (median={med_thr:.3f})')

    ax.set_xticks([0, 1])
    ax.set_xticklabels(['Normal\n(1 SSTORE)', 'Attack\n(200 SSTORE)'], fontsize=10)
    ax.set_ylabel('Anomaly Score', fontsize=11)
    ax.set_title('RAAC: AI Anomaly Score vs Classification', fontsize=10)
    ax.legend(fontsize=8, loc='upper left')
    ax.grid(True, alpha=0.25, axis='y')
    fig.tight_layout()
    out = out_prefix.parent / (out_prefix.name + '_scatter.pdf')
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, bbox_inches='tight')
    plt.close(fig)
    print(f'Scatter plot: {out}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gc-csv', help='Combined GC events CSV (variant,client,rep,pause_ms)')
    ap.add_argument('--raac-logs', nargs='+', help='raac_logs/ dir(s) from RAAC runs')
    ap.add_argument('--out-prefix', default='figures/raac')
    args = ap.parse_args()

    out_prefix = Path(args.out_prefix)

    if args.gc_csv:
        plot_cdf(Path(args.gc_csv), out_prefix)

    if args.raac_logs:
        plot_scatter(args.raac_logs, out_prefix)


if __name__ == '__main__':
    main()
