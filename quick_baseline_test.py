#!/usr/bin/env python3
"""
Simple baseline test - sends transactions directly to Besu to test GC behavior
This bypasses Caliper to quickly validate the testing infrastructure
"""

import json
import time
from web3 import Web3

# Connect to Besu
w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))

if not w3.is_connected():
    print('❌ Besu not running')
    exit(1)

print('✅ Connected to Besu')

# Load contract
with open('StateBloater.json', 'r') as f:
    artifact = json.load(f)

with open('networkconfig.json', 'r') as f:
    config = json.load(f)

contract_address = config['ethereum']['contracts']['StateBloater']['address']
print(f'✅ Contract at: {contract_address}')

# Setup account
private_key = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'
account = w3.eth.account.from_key(private_key)

# Create contract instance
contract = w3.eth.contract(address=contract_address, abi=artifact['abi'])

print(f'\n🚀 Running quick baseline test (30 seconds, ~10 tx/s)')
print(f'   This will generate memory pressure and trigger GC events\n')

tx_count = 0
start_time = time.time()
duration = 30  # 30 second test
slots_per_tx = 50

while time.time() - start_time < duration:
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
        
        tx_count += 1
        if tx_count % 10 == 0:
            print(f'  Sent {tx_count} transactions...')
        
        time.sleep(0.1)  # ~10 tx/s
        
    except Exception as e:
        print(f'  Error on tx {tx_count}: {e}')
        time.sleep(0.5)
        # Continue despite errors

elapsed = time.time() - start_time
print(f'\n✅ Test complete!')
print(f'   Transactions sent: {tx_count}')
print(f'   Duration: {elapsed:.1f}s')
print(f'   Rate: {tx_count/elapsed:.1f} tx/s')
print(f'\n📊 Check GC logs:')
print(f'   python3 scripts/monitor_gc.py baseline_gc_*.log\n')
