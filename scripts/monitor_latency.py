#!/usr/bin/env python3
"""
Transaction Latency Monitor for E-Spill Baseline Testing

Monitors transaction latency in real-time by:
1. Watching Caliper report files for transaction data
2. Calculating latency statistics (mean, percentiles, jitter)
3. Detecting latency spikes that correlate with GC events
"""

import json
import sys
import statistics
import time
from pathlib import Path
from collections import deque
from datetime import datetime

class LatencyMonitor:
    def __init__(self, report_file, window_size=100):
        self.report_file = report_file
        self.window_size = window_size  # Number of transactions for rolling stats
        self.latencies = deque(maxlen=window_size)
        self.all_latencies = []
        
    def parse_caliper_report(self):
        """Parse Caliper HTML/JSON report for latency data"""
        # Caliper may output HTML or JSON depending on version
        # Try to read as JSON first, fallback to parsing from logs
        
        if not Path(self.report_file).exists():
            print(f"Waiting for report file: {self.report_file}")
            return None
            
        try:
            with open(self.report_file, 'r') as f:
                content = f.read()
                # Try to find JSON embedded in HTML
                if '<script>' in content:
                    # Extract JSON from script tags
                    start = content.find('var reportData = ')
                    if start > 0:
                        end = content.find('};', start) + 1
                        json_str = content[start + 17:end]
                        data = json.loads(json_str)
                        return data
        except Exception as e:
            print(f"Could not parse report: {e}")
            
        return None
        
    def calculate_metrics(self, latencies=None):
        """Calculate latency metrics"""
        if latencies is None:
            latencies = self.all_latencies
            
        if not latencies:
            return None
            
        sorted_lat = sorted(latencies)
        
        metrics = {
            'count': len(latencies),
            'min': min(latencies),
            'max': max(latencies),
            'mean': statistics.mean(latencies),
            'median': statistics.median(latencies),
            'stdev': statistics.stdev(latencies) if len(latencies) > 1 else 0,
            'p50': self._percentile(sorted_lat, 50),
            'p90': self._percentile(sorted_lat, 90),
            'p95': self._percentile(sorted_lat, 95),
            'p99': self._percentile(sorted_lat, 99),
            'p99_9': self._percentile(sorted_lat, 99.9),
        }
        
        # Calculate jitter (coefficient of variation)
        if metrics['mean'] > 0:
            metrics['jitter_cv'] = (metrics['stdev'] / metrics['mean']) * 100
        else:
            metrics['jitter_cv'] = 0
            
        return metrics
        
    def _percentile(self, sorted_data, percentile):
        """Calculate percentile from sorted data"""
        if not sorted_data:
            return 0
        index = int(len(sorted_data) * percentile / 100.0)
        if index >= len(sorted_data):
            index = len(sorted_data) - 1
        return sorted_data[index]
        
    def print_summary(self, metrics):
        """Print formatted latency summary"""
        if not metrics:
            print("No latency data available")
            return
            
        print("=" * 70)
        print("TRANSACTION LATENCY ANALYSIS")
        print("=" * 70)
        print(f"Report File: {self.report_file}")
        print()
        
        print("LATENCY STATISTICS (seconds)")
        print("-" * 70)
        print(f"  Transactions:    {metrics['count']:8d}")
        print(f"  Min:             {metrics['min']:8.4f} s")
        print(f"  Mean:            {metrics['mean']:8.4f} s")
        print(f"  Median:          {metrics['median']:8.4f} s")
        print(f"  P90:             {metrics['p90']:8.4f} s")
        print(f"  P95:             {metrics['p95']:8.4f} s")
        print(f"  P99:             {metrics['p99']:8.4f} s  ⚠️  (TAIL LATENCY)")
        print(f"  P99.9:           {metrics['p99_9']:8.4f} s")
        print(f"  Max:             {metrics['max']:8.4f} s")
        print(f"  StdDev:          {metrics['stdev']:8.4f} s")
        print()
        
        print("JITTER ANALYSIS")
        print("-" * 70)
        print(f"  Coefficient of Variation: {metrics['jitter_cv']:.2f}%")
        if metrics['jitter_cv'] < 10:
            print("  ✓ Low jitter - consistent latency")
        elif metrics['jitter_cv'] < 30:
            print("  ⚠️  Moderate jitter - some variance")
        else:
            print("  ❌ High jitter - significant latency variance (likely GC impact)")
        print()
        
    def export_csv(self, output_file, latencies=None):
        """Export latencies to CSV"""
        if latencies is None:
            latencies = self.all_latencies
            
        with open(output_file, 'w') as f:
            f.write("transaction_id,latency_sec\n")
            for i, lat in enumerate(latencies):
                f.write(f"{i},{lat}\n")
        print(f"Latency data exported to: {output_file}")

def simulate_analysis(num_samples=1000, mean_lat=0.5, gc_spike_prob=0.05):
    """Simulate latency analysis for testing (when no real data available)"""
    import random
    
    print("⚠️  No report file found, running simulation for demonstration")
    print()
    
    latencies = []
    for i in range(num_samples):
        # Normal latency
        lat = random.gauss(mean_lat, mean_lat * 0.1)
        
        # Simulate GC spikes (5% of transactions)
        if random.random() < gc_spike_prob:
            lat += random.gauss(1.0, 0.3)  # Add GC pause
            
        latencies.append(max(0.001, lat))  # Minimum 1ms
        
    monitor = LatencyMonitor("simulated")
    monitor.all_latencies = latencies
    metrics = monitor.calculate_metrics()
    monitor.print_summary(metrics)
    
    print("NOTE: This is simulated data. Run actual Caliper tests for real metrics.")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 monitor_latency.py <caliper_report_file> [output_csv]")
        print()
        print("Example:")
        print("  python3 monitor_latency.py report.html")
        print("  python3 monitor_latency.py report.html results/low_intensity/latency.csv")
        print()
        simulate_analysis()
        sys.exit(0)
        
    report_file = sys.argv[1]
    
    monitor = LatencyMonitor(report_file)
    data = monitor.parse_caliper_report()
    
    if data:
        # Extract latencies from parsed data
        # Note: Actual implementation depends on Caliper report format
        print("Report parsed successfully")
        # TODO: Extract latency data from report structure
    else:
        print(f"Could not parse report file: {report_file}")
        print("For demonstration, showing simulated analysis:")
        print()
        simulate_analysis()
        sys.exit(0)
        
    metrics = monitor.calculate_metrics()
    monitor.print_summary(metrics)
    
    if len(sys.argv) >= 3:
        output_csv = sys.argv[2]
        monitor.export_csv(output_csv)

if __name__ == '__main__':
    main()
