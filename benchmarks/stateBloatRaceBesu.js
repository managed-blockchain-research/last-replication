'use strict';

/**
 * StateBloat workload with external RACE (Runtime-Aware Flow Control) for Besu.
 *
 * Background timer polls Besu Prometheus (/metrics) every SAMPLE_INTERVAL_MS,
 * computes RPI = alpha*H_t + beta*G_t + gamma*Q_mem, and transitions the
 * hysteresis state machine: NORMAL -> PACING -> SURVIVAL.
 *
 * In PACING mode:  accept only PACING_RATIO fraction of txs.
 * In SURVIVAL mode: accept only SURVIVAL_RATIO fraction of txs.
 *
 * Matches the "mempool_sensitive" Besu RACE profile from threshold_profiles.json:
 *   alpha=0.10, beta=0.10, gamma=0.80
 *   NormalToPacing=0.45, PacingToNormal=0.30
 *   PacingToSurvival=0.90, SurvivalToPacing=0.75
 *
 * Set env RACE_BESU_METRICS_URL (default http://127.0.0.1:9545/metrics)
 * Set env RACE_BESU_RPC_URL     (default http://127.0.0.1:8545)
 * Set env RACE_LOG_DIR          (optional CSV log directory)
 */

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const http = require('http');
const fs  = require('fs');
const path = require('path');

// ── RACE parameters (Besu mempool_sensitive profile) ──────────────────────────
const ALPHA  = 0.10;   // heap weight
const BETA   = 0.10;   // GC weight
const GAMMA  = 0.80;   // mempool weight

const THRESHOLD_NORMAL_TO_PACING  = 0.45;
const THRESHOLD_PACING_TO_NORMAL  = 0.30;
const THRESHOLD_PACING_TO_SURVIVAL = 0.90;
const THRESHOLD_SURVIVAL_TO_PACING = 0.75;
const PACING_RATIO   = 0.20;   // accept 20% in PACING
const SURVIVAL_RATIO = 0.05;   // accept 5%  in SURVIVAL

const SAMPLE_INTERVAL_MS = 1000;

// Prometheus metric names Besu exposes (jvm-client 0.16 naming)
const HEAP_USED_RE  = /^jvm_memory_bytes_used\{[^}]*area="heap"[^}]*\}\s+([\d.e+\-]+)/m;
const HEAP_MAX_RE   = /^jvm_memory_bytes_max\{[^}]*area="heap"[^}]*\}\s+([\d.e+\-]+)/m;
// Also support prometheus-client naming variants
const HEAP_USED_RE2 = /^jvm_memory_used_bytes\{[^}]*area="heap"[^}]*\}\s+([\d.e+\-]+)/m;
const HEAP_MAX_RE2  = /^jvm_memory_max_bytes\{[^}]*area="heap"[^}]*\}\s+([\d.e+\-]+)/m;
// GC pause total (G1 Old Generation)
const GC_SUM_RE  = /^jvm_gc_collection_seconds_sum\{[^}]*gc="G1 Old Generation"[^}]*\}\s+([\d.e+\-]+)/m;
const GC_SUM_RE2 = /^jvm_gc_pause_seconds_sum\{[^}]*action="end of major GC"[^}]*\}\s+([\d.e+\-]+)/m;

const METRICS_URL = process.env.RACE_BESU_METRICS_URL || 'http://127.0.0.1:9545/metrics';
const RPC_URL     = process.env.RACE_BESU_RPC_URL     || 'http://127.0.0.1:8545';

// ── Shared controller state (all workers in same process share this) ──────────
let _sharedState = null;

