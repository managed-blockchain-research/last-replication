#!/usr/bin/env node
/**
 * Deploy 1 StateBloater contract for XRAY-v2 Nethermind Clique evaluation.
 * Writes contract address into networkconfig_xray_nm_clique.json.
 * Uses private key 0x000...001 (address 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf).
 * Chain ID: 1337 (Clique, same as Besu dev for Apple-to-Apple comparison).
 */
'use strict';

const ethers = require('ethers');
const fs = require('fs');
const path = require('path');

const CONFIG_FILE = path.join(__dirname, 'networkconfig_xray_nm_clique.json');

async function deploy() {
    const provider = new ethers.JsonRpcProvider('http://127.0.0.1:8545');
    const network = await provider.getNetwork();
    const chainId = Number(network.chainId);
    console.log(`Connected. ChainId: ${chainId}. Expected: 1337`);

    if (chainId !== 1337) {
        console.error(`ERROR: Expected chainId 1337 (Clique) but got ${chainId}. Wrong node?`);
        process.exit(1);
    }

    const privateKey = '0x' + '1'.padStart(64, '0');
    const wallet = new ethers.Wallet(privateKey, provider);
    console.log(`Deployer: ${wallet.address}`);

    const artifact = JSON.parse(fs.readFileSync(path.join(__dirname, 'StateBloater.json'), 'utf8'));
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);

    const nonce = await provider.getTransactionCount(wallet.address);
    const deployTx = await factory.getDeployTransaction();
    const tx = {
        type: 0,
        data: deployTx.data,
        gasLimit: 8000000,
        gasPrice: ethers.parseUnits('1', 'gwei'),
        chainId: chainId,
        nonce: nonce,
    };
    const signed = await wallet.signTransaction(tx);
    const response = await provider.broadcastTransaction(signed);
    console.log(`  Deployment tx submitted: ${response.hash}`);

    const receipt = await provider.waitForTransaction(response.hash, 1, 120000);
    const addr = receipt.contractAddress;
    console.log(`  Contract Address: ${addr}`);

    const config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    config.ethereum.contracts = {
        SB0: {
            address: addr,
            abi: artifact.abi,
            gas: { gasLimit: 8000000 }
        }
    };

    fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
    console.log(`${path.basename(CONFIG_FILE)} updated with SB0 at ${addr}`);
}

deploy().catch(err => { console.error(err); process.exit(1); });
