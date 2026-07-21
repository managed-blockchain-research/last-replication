#!/bin/bash
# ============================================================
# 5×ctrl vs 5×lass75 Statistical Validation
#
# Runs 5 independent replicates of ctrl (stock Besu) and
# 5 independent replicates of LASS-75, then generates
# final_evaluation_report.md with statistical comparison.
#
# Parameters:
#   Heap:        4g (-Xmx4g, -Xms4g)
#   G1MaxNewSizePercent=90  (allows heap to fill to 90%)
#   Workers:     20
#   Warmup:      120s (not recorded)
#   Measurement: 300s (recorded)
#   Slots/tx:    200
#   LASS-75:     threshold=0.75, consecutive_samples=1
# ============================================================

set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_CTRL_BIN="/home/yeochan.yoon/besu-24.1.1/bin/besu"
BESU_LASS_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"

RUN_ID=$(date +%Y%m%d_%H%M%S)_5xval
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/validation_5x/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

HEAP_SIZE="4g"
WORKERS=20
WARMUP_DURATION=120
MEASURE_DURATION=300
SLOTS=200
REPLICATIONS=5

NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
LASS75_OPTS="-Dlass.old.gen.activation.threshold=0.75 -Dlass.old.gen.deactivation.threshold=0.60 -Dlass.old.gen.consecutive.samples=1"

echo "======================================================================"
echo "5x ctrl vs 5x lass75 Statistical Validation"
echo "Run ID: ${RUN_ID}"
echo "Heap: ${HEAP_SIZE} | Workers: ${WORKERS} | Warmup: ${WARMUP_DURATION}s | Measure: ${MEASURE_DURATION}s"
echo "Replications per variant: ${REPLICATIONS}"
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
    local pid_file="$1"
    if [ -f "${pid_file}" ]; then
        local pid
        pid=$(cat "${pid_file}")
        kill "${pid}" 2>/dev/null || true
        local wait=0
        while kill -0 "${pid}" 2>/dev/null && [ ${wait} -lt 25 ]; do
            sleep 1; wait=$((wait+1))
        done
        kill -9 "${pid}" 2>/dev/null || true
        rm -f "${pid_file}"
    fi
    # Fallback: kill any stray besu dev-network process
    local java_pid
    java_pid=$(pgrep -f "besu.*--network=dev" 2>/dev/null | head -1 || true)
    [ -n "${java_pid}" ] && kill -9 "${java_pid}" 2>/dev/null || true
    sleep 3
}

run_single() {
    local variant="$1"     # ctrl or lass75
    local rep="$2"         # 1..5
    local besu_bin="$3"
    local lass_opts="$4"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_5xval_${label}"
    local gc_log="${run_dir}/gc.log"
    local pid_file="/tmp/besu_5xval.pid"

    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────"

    # Clean data dir for fresh chain state
    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP_SIZE} -Xmx${HEAP_SIZE} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
