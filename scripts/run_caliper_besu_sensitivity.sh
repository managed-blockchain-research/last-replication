#!/bin/bash
# ============================================================
# Besu LASS Sensitivity: 5×lass60 + 5×lass90 @ 1g heap
#
# Companion to run_caliper_5x5.sh (ctrl + lass75 already done).
# Runs 5 replications of LASS-60 and 5 of LASS-90 with the
# same Caliper setup (fixed-rate 1500 TPS, 600s, 30 workers).
#
# Output: results/validation_caliper_1g/<RUN_ID>/
#         Copy ctrl+lass75 data ref is stored in provenance.txt
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_LASS_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-harsh-probe.yaml"

# Existing ctrl+lass75 results dir (used by analyze script)
PREV_RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/validation_caliper_1g/20260422_133356_caliper5x5"

RUN_ID=$(date +%Y%m%d_%H%M%S)_besu_sensitivity
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/validation_caliper_1g/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

HEAP="1g"
REPLICATIONS=5
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"

LASS60_OPTS="-Dlass.old.gen.activation.threshold=0.60 -Dlass.old.gen.deactivation.threshold=0.45 -Dlass.old.gen.consecutive.samples=1"
LASS90_OPTS="-Dlass.old.gen.activation.threshold=0.90 -Dlass.old.gen.deactivation.threshold=0.75 -Dlass.old.gen.consecutive.samples=1"

echo "======================================================================"
echo "Besu Sensitivity: 5×lass60 + 5×lass90 | Heap=${HEAP} | 600s @ 1500 TPS"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "Prev results (ctrl+lass75): ${PREV_RESULTS_DIR}"
echo "======================================================================"

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
    local variant="$1"
    local rep="$2"
    local lass_opts="$3"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_caliper_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc.log"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
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
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=5,filesize=50M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${lass_opts}"

    export BESU_OPTS="${java_opts}"

    nohup "${BESU_LASS_BIN}" \
        --network=dev \
        --data-path="${data_dir}" \
        --miner-enabled \
        --miner-coinbase=0xBE0cf996DE312b11990E4BcbBf7Fc156880AcFC8 \
        --rpc-http-enabled \
        --rpc-http-host=0.0.0.0 \
        --rpc-http-port=8545 \
        --rpc-http-cors-origins="*" \
        --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --rpc-ws-enabled \
        --rpc-ws-host=0.0.0.0 \
        --rpc-ws-port=8546 \
        --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --host-allowlist="*" \
        --min-gas-price=0 \
        --tx-pool-layer-max-capacity=1000000 \
        --tx-pool-max-prioritized=1000000 \
        --tx-pool-max-future-by-sender=100000 \
        --logging=INFO \
        > "${data_dir}/besu_console.log" 2>&1 &
    local besu_pid=$!
    echo "  Besu PID: ${besu_pid}"

    sleep 6
    if ! kill -0 ${besu_pid} 2>/dev/null; then
        echo "  ERROR: Besu died at startup."
        tail -20 "${data_dir}/besu_console.log" || true
        echo "  failed=startup" > "${run_dir}/FAILED"
        return 1
    fi

    wait_for_rpc || { stop_besu "${besu_pid}"; return 1; }

    echo "  Deploying StateBloater contract..."
    python3 deploy_contract.py > "${run_dir}/deploy.log" 2>&1
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | awk '{print $3}')
    if [ -z "${contract_addr}" ]; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_besu "${besu_pid}"
        return 1
    fi
    echo "  Contract: ${contract_addr}"

    sleep 5

    echo "  Running Caliper (600s @ 1500 TPS)..."
    local t_start
    t_start=$(date +%s)

    timeout 720 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig networkconfig.json \
        --caliper-txTimeout 60 \
        > "${run_dir}/caliper_console.log" 2>&1
    local caliper_exit=$?

    local t_end
    t_end=$(date +%s)
    echo "  Caliper exit: ${caliper_exit}. Elapsed: $((t_end - t_start))s"

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    cp "${data_dir}/besu_console.log" "${run_dir}/besu_console.log" 2>/dev/null || true

    echo "  Stopping Besu..."
    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    local gc_events maxgc full_gc mixed_gc
    gc_events=$(grep -c 'Pause' "${gc_log}" 2>/dev/null || echo 0)
    maxgc=$(grep "Pause" "${gc_log}" 2>/dev/null | grep -oP '[\d.]+ms$' | sed 's/ms//' | sort -n | tail -1)
    full_gc=$(grep -c 'Pause Full' "${gc_log}" 2>/dev/null || echo 0)
    mixed_gc=$(grep -c 'Pause Mixed' "${gc_log}" 2>/dev/null || echo 0)

    echo "  RESULT: GC=${gc_events} MaxGC=${maxgc:-N/A}ms Full=${full_gc} Mixed=${mixed_gc}"
    echo "  ✓ ${label} complete"
}

# Pre-flight
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
sleep 3

cat > "${RESULTS_DIR}/provenance.txt" <<EOF
Besu Sensitivity Analysis — LASS-60 + LASS-90
==============================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Heap:   ${HEAP} (Xms=Xmx)
GC:     G1GC MaxGCPauseMillis=200
Eden:   G1MaxNewSizePercent=90 G1NewSizePercent=20
Load:   Caliper fixed-rate tps=1500, 600s, 30 workers
TX:     stateBloat 200 slots/tx

LASS-60: threshold=0.60 deactivate=0.45 consecutive_samples=1
LASS-90: threshold=0.90 deactivate=0.75 consecutive_samples=1

Ctrl+LASS75 reference: ${PREV_RESULTS_DIR}

Binary: ${BESU_LASS_BIN}
EOF

echo ""
echo "=============================="
echo "PHASE 1: 5×LASS-60"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass60" "${i}" "${LASS60_OPTS}" || echo "  WARNING: lass60_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

echo ""
echo "=============================="
echo "PHASE 2: 5×LASS-90"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass90" "${i}" "${LASS90_OPTS}" || echo "  WARNING: lass90_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

echo ""
echo "======================================================================"
echo "ALL SENSITIVITY RUNS COMPLETE"
echo "======================================================================"

python3 scripts/analyze_besu_sensitivity.py \
    --prev "${PREV_RESULTS_DIR}" \
    --new "${RESULTS_DIR}" \
    > "${RESULTS_DIR}/analysis.log" 2>&1

echo "Report: ${RESULTS_DIR}/final_besu_sensitivity_1GB.md"
cp "${RESULTS_DIR}/final_besu_sensitivity_1GB.md" \
   "/home/yeochan.yoon/caliper-stress-test/final_besu_sensitivity_1GB.md" 2>/dev/null || true

echo "Done. Results: ${RESULTS_DIR}"
