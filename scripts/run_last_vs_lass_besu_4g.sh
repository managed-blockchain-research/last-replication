#!/bin/bash
# ============================================================
# LAST vs LASS Head-to-Head Evaluation — Hyperledger Besu @ 4GB Heap
#
# All 4 variants use besu-source (LAST+LASS patches) — cleaner design:
#   baseline   : besu-source, -Dlast.variant=DISABLED, no LASS
#   lass75     : besu-source, -Dlast.variant=DISABLED, LASS-75
#   last_al    : besu-source, -Dlast.variant=ADDRESS_LOCALITY, no LASS
#   last_lass75: besu-source, -Dlast.variant=ADDRESS_LOCALITY, LASS-75
#
# Caliper: 120s warmup + 300s measure, 1500 TPS, 30 workers, mempool uncapped
# Output: results/last_vs_lass_4g/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Binaries ─────────────────────────────────────────────────────────────────
BESU_VANILLA="/home/yeochan.yoon/besu-24.1.1/bin/besu"       # LAST-patched, no LASS
BESU_LASS="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"  # LAST+LASS-patched

LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-last-vs-lass-4g.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

# ── Run parameters ────────────────────────────────────────────────────────────
HEAP="4g"
REPLICATIONS=5
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
LASS75_OPTS="-Dlass.old.gen.activation.threshold=0.75 -Dlass.old.gen.deactivation.threshold=0.60 -Dlass.old.gen.consecutive.samples=1"
LAST_AL_OPTS="-Dlast.variant=ADDRESS_LOCALITY -Dlass.old.gen.activation.threshold=2.0"
DISABLED_LAST="-Dlast.variant=DISABLED -Dlass.old.gen.activation.threshold=2.0"

# ── Output directory ──────────────────────────────────────────────────────────
RUN_ID=$(date +%Y%m%d_%H%M%S)_last_vs_lass_4g
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/last_vs_lass_4g/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "LAST vs LASS Evaluation | Heap=${HEAP} | 1500 TPS | 120s+300s | 5 reps"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max_wait=120
    local count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"
            return 0
        fi
        echo -n "."
        sleep 1
        count=$((count + 1))
    done
    echo " TIMEOUT"
    return 1
}