-XX:G1HeapRegionSize=4m \
-XX:G1HeapWastePercent=5 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=5,filesize=50M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${lass_opts} \
-Dcom.sun.management.jmxremote \
-Dcom.sun.management.jmxremote.port=9011 \
-Dcom.sun.management.jmxremote.local.only=false \
-Dcom.sun.management.jmxremote.authenticate=false \
-Dcom.sun.management.jmxremote.ssl=false"

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
        --tx-pool-layer-max-capacity=20000 \
        --tx-pool-max-prioritized=10000 \
        --logging=INFO \
        > "${data_dir}/besu_console.log" 2>&1 &

    local besu_pid=$!
    echo "${besu_pid}" > "${pid_file}"
    echo "  Besu PID: ${besu_pid} | Binary: $(basename ${besu_bin})"

    sleep 5
    if ! kill -0 ${besu_pid} 2>/dev/null; then
        echo "  ERROR: Besu died on startup."
        tail -20 "${data_dir}/besu_console.log" || true
        return 1
    fi

    wait_for_rpc || { stop_besu "${pid_file}"; return 1; }

    echo "  Deploying StateBloater contract..."
    python3 deploy_contract.py > "${run_dir}/deploy.log" 2>&1
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | awk '{print $3}')
    if [ -z "${contract_addr}" ]; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_besu "${pid_file}"
        return 1
    fi
    echo "  Contract: ${contract_addr}"

    echo "  Running workload (warmup=${WARMUP_DURATION}s + measure=${MEASURE_DURATION}s)..."
    local t_start
    t_start=$(date +%s)

    python3 extreme_baseline_test.py \
        --workers "${WORKERS}" \
        --duration "${MEASURE_DURATION}" \
        --slots "${SLOTS}" \
        --warmup-duration "${WARMUP_DURATION}" \
        --output "${run_dir}/test" \
        > "${run_dir}/test.log" 2>&1

    local exit_code=$?
    local t_end
    t_end=$(date +%s)
    echo "  Workload done (exit=${exit_code}). Elapsed: $((t_end - t_start))s"

    echo "  Stopping Besu..."
    stop_besu "${pid_file}"

    cp "${data_dir}/besu_console.log" "${run_dir}/besu_console.log" 2>/dev/null || true

    # Quick summary from log
    local tps p99 maxgc
    tps=$(grep "Total Rate:" "${run_dir}/test.log" 2>/dev/null | awk '{print $3}')
    p99=$(grep -E "^\s+P99:" "${run_dir}/test.log" 2>/dev/null | awk '{print $2}')
    maxgc=$(grep "Max:" "${run_dir}/test.log" 2>/dev/null | head -1 | awk '{print $2}')
    echo "  RESULT: TPS=${tps:-N/A} P99=${p99:-N/A}ms MaxLat=${maxgc:-N/A}ms"
    echo "  ✓ ${label} complete"
}

# Pre-flight check
if pgrep -f "besu.*--network=dev" > /dev/null; then
    echo "ERROR: Besu already running. Stop it first."
    exit 1
fi

# Write provenance
LASS_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
5x ctrl vs 5x lass75 Statistical Validation
============================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Design:
  Heap:        ${HEAP_SIZE}
  GC:          G1GC MaxGCPauseMillis=200 G1HeapRegionSize=4m
  Eden:        G1MaxNewSizePercent=90 G1NewSizePercent=20
  Workers:     ${WORKERS}
  Warmup:      ${WARMUP_DURATION}s (not recorded)
  Measurement: ${MEASURE_DURATION}s
  Slots/tx:    ${SLOTS}
  Reps/variant: ${REPLICATIONS}

Binaries:
  ctrl:   ${BESU_CTRL_BIN}
  lass75: ${BESU_LASS_BIN} (commit: ${LASS_COMMIT})

LASS-75 flags:
  ${LASS75_OPTS}
EOF

# Run 5x ctrl
echo ""
echo "=============================="
echo "PHASE 1: 5× CTRL"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "ctrl" "${i}" "${BESU_CTRL_BIN}" ""
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 15s before next run)"
        sleep 15
    fi
done

# Run 5x lass75
echo ""
echo "=============================="
echo "PHASE 2: 5× LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass75" "${i}" "${BESU_LASS_BIN}" "${LASS75_OPTS}"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 15s before next run)"
        sleep 15
    fi
done

echo ""
echo "======================================================================"
echo "ALL RUNS COMPLETE — generating final_evaluation_report.md"
echo "======================================================================"

python3 scripts/analyze_5x_validation.py "${RESULTS_DIR}" > "${RESULTS_DIR}/analysis.log" 2>&1
echo "Report: ${RESULTS_DIR}/final_evaluation_report.md"

# Also copy report to caliper-stress-test root for easy access
cp "${RESULTS_DIR}/final_evaluation_report.md" \
   "/home/yeochan.yoon/caliper-stress-test/final_evaluation_report.md" 2>/dev/null || true

echo ""
echo "Done. Results: ${RESULTS_DIR}"
