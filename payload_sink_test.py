#!/usr/bin/env python3
"""
PayloadSink large-calldata stress test.

Each transaction carries `payload_bytes` bytes of calldata.
This forces Besu's JVM tx pool to hold the full payload in heap
for every in-flight transaction — the primary mechanism for Old Gen saturation.
"""

import json
import time
import csv
import os
import threading
import statistics
import argparse
from web3 import Web3


class PayloadSinkTest:
    def __init__(self, num_workers, duration, payload_bytes,
                 warmup_duration=0, warmup_workers=None):
        self.num_workers = num_workers
        self.duration = duration
        self.payload_bytes = payload_bytes
        self.warmup_duration = warmup_duration
        self.warmup_workers = warmup_workers if warmup_workers is not None else num_workers

        self.w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
        if not self.w3.is_connected():
            print('❌ Besu not running'); exit(1)

        with open('PayloadSink.json') as f:
            artifact = json.load(f)
        with open('networkconfig.json') as f:
            config = json.load(f)

        self.contract_address = config['ethereum']['contracts']['PayloadSink']['address']
        self.contract = self.w3.eth.contract(
            address=self.contract_address, abi=artifact['abi'])

        private_key = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'
        self.account = self.w3.eth.account.from_key(private_key)

        # Pre-build payload once (random-ish bytes to prevent compression)
        import hashlib
        seed = hashlib.sha256(b'payload').digest()
        self.payload = (seed * (payload_bytes // 32 + 1))[:payload_bytes]

        self.running = True
        self.lock = threading.Lock()
        self.results = []

        print(f'✅ PayloadSink Test Initialized')
        print(f'   Workers:      {num_workers}')
        print(f'   Duration:     {duration}s')
        print(f'   Payload/TX:   {payload_bytes:,} bytes ({payload_bytes/1024:.1f} KB)')
        print(f'   Contract:     {self.contract_address}')

    def worker_thread(self, worker_id, output_prefix, record=True,
                      duration=None, start_offset=0):
        duration = duration if duration is not None else self.duration
        tx_count = 0
        success_count = 0
        error_count = 0
        start_time = time.time()

        while self.running and (time.time() - start_time < duration):
            tx_start = time.time()
            try:
                tx = self.contract.functions.submit(self.payload).build_transaction({
                    'from': self.account.address,
                    'nonce': self.w3.eth.get_transaction_count(self.account.address),
                    'gas': 8000000,
                    'gasPrice': 0,
                    'chainId': 1337
                })
                signed_tx = self.account.sign_transaction(tx)
                tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

                latency_ms = (time.time() - tx_start) * 1000

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
                        })
                time.sleep(0.1)

    def run(self, output_prefix='results/payload_sink/run'):
        os.makedirs(os.path.dirname(output_prefix) if os.path.dirname(output_prefix) else '.', exist_ok=True)

        if self.warmup_duration > 0:
            print(f'\n🧪 Warmup {self.warmup_duration}s ({self.warmup_workers} workers)...')
            warmup_threads = []
            for i in range(self.warmup_workers):
                t = threading.Thread(
                    target=self.worker_thread,
                    args=(i, output_prefix, False, self.warmup_duration, 1_000_000_000))
                t.daemon = True
                warmup_threads.append(t)
                t.start()
                time.sleep(0.05)
            for t in warmup_threads:
                t.join()
            print('✅ Warmup done\n')

        print('🚀 Starting measurement...\n')
        start_time = time.time()
        threads = []

        for i in range(self.num_workers):
            t = threading.Thread(
                target=self.worker_thread,
                args=(i, output_prefix, True, self.duration, 0))
            t.daemon = True
            threads.append(t)
            t.start()
            time.sleep(0.05)

        # Progress monitor
        def monitor():
            last = 0
            while self.running and (time.time() - start_time < self.duration):
                time.sleep(15)
                with self.lock:
                    cur = len([r for r in self.results if r['success']])
                elapsed = time.time() - start_time
                rate = cur / elapsed if elapsed > 0 else 0
                print(f'  [{int(elapsed):3d}s] {cur:5d} txs | {rate:.1f} tx/s | +{cur-last} last 15s')
                last = cur
        mt = threading.Thread(target=monitor); mt.daemon = True; mt.start()

        try:
            for t in threads:
                t.join()
        except KeyboardInterrupt:
            self.running = False

        elapsed = time.time() - start_time
        success = [r for r in self.results if r['success']]

        print(f'\n{"="*60}')
        print(f'PAYLOAD SINK TEST COMPLETE')
        print(f'Duration: {elapsed:.1f}s | Successful TXs: {len(success)}')
        print(f'Total Rate: {len(success)/elapsed:.2f} tx/s')

        if success:
            lats = sorted(r['latency_ms'] for r in success)
            print(f'Latency (ms):')
            print(f'  Mean:   {statistics.mean(lats):.1f}')
            print(f'  P99:    {lats[max(0,int(len(lats)*0.99)-1)]:.1f}')
            print(f'  Max:    {max(lats):.1f}')

        csv_path = f'{output_prefix}_latency.csv'
        with open(csv_path, 'w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=['worker_id','tx_count','timestamp','latency_ms','success'])
            writer.writeheader()
            for r in self.results:
                writer.writerow({k: r.get(k, '') for k in ['worker_id','tx_count','timestamp','latency_ms','success']})
        print(f'Results: {csv_path}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--workers', type=int, default=40)
    parser.add_argument('--duration', type=int, default=200)
    parser.add_argument('--payload-bytes', type=int, default=10240,
                        help='Bytes of calldata per transaction (default: 10240 = 10KB)')
    parser.add_argument('--output', type=str, default='results/payload_sink/run')
    parser.add_argument('--warmup-duration', type=int, default=0)
    parser.add_argument('--warmup-workers', type=int, default=None)
    args = parser.parse_args()

    test = PayloadSinkTest(
        num_workers=args.workers,
        duration=args.duration,
        payload_bytes=args.payload_bytes,
        warmup_duration=args.warmup_duration,
        warmup_workers=args.warmup_workers
    )
    test.run(args.output)
