#!/usr/bin/env python3
"""
Analyze results from run_caliper_5x5.sh.
Parses GC logs, Caliper console logs, and E-SPILL TRAJECTORY lines.
Outputs final_evaluation_results_caliper.md.
"""
import sys
import os
import re
import math
from pathlib import Path
from datetime import datetime


def parse_gc_log(gc_log_path):
    """Parse G1GC log. Returns (gc_count, max_gc_ms, total_gc_ms, full_gc_count, max_full_gc_ms, mixed_gc_count)."""
    gc_pauses = []
    full_gc_pauses = []
    mixed_gc_count = 0
    if not os.path.exists(gc_log_path):
        return 0, 0.0, 0.0, 0, 0.0, 0
    with open(gc_log_path) as f:
        for line in f:
            # Match: GC(N) Pause <Type> [(...)] [heap] <ms>ms
            # Type may be followed by parenthesized reasons, e.g. "Full (G1 Compaction Pause)"
            m = re.search(r'GC\(\d+\)\s+Pause\s+(Full|Young|Mixed|Cleanup).*\s+([\d.]+)ms\s*$', line)
            if not m:
                continue
            gc_type = m.group(1).strip()
            try:
                pause_ms = float(m.group(2))
            except ValueError:
                continue
            if 'Full' in gc_type:
                full_gc_pauses.append(pause_ms)
            elif 'Mixed' in gc_type:
                mixed_gc_count += 1
                gc_pauses.append(pause_ms)
            else:
                gc_pauses.append(pause_ms)
    all_pauses = gc_pauses + full_gc_pauses
    gc_count = len(all_pauses)
    max_gc_ms = max(all_pauses) if all_pauses else 0.0
    total_gc_ms = sum(all_pauses)
    full_gc_count = len(full_gc_pauses)
    max_full_gc_ms = max(full_gc_pauses) if full_gc_pauses else 0.0
    return gc_count, max_gc_ms, total_gc_ms, full_gc_count, max_full_gc_ms, mixed_gc_count


def parse_caliper_results(caliper_console_path):
    """Parse Caliper console log for TPS and latency stats."""
    tps = None
    max_lat = None
    avg_lat = None
    min_lat = None
    succ = 0
    fail = 0
    if not os.path.exists(caliper_console_path):
        return None, None, None, None, 0, 0
    with open(caliper_console_path) as f:
        for line in f:
            # Table row: | cliff-probe | succ | fail | send_rate | max_lat | min_lat | avg_lat | tps |
            m = re.search(r'\|\s*cliff-probe\s*\|\s*([\d]+)\s*\|\s*([\d]+)\s*\|'
                          r'\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|', line)
            if m:
                succ = int(m.group(1))
                fail = int(m.group(2))
                # send_rate = m.group(3)
                max_lat = float(m.group(4))
                min_lat = float(m.group(5))
                avg_lat = float(m.group(6))
                tps = float(m.group(7))
    return tps, max_lat, avg_lat, min_lat, succ, fail


def parse_lass_events(besu_console_path):
    """Parse E-SPILL TRAJECTORY lines for LASS activation data."""
    max_activations = 0
    max_spill_events = 0
    total_spilled = 0
    peak_heap_pct = 0.0
    if not os.path.exists(besu_console_path):
        return 0, 0, 0, 0.0
    with open(besu_console_path) as f:
        for line in f:
            if 'E-SPILL TRAJECTORY' not in line and 'E-SPILL STATS' not in line:
                continue
            m_act = re.search(r'activations=(\d+)', line)
            if m_act:
                max_activations = max(max_activations, int(m_act.group(1)))
            m_spill = re.search(r'spillEvents=(\d+)', line)
            if m_spill:
                max_spill_events = max(max_spill_events, int(m_spill.group(1)))
            m_total = re.search(r'totalSpilled=(\d+)', line)
            if m_total:
                total_spilled = max(total_spilled, int(m_total.group(1)))
            m_heap = re.search(r'heap=([\d.]+)%', line)
            if m_heap:
                peak_heap_pct = max(peak_heap_pct, float(m_heap.group(1)))
    return max_activations, max_spill_events, total_spilled, peak_heap_pct


def mean(values):
    return sum(values) / len(values) if values else 0.0


def stdev(values):
    if len(values) < 2:
        return 0.0
    m = mean(values)
    return math.sqrt(sum((v - m) ** 2 for v in values) / (len(values) - 1))


