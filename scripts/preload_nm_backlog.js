#!/usr/bin/env node
/**
 * preload_nm_backlog.js
 *
 * Phase 1: Preload — submit N_TXS_PER_SENDER TXs from each of N_SENDERS pre-funded
 * accounts (keys 2..N_SENDERS+1) to Nethermind without waiting for confirmations.
 *
 * Creates a pending-pool backlog larger than the nonce window W=16, allowing
 * NmLarcController to exercise spill/restore during the subsequent drain phase.
 *
 * Pre-conditions:
 *   - NM running at http://localhost:8545 with genesis accounts funded
 *   - 30 contracts already deployed (networkconfig_nethermind_caliper.json updated)
 *   - Keys 2..N_SENDERS+1 each have 1,000,000 ETH in genesis
 *
 * Usage:
 *   node scripts/preload_nm_backlog.js [N_SENDERS] [TXS_PER_SENDER] [SLOTS_PER_TX]
 *   node scripts/preload_nm_backlog.js 30 64 50
 */
'use strict';

const ethers  = require('ethers');
const fs      = require('fs');
const path    = require('path');

// ── Config ────────────────────────────────────────────────────────────────────
const N_SENDERS      = parseInt(process.argv[2] ?? '30',  10);
const TXS_PER_SENDER = parseInt(process.argv[3] ?? '64',  10);
const SLOTS_PER_TX   = parseInt(process.argv[4] ?? '50',  10);
const NM_URL         = process.env.NM_URL ?? 'http://localhost:8545';
const NET_CFG        = process.argv[5] ?? './networkconfig_nethermind_caliper.json';

// ── Helpers ───────────────────────────────────────────────────────────────────
function log(msg) { process.stdout.write(`[preload] ${msg}\n`); }

function buildBloatCalldata(startIdx, count) {
    const iface = new ethers.Interface([
        'function bloat(uint256 startIdx, uint256 count)'
    ]);
    return iface.encodeFunctionData('bloat', [startIdx, count]);
}

async function getPendingCount(provider) {
    try {
        const res = await provider.send('txpool_content', []);
        const pending = res.pending ?? {};
        let total = 0;
        for (const senderTxs of Object.values(pending))
            total += Object.keys(senderTxs).length;
        return total;
    } catch {
        // fallback: use eth_getBlockByNumber pending
        try {
            const block = await provider.send('eth_getBlockByNumber', ['pending', false]);
            return (block?.transactions?.length ?? 0);
        } catch { return -1; }
    }
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
    const provider = new ethers.JsonRpcProvider(NM_URL);

    // Read contract address (use SB0 for all preload TXs)
    let contractAddr = '0x0000000000000000000000000000000000000000';
    try {
        const cfg = JSON.parse(fs.readFileSync(NET_CFG, 'utf8'));
        const contracts = cfg?.ethereum?.contracts ?? {};
        const sb0key = Object.keys(contracts).find(k => k === 'SB0');
        if (sb0key) contractAddr = contracts[sb0key].address;
    } catch {
        log(`WARN: could not read contract from ${NET_CFG}, using zero address`);
    }
    log(`Target contract SB0: ${contractAddr}`);

    const network = await provider.getNetwork();
    const chainId = Number(network.chainId);
    const gasPrice = ethers.parseUnits('1', 'gwei');
    log(`Chain: ${chainId}, gas: 1 Gwei, senders: ${N_SENDERS}, txs/sender: ${TXS_PER_SENDER}, slots/tx: ${SLOTS_PER_TX}`);

    // Build wallets: keys 2..N_SENDERS+1 (all pre-funded in genesis)
    const wallets = [];
    for (let i = 2; i <= N_SENDERS + 1; i++) {
        const key = '0x' + i.toString().padStart(64, '0');
        wallets.push(new ethers.Wallet(key, provider));
    }
    log(`Wallets: ${wallets[0].address} .. ${wallets[wallets.length-1].address}`);

    // Get current nonce for each sender in parallel
    const nonces = await Promise.all(
        wallets.map(w => provider.getTransactionCount(w.address, 'pending'))
    );

    // Pre-sign all TXs for all senders
    log(`Pre-signing ${N_SENDERS * TXS_PER_SENDER} transactions...`);
    const signedTxs = []; // { senderIdx, nonceOffset, raw }
    const calldata = buildBloatCalldata(0, SLOTS_PER_TX);
    const gasLimit = BigInt(25000) + BigInt(SLOTS_PER_TX) * BigInt(25000);  // conservative

    const signPromises = wallets.map(async (wallet, si) => {
        const rows = [];
        for (let t = 0; t < TXS_PER_SENDER; t++) {
            const tx = {
                type: 0,
                to: contractAddr,
                data: calldata,
                gasLimit,
                gasPrice,
                chainId,
                nonce: nonces[si] + t,
                value: 0n,
            };
            const raw = await wallet.signTransaction(tx);
            rows.push({ si, nonce: nonces[si] + t, raw });
        }
        return rows;
    });

    const allSigned = (await Promise.all(signPromises)).flat();
    log(`Signed ${allSigned.length} TXs. Broadcasting...`);

    // Broadcast all TXs as fast as possible (no await per TX)
    const t0 = Date.now();
    let sent = 0, errors = 0;
    const broadcastPromises = allSigned.map(async ({ raw }) => {
        try {
            await provider.broadcastTransaction(raw);
            sent++;
        } catch (e) {
            errors++;
            if (errors <= 5) log(`  broadcast error: ${e.message?.slice(0,80)}`);
        }
    });
    await Promise.all(broadcastPromises);

    const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
    log(`Broadcast complete: sent=${sent} errors=${errors} in ${elapsed}s`);

    // Check pending pool size
    await new Promise(r => setTimeout(r, 1000));
    const pending = await getPendingCount(provider);
    log(`Pending pool size (after 1s): ${pending}`);
    log(`Expected spillable TXs (nonce > min+16): ~${Math.max(0, TXS_PER_SENDER - 17) * N_SENDERS}`);

    // Output JSON summary for eval script
    const summary = {
        n_senders: N_SENDERS,
        txs_per_sender: TXS_PER_SENDER,
        slots_per_tx: SLOTS_PER_TX,
        total_sent: sent,
        errors,
        pending_after_1s: pending,
        spillable_estimate: Math.max(0, TXS_PER_SENDER - 17) * N_SENDERS,
    };
    process.stdout.write(`PRELOAD_SUMMARY:${JSON.stringify(summary)}\n`);
    process.exit(errors > sent * 0.1 ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
