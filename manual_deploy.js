const ethers = require('ethers');
const fs = require('fs');

async function deploy() {
    // 1. Setup Provider (Safe for v5/v6)
    const url = 'http://127.0.0.1:8545';
    const provider = ethers.providers 
        ? new ethers.providers.JsonRpcProvider(url) 
        : new ethers.JsonRpcProvider(url);

    const block = await provider.getBlockNumber();
    console.log(`Connected to Besu. Current Block: ${block}`);

    // 2. Setup Wallet
    const privateKey = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689';
    const wallet = new ethers.Wallet(privateKey, provider);

    // 3. Load and Parse Artifact
    const artifact = JSON.parse(fs.readFileSync('./StateBloater.json', 'utf8'));
    
    // Handle both flat (Caliper style) and nested (Hardhat/Truffle style) JSONs
    const abi = artifact.abi;
    const bytecode = artifact.bytecode || (artifact.data ? artifact.data.bytecode.object : null);

    if (!bytecode || bytecode === '0x') {
        throw new Error("Bytecode is missing in StateBloater.json. Check the file content.");
    }

    // 4. Resolve Factory (The 'Constructor' Fix)
    const Factory = ethers.ContractFactory || (ethers.providers ? ethers.ContractFactory : null);
    if (!Factory) {
        // Fallback for some specific v5 installs
        console.log("Checking deep exports...");
        const { ContractFactory } = require('ethers');
        var factory = new ContractFactory(abi, bytecode, wallet);
    } else {
        var factory = new Factory(abi, bytecode, wallet);
    }

    console.log('🚀 Deploying StateBloater to Besu...');
    const contract = await factory.deploy({ gasLimit: 8000000, gasPrice: 0 });
    
    console.log('Transaction sent:', contract.deployTransaction?.hash || contract.hash);
    
    // Wait for deployment
    if (contract.deployed) {
        await contract.deployed(); // v5
    } else {
        await contract.waitForDeployment(); // v6
    }
    
    const address = contract.address || await contract.getAddress();
    console.log('\n✅ DEPLOYMENT SUCCESSFUL');
    console.log('---------------------------');
    console.log('Contract Address:', address);
    console.log('---------------------------');
    console.log('\nNow update your networkconfig.json with this address.');
}

deploy().catch(console.error);