function getSharedState() {
    if (!_sharedState) {
        _sharedState = {
            mode: 'NORMAL',
            rpi:  0,
            ht:   0,
            gt:   0,
            qmem: 0,
            prevGcSum: 0,
            prevGcTime: Date.now(),
            heapMax: 1,
            txPoolMax: 256,
            txPoolSize: 0,
            logStream: null,
            timer: null,
            refCount: 0,
        };
    }
    return _sharedState;
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────
function httpGet(url, timeoutMs = 1500) {
    return new Promise((resolve, reject) => {
        const u = new URL(url);
        const req = http.request({
            hostname: u.hostname, port: u.port || 80,
            path: u.pathname + (u.search || ''),
            method: 'GET',
        }, (res) => {
            let raw = '';
            res.on('data', c => raw += c);
            res.on('end', () => resolve(raw));
        });
        req.setTimeout(timeoutMs, () => { req.destroy(); reject(new Error('timeout')); });
        req.on('error', reject);
        req.end();
    });
}

function rpcCall(method, params = []) {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify({ jsonrpc: '2.0', method, params, id: 1 });
        const u = new URL(RPC_URL);
        const req = http.request({
            hostname: u.hostname, port: u.port || 8545,
            path: '/', method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
        }, (res) => {
            let raw = '';
            res.on('data', c => raw += c);
            res.on('end', () => {
                try { resolve(JSON.parse(raw).result); } catch(e) { reject(e); }
            });
        });
        req.setTimeout(2000, () => { req.destroy(); reject(new Error('rpc timeout')); });
        req.on('error', reject);
        req.write(body); req.end();
    });
}

// ── Prometheus scraper ────────────────────────────────────────────────────────
async function scrapePrometheus(state) {
    try {
        const text = await httpGet(METRICS_URL);

        // Heap H_t
        let heapUsed = 0, heapMax = state.heapMax;
        const hu = text.match(HEAP_USED_RE) || text.match(HEAP_USED_RE2);
        const hm = text.match(HEAP_MAX_RE)  || text.match(HEAP_MAX_RE2);
        if (hu) heapUsed = parseFloat(hu[1]);
        if (hm && parseFloat(hm[1]) > 0) { heapMax = parseFloat(hm[1]); state.heapMax = heapMax; }
        state.ht = Math.min(heapUsed / heapMax, 1.0);

        // GC rate G_t (normalized: full pressure = 0.5 GC-sec/sec of old gen)
        const gcSumM = text.match(GC_SUM_RE) || text.match(GC_SUM_RE2);
        if (gcSumM) {
            const gcSum = parseFloat(gcSumM[1]);
            const now = Date.now();
            const dt  = (now - state.prevGcTime) / 1000;
            if (dt > 0.1) {
                const rate = Math.max(gcSum - state.prevGcSum, 0) / dt;
                state.gt = Math.min(rate / 0.5, 1.0);  // 0.5 GC-sec/sec = full pressure
            }
            state.prevGcSum  = gcSum;
            state.prevGcTime = Date.now();
        }
    } catch (_) { /* fail-open */ }

    // Q_mem from txpool_besuStatistics RPC
    try {
        const stats = await rpcCall('txpool_besuStatistics', []);
        if (stats && typeof stats === 'object') {
            const maxSize    = parseInt(stats.maxSize    || stats.maxLocalSize || 256);
            const localCnt   = parseInt(stats.localCount  || 0);
            const remoteCnt  = parseInt(stats.remoteCount || 0);
            const total      = localCnt + remoteCnt;
            if (maxSize > 0) {
                state.txPoolMax  = maxSize;
                state.txPoolSize = total;
                state.qmem = Math.min(total / maxSize, 1.0);
            }
        }
    } catch (_) { /* fail-open */ }

    // RPI
    state.rpi = Math.min(ALPHA * state.ht + BETA * state.gt + GAMMA * state.qmem, 1.0);
}

