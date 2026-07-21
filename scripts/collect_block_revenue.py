#!/usr/bin/env python3
"""
Collect per-block transaction revenue data while Besu is still running.
Fetches all blocks in [start_block, end_block] and categorizes transactions
as 'clustered' (SB, low-fee) or 'scattered' (SC, high-fee).

Usage:
    python3 scripts/collect_block_revenue.py \
        --start BLOCK_NUM \
        --end   BLOCK_NUM \
        --map   contracts_hfl_pareto.json \
        --out   run_dir/revenue.json \
        [--rpc  http://localhost:8545]
"""

import argparse
import json
import sys
from web3 import Web3

parser = argparse.ArgumentParser()
parser.add_argument('--start', type=int, required=True)
parser.add_argument('--end',   type=int, required=True)
parser.add_argument('--map',   default='contracts_hfl_pareto.json')
parser.add_argument('--out',   required=True)
parser.add_argument('--rpc',   default='http://localhost:8545')
args = parser.parse_args()

w3 = Web3(Web3.HTTPProvider(args.rpc))
if not w3.is_connected():
    print('ERROR: cannot connect to RPC', file=sys.stderr)
    sys.exit(1)

with open(args.map) as f:
    addr_map = json.load(f)  # addr_lower → {type, index, gasPrice}

clustered_count = 0
scattered_count = 0
other_count     = 0
clustered_fee   = 0
scattered_fee   = 0

block_data = []

for bn in range(args.start, args.end + 1):
    block = w3.eth.get_block(bn, full_transactions=True)
    b_clustered = b_scattered = b_other = 0
    for tx in block.transactions:
        to_addr = (tx.get('to') or '').lower()
        gas_used_estimate = tx.get('gas', 0)   # use gas limit as estimate
        gas_price = tx.get('gasPrice', 0)
        info = addr_map.get(to_addr)
        if info is None:
            b_other += 1
            other_count += 1
        elif info['type'] == 'clustered':
            b_clustered += 1
            clustered_count += 1
            clustered_fee += gas_used_estimate * gas_price
        else:
            b_scattered += 1
            scattered_count += 1
            scattered_fee += gas_used_estimate * gas_price

    block_data.append({
        'block':     bn,
        'clustered': b_clustered,
        'scattered': b_scattered,
        'other':     b_other,
    })

    if (bn - args.start) % 100 == 0:
        print(f'  Block {bn}/{args.end} processed...', file=sys.stderr)

total_tx = clustered_count + scattered_count + other_count
result = {
    'start_block':      args.start,
    'end_block':        args.end,
    'total_tx':         total_tx,
    'clustered_count':  clustered_count,
    'scattered_count':  scattered_count,
    'other_count':      other_count,
    'clustered_fee_wei': clustered_fee,
    'scattered_fee_wei': scattered_fee,
    'total_fee_wei':    clustered_fee + scattered_fee,
    'scattered_share':  scattered_count / total_tx if total_tx > 0 else 0,
    'scattered_fee_share': scattered_fee / (clustered_fee + scattered_fee) if (clustered_fee + scattered_fee) > 0 else 0,
    'blocks': block_data,
}

with open(args.out, 'w') as f:
    json.dump(result, f, indent=2)

print(f'Revenue saved → {args.out}')
print(f'  clustered: {clustered_count} txs, {clustered_fee:.0f} wei')
print(f'  scattered: {scattered_count} txs, {scattered_fee:.0f} wei')
print(f'  scattered fee share: {result["scattered_fee_share"]:.1%}')
