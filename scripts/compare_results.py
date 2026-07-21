#!/usr/bin/env python3
"""
Compare baseline and e-spill test results
Generates comprehensive comparison metrics for research paper
"""

import sys
import csv
import statistics
from pathlib import Path

def analyze_latency_file(csv_file):
    """Analyze latency CSV file and return statistics"""
    latencies = []
    errors = 0
    
    print(f"  Reading {csv_file}...")
    
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row['success'] == 'True':
                latencies.append(float(row['latency_ms']))
            else:
                errors += 1
    
    if not latencies:
        print(f"  ERROR: No successful transactions found in {csv_file}")
        return None
    
    latencies.sort()
    n = len(latencies)
    
    return {
        'count': n,
        'errors': errors,
        'min': min(latencies),
        'mean': statistics.mean(latencies),
        'median': statistics.median(latencies),
        'p50': latencies[int(n * 0.50)],
        'p90': latencies[int(n * 0.90)],
        'p95': latencies[int(n * 0.95)],
        'p99': latencies[int(n * 0.99)],
        'p999': latencies[int(n * 0.999)] if n > 1000 else latencies[-1],
        'max': max(latencies),
        'stdev': statistics.stdev(latencies) if len(latencies) > 1 else 0,
        'jitter_cv': (statistics.stdev(latencies) / statistics.mean(latencies)) * 100 if len(latencies) > 1 and statistics.mean(latencies) > 0 else 0
    }

def print_comparison(baseline_stats, espill_stats):
    """Print detailed comparison"""
    
    print("\n" + "=" * 80)
    print("E-SPILL VS BASELINE - DETAILED COMPARISON")
    print("=" * 80)
    
    print(f"\nDATASET SIZE:")
    print(f"  Baseline: {baseline_stats['count']:,} transactions ({baseline_stats['errors']:,} errors)")
    print(f"  E-Spill:  {espill_stats['count']:,} transactions ({espill_stats['errors']:,} errors)")
    
    print(f"\n{'LATENCY METRICS (milliseconds)':<25} {'Baseline':>12} {'E-Spill':>12} {'Improvement':>15}")
    print("-" * 80)
    
    metrics = [
        ('Min', 'min'),
        ('Mean', 'mean'),
        ('Median (P50)', 'median'),
        ('P90', 'p90'),
        ('P95', 'p95'),
        ('P99', 'p99'),
        ('P99.9', 'p999'),
        ('Max', 'max'),
        ('Std Dev', 'stdev'),
        ('Jitter (CV %)', 'jitter_cv')
    ]
    
    improvements = {}
    
    for label, key in metrics:
        baseline_val = baseline_stats[key]
        espill_val = espill_stats[key]
        
        if baseline_val > 0:
            improvement = ((baseline_val - espill_val) / baseline_val) * 100
        else:
            improvement = 0
        
        improvements[key] = improvement
        
        symbol = "✓" if improvement > 0 else "✗"
        print(f"{label:<25} {baseline_val:>12.2f} {espill_val:>12.2f} {symbol} {improvement:>13.1f}%")
    
    print("\n" + "=" * 80)
    print("KEY FINDINGS FOR RESEARCH PAPER")
    print("=" * 80)
    
    print(f"\n📊 JITTER REDUCTION:")
    print(f"   Baseline: {baseline_stats['jitter_cv']:.1f}% CV")
    print(f"   E-Spill:  {espill_stats['jitter_cv']:.1f}% CV")
    print(f"   ✓ Improvement: {improvements['jitter_cv']:.1f}% reduction")
    
    print(f"\n📊 TAIL LATENCY IMPROVEMENT (P99):")
    print(f"   Baseline: {baseline_stats['p99']:.0f} ms")
    print(f"   E-Spill:  {espill_stats['p99']:.0f} ms")
    print(f"   ✓ Improvement: {improvements['p99']:.1f}% faster")
    
    print(f"\n📊 MEAN LATENCY:")
    print(f"   Baseline: {baseline_stats['mean']:.1f} ms")
    print(f"   E-Spill:  {espill_stats['mean']:.1f} ms")
    print(f"   ✓ Improvement: {improvements['mean']:.1f}% faster")
    
    print(f"\n📊 WORST CASE (Max Latency):")
    print(f"   Baseline: {baseline_stats['max']:.0f} ms")
    print(f"   E-Spill:  {espill_stats['max']:.0f} ms")
    print(f"   ✓ Improvement: {improvements['max']:.1f}% faster")
    
    # Summary
    print("\n" + "=" * 80)
    print("SUMMARY")
    print("=" * 80)
    
    if improvements['jitter_cv'] > 50:
        print("✅ EXCELLENT: Jitter reduced by >50% - highly significant improvement!")
    elif improvements['jitter_cv'] > 25:
        print("✅ GOOD: Jitter reduced by >25% - clear improvement")
    else:
        print("⚠️  MODERATE: Jitter reduction <25% - may need tuning")
    
    if improvements['p99'] > 50:
        print("✅ EXCELLENT: P99 latency improved by >50% - major tail latency reduction!")
    elif improvements['p99'] > 25:
        print("✅ GOOD: P99 latency improved by >25% - significant improvement")
    else:
        print("⚠️  MODERATE: P99 improvement <25% - may need tuning")
    
    print("\n")

def export_for_plots(results_dir, baseline_stats, espill_stats):
    """Export data for plotting in research paper"""
    
    output_file = results_dir / "comparison_summary.csv"
    
    with open(output_file, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['Metric', 'Baseline', 'E-Spill', 'Improvement_%'])
        
        metrics = [
            ('Mean', 'mean'),
            ('Median', 'median'),
            ('P90', 'p90'),
            ('P95', 'p95'),
            ('P99', 'p99'),
            ('P99.9', 'p999'),
            ('Jitter_CV', 'jitter_cv')
        ]
        
        for label, key in metrics:
            baseline_val = baseline_stats[key]
            espill_val = espill_stats[key]
            improvement = ((baseline_val - espill_val) / baseline_val) * 100 if baseline_val > 0 else 0
            
            writer.writerow([label, baseline_val, espill_val, improvement])
    
    print(f"✓ Comparison data exported to: {output_file}")
    print(f"  Use this for generating plots in your paper\n")

def main(results_dir):
    results_dir = Path(results_dir)
    
    if not results_dir.exists():
        print(f"ERROR: Results directory not found: {results_dir}")
        sys.exit(1)
    
    baseline_file = results_dir / "baseline_latency.csv"
    espill_file = results_dir / "espill_latency.csv"
    
    if not baseline_file.exists():
        print(f"ERROR: Baseline file not found: {baseline_file}")
        sys.exit(1)
    
    if not espill_file.exists():
        print(f"ERROR: E-Spill file not found: {espill_file}")
        sys.exit(1)
    
    print("\nAnalyzing latency data...")
    baseline_stats = analyze_latency_file(baseline_file)
    espill_stats = analyze_latency_file(espill_file)
    
    if not baseline_stats or not espill_stats:
        print("ERROR: Could not analyze data files")
        sys.exit(1)
    
    print_comparison(baseline_stats, espill_stats)
    export_for_plots(results_dir, baseline_stats, espill_stats)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 compare_results.py <results_directory>")
        print("Example: python3 compare_results.py results/comparison_20260127_120000")
        sys.exit(1)
    
    main(sys.argv[1])
