#!/usr/bin/env python3
"""
Analyze LAST vs LASS head-to-head evaluation results.

Usage:
    python3 analyze_last_vs_lass.py <results_dir>

Reads per-run subdirs (baseline_N, lass75_N, last_al_N, last_lass75_N).
Each subdir contains: gc.log, caliper_console.log, besu_console.log
Output: final_LAST_vs_LASS_1GB_Evaluation.md
"""
import sys
import os
import re
import math
from pathlib import Path
from datetime import datetime


# ── GC log parser ─────────────────────────────────────────────────────────────

def parse_gc_log(gc_log_path):
    result = {
        'gc_count': 0,
        'max_gc_ms': 0.0,
        'total_gc_ms': 0.0,
        'full_gc_count': 0,
        'young_gc_count': 0,
    }
    if not os.path.exists(gc_log_path):
        return result

    # Patterns for G1GC log format:
    # [info][gc] GC(N) Pause Young (Normal) ... N.NNNms
    # [info][gc] GC(N) Pause Full ... N.NNNms
    pause_re = re.compile(
        r'GC\(\d+\)\s+Pause\s+(\S+.*?)\s+([\d.]+)ms\s*$'
    )
    full_re = re.compile(r'GC\(\d+\)\s+Pause\s+Full')
    young_re = re.compile(r'GC\(\d+\)\s+Pause\s+Young')

    try:
        with open(gc_log_path, errors='replace') as f:
            for line in f:
                m = pause_re.search(line)
                if m:
                    try:
                        ms = float(m.group(2))
                    except ValueError:
                        continue
                    result['gc_count'] += 1
                    result['total_gc_ms'] += ms
                    if ms > result['max_gc_ms']:
                        result['max_gc_ms'] = ms
                    if full_re.search(line):
                        result['full_gc_count'] += 1
                    elif young_re.search(line):
                        result['young_gc_count'] += 1
    except Exception:
        pass
    return result


# ── Caliper console log parser ────────────────────────────────────────────────

TX_DURATION_S = 300.0  # measure round txDuration in seconds

def parse_caliper_measure(caliper_log):
    """Parse only the 'measure' round row from caliper_console.log."""
    tps = None
    max_lat = None
    avg_lat = None
    send = None
    fail = None

    if not os.path.exists(caliper_log):
        return tps, max_lat, avg_lat, send, fail

    with open(caliper_log, errors='replace') as f:
        for line in f:
            # Caliper row: | measure | Succ | Fail | SendRate | MaxLat | MinLat | AvgLat | Throughput |
            m = re.search(
                r'\|\s*measure\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|'
                r'\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|',
                line
            )
            if m:
                send    = int(m.group(1))     # Succ (confirmed) count
                fail    = int(m.group(2))     # Fail/timeout count
                max_lat = float(m.group(4))   # Max Latency (s)
                avg_lat = float(m.group(6))   # Avg Latency (s)
                # Confirmed TPS = Succ / txDuration (NOT Caliper Throughput which includes Fail)
                tps     = send / TX_DURATION_S
    return tps, max_lat, avg_lat, send, fail


# ── Besu console log parser ───────────────────────────────────────────────────

def parse_besu_console(besu_log):
    """Count E-Spill activations and peak heap% from Besu console log."""
    lass_activations = 0
    peak_heap_pct = 0.0

    if not os.path.exists(besu_log):
        return lass_activations, peak_heap_pct

    act_re = re.compile(r'E-SPILL.*?activ', re.IGNORECASE)
    heap_re = re.compile(r'heap[^%]*?([\d.]+)%', re.IGNORECASE)

    try:
        with open(besu_log, errors='replace') as f:
            for line in f:
                if act_re.search(line):
                    lass_activations += 1
                m = heap_re.search(line)
                if m:
                    try:
                        v = float(m.group(1))
                        if v > peak_heap_pct:
                            peak_heap_pct = v
                    except ValueError:
                        pass
    except Exception:
        pass
    return lass_activations, peak_heap_pct


# ── Load rows for one variant ─────────────────────────────────────────────────

def load_variant_rows(results_dir, prefix):
    rows = []
    p = Path(results_dir)
    for entry in sorted(p.iterdir()):
        if not entry.is_dir():
            continue
        if not entry.name.startswith(prefix + '_'):
            continue

        gc = parse_gc_log(str(entry / 'gc.log'))
        tps, max_lat, avg_lat, sent, fail = parse_caliper_measure(
            str(entry / 'caliper_console.log'))
        lass_act, peak_heap = parse_besu_console(
            str(entry / 'besu_console.log'))

        rows.append({
            'run': entry.name,
            'tps': tps,
            'max_lat_s': max_lat,
            'avg_lat_s': avg_lat,
            'sent': sent,
            'fail': fail,
            'gc_count': gc['gc_count'],
            'max_gc_ms': gc['max_gc_ms'],
            'total_gc_ms': gc['total_gc_ms'],
            'full_gc_count': gc['full_gc_count'],
            'lass_activations': lass_act,
            'peak_heap_pct': peak_heap,
        })
    return rows


