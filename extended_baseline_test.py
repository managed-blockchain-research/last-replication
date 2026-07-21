#!/usr/bin/env python3
"""
Extended Baseline Test for E-Spill Research

Runs configurable intensity tests to measure GC overhead and transaction latency
"""

import json
import time
import csv
import argparse
from datetime import datetime
from web3 import Web3

def run_baseline_test(duration, tx_rate, slots_per_tx, output_prefix):
    """Run baseline test with specified parameters"""
    
    # Connect to Besu
    w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
    
    if not w3.is_connected():
        print('❌ Besu not running. Start with: ./scripts/start_besu_baseline.sh')
        exit(1)
    
    print('✅ Connected to Besu')
    print(f'   Block: {w3.eth.block_number}')
    
    # Load contract
    with open('StateBloater.json', 'r') as f:
        artifact = json.load(f)
    
    with open('networkconfig.json', 'r') as f:
        config = json.load(f)
    
    contract_address = config['ethereum']['contracts']['StateBloater']['address']
    print(f'✅ Contract: {contract_address}')
    
    # Setup account
    private_key = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'
    account = w3.eth.account.from_key(private_key)
    
    # Create contract instance
    contract = w3.eth.contract(address=contract_address, abi=artifact['abi'])
    
    print(f'\n🚀 Starting Baseline Test')
    print(f'   Duration: {duration}s')
    print(f'   Target Rate: {tx_rate} tx/s')
    print(f'   Slots per Tx: {slots_per_tx}')
    print(f'   Output: {output_prefix}_*.csv\n')
    
    # Prepare CSV output
    latency_file = f'{output_prefix}_latency.csv'
    with open(latency_file, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['tx_id', 'timestamp', 'latency_ms', 'success'])
    
    tx_count = 0
    success_count = 0
    error_count = 0
    start_time = time.time()
    latencies = []
    
    delay = 1.0 / tx_rate if tx_rate > 0 else 0.1
    
    try:
        while time.time() - start_time < duration:
            tx_start = time.time()
            
            try:
                # Build transaction
                start_idx = tx_count * slots_per_tx
                tx = contract.functions.bloat(start_idx, slots_per_tx).build_transaction({
                    'from': account.address,
                    'nonce': w3.eth.get_transaction_count(account.address),
                    'gas': 8000000,
                    'gasPrice': 0,
                    'chainId': 1337
                })
                
                # Sign and send
                signed_tx = account.sign_transaction(tx)
                tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
                
                # Measure latency (time to send, not confirm)
                latency_ms = (time.time() - tx_start) * 1000
                latencies.append(latency_ms)
                
                # Log to CSV
                with open(latency_file, 'a', newline='') as f:
                    writer = csv.writer(f)
                    writer.writerow([tx_count, time.time() - start_time, latency_ms, True])
                
                success_count += 1
                tx_count += 1
                
                if tx_count % 50 == 0:
                    elapsed = time.time() - start_time
                    actual_rate = success_count / elapsed
                    print(f'  [{int(elapsed)}s] Sent {success_count} txs (rate: {actual_rate:.1f} tx/s, errors: {error_count})')
                
            except Exception as e:
                error_count += 1
                latency_ms = (time.time() - tx_start) * 1000
                
                # Log error to CSV
                with open(latency_file, 'a', newline='') as f:
                    writer = csv.writer(f)
                    writer.writerow([tx_count, time.time() - start_time, latency_ms, False])
                
                if error_count % 10 == 0:
                    print(f'  ⚠️  {error_count} errors so far (e.g.: {str(e)[:50]}...)')
                
                time.sleep(0.5)  # Back off on errors
                continue
            
            # Rate limiting
            time.sleep(delay)
    
    except KeyboardInterrupt:
        print('\n⚠️  Test interrupted by user')
    
    elapsed = time.time() - start_time
    
    # Final summary
    print(f'\n{"="*70}')
    print(f'BASELINE TEST COMPLETE')
    print(f'{"="*70}')
    print(f'Duration:          {elapsed:.1f}s')
    print(f'Transactions Sent: {success_count}')
    print(f'Errors:            {error_count}')
    print(f'Actual Rate:       {success_count/elapsed:.2f} tx/s')
    
    if latencies:
        latencies.sort()
        print(f'\nLatency Statistics (ms):')
        print(f'  Min:    {min(latencies):.2f}')
        print(f'  Mean:   {sum(latencies)/len(latencies):.2f}')
        print(f'  Median: {latencies[len(latencies)//2]:.2f}')
        print(f'  P95:    {latencies[int(len(latencies)*0.95)]:.2f}')
        print(f'  P99:    {latencies[int(len(latencies)*0.99)]:.2f}')
        print(f'  Max:    {max(latencies):.2f}')
    
    print(f'\n📊 Results saved to:')
    print(f'   {latency_file}')
    print(f'\n📊 Analyze GC logs:')
    print(f'   python3 scripts/monitor_gc.py baseline_gc_*.log')
    print()

def main():
    parser = argparse.ArgumentParser(description='Run extended baseline test for e-spill research')
    parser.add_argument('--duration', type=int, default=300, help='Test duration in seconds (default: 300)')
    parser.add_argument('--rate', type=float, default=20, help='Target transaction rate (default: 20 tx/s)')
    parser.add_argument('--slots', type=int, default=50, help='Storage slots per transaction (default: 50)')
    parser.add_argument('--output', type=str, default='results/baseline', help='Output file prefix (default: results/baseline)')
    parser.add_argument('--config', type=str, choices=['low', 'medium', 'high'], help='Use preset configuration')
    
    args = parser.parse_args()
    
    # Preset configurations
    if args.config == 'low':
        args.duration = 300  # 5 minutes
        args.rate = 20
        args.slots = 50
        args.output = 'results/low_intensity/baseline'
    elif args.config == 'medium':
        args.duration = 600  # 10 minutes
        args.rate = 50
        args.slots = 50
        args.output = 'results/medium_intensity/baseline'
    elif args.config == 'high':
        args.duration = 900  # 15 minutes
        args.rate = 100
        args.slots = 100
        args.output = 'results/high_intensity/baseline'
    
    # Create output directory
    import os
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    
    run_baseline_test(args.duration, args.rate, args.slots, args.output)

if __name__ == '__main__':
    main()
