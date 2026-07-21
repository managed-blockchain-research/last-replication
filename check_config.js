'use strict';

const fs = require('fs');
const path = require('path');

try {
    const configPath = path.join(__dirname, 'networkconfig.json');
    const rawData = fs.readFileSync(configPath);
    const config = JSON.parse(rawData);

    console.log('--- Config Verification ---');
    console.log('File Path:', configPath);
    
    if (config.ethereum && config.ethereum.contracts && config.ethereum.contracts.StateBloater) {
        const sb = config.ethereum.contracts.StateBloater;
        console.log('StateBloater Config Found:');
        console.log('- path:', sb.path);
        console.log('- gas:', sb.gas, `(Type: ${typeof sb.gas})`);
        console.log('- deploy:', sb.deploy, `(Type: ${typeof sb.deploy})`);
        console.log('- estimateGas:', sb.estimateGas);
        
        if (typeof sb.gas === 'undefined' && !sb.estimateGas) {
            console.error('\n!!! CRITICAL: The "gas" property is missing or undefined in the JSON object.');
        } else if (typeof sb.gas !== 'number' && typeof sb.gas !== 'string') {
            console.error('\n!!! CRITICAL: "gas" must be a Number or a String.');
        } else {
            console.log('\n✅ JSON structure looks valid for the Ethereum connector.');
        }
    } else {
        console.error('\n!!! CRITICAL: Could not find ethereum.contracts.StateBloater path in JSON.');
    }

    // Checking for invisible characters or BOM
    if (rawData[0] === 0xEF && rawData[1] === 0xBB && rawData[2] === 0xBF) {
        console.warn('⚠️ Warning: File contains a UTF-8 BOM which can sometimes confuse parsers.');
    }

} catch (err) {
    console.error('❌ Error reading or parsing networkconfig.json:');
    console.error(err.message);
}
