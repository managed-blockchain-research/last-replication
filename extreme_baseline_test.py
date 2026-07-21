#!/usr/bin/env python3
"""
EXTREME Intensity Test - Designed to trigger heavy GC pressure

This test uses aggressive parameters to demonstrate the problem that e-spill solves:
- High transaction rate (200+ tx/s)
- Large memory footprint per transaction (200 slots)
- Many concurrent workers
- Sustained duration

Expected outcome: >15% GC overhead, significant latency jitter
"""

import json
import time
import csv
import threading
from datetime import datetime
from web3 import Web3
import statistics

class AggressiveBaselineTest:
    def __init__(self, num_workers=20, duration=600, slots_per_tx=200, warmup_duration=0, warmup_slots=None, warmup_workers=None):
        self.num_workers = num_workers
        self.duration = duration
        self.slots_per_tx = slots_per_tx
        self.warmup_duration = warmup_duration
        self.warmup_slots = warmup_slots if warmup_slots is not None else slots_per_tx
        self.warmup_workers = warmup_workers if warmup_workers is not None else num_workers
        
        # Connect to Besu
        self.w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
        
        if not self.w3.is_connected():
            print('❌ Besu not running')
            exit(1)
        
        # Load contract
        with open('StateBloater.json', 'r') as f:
            artifact = json.load(f)
        
        with open('networkconfig.json', 'r') as f:
            config = json.load(f)
        
        self.contract_address = config['ethereum']['contracts']['StateBloater']['address']
        self.contract = self.w3.eth.contract(address=self.contract_address, abi=artifact['abi'])
        
        # Setup account
        private_key = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'
        self.account = self.w3.eth.account.from_key(private_key)
        
        # Shared state
        self.running = True
        self.lock = threading.Lock()
        self.results = []
        
        print('✅ Extreme Intensity Test Initialized')
        print(f'   Workers: {num_workers}')
        print(f'   Duration: {duration}s ({duration/60:.1f} minutes)')
        print(f'   Slots per TX: {slots_per_tx}')
        print(f'   Contract: {self.contract_address}')
        print(f'   Expected: >200 tx/s total, HIGH GC pressure\n')
    
    def worker_thread(self, worker_id, output_file, record=True, slots_per_tx=None, duration=None, start_offset=0):
        """Worker thread that continuously sends transactions"""
        slots_per_tx = slots_per_tx if slots_per_tx is not None else self.slots_per_tx
        duration = duration if duration is not None else self.duration
        tx_count = 0
        success_count = 0
        error_count = 0
        start_time = time.time()
        
        while self.running and (time.time() - start_time < duration):
            tx_start = time.time()
            
            try:
                # Calculate unique storage range for this worker
                start_idx = start_offset + (worker_id * 10000000) + (tx_count * slots_per_tx)
                
                # Build transaction
                tx = self.contract.functions.bloat(start_idx, slots_per_tx).build_transaction({
                    'from': self.account.address,
                    'nonce': self.w3.eth.get_transaction_count(self.account.address),
                    'gas': 8000000,
                    'gasPrice': 0,
                    'chainId': 1337
                })
                
                # Sign and send
                signed_tx = self.account.sign_transaction(tx)
                tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
                
                latency_ms = (time.time() - tx_start) * 1000
                
                # Record result
                if record:
                    with self.lock:
                        self.results.append({
                            'worker_id': worker_id,
                            'tx_count': tx_count,
                            'timestamp': time.time() - start_time,
                            'latency_ms': latency_ms,
                            'success': True
                        })
                
                success_count += 1
                tx_count += 1
                
                # No sleep - send as fast as possible to maximize pressure
                
            except Exception as e:
                error_count += 1
                latency_ms = (time.time() - tx_start) * 1000
                
                if record:
                    with self.lock:
                        self.results.append({
                            'worker_id': worker_id,
                            'tx_count': tx_count,
                            'timestamp': time.time() - start_time,
                            'latency_ms': latency_ms,
                            'success': False,
                            'error': str(e)[:50]
                        })
                
                time.sleep(0.1)  # Brief backoff on errors
        
        if record:
            print(f'  Worker {worker_id:2d} finished: {success_count} txs sent, {error_count} errors')
    
    def monitor_thread(self, start_time):
        """Monitor thread that prints periodic updates"""
        last_count = 0
        
        while self.running and (time.time() - start_time < self.duration):
            time.sleep(10)  # Update every 10 seconds
            
            with self.lock:
                current_count = len([r for r in self.results if r['success']])
            
            elapsed = time.time() - start_time
            rate = current_count / elapsed if elapsed > 0 else 0
            new_txs = current_count - last_count
            
            print(f'  [{int(elapsed):3d}s] Total: {current_count:5d} txs | Rate: {rate:6.1f} tx/s | Last 10s: {new_txs} txs')
            last_count = current_count
    
    def run(self, output_prefix='results/extreme/baseline'):
        """Run the extreme intensity test"""
        import os
        os.makedirs(os.path.dirname(output_prefix), exist_ok=True)

        if self.warmup_duration > 0:
            print('🧪 Starting warm-up phase (state aging)...')
            print(f'   Warm-up Workers: {self.warmup_workers}')
            print(f'   Warm-up Duration: {self.warmup_duration}s')
            print(f'   Warm-up Slots per TX: {self.warmup_slots}\n')

            warmup_threads = []
            warmup_start = time.time()
            warmup_offset = 1_000_000_000
            for i in range(self.warmup_workers):
                t = threading.Thread(
                    target=self.worker_thread,
                    args=(i, output_prefix, False, self.warmup_slots, self.warmup_duration, warmup_offset)
                )
                t.daemon = True
                warmup_threads.append(t)
                t.start()
                time.sleep(0.05)

            for t in warmup_threads:
                t.join()

            print(f'✅ Warm-up complete in {time.time() - warmup_start:.1f}s\n')
        
        print('🚀 Starting EXTREME intensity test...\n')
        
        start_time = time.time()
        threads = []
        
        # Start monitor thread
        monitor = threading.Thread(target=self.monitor_thread, args=(start_time,))
        monitor.daemon = True
        monitor.start()
        
        # Start worker threads
        for i in range(self.num_workers):
            t = threading.Thread(target=self.worker_thread, args=(i, output_prefix, True, self.slots_per_tx, self.duration, 0))
            t.daemon = True
            threads.append(t)
            t.start()
            time.sleep(0.05)  # Stagger start slightly
        
        # Wait for completion
        try:
            for t in threads:
                t.join()
        except KeyboardInterrupt:
            print('\n⚠️  Test interrupted by user')
            self.running = False
            time.sleep(2)  # Let threads finish
        
        elapsed = time.time() - start_time
        
        # Analyze results
        success_results = [r for r in self.results if r['success']]
        error_results = [r for r in self.results if not r['success']]
        
        print(f'\n{"="*70}')
        print(f'EXTREME INTENSITY TEST COMPLETE')
        print(f'{"="*70}')
        print(f'Duration:          {elapsed:.1f}s ({elapsed/60:.1f} minutes)')
        print(f'Successful TXs:    {len(success_results)}')
        print(f'Failed TXs:        {len(error_results)}')
        print(f'Total Rate:        {len(success_results)/elapsed:.2f} tx/s')
        print(f'Memory Pressure:   ~{len(success_results) * self.slots_per_tx * 32 / (1024**3):.2f} GB written')
        
        if success_results:
            latencies = [r['latency_ms'] for r in success_results]
            latencies.sort()
            
            print(f'\nLatency Statistics (ms):')
            print(f'  Min:     {min(latencies):7.2f}')
            print(f'  Mean:    {statistics.mean(latencies):7.2f}')
            print(f'  Median:  {statistics.median(latencies):7.2f}')
            print(f'  P90:     {latencies[int(len(latencies)*0.90)]:7.2f}')
            print(f'  P95:     {latencies[int(len(latencies)*0.95)]:7.2f}')
            print(f'  P99:     {latencies[int(len(latencies)*0.99)]:7.2f}')
            print(f'  Max:     {max(latencies):7.2f}')
            print(f'  StdDev:  {statistics.stdev(latencies):7.2f}')
            
            # Calculate jitter
            cv = (statistics.stdev(latencies) / statistics.mean(latencies)) * 100
            print(f'  Jitter (CV): {cv:.1f}%')
        
        # Export to CSV
        csv_file = f'{output_prefix}_latency.csv'
        with open(csv_file, 'w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=['worker_id', 'tx_count', 'timestamp', 'latency_ms', 'success'])
            writer.writeheader()
            for r in self.results:
                writer.writerow({k: r.get(k, '') for k in ['worker_id', 'tx_count', 'timestamp', 'latency_ms', 'success']})
        
        print(f'\n📊 Results saved to:')
        print(f'   {csv_file}')
        print(f'\n📊 NOW ANALYZE GC LOGS:')
        print(f'   python3 scripts/monitor_gc.py $(ls -t baseline_gc_*.log | head -1)')
        print(f'\n⚠️  Expected GC overhead: >15% (demonstrates e-spill benefit!)')
        print()

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='Extreme intensity test to demonstrate GC problem')
    parser.add_argument('--workers', type=int, default=20, help='Number of concurrent workers (default: 20)')
    parser.add_argument('--duration', type=int, default=600, help='Test duration in seconds (default: 600 = 10 min)')
    parser.add_argument('--slots', type=int, default=200, help='Storage slots per TX (default: 200)')
    parser.add_argument('--output', type=str, default='results/extreme/baseline', help='Output prefix')
    parser.add_argument('--warmup-duration', type=int, default=0, help='Warm-up duration in seconds before measurement')
    parser.add_argument('--warmup-slots', type=int, default=None, help='Warm-up slots per TX (defaults to --slots)')
    parser.add_argument('--warmup-workers', type=int, default=None, help='Warm-up worker count (defaults to --workers)')
    
    args = parser.parse_args()
    
    test = AggressiveBaselineTest(
        num_workers=args.workers,
        duration=args.duration,
        slots_per_tx=args.slots,
        warmup_duration=args.warmup_duration,
        warmup_slots=args.warmup_slots,
        warmup_workers=args.warmup_workers
    )
    
    test.run(args.output)
