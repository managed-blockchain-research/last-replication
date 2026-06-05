#!/usr/bin/env python3
"""
Analyze LAST vs LASS head-to-head evaluation results for Nethermind.

Usage:
    python3 analyze_last_vs_lass_nm.py <results_dir>

Reads per-run subdirs (baseline_N, lass75_N, last_al_N, last_lass75_N).
Each subdir contains: gc_summary.txt, caliper_console.log, nm_console.log
Output: final_NM_LAST_vs_LASS_1GB_Evaluation.md
"""
import sys
import os
import re
import math
from pathlib import Path
from datetime import datetime


# ── GC summary parser (NettraceGcParser output) ───────────────────────────────

def parse_gc_summary(gc_summary_path):
    """
    Parse gc_summary.txt produced by NettraceGcParser.dll.
    Expected lines like:
      gen0_gc_count: 12
      gen1_gc_count: 3
      gen2_gc_count: 1
      total_pause_ms: 15234.5
      avg_pause_ms: 456.7
    """
    result = {
        'gen0_gc_count': 0,
        'gen1_gc_count': 0,
        'gen2_gc_count': 0,
        'total_gc_count': 0,
        'total_pause_ms': 0.0,
        'avg_pause_ms': 0.0,
    }
    if not os.path.exists(gc_summary_path):
        return result

    kv_re = re.compile(r'([\w_]+)\s*[:=]\s*([\d.]+)')
    try:
        with open(gc_summary_path, errors='replace') as f:
            for line in f:
                m = kv_re.search(line)
                if not m:
                    continue
                key = m.group(1).lower()
                val = m.group(2)
                if 'gen0' in key and 'count' in key:
                    result['gen0_gc_count'] = int(float(val))
                elif 'gen1' in key and 'count' in key:
                    result['gen1_gc_count'] = int(float(val))
                elif 'gen2' in key and 'count' in key:
                    result['gen2_gc_count'] = int(float(val))
                elif 'total_pause' in key:
                    result['total_pause_ms'] = float(val)
                elif 'avg_pause' in key:
                    result['avg_pause_ms'] = float(val)
    except Exception:
        pass

    result['total_gc_count'] = (result['gen0_gc_count']
                                + result['gen1_gc_count']
                                + result['gen2_gc_count'])
    if result['total_gc_count'] > 0 and result['avg_pause_ms'] == 0.0 and result['total_pause_ms'] > 0:
        result['avg_pause_ms'] = result['total_pause_ms'] / result['total_gc_count']

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


# ── Load rows for one variant ─────────────────────────────────────────────────

