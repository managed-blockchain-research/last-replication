#!/usr/bin/env python3
"""
MemoryBloater stress test.

Each TX calls bloat(sizeBytes) which allocates a fat `bytes` array in EVM
memory, touches every 32-byte word, then writes a checksum to storage.

The JVM must hold the EVM memory backing-array alive for the entire duration
of transaction execution, bypassing EVM state-trie lock contention and
attacking the JVM heap directly.

3 pre-funded dev accounts (round-robin) eliminate nonce contention.
"""

import json, time, csv, os, threading, argparse
from web3 import Web3

ACCOUNTS = [
    ('0xfe3b557e8fb62b89f4916b721be55ceb828dbd73',
     '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'),
    ('0x627306090abaB3A6e1400e9345bC60c78a8BEf57',
     '0xc87509a1c067bbde78beb793e6fa76530b6382a4c0241e5e4a9ec0a0f44dc0d3'),
    ('0xf17f52151EbEF6C7334FAD080c5704D77216b732',
     '0xae6ae8e5ccbfb04590405997ee2d52d2b330726137b875053c36d94e974d162f'),
]


class MemoryBloatTest:
    def __init__(self, num_workers, duration, size_bytes,
                 warmup_duration=0, warmup_workers=None):
        self.num_workers = num_workers
        self.duration = duration
        self.size_bytes = size_bytes
        self.warmup_duration = warmup_duration
        self.warmup_workers = warmup_workers if warmup_workers is not None else num_workers

        self.w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
        if not self.w3.is_connected():
            print('❌ Besu not running'); exit(1)

        with open('MemoryBloater.json') as f:
            artifact = json.load(f)
        with open('networkconfig.json') as f:
            config = json.load(f)

        self.contract_address = config['ethereum']['contracts']['MemoryBloater']['address']
        self.contract = self.w3.eth.contract(
            address=self.contract_address, abi=artifact['abi'])

        self.eth_accounts = [
            self.w3.eth.account.from_key(pk) for _, pk in ACCOUNTS
        ]

        # 300M covers up to ~8MB EVM memory expansion (quadratic gas formula)
        self.gas_per_tx = 300_000_000

        self.running = True
        self.lock = threading.Lock()
        self.results = []

        n_accts = len(self.eth_accounts)
        size_kb = size_bytes / 1024
        print(f'✅ MemoryBloatTest | workers={num_workers} | size={size_kb:.0f}KB/TX | '
              f'accts={n_accts} (~{num_workers//n_accts} workers/acct) | '
              f'gas={self.gas_per_tx:,}')
        print(f'   Contract: {self.contract_address}')
        for i, acct in enumerate(self.eth_accounts):
            print(f'   Account {i}: {acct.address}')

    def worker_thread(self, worker_id, output_prefix, record=True,
                      size_bytes=None, duration=None):
        size_bytes = size_bytes if size_bytes is not None else self.size_bytes
        duration = duration if duration is not None else self.duration

        acct = self.eth_accounts[worker_id % len(self.eth_accounts)]
        tx_count = 0
        start_time = time.time()

        while self.running and (time.time() - start_time < duration):
            tx_start = time.time()
            try:
                tx = self.contract.functions.bloat(size_bytes).build_transaction({
                    'from': acct.address,
                    'nonce': self.w3.eth.get_transaction_count(acct.address),
                    'gas': self.gas_per_tx,
                    'gasPrice': 0,
                    'chainId': 1337
                })
                signed_tx = acct.sign_transaction(tx)
                self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

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
                tx_count += 1

            except Exception as e:
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

    def run(self, output_prefix):
        os.makedirs(
            os.path.dirname(output_prefix) if os.path.dirname(output_prefix) else '.',
            exist_ok=True)

        if self.warmup_duration > 0:
            print(f'\n🧪 Warmup {self.warmup_duration}s ({self.warmup_workers} workers)...')
            warmup_threads = []
            for i in range(self.warmup_workers):
                t = threading.Thread(
                    target=self.worker_thread,
                    args=(i, output_prefix, False, self.size_bytes, self.warmup_duration))
                t.daemon = True
                warmup_threads.append(t)
                t.start()
                time.sleep(0.02)
            for t in warmup_threads:
                t.join()
            print('✅ Warmup done\n')

        print('🚀 Measurement starting...\n')
        start_time = time.time()
        threads = []

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

        for i in range(self.num_workers):
            t = threading.Thread(
                target=self.worker_thread,
                args=(i, output_prefix, True, self.size_bytes, self.duration))
            t.daemon = True
            threads.append(t)
            t.start()
            time.sleep(0.02)

        try:
            for t in threads:
                t.join()
        except KeyboardInterrupt:
            self.running = False

        elapsed = time.time() - start_time
        success = [r for r in self.results if r['success']]
        print(f'\n{"="*60}')
        print(f'Duration: {elapsed:.1f}s | Successful TXs: {len(success)}')
        print(f'Total Rate: {len(success)/elapsed:.2f} tx/s')

        if success:
            lats = sorted(r['latency_ms'] for r in success)
            print(f'P99: {lats[max(0,int(len(lats)*0.99)-1)]:.1f}ms')
            print(f'Max: {max(lats):.1f}ms')

        csv_path = f'{output_prefix}_latency.csv'
        with open(csv_path, 'w', newline='') as f:
            writer = csv.DictWriter(
                f, fieldnames=['worker_id','tx_count','timestamp','latency_ms','success'])
            writer.writeheader()
            for r in self.results:
                writer.writerow({k: r.get(k,'') for k in
                                 ['worker_id','tx_count','timestamp','latency_ms','success']})
        print(f'Results: {csv_path}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--workers', type=int, default=40)
    parser.add_argument('--duration', type=int, default=200)
    parser.add_argument('--size-bytes', type=int, default=262144,
                        help='EVM memory allocation per TX in bytes (default 256KB)')
    parser.add_argument('--output', type=str, default='results/memory_bloat/run')
    parser.add_argument('--warmup-duration', type=int, default=0)
    parser.add_argument('--warmup-workers', type=int, default=None)
    args = parser.parse_args()

    test = MemoryBloatTest(
        num_workers=args.workers,
        duration=args.duration,
        size_bytes=args.size_bytes,
        warmup_duration=args.warmup_duration,
        warmup_workers=args.warmup_workers
    )
    test.run(args.output)
