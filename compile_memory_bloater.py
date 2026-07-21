#!/usr/bin/env python3
"""Compile MemoryBloater — allocates fat bytes in EVM memory per TX."""

import json, os
from solcx import compile_source, install_solc

SOLIDITY_SOURCE = """
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MemoryBloater {
    uint256 public counter;

    /// O(1) instant allocation — no loops, no hashing.
    /// A single `new bytes(sizeBytes)` forces the Besu JVM to allocate
    /// a fat byte[] immediately, bypassing all EVM CPU overhead.
    /// `counter = fat.length` prevents dead-code elimination and
    /// persists a result via SSTORE.
    function bloat(uint256 sizeBytes) external {
        bytes memory fat = new bytes(sizeBytes);
        counter = fat.length;
    }
}
"""

print("Installing solc 0.8.20 (cached if present)...")
install_solc('0.8.20', show_progress=False)

print("Compiling MemoryBloater...")
compiled = compile_source(
    SOLIDITY_SOURCE,
    solc_version='0.8.20',
    output_values=['abi', 'bin']
)
iface = compiled['<stdin>:MemoryBloater']

artifact = {
    'abi': iface['abi'],
    'bytecode': '0x' + iface['bin']
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'MemoryBloater.json')
with open(out, 'w') as f:
    json.dump(artifact, f, indent=2)

print(f'✓ MemoryBloater.json written  ({len(artifact["bytecode"])//2} bytes)')
