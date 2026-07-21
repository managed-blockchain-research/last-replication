'use strict';

/**
 * Mixed Attack Workload — LOH Pressure, RAAC Baseline
 * 70% "normal" txs: StateBloater.bloat(startIdx, 1) — 1 SSTORE, low gas
 * 30% "attack" txs: StateBloater.sink(96KB_data)    — 96 KB calldata, gas=12M
 *
 * The 96 KB calldata forces NM to allocate a >85 KB byte[] per attack tx,
 * landing in .NET's Large Object Heap and triggering Gen2 STW collections.
 * No AI filtering — all txs reach the node. Used as the baseline.
 */

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const fs = require('fs');
const path = require('path');

const ATTACK_RATIO  = 0.30;
const NORMAL_SLOTS  = 1;
const ATTACK_DATA   = '0x' + '00'.repeat(96000); // 96 KB zero calldata → .NET LOH

class MixedAttackLOHWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex    = 0;
        this.normalCount = 0;
        this.attackCount = 0;
        this.logStream   = null;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);

        const args = this.roundArguments || {};
        const numContracts = args.numContracts || 30;
        const prefix       = args.contractPrefix || 'SB';
        this.contractId    = `${prefix}${workerIndex % numContracts}`;

        const logDir = args.logDir || process.env.RAAC_LOG_DIR || null;
        if (logDir) {
            const logFile = path.join(logDir, `worker${workerIndex}_baseline.jsonl`);
            this.logStream = fs.createWriteStream(logFile, { flags: 'a' });
        }

        console.log(`[MixedAttackLOH/baseline] Worker ${workerIndex} → contract ${this.contractId}`);
    }

    async submitTransaction() {
        this.txIndex++;
        const isAttack = Math.random() < ATTACK_RATIO;

        if (isAttack) this.attackCount++;
        else          this.normalCount++;

        if (this.logStream) {
            this.logStream.write(JSON.stringify({
                worker: this.workerIndex, txIndex: this.txIndex,
                type: isAttack ? 'attack' : 'normal',
                raac_mode: 'baseline', submitted: true,
            }) + '\n');
        }

        let request;
        if (isAttack) {
            request = {
                contract: this.contractId,
                verb:     'sink',
                args:     [ATTACK_DATA],
                readOnly: false,
            };
        } else {
            const startIdx = (this.workerIndex * 10_000_000) + (this.txIndex * NORMAL_SLOTS);
            request = {
                contract: this.contractId,
                verb:     'bloat',
                args:     [startIdx, NORMAL_SLOTS],
                readOnly: false,
            };
        }

        await this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {
        if (this.logStream) this.logStream.end();
        console.log(`[MixedAttackLOH/baseline] Worker ${this.workerIndex} done: normal=${this.normalCount} attack=${this.attackCount}`);
    }
}

module.exports.createWorkloadModule = () => new MixedAttackLOHWorkload();
