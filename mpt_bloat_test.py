#!/usr/bin/env python3
"""
ChunkWriter MPT-Leaf-Bloat stress test.

Each TX calls bloat(key), which writes 1024 × 32-byte words (32 KB) to storage
under a unique key. This forces Besu to instantiate massive MPT leaf nodes in
the JVM heap, keeping them live until block commit.

Key design decisions:
  - No keccak256 or large memory loops → EVM CPU is not the bottleneck
  - Thread-safe per-account NonceManager → 120 workers across 3 accounts
    without nonce collisions
  - Unique key per (worker_id, tx_count) → no cross-worker SSTORE collision
"""

import json, time, csv, os, threading, argparse
from web3 import Web3

HERE = os.path.dirname(os.path.abspath(__file__))

ACCOUNTS = [
    ('0xfe3b557e8fb62b89f4916b721be55ceb828dbd73',
     '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'),
    ('0x627306090abaB3A6e1400e9345bC60c78a8BEf57',
     '0xc87509a1c067bbde78beb793e6fa76530b6382a4c0241e5e4a9ec0a0f44dc0d3'),
    ('0xf17f52151EbEF6C7334FAD080c5704D77216b732',
     '0xae6ae8e5ccbfb04590405997ee2d52d2b330726137b875053c36d94e974d162f'),
]

# How far apart adjacent workers' storage keys are — avoids any overlap
# even with a long-running experiment (10M TXs per worker max)
KEY_STRIDE = 100_000_000


class NonceManager:
    """Thread-safe per-account nonce counter seeded from chain state."""

    def __init__(self, w3, accounts):
        self._w3 = w3
        self._counts = {}
        self._locks = {}
        for acct in accounts:
            addr = acct.address
            # Use 'pending' so we include already-submitted-but-unconfirmed TXs
            pending = w3.eth.get_transaction_count(addr, 'pending')
            self._counts[addr] = pending
            self._locks[addr] = threading.Lock()

    def next(self, address):
        with self._locks[address]:
            n = self._counts[address]
            self._counts[address] += 1
            return n


class MPTBloatTest:
    def __init__(self, num_workers, duration,
                 warmup_duration=0, warmup_workers=None, start_key_offset=0):
        self.num_workers = num_workers
        self.duration = duration
        self.warmup_duration = warmup_duration
        self.warmup_workers = warmup_workers if warmup_workers is not None else num_workers
        self.start_key_offset = start_key_offset

        self.w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
        if not self.w3.is_connected():
            print('❌ Besu not running'); exit(1)

        with open(os.path.join(HERE, 'ChunkWriter.json')) as f:
            artifact = json.load(f)
        with open(os.path.join(HERE, 'networkconfig.json')) as f:
            config = json.load(f)

        self.contract_address = config['ethereum']['contracts']['ChunkWriter']['address']
        self.contract = self.w3.eth.contract(
            address=self.contract_address, abi=artifact['abi'])

        self.eth_accounts = [
            self.w3.eth.account.from_key(pk) for _, pk in ACCOUNTS
        ]

        # Gas: 1024 cold SSTOREs × 22,100 = ~22.6M + loop overhead ≈ 25M
        # Use 300M for headroom across all EVM versions
        self.gas_per_tx = 300_000_000

        self.running = True
        self.lock = threading.Lock()
        self.results = []

        n_accts = len(self.eth_accounts)
        print(f'✅ MPTBloatTest | workers={num_workers} | 32KB/TX (1024 SSTOREs) | '
              f'accts={n_accts} (~{num_workers//n_accts} workers/acct)')
        print(f'   gas/TX={self.gas_per_tx:,} | duration={duration}s')
        print(f'   Contract: {self.contract_address}')
        for i, acct in enumerate(self.eth_accounts):
            print(f'   Account {i}: {acct.address}')

    def worker_thread(self, worker_id, output_prefix, nonce_mgr, record=True,
                      duration=None, key_offset=0):
        duration = duration if duration is not None else self.duration

        acct = self.eth_accounts[worker_id % len(self.eth_accounts)]
        tx_count = 0
        start_time = time.time()

        while self.running and (time.time() - start_time < duration):
            tx_start = time.time()
            try:
                # Unique key per (worker, tx) — no cross-worker collision
                key = key_offset + (worker_id * KEY_STRIDE) + tx_count

                nonce = nonce_mgr.next(acct.address)

                tx = self.contract.functions.bloat(key).build_transaction({
                    'from': acct.address,
                    'nonce': nonce,
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
                    args=(i, output_prefix, nonce_mgr, False,
                          self.warmup_duration, 5_000_000_000))
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
                args=(i, output_prefix, nonce_mgr, True, self.duration, self.start_key_offset))
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
    parser.add_argument('--workers', type=int, default=120)
    parser.add_argument('--duration', type=int, default=200)
    parser.add_argument('--output', type=str, default='results/mpt_bloat/run')
    parser.add_argument('--warmup-duration', type=int, default=0)
    parser.add_argument('--warmup-workers', type=int, default=None)
    parser.add_argument('--start-key-offset', type=int, default=0)
    args = parser.parse_args()

    test = MPTBloatTest(
        num_workers=args.workers,
        duration=args.duration,
        warmup_duration=args.warmup_duration,
        warmup_workers=args.warmup_workers,
        start_key_offset=args.start_key_offset,
    )
    test.run(args.output)