def main():
    if len(sys.argv) < 2:
        print("Usage: analyze_caliper_5x5.py <results_dir>")
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    report_path = results_dir / "final_evaluation_results_caliper.md"

    variants = ['ctrl', 'lass75']
    data = {v: [] for v in variants}

    for entry in sorted(results_dir.iterdir()):
        if not entry.is_dir():
            continue
        name = entry.name
        variant = None
        for v in variants:
            if name.startswith(v + '_'):
                variant = v
                break
        if variant is None:
            continue

        gc_log = entry / 'gc.log'
        caliper_log = entry / 'caliper_console.log'
        besu_log = entry / 'besu_console.log'
        heap_file = entry / 'heap_used.txt'

        gc_count, max_gc_ms, total_gc_ms, full_gc_count, max_full_gc_ms, mixed_gc_count = parse_gc_log(str(gc_log))
        tps, max_lat, avg_lat, min_lat, succ, fail = parse_caliper_results(str(caliper_log))
        lass_activations, spill_events, total_spilled, peak_heap = parse_lass_events(str(besu_log))

        row = {
            'run': name,
            'tps': tps,
            'max_lat': max_lat,
            'avg_lat': avg_lat,
            'gc_count': gc_count,
            'max_gc_ms': max_gc_ms,
            'total_gc_ms': total_gc_ms,
            'full_gc_count': full_gc_count,
            'max_full_gc_ms': max_full_gc_ms,
            'mixed_gc_count': mixed_gc_count,
            'lass_activations': lass_activations,
            'spill_events': spill_events,
            'total_spilled': total_spilled,
            'peak_heap': peak_heap,
            'succ_txs': succ,
        }
        data[variant].append(row)

    lines = []
    lines.append("# Final Evaluation Report: Caliper 5×ctrl vs 5×lass75")
    lines.append("")
    lines.append(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"**Results dir:** `{results_dir}`")
    lines.append("")
    lines.append("## Configuration")
    lines.append("")
    lines.append("| Parameter | Value |")
    lines.append("|-----------|-------|")
    lines.append("| JVM Heap | 1g (Xms1g Xmx1g) |")
    lines.append("| GC | G1GC MaxGCPauseMillis=200 |")
    lines.append("| Eden sizing | G1MaxNewSizePercent=90 G1NewSizePercent=20 |")
    lines.append("| Caliper workers | 30 |")
    lines.append("| TX load | fixed-load transactionLoad=1500 |")
    lines.append("| Duration | 600s |")
    lines.append("| Slots/tx | 200 |")
    lines.append("| LASS threshold | 0.75 (deactivate=0.60, consecutive_samples=1) |")
    lines.append("| Replications | 5 per variant |")
    lines.append("")
    lines.append("## Per-Run Data")
    lines.append("")

    for variant in variants:
        rows = data[variant]
        vname = "ctrl (stock Besu 24.1.1)" if variant == 'ctrl' else "lass75 (LASS-75)"
        lines.append(f"### {vname}")
        lines.append("")
        lines.append("| Run | TPS | Max Lat (s) | Avg Lat (s) | GC count | Max GC (ms) | Total GC (ms) | Full GC | Mixed GC | LASS act. |")
        lines.append("|-----|-----|-------------|-------------|----------|-------------|---------------|---------|----------|-----------|")
        for r in rows:
            tps_s = f"{r['tps']:.1f}" if r['tps'] is not None else "N/A"
            max_lat_s = f"{r['max_lat']:.2f}" if r['max_lat'] is not None else "N/A"
            avg_lat_s = f"{r['avg_lat']:.2f}" if r['avg_lat'] is not None else "N/A"
            row_str = (f"| {r['run']} | {tps_s} | {max_lat_s} | {avg_lat_s} "
                       f"| {r['gc_count']} | {r['max_gc_ms']:.1f} | {r['total_gc_ms']:.1f} "
                       f"| {r['full_gc_count']} | {r['mixed_gc_count']} | {r['lass_activations']} |")
            lines.append(row_str)
        lines.append("")

    # Summary stats
    lines.append("## Summary Statistics (mean ± stdev)")
    lines.append("")
    lines.append("| Metric | ctrl | lass75 | Change |")
    lines.append("|--------|------|--------|--------|")

    def fmt_metric(rows, key, precision=1):
        vals = [r[key] for r in rows if r[key] is not None]
        if not vals:
            return "N/A"
        m = mean(vals)
        s = stdev(vals)
        return f"{m:.{precision}f} ± {s:.{precision}f}"

    def pct_change(ctrl_rows, lass_rows, key):
        cv = [r[key] for r in ctrl_rows if r[key] is not None]
        lv = [r[key] for r in lass_rows if r[key] is not None]
        if not cv or not lv:
            return "N/A"
        cm = mean(cv)
        lm = mean(lv)
        if cm == 0:
            return "N/A"
        pct = (lm - cm) / cm * 100
        arrow = "↑" if pct > 0 else "↓"
        return f"{arrow} {abs(pct):.1f}%"

    ctrl_rows = data['ctrl']
    lass_rows = data['lass75']

    metrics = [
        ('TPS (Caliper throughput)', 'tps', 1),
        ('Max TX Latency (s)', 'max_lat', 2),
        ('Avg TX Latency (s)', 'avg_lat', 2),
        ('GC Event Count', 'gc_count', 0),
        ('Max GC Pause (ms)', 'max_gc_ms', 1),
        ('Total GC Time (ms)', 'total_gc_ms', 0),
        ('Full GC Count', 'full_gc_count', 0),
        ('Mixed GC Count', 'mixed_gc_count', 0),
    ]

    for label, key, prec in metrics:
        ctrl_str = fmt_metric(ctrl_rows, key, prec)
        lass_str = fmt_metric(lass_rows, key, prec)
        chg = pct_change(ctrl_rows, lass_rows, key)
        lines.append(f"| {label} | {ctrl_str} | {lass_str} | {chg} |")

    lines.append(f"| LASS activations | 0 | {fmt_metric(lass_rows, 'lass_activations', 0)} | — |")
    lines.append(f"| Peak heap % | — | {fmt_metric(lass_rows, 'peak_heap', 1)} | — |")
    lines.append("")

    # Interpretation
    ctrl_tps = [r['tps'] for r in ctrl_rows if r['tps']]
    lass_tps = [r['tps'] for r in lass_rows if r['tps']]
    ctrl_maxgc = [r['max_gc_ms'] for r in ctrl_rows]
    lass_maxgc = [r['max_gc_ms'] for r in lass_rows]
    ctrl_gc_cnt = [r['gc_count'] for r in ctrl_rows]
    lass_gc_cnt = [r['gc_count'] for r in lass_rows]

    lines.append("## Interpretation")
    lines.append("")

    if ctrl_maxgc and lass_maxgc:
        cm_maxgc = mean(ctrl_maxgc)
        lm_maxgc = mean(lass_maxgc)
        pct = (cm_maxgc - lm_maxgc) / cm_maxgc * 100 if cm_maxgc > 0 else 0
        lines.append(f"LASS-75 reduced max GC pause by **{pct:.1f}%** (ctrl: {cm_maxgc:.1f}ms → lass75: {lm_maxgc:.1f}ms).")

    if ctrl_gc_cnt and lass_gc_cnt:
        cm_cnt = mean(ctrl_gc_cnt)
        lm_cnt = mean(lass_gc_cnt)
        pct = (cm_cnt - lm_cnt) / cm_cnt * 100 if cm_cnt > 0 else 0
        lines.append(f"GC event count changed by **{pct:.1f}%** (ctrl: {cm_cnt:.0f} → lass75: {lm_cnt:.0f}).")

    if ctrl_tps and lass_tps:
        cm_tps = mean(ctrl_tps)
        lm_tps = mean(lass_tps)
        pct = (lm_tps - cm_tps) / cm_tps * 100 if cm_tps > 0 else 0
        arrow = "↑" if pct > 0 else "↓"
        lines.append(f"Throughput was {abs(pct):.1f}% {arrow.replace('↑','higher').replace('↓','lower')} under LASS-75 "
                     f"(ctrl: {cm_tps:.1f} TPS → lass75: {lm_tps:.1f} TPS).")

    ctrl_full = sum(r['full_gc_count'] for r in ctrl_rows)
    lass_full = sum(r['full_gc_count'] for r in lass_rows)
    if ctrl_full > 0:
        lines.append(f"\n### GC Cliff")
        lines.append(f"Full GC events detected in ctrl: **{ctrl_full}** total across {len(ctrl_rows)} runs.")
        lines.append(f"LASS-75 Full GC events: **{lass_full}** total.")
    else:
        lines.append(f"\n### GC Load Profile")
        lines.append(f"No Full GC in ctrl — {mean(ctrl_gc_cnt):.0f} Young GC events/run at {mean(ctrl_maxgc):.1f}ms max.")
        lines.append(f"LASS-75 target: reduce Young GC frequency via TX pool spilling at 75% heap usage.")

    lass_act_avg = mean([r['lass_activations'] for r in lass_rows]) if lass_rows else 0
    lines.append("")
    lines.append("### LASS Activation Check")
    lines.append(f"LASS-75 activated on average **{lass_act_avg:.1f}** times per run.")
    lines.append("")
    lines.append("---")
    lines.append("*Report generated by analyze_caliper_5x5.py*")

    report_text = "\n".join(lines)

    with open(report_path, 'w') as f:
        f.write(report_text)

    print(report_text)
    print(f"\nReport written to: {report_path}")


if __name__ == '__main__':
    main()