stop_besu() {
    local besu_pid="$1"
    kill "${besu_pid}" 2>/dev/null || true
    local wait=0
    while kill -0 "${besu_pid}" 2>/dev/null && [ ${wait} -lt 30 ]; do
        sleep 1; wait=$((wait+1))
    done
    kill -9 "${besu_pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

run_single() {
    local variant="$1"   # baseline | lass75 | last_al | last_lass75
    local rep="$2"
    local besu_bin="$3"
    local last_opt="$4"
    local lass_opt="$5"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_lvl_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc.log"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  binary: $(basename $(dirname ${besu_bin}))/$(basename ${besu_bin})"
    echo "  LAST:   ${last_opt}"
    echo "  LASS:   ${lass_opt:-none}"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
-XX:G1HeapWastePercent=5 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=3,filesize=20M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${last_opt} \
${lass_opt}"

    export BESU_OPTS="${java_opts}"

    nohup "${besu_bin}" \
        --network=dev \
        --miner-enabled \
        --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
        --data-path="${data_dir}" \
        --rpc-http-enabled \
        --rpc-http-port=8545 \
        --rpc-http-host=0.0.0.0 \
        --rpc-http-cors-origins="*" \
        --rpc-ws-enabled \
        --rpc-ws-port=8546 \
        --rpc-ws-max-active-connections=200 \
        --host-allowlist="*" \
        --min-gas-price=0 \
        --tx-pool-layer-max-capacity=1000000 \
        --tx-pool-max-prioritized=1000000 \
        --tx-pool-max-future-by-sender=100000 \
        > "${run_dir}/besu_console.log" 2>&1 &
    local besu_pid=$!
    echo "  Besu PID: ${besu_pid}"

    sleep 8
    if ! kill -0 ${besu_pid} 2>/dev/null; then
        echo "  ERROR: Besu died at startup."
        tail -20 "${run_dir}/besu_console.log" || true
        echo "failed=startup" > "${run_dir}/FAILED"
        return 1
    fi

    wait_for_rpc || {
        stop_besu "${besu_pid}"
        echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        return 1
    }

    echo "  Deploying 30 StateBloater contracts..."
    python3 "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_besu "${besu_pid}"
        echo "failed=deploy" > "${run_dir}/FAILED"
        return 1
    fi
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | awk '{print $3}')
    echo "  First contract: ${contract_addr}"

    sleep 3

    echo "  Running Caliper (120s warmup + 300s measure @ 1500 TPS)..."
    local t_start
    t_start=$(date +%s)

    timeout 1500 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1
    local caliper_exit=$?

    local t_end
    t_end=$(date +%s)
    echo "  Caliper exit: ${caliper_exit}. Elapsed: $((t_end - t_start))s"

    cp caliper.log  "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html  "${run_dir}/report.html"  2>/dev/null || true

    echo "  Stopping Besu..."
    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    # Quick summary from caliper log
    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"

    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
BESU_SRC_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
LAST vs LASS Head-to-Head Evaluation @ 4GB Heap
================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Binaries:
  baseline/last_al : ${BESU_VANILLA}
  lass75/last_lass75: ${BESU_LASS} (commit: ${BESU_SRC_COMMIT})

LAST patch: banning/clients/besu-last (ADDRESS_LOCALITY variant)
LASS-75:    activation=0.75, deactivation=0.60, consecutive_samples=1

Heap:    -Xms1g -Xmx1g (fixed)
GC:      G1GC MaxGCPauseMillis=200
TxPool:  --tx-pool-max-size=1000000 (uncapped)
Load:    Caliper fixed-rate 1500 TPS, 120s warmup + 300s measure, 30 workers
TX:      stateBloat 200 slots/tx

Variants:
  baseline   : besu-24.1.1, DISABLED LAST, no LASS
  lass75     : besu-source,  DISABLED LAST, LASS-75
  last_al    : besu-24.1.1, ADDRESS_LOCALITY, no LASS
  last_lass75: besu-source,  ADDRESS_LOCALITY, LASS-75
EOF

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: Baseline (FIFO, no LASS, no LAST) ───────────────────────────────
echo ""
echo "=============================="
echo "PHASE 1: 5×BASELINE"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "baseline" "${i}" "${BESU_LASS}" "${DISABLED_LAST}" "" \
        || echo "  WARNING: baseline_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# ── Phase 2: LASS-75 only ─────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 2: 5×LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass75" "${i}" "${BESU_LASS}" "${DISABLED_LAST}" "${LASS75_OPTS}" \
        || echo "  WARNING: lass75_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# ── Phase 3: LAST-AL only ─────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 3: 5×LAST-AL"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_al" "${i}" "${BESU_LASS}" "${LAST_AL_OPTS}" "" \
        || echo "  WARNING: last_al_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# ── Phase 4: LAST-AL + LASS-75 (Synergy) ─────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 4: 5×LAST+LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_lass75" "${i}" "${BESU_LASS}" "${LAST_AL_OPTS}" "${LASS75_OPTS}" \
        || echo "  WARNING: last_lass75_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# ── Analysis ──────────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo "ALL RUNS COMPLETE — running analysis"
echo "======================================================================"

python3 scripts/analyze_last_vs_lass.py "${RESULTS_DIR}" 4GB \
    > "${RESULTS_DIR}/analysis.log" 2>&1 && \
    echo "Report: ${RESULTS_DIR}/final_LAST_vs_LASS_4GB_Evaluation.md" || \
    echo "WARNING: analysis script failed — check ${RESULTS_DIR}/analysis.log"

echo "Done. Results: ${RESULTS_DIR}"
