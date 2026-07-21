#!/usr/bin/env python3
import argparse
import csv
import json
import math
import os
import sys


def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    d0 = sorted_vals[f] * (c - k)
    d1 = sorted_vals[c] * (k - f)
    return d0 + d1


def _iter_latency_files(path):
    if os.path.isfile(path):
        return [path]
    if not os.path.isdir(path):
        raise FileNotFoundError(f'Input path not found: {path}')
    return [
        os.path.join(path, entry)
        for entry in os.listdir(path)
        if entry.endswith('.csv')
    ]


def _is_success(value):
    if value is None:
        return True
    return str(value).strip().lower() in {'1', 'true', 'yes', 'y'}


def read_latencies(input_path):
    latencies = []
    for path in _iter_latency_files(input_path):
        with open(path, 'r', encoding='utf-8') as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                if not _is_success(row.get('success')):
                    continue
                try:
                    latencies.append(float(row['latency_ms']))
                except (ValueError, KeyError):
                    continue
    return latencies


def summarize(latencies):
    latencies = sorted(latencies)
    if not latencies:
        return {
            'count': 0,
            'avg_ms': None,
            'min_ms': None,
            'max_ms': None,
            'stddev_ms': None,
            'cv': None,
            'p50_ms': None,
            'p95_ms': None,
            'p99_ms': None,
        }
    avg = sum(latencies) / len(latencies)
    variance = sum((value - avg) ** 2 for value in latencies) / len(latencies)
    stddev = math.sqrt(variance)
    return {
        'count': len(latencies),
        'avg_ms': avg,
        'min_ms': latencies[0],
        'max_ms': latencies[-1],
        'stddev_ms': stddev,
        'cv': stddev / avg if avg else None,
        'p50_ms': percentile(latencies, 50),
        'p95_ms': percentile(latencies, 95),
        'p99_ms': percentile(latencies, 99),
    }


def try_plot(labels, summaries, output_path):
    try:
        import matplotlib.pyplot as plt  # pylint: disable=import-error
    except Exception as exc:  # pragma: no cover - best effort plot
        print(f'WARN: matplotlib not available ({exc}); skipping plot.', file=sys.stderr)
        return

    categories = ['p50_ms', 'p95_ms', 'p99_ms']
    x = list(range(len(categories)))
    width = 0.8 / max(1, len(labels))

    fig, ax = plt.subplots(figsize=(10, 6))
    for idx, label in enumerate(labels):
        values = [summaries[label][key] or 0 for key in categories]
        offset = (idx - (len(labels) - 1) / 2) * width
        bars = ax.bar([pos + offset for pos in x], values, width, label=label, edgecolor='black', linewidth=0.8)
        ax.bar_label(bars, fmt='%.0f', padding=3)

    ax.set_xlabel('Percentile')
    ax.set_ylabel('Latency (ms)')
    ax.set_title('Latency Percentiles (Successful Transactions)')
    ax.set_xticks(x)
    ax.set_xticklabels(['P50', 'P95', 'P99'])
    ax.legend(loc='upper right')
    ax.grid(axis='y', alpha=0.3, linestyle='--')
    fig.tight_layout()
    fig.savefig(output_path, dpi=300, bbox_inches='tight')

    avg_fig, avg_ax = plt.subplots(figsize=(8, 5))
    avg_values = [summaries[label]['avg_ms'] or 0 for label in labels]
    bars = avg_ax.bar(labels, avg_values, color='#4ECDC4', edgecolor='black', linewidth=0.8)
    avg_ax.bar_label(bars, fmt='%.0f', padding=3)
    avg_ax.set_ylabel('Latency (ms)')
    avg_ax.set_title('Average Latency (Successful Transactions)')
    avg_ax.grid(axis='y', alpha=0.3, linestyle='--')
    avg_fig.tight_layout()
    avg_fig.savefig(output_path.replace('latency_percentiles', 'latency_average'), dpi=300, bbox_inches='tight')


def main():
    parser = argparse.ArgumentParser(description='Compare latency percentiles across runs.')
    parser.add_argument(
        '--input',
        action='append',
        required=True,
        help='Label=directory with latency CSVs (can be provided multiple times).'
    )
    parser.add_argument(
        '--output-dir',
        default=os.path.join(os.path.dirname(__file__), '..', 'results', 'latency'),
        help='Output directory for summary and plot.'
    )
    args = parser.parse_args()

    labels = []
    summaries = {}
    for item in args.input:
        if '=' not in item:
            raise ValueError('Input must be in the form label=/path/to/latency_dir')
        label, path = item.split('=', 1)
        labels.append(label)
        latencies = read_latencies(path)
        summaries[label] = summarize(latencies)

    os.makedirs(args.output_dir, exist_ok=True)
    summary_path = os.path.join(args.output_dir, 'latency_summary.json')
    with open(summary_path, 'w', encoding='utf-8') as handle:
        json.dump(summaries, handle, indent=2)

    csv_path = os.path.join(args.output_dir, 'latency_summary.csv')
    with open(csv_path, 'w', encoding='utf-8', newline='') as handle:
        writer = csv.writer(handle)
        writer.writerow(['label', 'count', 'avg_ms', 'min_ms', 'max_ms', 'p50_ms', 'p95_ms', 'p99_ms'])
        for label in labels:
            summary = summaries[label]
            writer.writerow([
                label,
                summary['count'],
                summary['avg_ms'],
                summary['min_ms'],
                summary['max_ms'],
                summary['p50_ms'],
                summary['p95_ms'],
                summary['p99_ms'],
            ])

    plot_path = os.path.join(args.output_dir, 'latency_percentiles.png')
    try_plot(labels, summaries, plot_path)

    print(f'Wrote summary JSON: {summary_path}')
    print(f'Wrote summary CSV: {csv_path}')
    print(f'Plot (if matplotlib available): {plot_path}')


if __name__ == '__main__':
    main()
