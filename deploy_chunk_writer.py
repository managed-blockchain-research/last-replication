#!/usr/bin/env python3
"""Deploy ChunkWriter and update networkconfig.json."""

import json, os
from web3 import Web3

# Use absolute paths based on this script's own location —
# works regardless of the calling directory.
HERE = os.path.dirname(os.path.abspath(__file__))

w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
if not w3.is_connected():
    print('❌ Could not connect to Besu'); exit(1)

print(f'✓ Connected (block {w3.eth.block_number})')

with open(os.path.join(HERE, 'ChunkWriter.json')) as f:
    artifact = json.load(f)

# Use a genesis-funded account as deployer (not the miner coinbase).
# Key 0xc875... → 0x627306090abaB3A6e1400e9345bC60c78a8BEf57 (dev alloc)
private_key = '0xc87509a1c067bbde78beb793e6fa76530b6382a4c0241e5e4a9ec0a0f44dc0d3'
account = w3.eth.account.from_key(private_key)
print(f'✓ Deployer: {account.address}')

Contract = w3.eth.contract(abi=artifact['abi'], bytecode=artifact['bytecode'])
tx = Contract.constructor().build_transaction({
    'from': account.address,
    'nonce': w3.eth.get_transaction_count(account.address),
    'gas': 2_000_000,
    'gasPrice': 0,
    'chainId': 1337
})
signed_tx = account.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
contract_address = receipt.contractAddress

print(f'Contract Address: {contract_address}')

ncfg = os.path.join(HERE, 'networkconfig.json')
with open(ncfg) as f:
    config = json.load(f)
config['ethereum']['contracts']['ChunkWriter'] = {'address': contract_address}
with open(ncfg, 'w') as f:
    json.dump(config, f, indent=2)
print('✓ networkconfig.json updated')
