#!/bin/bash
# ============================================================
# Caliper 5×ctrl vs 5×lass75 — 1g heap, 600s @ 1500 TPS
#
# Runs 5 replications of ctrl (stock Besu 24.1.1) and
# 5 replications of lass75 (LASS-modified Besu) using
# Hyperledger Caliper at 1500 in-flight TXs, 600s measurement.
#
# Heap=1g creates 150+ Young GC events/minute under 1500 TPS
# load. LASS-75 fires at 75%×1g=768MB (before each Young GC),
# spilling low-priority TXs to RocksDB → fewer GC events,
# lower GC overhead, better Besu throughput.
#
# Output: results/validation_caliper_1g/<RUN_ID>/
#         final_evaluation_results_caliper.md
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_CTRL_BIN="/home/yeochan.yoon/besu-24.1.1/bin/besu"
BESU_LASS_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-harsh-probe.yaml"

RUN_ID=$(date +%Y%m%d_%H%M%S)_caliper5x5
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/validation_caliper_1g/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

HEAP="1g"
REPLICATIONS=5
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
LASS75_OPTS="-Dlass.old.gen.activation.threshold=0.75 -Dlass.old.gen.deactivation.threshold=0.60 -Dlass.old.gen.consecutive.samples=1"

echo "======================================================================"
echo "5×ctrl vs 5×lass75 — Caliper 1500 TPS | Heap=${HEAP} | 600s"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"
echo ""

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
    local besu_bin="$3"
    local lass_opts="$4"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_caliper_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc.log"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    # Ensure clean slate before each run
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

    nohup "${besu_bin}" \
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
    echo "  Besu PID: ${besu_pid} | Binary: $(basename ${besu_bin})"

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

    echo "  Waiting 5s for Besu to stabilize..."
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

    # Quick GC summary
    local gc_events maxgc full_gc mixed_gc
    gc_events=$(grep -c 'Pause' "${gc_log}" 2>/dev/null || echo 0)
    maxgc=$(grep "Pause" "${gc_log}" 2>/dev/null | grep -oP '[\d.]+ms$' | sed 's/ms//' | sort -n | tail -1)
    full_gc=$(grep -c 'Pause Full' "${gc_log}" 2>/dev/null || echo 0)
    mixed_gc=$(grep -c 'Pause Mixed' "${gc_log}" 2>/dev/null || echo 0)
    local caliper_tps caliper_maxlat
    caliper_tps=$(grep -A5 "cliff-probe" "${run_dir}/caliper_console.log" 2>/dev/null | grep -oP '[\d.]+\s*$' | tail -1)
    caliper_maxlat=$(grep "cliff-probe" "${run_dir}/caliper_console.log" 2>/dev/null | grep -oP '\|\s+[\d.]+\s+\|' | head -2 | tail -1 | tr -d '| ')

    echo "  RESULT: GC=${gc_events} MaxGC=${maxgc:-N/A}ms Full=${full_gc} Mixed=${mixed_gc} | CaliperTPS=${caliper_tps:-N/A}"
    echo "  ✓ ${label} complete"
}

# Pre-flight: kill any stray Besu from prior runs
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
sleep 3

LASS_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
5×ctrl vs 5×lass75 — Caliper 1500 TPS, 1g heap, 600s
======================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Heap:   ${HEAP} (Xms=Xmx, no expansion)
GC:     G1GC MaxGCPauseMillis=200
Eden:   G1MaxNewSizePercent=90 G1NewSizePercent=20
LASS:   threshold=0.75 deactivate=0.60 consecutive_samples=1
Load:   Caliper fixed-load transactionLoad=1500, 600s, 30 workers
TX:     stateBloat 200 slots/tx

Expected behavior:
  ctrl:   ~150+ Young GC/min at 1g heap, MaxGC≈44ms
  lass75: LASS fires at 768MB (75%×1g), spills TXs → fewer GC events

Binaries:
  ctrl:   ${BESU_CTRL_BIN}
  lass75: ${BESU_LASS_BIN} (commit: ${LASS_COMMIT})
EOF

# Phase 1: 5×ctrl
echo ""
echo "=============================="
echo "PHASE 1: 5×CTRL"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "ctrl" "${i}" "${BESU_CTRL_BIN}" "" || echo "  WARNING: ctrl_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# Phase 2: 5×lass75
echo ""
echo "=============================="
echo "PHASE 2: 5×LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass75" "${i}" "${BESU_LASS_BIN}" "${LASS75_OPTS}" || echo "  WARNING: lass75_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

echo ""
echo "======================================================================"
echo "ALL RUNS COMPLETE — generating final_evaluation_results_caliper.md"
echo "======================================================================"

python3 scripts/analyze_caliper_5x5.py "${RESULTS_DIR}" > "${RESULTS_DIR}/analysis.log" 2>&1
echo "Report: ${RESULTS_DIR}/final_evaluation_results_caliper.md"

cp "${RESULTS_DIR}/final_evaluation_results_caliper.md" \
   "/home/yeochan.yoon/caliper-stress-test/final_evaluation_results_caliper.md" 2>/dev/null || true

echo "Done. Results: ${RESULTS_DIR}"
