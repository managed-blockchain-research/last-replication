'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

// Workers with index < half → clustered (SB contracts, low fee)
// Workers with index >= half → scattered (SC contracts, high fee)
const LOW_FEE_GAS_PRICE  = '1000000000';  // 1 gwei  (SB clustered)
const HIGH_FEE_GAS_PRICE = '2000000000';  // 2 gwei  (SC scattered — was 5gwei; reduced for HFL Pareto)

class StateBloaterMixedWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
        this.isClustered = true;
        this.numContracts = 30;
        this.contractPrefix = 'SB';
        this.gasPrice = LOW_FEE_GAS_PRICE;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);
        const args = this.roundArguments || {};

        const half = Math.floor(totalWorkers / 2);
        this.isClustered = (workerIndex < half);

        if (this.isClustered) {
            this.numContracts  = args.numClusteredContracts || 30;
            this.contractPrefix = args.clusteredPrefix || 'SB';
            this.gasPrice       = LOW_FEE_GAS_PRICE;
        } else {
            this.numContracts  = args.numScatteredContracts || 300;
            this.contractPrefix = args.scatteredPrefix || 'SC';
            this.gasPrice       = HIGH_FEE_GAS_PRICE;
        }

        this.slotsPerTx = args.slotsPerTx || 200;
        console.log(`Worker ${workerIndex}/${totalWorkers} → ${this.isClustered ? 'CLUSTERED' : 'SCATTERED'} | prefix=${this.contractPrefix} contracts=${this.numContracts} gasPrice=${this.gasPrice}`);
    }

    async submitTransaction() {
        this.txIndex++;
        const contractId = `${this.contractPrefix}${(this.txIndex - 1) % this.numContracts}`;
        const startIdx   = (this.workerIndex * 1000000) + (this.txIndex * this.slotsPerTx);

        await this.sutAdapter.sendRequests({
            contract:  contractId,
            verb:      'bloat',
            args:      [startIdx, this.slotsPerTx],
            gasPrice:  this.gasPrice,
            readOnly:  false,
        });
    }
}

function createWorkloadModule() {
    return new StateBloaterMixedWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
