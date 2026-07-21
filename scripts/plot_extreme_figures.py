#!/usr/bin/env python3
import argparse
import csv
import os

import numpy as np
import matplotlib.pyplot as plt


def read_latencies(path):
    latencies = []
    with open(path, 'r', encoding='utf-8') as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            success = str(row.get('success', '')).lower()
            if success in {'false', '0', 'no'}:
                continue
            try:
                latencies.append(float(row['latency_ms']))
            except (ValueError, KeyError):
                continue
    return np.array(latencies, dtype=float)


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def plot_throughput_failure_rate(output_dir, baseline, espill):
    labels = ['Baseline', 'E-Spill']
    throughput = [baseline['throughput'], espill['throughput']]
    success_rate = [baseline['success_rate'], espill['success_rate']]
    failure_rate = [baseline['failure_rate'], espill['failure_rate']]

    x = np.arange(len(labels))
    fig, ax = plt.subplots(figsize=(8, 5))
    bars = ax.bar(x, throughput, color=['#4E79A7', '#59A14F'], edgecolor='black', linewidth=0.8)
    ax.bar_label(bars, fmt='%.2f', padding=3)
    ax.set_ylabel('Throughput (tx/s)')
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_title('Throughput and Success/Failure Rate')
    ax.grid(axis='y', alpha=0.3, linestyle='--')

    ax2 = ax.twinx()
    ax2.plot(x, success_rate, color='#F28E2B', marker='o', label='Success Rate')
    ax2.plot(x, failure_rate, color='#E15759', marker='s', label='Failure Rate')
    ax2.set_ylabel('Rate (%)')
    ax2.set_ylim(0, 100)
    ax2.legend(loc='upper right')

    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, 'throughput_failure_rate.png'), dpi=300, bbox_inches='tight')


def plot_latency_cdf(output_dir, baseline_lat, espill_lat):
    def cdf(data):
        data = np.sort(data)
        y = np.arange(1, len(data) + 1) / len(data)
        return data, y

    b_x, b_y = cdf(baseline_lat)
    e_x, e_y = cdf(espill_lat)

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(b_x, b_y, label='Baseline', color='#4E79A7', linewidth=2)
    ax.plot(e_x, e_y, label='E-Spill', color='#59A14F', linewidth=2)
    ax.set_xscale('log')
    ax.set_xlabel('Transaction Latency (ms) [log scale]')
    ax.set_ylabel('CDF')
    ax.set_title('Latency CDF')
    ax.grid(alpha=0.3, linestyle='--')
    ax.legend(loc='lower right')

    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, 'latency_cdf.png'), dpi=300, bbox_inches='tight')


def plot_gc_overhead_events(output_dir, baseline, espill):
    labels = ['Baseline', 'E-Spill']
    overhead = [baseline['gc_overhead'], espill['gc_overhead']]
    events = [baseline['gc_events'], espill['gc_events']]
    x = np.arange(len(labels))

    fig, ax = plt.subplots(figsize=(8, 5))
    bars = ax.bar(x, overhead, color=['#9C755F', '#76B7B2'], edgecolor='black', linewidth=0.8)
    ax.bar_label(bars, fmt='%.2f%%', padding=3)
    ax.set_ylabel('GC Overhead (%)')
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_title('GC Overhead vs Event Count')
    ax.grid(axis='y', alpha=0.3, linestyle='--')

    ax2 = ax.twinx()
    ax2.plot(x, events, color='#E15759', marker='o', linewidth=2, label='GC Events')
    ax2.set_ylabel('Total GC Events')
    ax2.legend(loc='upper right')

    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, 'gc_overhead_events.png'), dpi=300, bbox_inches='tight')


def plot_jitter_violin(output_dir, baseline_lat, espill_lat):
    fig, ax = plt.subplots(figsize=(8, 5))
    parts = ax.violinplot([baseline_lat, espill_lat], positions=[1, 2], showmeans=True, showmedians=True)
    for pc, color in zip(parts['bodies'], ['#4E79A7', '#59A14F']):
        pc.set_facecolor(color)
        pc.set_edgecolor('black')
        pc.set_alpha(0.7)
    parts['cmeans'].set_color('black')
    parts['cmeans'].set_linewidth(1.5)
    parts['cmedians'].set_color('red')
    parts['cmedians'].set_linewidth(1.5)

    ax.set_xticks([1, 2])
    ax.set_xticklabels(['Baseline', 'E-Spill'])
    ax.set_ylabel('Transaction Latency (ms)')
    ax.set_title('Latency Jitter')
    ax.grid(axis='y', alpha=0.3, linestyle='--')

    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, 'jitter_violin.png'), dpi=300, bbox_inches='tight')


def main():
    parser = argparse.ArgumentParser(description='Generate extreme comparison plots.')
    parser.add_argument('--baseline-latency', required=True)
    parser.add_argument('--espill-latency', required=True)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()

    ensure_dir(args.output_dir)

    baseline_lat = read_latencies(args.baseline_latency)
    espill_lat = read_latencies(args.espill_latency)

    baseline = {
        'throughput': 108.75,
        'success': 65362,
        'fail': 10849,
        'success_rate': 65362 / (65362 + 10849) * 100,
        'failure_rate': 10849 / (65362 + 10849) * 100,
        'gc_overhead': 0.24,
        'gc_events': 837,
    }
    espill = {
        'throughput': 113.85,
        'success': 68426,
        'fail': 11062,
        'success_rate': 68426 / (68426 + 11062) * 100,
        'failure_rate': 11062 / (68426 + 11062) * 100,
        'gc_overhead': 0.02,
        'gc_events': 16,
    }

    plot_throughput_failure_rate(args.output_dir, baseline, espill)
    plot_latency_cdf(args.output_dir, baseline_lat, espill_lat)
    plot_gc_overhead_events(args.output_dir, baseline, espill)
    plot_jitter_violin(args.output_dir, baseline_lat, espill_lat)

    print('Plots generated in:', args.output_dir)


if __name__ == '__main__':
    main()