// ── State machine ─────────────────────────────────────────────────────────────
function advanceMode(state) {
    const prev = state.mode;
    const rpi  = state.rpi;
    if (state.mode === 'NORMAL'   && rpi >= THRESHOLD_NORMAL_TO_PACING)    state.mode = 'PACING';
    else if (state.mode === 'PACING'   && rpi >= THRESHOLD_PACING_TO_SURVIVAL) state.mode = 'SURVIVAL';
    else if (state.mode === 'PACING'   && rpi <  THRESHOLD_PACING_TO_NORMAL)   state.mode = 'NORMAL';
    else if (state.mode === 'SURVIVAL' && rpi <  THRESHOLD_SURVIVAL_TO_PACING) state.mode = 'PACING';

    if (state.logStream) {
        const event = prev !== state.mode ? `${prev}->${state.mode}` : 'NONE';
        state.logStream.write(JSON.stringify({
            ts: Date.now(), mode: state.mode, prev_mode: prev,
            transition: event, rpi: state.rpi.toFixed(6),
            ht: state.ht.toFixed(6), gt: state.gt.toFixed(6), qmem: state.qmem.toFixed(6),
        }) + '\n');
    }
}

// ── Controller lifecycle ──────────────────────────────────────────────────────
function startController(logDir) {
    const state = getSharedState();
    state.refCount++;
    if (state.timer) return state;  // already running

    if (logDir) {
        const lf = path.join(logDir, 'race_besu_rpi.jsonl');
        state.logStream = fs.createWriteStream(lf, { flags: 'a' });
    }

    const tick = async () => {
        await scrapePrometheus(state);
        advanceMode(state);
    };
    tick();  // immediate first sample
    state.timer = setInterval(tick, SAMPLE_INTERVAL_MS);
    return state;
}

function stopController(state) {
    state.refCount--;
    if (state.refCount > 0) return;
    if (state.timer)     { clearInterval(state.timer); state.timer = null; }
    if (state.logStream) { state.logStream.end(); state.logStream = null; }
    _sharedState = null;
}

// ── Workload module ───────────────────────────────────────────────────────────
class StateBloatRaceBesuWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex     = 0;
        this.contractId  = null;
        this.raceSt      = null;
        this.accepted    = 0;
        this.throttled   = 0;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);
        const args = this.roundArguments || {};
        const numContracts = args.numContracts || 30;
        const prefix       = args.contractPrefix || 'SB';
        this.contractId    = `${prefix}${workerIndex % numContracts}`;
        this.slotsPerTx    = args.slotsPerTx || 200;

        const logDir = process.env.RACE_LOG_DIR || null;
        this.raceSt = startController(logDir);

        console.log(`[StateBloat/RACE-Besu] Worker ${workerIndex} → contract ${this.contractId} | metrics: ${METRICS_URL}`);
    }

    async submitTransaction() {
        this.txIndex++;
        const state = this.raceSt;

        // Throttle based on RACE mode
        let drop = false;
        if (state.mode === 'PACING') {
            drop = Math.random() >= PACING_RATIO;
        } else if (state.mode === 'SURVIVAL') {
            drop = Math.random() >= SURVIVAL_RATIO;
        }

        if (drop) {
            this.throttled++;
            return;  // do not submit
        }

        this.accepted++;
        const startIdx = (this.workerIndex * 10_000_000) + (this.txIndex * this.slotsPerTx);
        await this.sutAdapter.sendRequests({
            contract: this.contractId,
            verb:     'bloat',
            args:     [startIdx, this.slotsPerTx],
            readOnly: false,
        });
    }

    async cleanupWorkloadModule() {
        const state = this.raceSt;
        console.log(`[StateBloat/RACE-Besu] Worker ${this.workerIndex}: ` +
            `accepted=${this.accepted} throttled=${this.throttled} ` +
            `finalMode=${state.mode} finalRPI=${state.rpi.toFixed(3)} ` +
            `H_t=${state.ht.toFixed(3)} G_t=${state.gt.toFixed(3)} Q_mem=${state.qmem.toFixed(3)}`);
        stopController(state);
    }
}

function createWorkloadModule() {
    return new StateBloatRaceBesuWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
