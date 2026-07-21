#!/usr/bin/env python3
"""
Mempool Tsunami stress test.

Each TX is a plain ETH transfer (value=0) to a dummy address with
CALLDATA_SIZE bytes of zero calldata. No contract execution, no SSTOREs,
no EVM loops — just raw TX pool heap pressure.

Each TX occupies ~CALLDATA_SIZE bytes in Besu's pending TX pool (JVM heap).
With 30 workers submitting continuously, the pool saturates and forces
Old Gen GC pressure without touching the state trie lock.

Key design:
  - 21,000 (base) + CALLDATA_SIZE * 16 (zero bytes) gas per TX
  - 30 workers < Besu HTTP thread pool limit (avoids RemoteDisconnected)
  - NonceManager: thread-safe per-account nonce counter
  - calldata size is configurable (default 10240 = 10 KB)
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

DEAD_ADDRESS = '0x000000000000000000000000000000000000dEaD'


class NonceManager:
    """Thread-safe per-account nonce counter seeded from chain state."""

    def __init__(self, w3, accounts):
        self._counts = {}
        self._locks = {}
        for acct in accounts:
            addr = acct.address
            pending = w3.eth.get_transaction_count(addr, 'pending')
            self._counts[addr] = pending
            self._locks[addr] = threading.Lock()

    def next(self, address):
        with self._locks[address]:
            n = self._counts[address]
            self._counts[address] += 1
            return n


class MempoolFloodTest:
    def __init__(self, num_workers, duration, calldata_size,
                 warmup_duration=0, warmup_workers=None):
        self.num_workers = num_workers
        self.duration = duration
        self.calldata_size = calldata_size
        self.warmup_duration = warmup_duration
        self.warmup_workers = warmup_workers if warmup_workers is not None else num_workers

        self.w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
        if not self.w3.is_connected():
            print('❌ Besu not running'); exit(1)

        self.eth_accounts = [
            self.w3.eth.account.from_key(pk) for _, pk in ACCOUNTS
        ]

        # Gas: 21,000 base + calldata_size * 16 (non-zero=68, zero=16; use zero bytes)
        # 10KB: 21,000 + 10240*16 = 184,840 → use 300,000 for headroom
        self.gas_per_tx = max(300_000, 21_000 + calldata_size * 16 + 50_000)

        # Pre-build the calldata blob (zero bytes are cheapest at 16 gas each)
        self.calldata = b'\x00' * calldata_size

        self.running = True
        self.lock = threading.Lock()
        self.results = []

        n_accts = len(self.eth_accounts)
        print(f'✅ MempoolFloodTest | workers={num_workers} | '
              f'calldata={calldata_size//1024}KB/TX | accts={n_accts}')
        print(f'   gas/TX={self.gas_per_tx:,} | duration={duration}s')
        print(f'   Target: {DEAD_ADDRESS}')
        for i, acct in enumerate(self.eth_accounts):
            print(f'   Account {i}: {acct.address}')

    def worker_thread(self, worker_id, nonce_mgr, record=True, duration=None):
        duration = duration if duration is not None else self.duration

        acct = self.eth_accounts[worker_id % len(self.eth_accounts)]
        tx_count = 0
        start_time = time.time()

        while self.running and (time.time() - start_time < duration):
            tx_start = time.time()
            try:
                nonce = nonce_mgr.next(acct.address)

                tx = {
                    'from': acct.address,
                    'to': DEAD_ADDRESS,
                    'value': 0,
                    'nonce': nonce,
                    'gas': self.gas_per_tx,
                    'gasPrice': 0,
                    'chainId': 1337,
                    'data': self.calldata,
                }
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
                            'success': True,
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
                time.sleep(0.05)

    def run(self, output_prefix):
        os.makedirs(
            os.path.dirname(output_prefix) if os.path.dirname(output_prefix) else '.',
            exist_ok=True)

        if self.warmup_duration > 0:
            print(f'\n🧪 Warmup {self.warmup_duration}s ({self.warmup_workers} workers)...')
            nonce_mgr = NonceManager(self.w3, self.eth_accounts)
            warmup_threads = []
            for i in range(self.warmup_workers):
                t = threading.Thread(
                    target=self.worker_thread,
                    args=(i, nonce_mgr, False, self.warmup_duration))
                t.daemon = True
                warmup_threads.append(t)
                t.start()
                time.sleep(0.02)
            for t in warmup_threads:
                t.join()
            print('✅ Warmup done\n')

        print('🚀 Measurement starting...\n')
        nonce_mgr = NonceManager(self.w3, self.eth_accounts)
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
                args=(i, nonce_mgr, True, self.duration))
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
    parser.add_argument('--workers', type=int, default=30)
    parser.add_argument('--duration', type=int, default=200)
    parser.add_argument('--calldata-size', type=int, default=10240,
                        help='Calldata bytes per TX (default 10240 = 10 KB)')
    parser.add_argument('--output', type=str, default='results/mempool_flood/run')
    parser.add_argument('--warmup-duration', type=int, default=0)
    parser.add_argument('--warmup-workers', type=int, default=None)
    args = parser.parse_args()

    test = MempoolFloodTest(
        num_workers=args.workers,
        duration=args.duration,
        calldata_size=args.calldata_size,
        warmup_duration=args.warmup_duration,
        warmup_workers=args.warmup_workers,
    )
    test.run(args.output)
