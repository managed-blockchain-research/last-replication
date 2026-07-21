const fs = require('fs');
const path = require('path');
const solc = require('solc');

const sourcePath = path.join(__dirname, '..', 'src', 'StateBloater.sol');
const source = fs.readFileSync(sourcePath, 'utf8');

const input = {
  language: 'Solidity',
  sources: {
    'StateBloater.sol': {
      content: source
    }
  },
  settings: {
    outputSelection: {
      '*': {
        '*': ['abi', 'evm.bytecode.object']
      }
    }
  }
};

const rawOutput = solc.compile(JSON.stringify(input));
const output = typeof rawOutput === 'string' ? JSON.parse(rawOutput) : rawOutput;
if (output.errors) {
  const fatal = output.errors.filter((e) => e.severity === 'error');
  output.errors.forEach((e) => {
    console.error(e.formattedMessage || e.message);
  });
  if (fatal.length > 0) {
    process.exit(1);
  }
}

const contract = output.contracts['StateBloater.sol'].StateBloater;
const artifact = {
  contractName: 'StateBloater',
  abi: contract.abi,
  bytecode: `0x${contract.evm.bytecode.object}`
};

const rootArtifact = path.join(__dirname, '..', 'StateBloater.json');
const srcArtifact = path.join(__dirname, '..', 'src', 'StateBloater.json');

fs.writeFileSync(rootArtifact, JSON.stringify(artifact, null, 2));
fs.writeFileSync(srcArtifact, JSON.stringify(artifact, null, 2));

console.log('✓ Compiled StateBloater and wrote artifacts:');
console.log(`  - ${rootArtifact}`);
console.log(`  - ${srcArtifact}`);
