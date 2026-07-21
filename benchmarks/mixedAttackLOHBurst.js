'use strict';

/**
 * Burst Attack Workload — LOH Pressure, Baseline (No AI Filtering)
 *
 * attackRatio set per-round via YAML arguments (0.0 = normal, 1.0 = all attack).
 * All txs submitted directly to NM — no AI filtering.
 */

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const fs   = require('fs');
const path = require('path');

const ATTACK_DATA = '0x' + '00'.repeat(96000);

class MixedAttackLOHBurstWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex     = 0;
        this.contractId  = null;
        this.attackRatio = 0;
        this.normalCount = 0;
        this.attackCount = 0;
        this.logStream   = null;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);

        const args         = this.roundArguments || {};
        const numContracts = args.numContracts || 30;
        const prefix       = args.contractPrefix || 'SB';
        this.contractId    = `${prefix}${workerIndex % numContracts}`;
        this.attackRatio   = typeof args.attackRatio === 'number' ? args.attackRatio : 0;

        const logDir = args.logDir || process.env.RAAC_LOG_DIR || null;
        if (logDir) {
            const label   = args.roundLabel || 'round';
            const logFile = path.join(logDir, `worker${workerIndex}_${label}_baseline.jsonl`);
            this.logStream = fs.createWriteStream(logFile, { flags: 'a' });
        }

        console.log(`[BaselineBurst] Worker ${workerIndex} → ${this.contractId} | attackRatio=${this.attackRatio}`);
    }

    async submitTransaction() {
        this.txIndex++;
        const isAttack = Math.random() < this.attackRatio;

        if (isAttack) this.attackCount++; else this.normalCount++;

        if (this.logStream) {
            this.logStream.write(JSON.stringify({
                worker: this.workerIndex, txIndex: this.txIndex,
                type: isAttack ? 'attack' : 'normal',
                submitted: true,
            }) + '\n');
        }

        let request;
        if (isAttack) {
            request = { contract: this.contractId, verb: 'sink', args: [ATTACK_DATA], readOnly: false };
        } else {
            const startIdx = (this.workerIndex * 10_000_000) + this.txIndex;
            request = { contract: this.contractId, verb: 'bloat', args: [startIdx, 1], readOnly: false };
        }
        await this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {
        if (this.logStream) this.logStream.end();
        console.log(`[BaselineBurst] Worker ${this.workerIndex}: normal=${this.normalCount} attack=${this.attackCount}`);
    }
}

module.exports.createWorkloadModule = () => new MixedAttackLOHBurstWorkload();
