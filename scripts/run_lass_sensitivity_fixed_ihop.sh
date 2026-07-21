#!/bin/bash
# ============================================================
# LASS Sensitivity Analysis v2: Fixed IHOP=95%
#
# Problem with adaptive IHOP: G1GC settles at ~61% IHOP,
# so LASS-75% and LASS-90% thresholds never fire before GC.
#
# Fix: -XX:-G1UseAdaptiveIHOP -XX:InitiatingHeapOccupancyPercent=95
# This forces G1GC to wait until 95% before starting concurrent marking.
# Young GC still fires based on Eden size, but the BIG collection
# that drops heap from ~60%→3% is now delayed to ~95%.
#
# With IHOP=95%:
#   - Baseline: GC at ~95% (2375MB of 2500MB)
#   - LASS-60: fires at 1500MB, ~40s before GC
#   - LASS-75: fires at 1875MB, ~22s before GC
#   - LASS-90: fires at 2250MB, ~6s before GC
#
# Key difference from v1:
#   - consecutive_samples=1 (immediate activation)
#   - -XX:-G1UseAdaptiveIHOP -XX:InitiatingHeapOccupancyPercent=95
#   - SAME settings for ALL experiments (fair comparison)
#
# Provenance:
#   - LASS binary: /home/yeochan.yoon/besu-source/build/install/besu/bin/besu
#   - LASS commit: 9b0e38fa (release-24.1.1 + ESpill fixes)
#   - Baseline binary: /home/yeochan.yoon/besu-24.1.1/bin/besu
#   - Heap: 2500m | IHOP=95% (fixed) | G1GC MaxPause=200ms
#   - Run date: $(date +%Y-%m-%d)
# ============================================================

set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_BASELINE_BIN="/home/yeochan.yoon/besu-24.1.1/bin/besu"
BESU_LASS_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/sensitivity_analysis"
RUN_ID=$(date +%Y%m%d_%H%M%S)_ihop95
RESULTS_SUBDIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${RESULTS_SUBDIR}"

WORKLOAD_WORKERS=20
WORKLOAD_DURATION=600
WORKLOAD_SLOTS=200

HEAP_SIZE="2500m"
# Fixed IHOP at 95%: prevents G1GC from collecting until heap reaches 95% = 2375MB
# This gives LASS-60/75/90 real windows before the major collection
IHOP_FLAGS="-XX:-G1UseAdaptiveIHOP -XX:InitiatingHeapOccupancyPercent=95"

echo "======================================================================"
echo "LASS Sensitivity Analysis v2 (Fixed IHOP=95%)"
echo "Run ID: ${RUN_ID}"
echo "Heap: ${HEAP_SIZE} | IHOP=95% (fixed) | Workers: ${WORKLOAD_WORKERS} | Duration: ${WORKLOAD_DURATION}s"
echo "Results: ${RESULTS_SUBDIR}"
echo "======================================================================"

wait_for_rpc() {
    local max_wait=90
    local count=0
    echo -n "Waiting for RPC"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s -X POST -H "Content-Type: application/json" \
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
        local pid=$(cat "${pid_file}")
        kill "${pid}" 2>/dev/null || true
        local wait=0
        while kill -0 "${pid}" 2>/dev/null && [ ${wait} -lt 20 ]; do
            sleep 1; wait=$((wait+1))
        done
        kill -9 "${pid}" 2>/dev/null || true
        rm -f "${pid_file}"
    fi
    sleep 2
}

