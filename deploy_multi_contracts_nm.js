#!/usr/bin/env node
/**
 * Deploy N StateBloater contracts to Nethermind and update networkconfig_nethermind_caliper.json.
 * Usage: node deploy_multi_contracts_nm.js [N]   (default N=30)
 */
'use strict';

const ethers = require('ethers');
const fs = require('fs');

const N = parseInt(process.argv[2] || '30', 10);
const OUT_CONFIG = process.argv[3] || './networkconfig_nethermind_caliper.json';

async function deploy() {
    console.log(`Deploying ${N} StateBloater contracts to Nethermind...`);

    const provider = new ethers.JsonRpcProvider('http://127.0.0.1:8545');
    const network = await provider.getNetwork();
    const chainId = Number(network.chainId);

    const privateKey = '0x' + '1'.padStart(64, '0');
    const wallet = new ethers.Wallet(privateKey, provider);
    console.log(`Connected. ChainId: ${chainId}. Deployer: ${wallet.address}`);

    const artifact = JSON.parse(fs.readFileSync('./StateBloater.json', 'utf8'));
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);

    // Batch-submit all deployment transactions
    const txHashes = [];
    let nonce = await provider.getTransactionCount(wallet.address);

    for (let i = 0; i < N; i++) {
        const deployTx = await factory.getDeployTransaction();
        const tx = {
            type: 0,
            data: deployTx.data,
            gasLimit: 8000000,
            gasPrice: ethers.parseUnits('1', 'gwei'),
            chainId: chainId,
            nonce: nonce + i,
        };
        const signed = await wallet.signTransaction(tx);
        const response = await provider.broadcastTransaction(signed);
        txHashes.push(response.hash);
        if ((i + 1) % 10 === 0) {
            console.log(`  Submitted ${i + 1}/${N} deployment txs...`);
        }
    }

    console.log(`All ${N} deployment txs submitted. Waiting for confirmations...`);

    const addresses = [];
    for (let i = 0; i < txHashes.length; i++) {
        const receipt = await provider.waitForTransaction(txHashes[i], 1, 300000);
        addresses.push(receipt.contractAddress);
        console.log(`  SB${i}: ${receipt.contractAddress}`);
    }

    console.log(`\nAll ${N} contracts deployed. Updating ${OUT_CONFIG}...`);

    const config = fs.existsSync(OUT_CONFIG)
        ? JSON.parse(fs.readFileSync(OUT_CONFIG, 'utf8'))
        : JSON.parse(fs.readFileSync('./networkconfig_nethermind_caliper.json', 'utf8'));
    const abi = artifact.abi;
    const gas = { gasLimit: 8000000 };

    const newContracts = {};
    for (let i = 0; i < N; i++) {
        newContracts[`SB${i}`] = { address: addresses[i], abi, gas };
    }

    config.ethereum.contracts = newContracts;
    config.ethereum.transactionPollingTimeout = 90;
    config.ethereum.transactionBlockTimeout = 200;

    fs.writeFileSync(OUT_CONFIG, JSON.stringify(config, null, 2));

    // Sentinel for shell script grep
    console.log(`Contract Address: ${addresses[0]}`);
    console.log(`\nDone. ${N} contracts registered as SB0..SB${N - 1}`);

    fs.writeFileSync('./deployed_contracts_nm.json', JSON.stringify({
        contracts: Array.from({length: N}, (_, i) => `SB${i}`),
        addresses,
    }, null, 2));
}

deploy().catch(err => {
    console.error('Deployment failed:', err.message || err);
    process.exit(1);
});
