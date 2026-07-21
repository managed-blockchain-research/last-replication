const fs = require('fs');
const path = require('path');
let Web3;

// 1. Load Web3 to fix the "Checksum" error
try {
    Web3 = require('web3');
} catch (e) {
    // Attempt to load from global or common paths if local install fails
    try {
        Web3 = require('/home/yeochan.yoon/node_modules/web3');
    } catch (e2) {
        console.error("❌ Error: Web3 module not found. Run 'npm install web3'");
        process.exit(1);
    }
}

// 2. Derive Valid Address from Private Key
// This fixes the "capitalization checksum test failed" error
const web3 = new Web3();
const privateKey = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689';
const account = web3.eth.accounts.privateKeyToAccount(privateKey);
const validAddress = account.address;

console.log(`✅ Derived Valid Checksum Address: ${validAddress}`);

// 3. Resolve Absolute Path to Contract
// This fixes the "Cannot find module/ABI" error
const contractPath = path.resolve(__dirname, 'StateBloater.json');

// 4. Generate Configuration
const config = {
  "caliper": {
    "blockchain": "ethereum"
  },
  "ethereum": {
    "url": "ws://localhost:8546", // WebSockets required for Besu 24.1.1
    "contractDeployerAddress": validAddress,
    "contractDeployerAddressPrivateKey": privateKey,
    "fromAddress": validAddress,
    "fromAddressPrivateKey": privateKey,
    "contracts": {
      "StateBloater": {
        "path": contractPath,
        "estimateGas": false,
        "gas": {
          "deploy": 8000000,   // <--- THIS LINE FIXES "Error: gas is missing"
          "query": 500000,
          "transfer": 500000
        }
      }
    },
    "transactionOptions": {
      "gas": 8000000,
      "gasPrice": "0"
    }
  }
};

// 5. Write the file
fs.writeFileSync('networkconfig.json', JSON.stringify(config, null, 2));
console.log('✅ networkconfig.json updated successfully with DEPLOY GAS limit.');
