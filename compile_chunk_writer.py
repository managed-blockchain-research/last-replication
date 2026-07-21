#!/usr/bin/env python3
"""
Compile ChunkWriter — writes 1024 × 32-byte words (32KB) to storage per TX.
No keccak256, no large memory loops. Values are simple arithmetic (O(1) per slot).
SSTOREs force MPT leaf node creation in the Besu JVM heap.
"""

import json, os
from solcx import compile_source, install_solc

SOLIDITY_SOURCE = """
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ChunkWriter {
    // key -> word_index -> 32-byte value  (32KB per key = 1024 slots)
    mapping(uint256 => mapping(uint256 => bytes32)) public store;
    uint256 public counter;

    /// Write 1024 storage words (32 KB) under `key`.
    /// Values are cheap arithmetic — no keccak256, no memory loops.
    /// Each SSTORE forces a distinct MPT leaf into the Besu JVM heap.
    function bloat(uint256 key) external {
        mapping(uint256 => bytes32) storage s = store[key];
        for (uint256 i = 0; i < 1024; i++) {
            s[i] = bytes32(key * 1024 + i + 1);
        }
        counter++;
    }
}
"""

print("Installing solc 0.8.20 (cached if present)...")
install_solc('0.8.20', show_progress=False)

print("Compiling ChunkWriter (evm_version=berlin — no PUSH0, Besu dev=Berlin fork)...")
compiled = compile_source(
    SOLIDITY_SOURCE,
    solc_version='0.8.20',
    output_values=['abi', 'bin'],
    evm_version='berlin'
)
iface = compiled['<stdin>:ChunkWriter']

artifact = {
    'abi': iface['abi'],
    'bytecode': '0x' + iface['bin']
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ChunkWriter.json')
with open(out, 'w') as f:
    json.dump(artifact, f, indent=2)

print(f'✓ ChunkWriter.json written  ({len(artifact["bytecode"])//2} bytes)')
