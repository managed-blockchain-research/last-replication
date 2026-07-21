#!/usr/bin/env python3
"""
Deploy SB0-SB29 (clustered, 30) and SC0-SC299 (scattered, 300) contracts.
Writes networkconfig_hfl_pareto.json with both sets.

Usage:
    python3 deploy_mixed_contracts.py [--sb N] [--sc M]
    Defaults: --sb 30 --sc 300
"""

import argparse
import json
import sys
from web3 import Web3

parser = argparse.ArgumentParser()
parser.add_argument('--sb', type=int, default=30,  help='Number of clustered SB contracts')
parser.add_argument('--sc', type=int, default=300, help='Number of scattered SC contracts')
args = parser.parse_args()

N_SB = args.sb
N_SC = args.sc

w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
if not w3.is_connected():
    print('ERROR: Cannot connect to node at localhost:8545')
    sys.exit(1)

print(f'Connected. Block: {w3.eth.block_number}')
print(f'Deploying {N_SB} SB (clustered) + {N_SC} SC (scattered) contracts...')

with open('StateBloater.json', 'r') as f:
    artifact = json.load(f)

PRIVATE_KEY = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'
account = w3.eth.account.from_key(PRIVATE_KEY)
Contract = w3.eth.contract(abi=artifact['abi'], bytecode=artifact['bytecode'])

total = N_SB + N_SC
tx_hashes = []
nonce = w3.eth.get_transaction_count(account.address)

for i in range(total):
    tx = Contract.constructor().build_transaction({
        'from':     account.address,
        'nonce':    nonce + i,
        'gas':      8_000_000,
        'gasPrice': 1_000_000_000,
        'chainId':  1337,
    })
    signed   = account.sign_transaction(tx)
    tx_hash  = w3.eth.send_raw_transaction(signed.raw_transaction)
    tx_hashes.append(tx_hash)
    if (i + 1) % 50 == 0:
        print(f'  Submitted {i + 1}/{total} deployment txs...')

print(f'All {total} deployment txs submitted. Waiting for receipts...')

sb_addresses = []
sc_addresses = []

for i, tx_hash in enumerate(tx_hashes):
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=600)
    addr = receipt.contractAddress
    if i < N_SB:
        sb_addresses.append(addr)
        print(f'  SB{i}: {addr}')
    else:
        sc_idx = i - N_SB
        sc_addresses.append(addr)
        if sc_idx % 50 == 0 or sc_idx == N_SC - 1:
            print(f'  SC{sc_idx}: {addr}')

# Build networkconfig_hfl_pareto.json
with open('networkconfig.json', 'r') as f:
    base_config = json.load(f)

contracts_section = {}

for i, addr in enumerate(sb_addresses):
    contracts_section[f'SB{i}'] = {
        'address': addr,
        'abi':     artifact['abi'],
        'gas':     5_000_000,
    }

for i, addr in enumerate(sc_addresses):
    contracts_section[f'SC{i}'] = {
        'address': addr,
        'abi':     artifact['abi'],
        'gas':     5_000_000,
    }

new_config = dict(base_config)
new_config['ethereum'] = dict(base_config['ethereum'])
new_config['ethereum']['contracts'] = contracts_section

with open('networkconfig_hfl_pareto.json', 'w') as f:
    json.dump(new_config, f, indent=2)

# Save address mapping for revenue analysis
address_map = {}
for i, addr in enumerate(sb_addresses):
    address_map[addr.lower()] = {'type': 'clustered', 'index': i, 'gasPrice': 1_000_000_000}
for i, addr in enumerate(sc_addresses):
    address_map[addr.lower()] = {'type': 'scattered', 'index': i, 'gasPrice': 5_000_000_000}

with open('contracts_hfl_pareto.json', 'w') as f:
    json.dump(address_map, f, indent=2)

print(f'\nDone.')
print(f'  networkconfig_hfl_pareto.json  — {N_SB + N_SC} contracts')
print(f'  contracts_hfl_pareto.json      — address→type mapping for revenue analysis')