def load_variant_rows(results_dir, prefix):
    rows = []
    p = Path(results_dir)
    for entry in sorted(p.iterdir()):
        if not entry.is_dir():
            continue
        if not entry.name.startswith(prefix + '_'):
            continue

        gc = parse_gc_summary(str(entry / 'gc_summary.txt'))
        tps, max_lat, avg_lat, sent, fail = parse_caliper_measure(
            str(entry / 'caliper_console.log'))

        rows.append({
            'run': entry.name,
            'tps': tps,
            'max_lat_s': max_lat,
            'avg_lat_s': avg_lat,
            'sent': sent,
            'fail': fail,
            'gen0_gc_count': gc['gen0_gc_count'],
            'gen1_gc_count': gc['gen1_gc_count'],
            'gen2_gc_count': gc['gen2_gc_count'],
            'total_gc_count': gc['total_gc_count'],
            'total_pause_ms': gc['total_pause_ms'],
            'avg_pause_ms': gc['avg_pause_ms'],
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
    lines.append('| Run | TPS | Max Lat (s) | Avg Lat (s) | Gen0 GC | Gen1 GC | Gen2 GC | Total GC | Total Pause (ms) | Avg Pause (ms) |')
    lines.append('|-----|-----|-------------|-------------|---------|---------|---------|----------|-----------------|----------------|')
    for r in rows:
        tps_s = f"{r['tps']:.1f}"        if r['tps']     is not None else 'N/A'
        mxl_s = f"{r['max_lat_s']:.2f}"  if r['max_lat_s'] is not None else 'N/A'
        avl_s = f"{r['avg_lat_s']:.2f}"  if r['avg_lat_s'] is not None else 'N/A'
        lines.append(
            f"| {r['run']} | {tps_s} | {mxl_s} | {avl_s} "
            f"| {r['gen0_gc_count']} | {r['gen1_gc_count']} | {r['gen2_gc_count']} "
            f"| {r['total_gc_count']} "
            f"| {r['total_pause_ms']:.0f} | {r['avg_pause_ms']:.1f} |"
        )
    lines.append('')


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print('Usage: analyze_last_vs_lass_nm.py <results_dir>')
        sys.exit(1)

    results_dir = Path(sys.argv[1])

    baseline_rows    = load_variant_rows(results_dir, 'baseline')
    lass75_rows      = load_variant_rows(results_dir, 'lass75')
    last_al_rows     = load_variant_rows(results_dir, 'last_al')
    last_lass75_rows = load_variant_rows(results_dir, 'last_lass75')

    variants = [
        ('baseline',    baseline_rows,    'Baseline (FIFO)'),
        ('lass75',      lass75_rows,      'LASS-75 only'),
        ('last_al',     last_al_rows,     'LAST-AL only'),
        ('last_lass75', last_lass75_rows, 'LAST-AL + LASS-75'),
    ]

    lines = []
    lines.append('# LAST vs LASS Head-to-Head Evaluation @ 1GB Heap (Nethermind)')
    lines.append('')
    lines.append(f'**Generated:** {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    lines.append(f'**Results dir:** `{results_dir}`')
    lines.append('')

    lines.append('## Configuration')
    lines.append('')
    lines.append('| Parameter | Value |')
    lines.append('|-----------|-------|')
    lines.append('| Client | Nethermind (NethDev instant miner) |')
    lines.append('| CLR Heap (LASS variants) | `DOTNET_GCHeapHardLimit=1000000000` (1GB) |')
    lines.append('| LASS-75 | `DOTNET_GCHighMemPercent=75` (GC aggressive at 750MB) |')
    lines.append('| Caliper TPS | 150 (fixed-rate; NethDev ~240 TPS ceiling) |')
    lines.append('| Warmup | 120s (excluded from measurement) |')
    lines.append('| Measure | 300s |')
    lines.append('| Workers | 30 |')
    lines.append('| Workload | stateBloat, 200 slots/tx |')
    lines.append('| Replications | 5 per variant |')
    lines.append('| GC metrics | dotnet-trace + NettraceGcParser.dll |')
    lines.append('| Baseline binary | nethermind (stock, no LAST) |')
    lines.append('| LASS-75 binary | nethermind (stock, no LAST) + LASS env vars |')
    lines.append('| LAST-AL binary | banning/clients/nethermind (`NETHERMIND_LAST_MODE=AL`) |')
    lines.append('| LAST+LASS-75 binary | banning/clients/nethermind + LASS env vars |')
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
        ('TPS',                  'tps',            1,  1.0),
        ('Max Latency (s)',       'max_lat_s',      2,  1.0),
        ('Avg Latency (s)',       'avg_lat_s',      2,  1.0),
        ('Total GC Events',      'total_gc_count',  0,  1.0),
        ('Gen0 GC Count',        'gen0_gc_count',   0,  1.0),
        ('Gen1 GC Count',        'gen1_gc_count',   0,  1.0),
        ('Gen2 GC Count',        'gen2_gc_count',   0,  1.0),
        ('Total Pause (ms)',     'total_pause_ms',  0,  1.0),
        ('Avg Pause/event (ms)', 'avg_pause_ms',    1,  1.0),
    ]
    for label, key, prec, scale in metrics:
        b  = fmt(baseline_rows,    key, prec, scale) if prec > 0 else fmt_int(baseline_rows,    key)
        l7 = fmt(lass75_rows,      key, prec, scale) if prec > 0 else fmt_int(lass75_rows,      key)
        la = fmt(last_al_rows,     key, prec, scale) if prec > 0 else fmt_int(last_al_rows,     key)
        ll = fmt(last_lass75_rows, key, prec, scale) if prec > 0 else fmt_int(last_lass75_rows, key)
        lines.append(f'| {label} | {b} | {l7} | {la} | {ll} |')
    lines.append('')

    lines.append('## Change vs Baseline (mean)')
    lines.append('')
    lines.append('| Metric | LASS-75 only | LAST-AL only | LAST-AL + LASS-75 |')
    lines.append('|--------|-------------|-------------|------------------|')
    change_metrics = [
        ('TPS',                  'tps'),
        ('Max Latency (s)',      'max_lat_s'),
        ('Total GC Events',     'total_gc_count'),
        ('Gen2 GC Count',       'gen2_gc_count'),
        ('Total Pause (ms)',    'total_pause_ms'),
        ('Avg Pause/event (ms)','avg_pause_ms'),
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

    def interp(rows, baseline, name):
        if not rows or not baseline:
            lines.append(f'**{name}**: No data.')
            return
        pause_chg  = pct_change(baseline, rows, 'total_pause_ms')
        tps_chg    = pct_change(baseline, rows, 'tps')
        lat_chg    = pct_change(baseline, rows, 'max_lat_s')
        gc_chg     = pct_change(baseline, rows, 'total_gc_count')
        b_pause    = mean([r['total_pause_ms'] for r in baseline if r['total_pause_ms'] is not None])
        r_pause    = mean([r['total_pause_ms'] for r in rows     if r['total_pause_ms'] is not None])
        b_tps      = mean([r['tps']            for r in baseline if r['tps']            is not None])
        r_tps      = mean([r['tps']            for r in rows     if r['tps']            is not None])
        lines.append(f'**{name}**: Total Pause {pause_chg} ({b_pause:.0f}ms→{r_pause:.0f}ms), '
                     f'GC Events {gc_chg}, Max Latency {lat_chg}, '
                     f'TPS {tps_chg} ({b_tps:.0f}→{r_tps:.0f}).')

    interp(lass75_rows,      baseline_rows, 'LASS-75 only')
    interp(last_al_rows,     baseline_rows, 'LAST-AL only')
    interp(last_lass75_rows, baseline_rows, 'LAST-AL + LASS-75 (Synergy)')

    lines.append('')
    lines.append('### Notes')
    lines.append('- Metrics from the **measure** round (300s) only; warmup (120s) excluded.')
    lines.append('- GC pause metrics from dotnet-trace (NettraceGcParser.dll); span entire node lifetime.')
    lines.append('- NethDev miner: 1 block/sec, ~476 txs/block batch capacity; 150 TPS keeps pool healthy.')
    lines.append('- LASS reduces GC pause duration; LAST reduces cache misses by grouping contract-local txs.')
    lines.append('- `NETHERMIND_LAST_MODE=AL` applies address-locality ordering (group by `tx.To` address).')
    lines.append('')
    lines.append('---')
    lines.append('*Report generated by analyze_last_vs_lass_nm.py*')

    report_text = '\n'.join(lines)

    report_path = results_dir / 'final_NM_LAST_vs_LASS_1GB_Evaluation.md'
    with open(report_path, 'w') as f:
        f.write(report_text)

    cwd_copy = Path('/home/yeochan.yoon/caliper-stress-test/final_NM_LAST_vs_LASS_1GB_Evaluation.md')
    with open(cwd_copy, 'w') as f:
        f.write(report_text)

    print(report_text)
    print(f'\nReport: {report_path}')


if __name__ == '__main__':
    main()
