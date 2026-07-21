'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

class StateBloaterWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);
    }

    async submitTransaction() {
        this.txIndex++;
        
        // Calculate a unique range for this specific transaction
        // Formula: (WorkerID * 1,000,000) + (LocalTxCount * slotsPerTx)
        const slotsPerTx = this.workerArguments.slotsPerTx || 50;
        const startIdx = (this.workerIndex * 1000000) + (this.txIndex * slotsPerTx);

        const request = {
            contractId: this.workerArguments.contractId,
            contractFunction: 'bloat',
            invokerIdentity: '0xBE0cf996DE312b11990E4BcbBf7Fc156880AcFC8',
            contractArguments: [startIdx, slotsPerTx],
            readOnly: false
        };

        await this.sutAdapter.sendRequests(request);
    }
}

function createWorkloadModule() {
    return new StateBloaterWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
