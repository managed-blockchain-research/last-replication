#!/usr/bin/env python3
"""
Extreme intensity test for Nethermind (spaceneth)
"""

import json
import time
import csv
import threading
import argparse
import statistics
import os
import subprocess
from web3 import Web3


class AggressiveNethermindTest:
    def __init__(
        self,
        num_workers=20,
        duration=600,
        slots_per_tx=200,
        collect_metrics=True,
        metrics_output_dir='results/nethermind/metrics',
        warmup_duration=0,
        warmup_slots=None,
        warmup_workers=None,
        use_dotnet_trace=False
    ):
        self.num_workers = num_workers
        self.duration = duration
        self.slots_per_tx = slots_per_tx
        self.collect_metrics = collect_metrics
        self.metrics_output_dir = metrics_output_dir
        self.warmup_duration = warmup_duration
        self.warmup_slots = warmup_slots if warmup_slots is not None else slots_per_tx
        self.warmup_workers = warmup_workers if warmup_workers is not None else num_workers
        self.use_dotnet_trace = use_dotnet_trace

        self.w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
        if not self.w3.is_connected():
            print('❌ Nethermind not running')
            exit(1)

        self.chain_id = int(self.w3.eth.chain_id)

        with open('StateBloater.json', 'r') as f:
            artifact = json.load(f)

        with open('networkconfig_nethermind.json', 'r') as f:
            config = json.load(f)

        self.contract_address = config['ethereum']['contracts']['StateBloater']['address']
        self.contract = self.w3.eth.contract(address=self.contract_address, abi=artifact['abi'])

        self.private_key = '0x' + '1'.zfill(64)
        self.account = self.w3.eth.account.from_key(self.private_key)

        self.running = True
        self.lock = threading.Lock()
        self.nonce_lock = threading.Lock()
        self.next_nonce = self.w3.eth.get_transaction_count(self.account.address, 'pending')
        self.results = []

        print('✅ Nethermind Extreme Test Initialized')
        print(f'   Workers: {num_workers}')
        print(f'   Duration: {duration}s ({duration/60:.1f} minutes)')
        print(f'   Slots per TX: {slots_per_tx}')
        print(f'   Contract: {self.contract_address}')
        print(f'   Chain ID: {self.chain_id}')
        print()

    def worker_thread(self, worker_id, record=True, slots_per_tx=None, duration=None, start_offset=0):
        tx_count = 0
        success_count = 0
        error_count = 0
        start_time = time.time()

        slots_per_tx = slots_per_tx if slots_per_tx is not None else self.slots_per_tx
        duration = duration if duration is not None else self.duration

        while self.running and (time.time() - start_time < duration):
            tx_start = time.time()

            try:
                start_idx = start_offset + (worker_id * 10000000) + (tx_count * slots_per_tx)
                with self.nonce_lock:
                    nonce = self.next_nonce
                    self.next_nonce += 1
                tx = self.contract.functions.bloat(start_idx, slots_per_tx).build_transaction({
                    'from': self.account.address,
                    'nonce': nonce,
                    'gas': 8000000,
                    'gasPrice': 1_000_000_000,
                    'chainId': self.chain_id
                })

                signed_tx = self.account.sign_transaction(tx)
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
                            'error': ''
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
                            'error': str(e)[:120]
                        })
                msg = str(e).lower()
                if 'nonce' in msg:
                    with self.nonce_lock:
                        current = self.w3.eth.get_transaction_count(self.account.address, 'pending')
                        if current > self.next_nonce:
                            self.next_nonce = current
                time.sleep(0.1)

        if record:
            print(f'  Worker {worker_id:2d} finished: {success_count} txs sent, {error_count} errors')

    def monitor_thread(self, start_time):
        last_count = 0
        while self.running and (time.time() - start_time < self.duration):
            time.sleep(10)
            with self.lock:
                current_count = len([r for r in self.results if r['success']])
            elapsed = time.time() - start_time
            rate = current_count / elapsed if elapsed > 0 else 0
            new_txs = current_count - last_count
            print(f'  [{int(elapsed):3d}s] Total: {current_count:5d} txs | Rate: {rate:6.1f} tx/s | Last 10s: {new_txs} txs')
            last_count = current_count

    def _format_duration(self, seconds):
        seconds = int(seconds)
        days = seconds // 86400
        seconds %= 86400
        hours = seconds // 3600
        seconds %= 3600
        minutes = seconds // 60
        seconds %= 60
        return f"{days:02d}:{hours:02d}:{minutes:02d}:{seconds:02d}"

    def _find_nethermind_pid(self):
        pid_file = '/tmp/nethermind_spaceneth.pid'
        if os.path.exists(pid_file):
            try:
                pid = open(pid_file).read().strip()
                if pid and os.path.exists(f'/proc/{pid}'):
                    return pid
            except Exception:
                pass
        try:
            output = subprocess.check_output(['dotnet-counters', 'ps'], text=True)
        except Exception:
            output = ""
        for line in output.splitlines():
            line = line.strip()
            if not line or line.lower().startswith('pid'):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            pid = parts[0]
            name = " ".join(parts[1:]).lower()
            if 'nethermind' in name:
                return pid
        try:
            output = subprocess.check_output(['pgrep', '-f', 'nethermind.dll.*spaceneth'], text=True)
            pid = output.splitlines()[0].strip()
            if pid:
                return pid
        except Exception:
            pass
        return None

    def _start_dotnet_counters(self):
        os.makedirs(self.metrics_output_dir, exist_ok=True)
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        output_file = os.path.join(self.metrics_output_dir, f"dotnet_counters_{timestamp}.csv")
        duration = self._format_duration(self.duration)

        pid = self._find_nethermind_pid()
        if not pid:
            print('⚠️  Could not find Nethermind PID for dotnet-counters. Skipping metrics.')
            return None, None

        env = os.environ.copy()
        if 'DOTNET_ROOT' not in env and os.path.exists('/home/yeochan.yoon/.dotnet'):
            env['DOTNET_ROOT'] = '/home/yeochan.yoon/.dotnet'
            env['PATH'] = f"{env['DOTNET_ROOT']}:{env.get('PATH','')}"

        cmd = [
            'dotnet-counters', 'collect',
            '--process-id', str(pid),
            '--counters', 'System.Runtime',
            '--refresh-interval', '1',
            '--duration', duration,
            '--format', 'csv',
            '--output', output_file
        ]

        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env)
            print(f'📈 dotnet-counters started (PID {proc.pid})')
            print(f'   Output: {output_file}')
            return proc, output_file
        except Exception as e:
            print(f'⚠️  Failed to start dotnet-counters: {e}')
            return None, None

    def _start_dotnet_trace(self):
        os.makedirs(self.metrics_output_dir, exist_ok=True)
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        output_file = os.path.join(self.metrics_output_dir, f"dotnet_trace_{timestamp}.nettrace")
        duration = self._format_duration(self.duration)

        pid = self._find_nethermind_pid()
        if not pid:
            print('⚠️  Could not find Nethermind PID for dotnet-trace. Skipping trace.')
            return None, None

        env = os.environ.copy()
        if 'DOTNET_ROOT' not in env and os.path.exists('/home/yeochan.yoon/.dotnet'):
            env['DOTNET_ROOT'] = '/home/yeochan.yoon/.dotnet'
            env['PATH'] = f"{env['DOTNET_ROOT']}:{env.get('PATH','')}"

        cmd = [
            'dotnet-trace', 'collect',
            '--process-id', str(pid),
            '--duration', duration,
            '--profile', 'gc-verbose',
            '--output', output_file
        ]

        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env)
            print(f'📈 dotnet-trace started (PID {proc.pid})')
            print(f'   Output: {output_file}')
            return proc, output_file
        except Exception as e:
            print(f'⚠️  Failed to start dotnet-trace: {e}')
            return None, None

    def run(self, output_prefix='results/nethermind/baseline'):
        os.makedirs(os.path.dirname(output_prefix), exist_ok=True)

        print('🚀 Starting Nethermind EXTREME intensity test...\n')

        start_time = time.time()
        threads = []

        if self.warmup_duration > 0:
            print('🧪 Starting warm-up phase (state aging)...')
            print(f'   Warm-up Workers: {self.warmup_workers}')
            print(f'   Warm-up Duration: {self.warmup_duration}s')
            print(f'   Warm-up Slots per TX: {self.warmup_slots}\n')

            warmup_threads = []
            warmup_offset = 1_000_000_000
            for i in range(self.warmup_workers):
                t = threading.Thread(
                    target=self.worker_thread,
                    args=(i, False, self.warmup_slots, self.warmup_duration, warmup_offset)
                )
                t.daemon = True
                warmup_threads.append(t)
                t.start()
                time.sleep(0.05)

            for t in warmup_threads:
                t.join()

            print('✅ Warm-up complete\n')

        metrics_proc = None
        metrics_file = None
        if self.use_dotnet_trace:
            metrics_proc, metrics_file = self._start_dotnet_trace()
        elif self.collect_metrics:
            metrics_proc, metrics_file = self._start_dotnet_counters()

        monitor = threading.Thread(target=self.monitor_thread, args=(start_time,))
        monitor.daemon = True
        monitor.start()

        for i in range(self.num_workers):
            t = threading.Thread(target=self.worker_thread, args=(i, True, self.slots_per_tx, self.duration, 0))
            t.daemon = True
            threads.append(t)
            t.start()
            time.sleep(0.05)

        try:
            for t in threads:
                t.join()
        except KeyboardInterrupt:
            print('\n⚠️  Test interrupted by user')
            self.running = False
            time.sleep(2)

        if metrics_proc:
            metrics_proc.wait(timeout=self.duration + 60)
            if metrics_proc.stderr:
                err = metrics_proc.stderr.read()
                if err:
                    print(f'⚠️  diagnostics stderr: {err.strip()}')
            if metrics_file and not self.use_dotnet_trace:
                summary_path = os.path.splitext(metrics_file)[0] + "_summary.json"
                try:
                    subprocess.run(
                        [
                            'python3',
                            os.path.join(os.path.dirname(__file__), 'scripts', 'summarize_dotnet_counters.py'),
                            '--input', metrics_file,
                            '--output', summary_path
                        ],
                        check=True
                    )
                    print(f'📊 dotnet-counters summary: {summary_path}')
                except Exception as e:
                    print(f'⚠️  Failed to summarize dotnet-counters: {e}')

        elapsed = time.time() - start_time
        success_results = [r for r in self.results if r['success']]
        error_results = [r for r in self.results if not r['success']]

        print(f'\n{"="*70}')
        print('NETHERMIND EXTREME TEST COMPLETE')
        print(f'{"="*70}')
        print(f'Duration:          {elapsed:.1f}s ({elapsed/60:.1f} minutes)')
        print(f'Successful TXs:    {len(success_results)}')
        print(f'Failed TXs:        {len(error_results)}')
        print(f'Total Rate:        {len(success_results)/elapsed:.2f} tx/s')
        print(f'Memory Pressure:   ~{len(success_results) * self.slots_per_tx * 32 / (1024**3):.2f} GB written')

        if success_results:
            latencies = [r['latency_ms'] for r in success_results]
            latencies.sort()
            print('\nLatency Statistics (ms):')
            print(f'  Min:     {min(latencies):7.2f}')
            print(f'  Mean:    {statistics.mean(latencies):7.2f}')
            print(f'  Median:  {statistics.median(latencies):7.2f}')
            print(f'  P90:     {latencies[int(len(latencies)*0.90)]:7.2f}')
            print(f'  P95:     {latencies[int(len(latencies)*0.95)]:7.2f}')
            print(f'  P99:     {latencies[int(len(latencies)*0.99)]:7.2f}')
            print(f'  Max:     {max(latencies):7.2f}')
            print(f'  StdDev:  {statistics.stdev(latencies):7.2f}')
            cv = (statistics.stdev(latencies) / statistics.mean(latencies)) * 100
            print(f'  Jitter (CV): {cv:.1f}%')
        else:
            first_error = next((r.get('error') for r in error_results if r.get('error')), None)
            if first_error:
                print(f'First error: {first_error}')

        csv_file = f'{output_prefix}_latency.csv'
        with open(csv_file, 'w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=['worker_id', 'tx_count', 'timestamp', 'latency_ms', 'success', 'error'])
            writer.writeheader()
            for r in self.results:
                writer.writerow({k: r.get(k, '') for k in ['worker_id', 'tx_count', 'timestamp', 'latency_ms', 'success', 'error']})

        print(f'\n📊 Results saved to:')
        print(f'   {csv_file}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Extreme intensity test for Nethermind')
    parser.add_argument('--workers', type=int, default=20)
    parser.add_argument('--duration', type=int, default=600)
    parser.add_argument('--slots', type=int, default=200)
    parser.add_argument('--output', type=str, default='results/nethermind/baseline')
    parser.add_argument('--no-collect-metrics', action='store_true', help='Disable dotnet GC/LOH metrics collection')
    parser.add_argument('--metrics-output-dir', type=str, default='results/nethermind/metrics')
    parser.add_argument('--warmup-duration', type=int, default=0, help='Warm-up duration in seconds before measurement')
    parser.add_argument('--warmup-slots', type=int, default=None, help='Warm-up slots per TX (defaults to --slots)')
    parser.add_argument('--warmup-workers', type=int, default=None, help='Warm-up worker count (defaults to --workers)')
    parser.add_argument('--use-dotnet-trace', action='store_true', help='Collect dotnet-trace instead of dotnet-counters')
    args = parser.parse_args()

    test = AggressiveNethermindTest(
        num_workers=args.workers,
        duration=args.duration,
        slots_per_tx=args.slots,
        collect_metrics=not args.no_collect_metrics,
        metrics_output_dir=args.metrics_output_dir,
        warmup_duration=args.warmup_duration,
        warmup_slots=args.warmup_slots,
        warmup_workers=args.warmup_workers,
        use_dotnet_trace=args.use_dotnet_trace
    )
    test.run(args.output)
