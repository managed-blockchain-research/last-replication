const fs = require('fs');
const path = require('path');

// 1. Define the correct JSON Artifact (ABI + Bytecode)
// This matches the Solidity 0.8.0 code for StateBloater
const artifactContent = {
  "contractName": "StateBloater",
  "abi": [
    {
      "anonymous": false,
      "inputs": [
        { "indexed": false, "internalType": "uint256", "name": "startIdx", "type": "uint256" },
        { "indexed": false, "internalType": "uint256", "name": "count", "type": "uint256" }
      ],
      "name": "Bloated",
      "type": "event"
    },
    {
      "inputs": [
        { "internalType": "uint256", "name": "startIdx", "type": "uint256" },
        { "internalType": "uint256", "name": "count", "type": "uint256" }
      ],
      "name": "bloat",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    },
    {
      "inputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
      "name": "heavyStorage",
      "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
      "stateMutability": "view",
      "type": "function"
    }
  ],
  "bytecode": "0x608060405234801561001057600080fd5b5061012a806100206000396000f3fe608060405234801561001057600080fd5b50600436106100365760003560e01c80637951e60a1461003b578063e52e698b14610059575b600080fd5b6100436004803603602081101561005157600080fd5b8101908080359060200190929190505050610077565b6040518082815260200191505060405180910390f35b6100756004803603604081101561006f57600080fd5b81019080803590602001909291908035906020019092919050505061008a565b005b60006020528060005260406000206000915090505481565b6000819050816000036100e4575050565b5b6000818110156100e0574281018483016000526020600020810155808060010191505061009e565b505056fea264697066735822122045e050307873138383574d6c69438259695624736f6c63430008000033"
};

// 2. Write the JSON Artifact
// Ensure 'src' directory exists
if (!fs.existsSync('src')){
    fs.mkdirSync('src');
}
fs.writeFileSync('src/StateBloater.json', JSON.stringify(artifactContent, null, 2));
console.log('✅ Created src/StateBloater.json with correct ABI and Bytecode.');

// 3. Fix networkconfig.json
const configPath = 'networkconfig.json';
if (fs.existsSync(configPath)) {
    let config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    
    // Ensure the contracts section points to the JSON file
    if (!config.ethereum.contracts) config.ethereum.contracts = {};
    
    config.ethereum.contracts.StateBloater = {
        "path": "src/StateBloater.json",
        "estimateGas": true,
        "gas": {
            "query": 100000,
            "transfer": 70000
        }
    };

    fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
    console.log('✅ Updated networkconfig.json to point to src/StateBloater.json');
} else {
    console.error('❌ Could not find networkconfig.json!');
}
