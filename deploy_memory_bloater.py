#!/usr/bin/env python3
"""Deploy MemoryBloater and update networkconfig.json."""

import json
from web3 import Web3

w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
if not w3.is_connected():
    print('❌ Could not connect to Besu'); exit(1)

print(f'✓ Connected (block {w3.eth.block_number})')

with open('MemoryBloater.json') as f:
    artifact = json.load(f)

private_key = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'
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

with open('networkconfig.json') as f:
    config = json.load(f)
config['ethereum']['contracts']['MemoryBloater'] = {'address': contract_address}
with open('networkconfig.json', 'w') as f:
    json.dump(config, f, indent=2)
print('✓ networkconfig.json updated')