# ── Stats helpers ─────────────────────────────────────────────────────────────

def mean(vals):
    return sum(vals) / len(vals) if vals else 0.0

def stdev(vals):
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))

def fmt(rows, key, prec=1, scale=1.0):
    vals = [r[key] * scale for r in rows if r[key] is not None]
    if not vals:
        return 'N/A'
    return f'{mean(vals):.{prec}f} ± {stdev(vals):.{prec}f}'

def fmt_int(rows, key):
    vals = [r[key] for r in rows if r[key] is not None]
    if not vals:
        return 'N/A'
    return f'{mean(vals):.0f} ± {stdev(vals):.0f}'

def pct_change(base, cmp, key, scale=1.0):
    bv = [r[key] * scale for r in base if r[key] is not None]
    cv = [r[key] * scale for r in cmp  if r[key] is not None]
    if not bv or not cv:
        return 'N/A'
    bm, cm = mean(bv), mean(cv)
    if bm == 0:
        return 'N/A'
    pct = (cm - bm) / bm * 100
    arrow = '↑' if pct > 0 else '↓'
    return f'{arrow} {abs(pct):.1f}%'


# ── Per-run table ─────────────────────────────────────────────────────────────

def per_run_table(rows, lines):
    lines.append('| Run | TPS | Max Lat (s) | Avg Lat (s) | GC Events | Max GC (ms) | Total GC (ms) | Full GC | LASS Act. |')
    lines.append('|-----|-----|-------------|-------------|-----------|-------------|---------------|---------|-----------|')
    for r in rows:
        tps_s    = f"{r['tps']:.1f}"    if r['tps']     is not None else 'N/A'
        mxl_s    = f"{r['max_lat_s']:.2f}" if r['max_lat_s'] is not None else 'N/A'
        avl_s    = f"{r['avg_lat_s']:.2f}" if r['avg_lat_s'] is not None else 'N/A'
        lines.append(
            f"| {r['run']} | {tps_s} | {mxl_s} | {avl_s} "
            f"| {r['gc_count']} | {r['max_gc_ms']:.0f} "
            f"| {r['total_gc_ms']:.0f} | {r['full_gc_count']} "
            f"| {r['lass_activations']} |"
        )
    lines.append('')


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print('Usage: analyze_last_vs_lass.py <results_dir> [heap_label]')
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    # Infer heap label from results dir path or explicit arg
    heap_label = sys.argv[2] if len(sys.argv) > 2 else (
        '4GB' if '4g' in str(results_dir).lower() or '4gb' in str(results_dir).lower() else '1GB'
    )

    baseline_rows   = load_variant_rows(results_dir, 'baseline')
    lass75_rows     = load_variant_rows(results_dir, 'lass75')
    last_al_rows    = load_variant_rows(results_dir, 'last_al')
    last_lass75_rows = load_variant_rows(results_dir, 'last_lass75')

    variants = [
        ('baseline',    baseline_rows,    'Baseline (FIFO)'),
        ('lass75',      lass75_rows,      'LASS-75 only'),
        ('last_al',     last_al_rows,     'LAST-AL only'),
        ('last_lass75', last_lass75_rows, 'LAST-AL + LASS-75'),
    ]

    lines = []
    lines.append('# LAST vs LASS Head-to-Head Evaluation @ 1GB Heap (Besu)')
    lines.append('')
    lines.append(f'**Generated:** {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    lines.append(f'**Results dir:** `{results_dir}`')
    lines.append('')

    lines.append('## Configuration')
    lines.append('')
    lines.append('| Parameter | Value |')
    lines.append('|-----------|-------|')
    lines.append('| Client | Hyperledger Besu 24.1.1 |')
    lines.append('| JVM Heap | `-Xms1g -Xmx1g` (fixed, no expansion) |')
    lines.append('| GC | G1GC, MaxGCPauseMillis=200 |')
    lines.append('| Eden sizing | G1MaxNewSizePercent=90, G1NewSizePercent=20 |')
    lines.append('| TxPool | Uncapped (`--tx-pool-max-size=1000000`) |')
    lines.append('| Caliper TPS | 1500 (fixed-rate) |')
    lines.append('| Warmup | 120s (excluded from measurement) |')
    lines.append('| Measure | 300s |')
    lines.append('| Workers | 30 |')
    lines.append('| Workload | stateBloat, 200 slots/tx |')
    lines.append('| Replications | 5 per variant |')
    lines.append('| Baseline binary | besu-24.1.1 (`-Dlast.variant=DISABLED`) |')
    lines.append('| LASS-75 binary | besu-source (E-Spill, activation=0.75, deact=0.60) |')
    lines.append('| LAST-AL binary | besu-24.1.1 + LAST patch (`-Dlast.variant=ADDRESS_LOCALITY`) |')
    lines.append('| LAST+LASS-75 binary | besu-source + LAST patch + LASS-75 opts |')
    lines.append('')

    lines.append('## Per-Run Data')
    lines.append('')
    for vkey, rows, vname in variants:
        lines.append(f'### {vname}')
        lines.append('')
        if rows:
            per_run_table(rows, lines)
        else:
            lines.append('*No data found.*')
            lines.append('')

    lines.append('## Summary Statistics (mean ± stdev, measure round only)')
    lines.append('')
    lines.append('| Metric | Baseline (FIFO) | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |')
    lines.append('|--------|----------------|-------------|-------------|------------------|')

    metrics = [
        ('TPS',                   'tps',            1,  1.0),
        ('Max Latency (s)',        'max_lat_s',       2,  1.0),
        ('Avg Latency (s)',        'avg_lat_s',       2,  1.0),
        ('GC Event Count',        'gc_count',        0,  1.0),
        ('Max GC Pause (ms)',     'max_gc_ms',       0,  1.0),
        ('Total GC Time (ms)',    'total_gc_ms',     0,  1.0),
        ('Full GC Count',         'full_gc_count',   0,  1.0),
        ('LASS Activations',      'lass_activations',0,  1.0),
    ]
    for label, key, prec, scale in metrics:
        b  = fmt(baseline_rows,   key, prec, scale) if prec > 0 else fmt_int(baseline_rows,   key)
        l7 = fmt(lass75_rows,     key, prec, scale) if prec > 0 else fmt_int(lass75_rows,     key)
        la = fmt(last_al_rows,    key, prec, scale) if prec > 0 else fmt_int(last_al_rows,    key)
        ll = fmt(last_lass75_rows,key, prec, scale) if prec > 0 else fmt_int(last_lass75_rows,key)
        lines.append(f'| {label} | {b} | {l7} | {la} | {ll} |')
    lines.append('')

    lines.append('## Change vs Baseline (mean)')
    lines.append('')
    lines.append('| Metric | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |')
    lines.append('|--------|-------------|-------------|------------------|')
    change_metrics = [
        ('TPS',                'tps'),
        ('Max Latency (s)',    'max_lat_s'),
        ('GC Event Count',    'gc_count'),
        ('Max GC Pause (ms)', 'max_gc_ms'),
        ('Total GC Time (ms)','total_gc_ms'),
        ('Full GC Count',     'full_gc_count'),
    ]
    for label, key in change_metrics:
        c7  = pct_change(baseline_rows, lass75_rows,      key)
        ca  = pct_change(baseline_rows, last_al_rows,     key)
        cll = pct_change(baseline_rows, last_lass75_rows, key)
        lines.append(f'| {label} | {c7} | {ca} | {cll} |')
    lines.append('')

    lines.append('## Interpretation')
    lines.append('')
    lines.append('### Hypothesis Validation')
    lines.append('')

    def interp(rows, baseline, name, key_gc='total_gc_ms', key_tps='tps', key_max='max_gc_ms'):
        gc_chg   = pct_change(baseline, rows, key_gc)
        tps_chg  = pct_change(baseline, rows, key_tps)
        max_chg  = pct_change(baseline, rows, key_max)
        full_chg = pct_change(baseline, rows, 'full_gc_count')
        b_gc  = mean([r[key_gc]  for r in baseline if r[key_gc]  is not None])
        r_gc  = mean([r[key_gc]  for r in rows     if r[key_gc]  is not None])
        b_tps = mean([r[key_tps] for r in baseline if r[key_tps] is not None])
        r_tps = mean([r[key_tps] for r in rows     if r[key_tps] is not None])
        lines.append(f'**{name}**: Total GC {gc_chg} ({b_gc:.0f}ms→{r_gc:.0f}ms), '
                     f'Max GC pause {max_chg}, Full GC {full_chg}, '
                     f'TPS {tps_chg} ({b_tps:.0f}→{r_tps:.0f}).')

    if lass75_rows and baseline_rows:
        interp(lass75_rows, baseline_rows, 'LASS-75 only')
    if last_al_rows and baseline_rows:
        interp(last_al_rows, baseline_rows, 'LAST-AL only')
    if last_lass75_rows and baseline_rows:
        interp(last_lass75_rows, baseline_rows, 'LAST-AL + LASS-75 (Synergy)')

    lines.append('')
    lines.append('### Notes')
    lines.append('- Metrics from the **measure** round (300s) only; warmup (120s) excluded.')
    lines.append('- GC metrics span the entire node lifetime per run (warmup + measure),')
    lines.append('  providing a conservative view of steady-state GC behaviour.')
    lines.append('- `Max Latency` is the worst single-transaction confirmed latency (Caliper).')
    lines.append('- `LASS Activations` counts E-Spill trigger events logged in Besu console.')
    lines.append('')
    lines.append('---')
    lines.append('*Report generated by analyze_last_vs_lass.py*')

    report_text = '\n'.join(lines)

    report_path = results_dir / f'final_LAST_vs_LASS_{heap_label}_Evaluation.md'
    with open(report_path, 'w') as f:
        f.write(report_text)

    cwd_copy = Path(f'/home/yeochan.yoon/caliper-stress-test/final_LAST_vs_LASS_{heap_label}_Evaluation.md')
    with open(cwd_copy, 'w') as f:
        f.write(report_text)

    print(report_text)
    print(f'\nReport: {report_path}')


if __name__ == '__main__':
    main()