run_experiment() {
    local variant="$1"
    local besu_bin="$2"
    local lass_opts="$3"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_ihop95_${variant}"
    local gc_log="${RESULTS_SUBDIR}/gc_${variant}.log"
    local pid_file="/tmp/besu_ihop95.pid"
    local output_prefix="${RESULTS_SUBDIR}/${variant}"

    echo ""
    echo "────────────────────────────────────────"
    echo "EXPERIMENT: ${variant} | $(date '+%H:%M:%S')"
    echo "────────────────────────────────────────"

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP_SIZE} -Xmx${HEAP_SIZE} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
-XX:G1HeapRegionSize=4m \
-XX:G1HeapWastePercent=5 \
${IHOP_FLAGS} \
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
    echo "  Besu PID: ${besu_pid}"

    sleep 5
    if ! kill -0 ${besu_pid} 2>/dev/null; then
        echo "  ERROR: Besu died. Check log."
        tail -30 "${data_dir}/besu_console.log" || true
        return 1
    fi

    wait_for_rpc || { stop_besu "${pid_file}"; return 1; }

    echo "  Deploying contract..."
    python3 deploy_contract.py > "${output_prefix}_deploy.log" 2>&1
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${output_prefix}_deploy.log" | awk '{print $3}')
    echo "  Contract: ${contract_addr}"

    echo "  Running workload (${WORKLOAD_DURATION}s)..."
    local test_start=$(date +%s)
    python3 extreme_baseline_test.py \
        --workers "${WORKLOAD_WORKERS}" \
        --duration "${WORKLOAD_DURATION}" \
        --slots "${WORKLOAD_SLOTS}" \
        --output "${output_prefix}" \
        > "${output_prefix}_test.log" 2>&1
    local test_end=$(date +%s)
    echo "  Workload done. Elapsed: $((test_end - test_start))s"

    echo "  Stopping Besu..."
    stop_besu "${pid_file}"

    cp "${data_dir}/besu_console.log" "${output_prefix}_besu_console.log"
    echo "  ✓ ${variant} complete → ${output_prefix}_*"
}

if pgrep -f "besu.*--network=dev" > /dev/null; then
    echo "ERROR: Besu already running. Stop it first."
    exit 1
fi

LASS_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_SUBDIR}/provenance.txt" <<EOF
LASS Sensitivity Analysis v2 Provenance
========================================
Run ID: ${RUN_ID}
Date: $(date)
Host: $(hostname)

Design motivation:
  G1GC adaptive IHOP settles at ~61.7% for this workload.
  Any LASS threshold > 61.7% never fires before GC.
  Fix: -XX:-G1UseAdaptiveIHOP -XX:InitiatingHeapOccupancyPercent=95
  Applied to ALL experiments (baseline + LASS) for fair comparison.

Binaries:
  Baseline: /home/yeochan.yoon/besu-24.1.1/bin/besu (stock 24.1.1)
  LASS:     /home/yeochan.yoon/besu-source/build/install/besu/bin/besu
  Commit:   ${LASS_COMMIT}

JVM (all experiments):
  Heap:     ${HEAP_SIZE}
  GC:       G1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=4m
  IHOP:     ${IHOP_FLAGS}
  (IHOP=95%: GC fires at ~2375MB, giving all thresholds real activation windows)

Workload:
  Script:   extreme_baseline_test.py
  Workers:  ${WORKLOAD_WORKERS}
  Duration: ${WORKLOAD_DURATION}s
  Slots/tx: ${WORKLOAD_SLOTS}
  Pool max: 20000 layer / 10000 prioritized

LASS Thresholds:
  lass60:  activate=60%, deactivate=45%, consecutive=1  (fires 40s before GC)
  lass75:  activate=75%, deactivate=60%, consecutive=1  (fires 22s before GC)
  lass90:  activate=90%, deactivate=75%, consecutive=1  (fires 6s before GC)

Trigger Signal: total heap ratio (getHeapUsageRatio)
Spill Fraction: 60% of pending transactions per spill round
EOF

echo "Provenance written to: ${RESULTS_SUBDIR}/provenance.txt"
echo ""

run_experiment "baseline" "${BESU_BASELINE_BIN}" ""

run_experiment "lass60" "${BESU_LASS_BIN}" \
    "-Dlass.old.gen.activation.threshold=0.60 -Dlass.old.gen.deactivation.threshold=0.45 -Dlass.old.gen.consecutive.samples=1"

run_experiment "lass75" "${BESU_LASS_BIN}" \
    "-Dlass.old.gen.activation.threshold=0.75 -Dlass.old.gen.deactivation.threshold=0.60 -Dlass.old.gen.consecutive.samples=1"

run_experiment "lass90" "${BESU_LASS_BIN}" \
    "-Dlass.old.gen.activation.threshold=0.90 -Dlass.old.gen.deactivation.threshold=0.75 -Dlass.old.gen.consecutive.samples=1"

echo ""
echo "======================================================================"
echo "ALL EXPERIMENTS COMPLETE"
echo "Results: ${RESULTS_SUBDIR}"
echo "======================================================================"
echo ""
echo "Analyze: python3 scripts/analyze_sensitivity.py ${RESULTS_SUBDIR}"
