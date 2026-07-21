#!/bin/bash
# ============================================================
# LASS Sensitivity Analysis v3: G1MaxNewSizePercent=90
#
# Root cause of LASS-75/90 never firing:
#   G1GC's Young Gen (Eden) is capped at 60% of heap by default
#   (-XX:G1MaxNewSizePercent=60 default).
#   Eden fills to 1500MB (60% of 2500MB), triggering GC at 1542MB.
#   Any LASS threshold > 61.7% never fires before GC.
#
# Fix: -XX:G1MaxNewSizePercent=90
#   Allows Eden to grow up to 90% of 2500MB = 2250MB.
#   Since current GC pauses are well under MaxGCPauseMillis=200ms,
#   G1GC will use the full 2250MB Eden → GC fires at ~2250MB = 90%.
#
# With MaxNewSizePercent=90:
#   - Baseline: GC fires at ~2250MB (90%)
#   - LASS-60: fires at 1500MB (~28s before GC)
#   - LASS-75: fires at 1875MB (~16s before GC)
#   - LASS-90: fires at 2250MB (right before GC, ~1s window)
#
# SAME settings for ALL experiments (baseline + LASS-60/75/90).
# consecutive_samples=1 for immediate LASS activation.
#
# Provenance:
#   - LASS binary: /home/yeochan.yoon/besu-source/build/install/besu/bin/besu
#   - LASS commit: 9b0e38fa (release-24.1.1 + ESpill fixes)
#   - Baseline binary: /home/yeochan.yoon/besu-24.1.1/bin/besu
#   - Heap: 2500m | G1MaxNewSizePercent=90 | MaxGCPauseMillis=200ms
# ============================================================

set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_BASELINE_BIN="/home/yeochan.yoon/besu-24.1.1/bin/besu"
BESU_LASS_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/sensitivity_analysis"
RUN_ID=$(date +%Y%m%d_%H%M%S)_ng90
RESULTS_SUBDIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${RESULTS_SUBDIR}"

WORKLOAD_WORKERS=20
WORKLOAD_DURATION=600
WORKLOAD_SLOTS=200
HEAP_SIZE="2500m"

# Key GC flag: allow Eden up to 90% of heap so GC fires at ~90%
# G1MaxNewSizePercent is experimental in JDK 17+ → requires UnlockExperimentalVMOptions
# Applied uniformly to baseline + all LASS experiments
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"

echo "======================================================================"
echo "LASS Sensitivity Analysis v3 (G1MaxNewSizePercent=90)"
echo "Run ID: ${RUN_ID}"
echo "Heap: ${HEAP_SIZE} | MaxNewSizePercent=90 | Workers: ${WORKLOAD_WORKERS} | Duration: ${WORKLOAD_DURATION}s"
echo "Expected: GC fires at ~90% = 2250MB | LASS-60 fires 28s before GC"
echo "Results: ${RESULTS_SUBDIR}"
echo "======================================================================"

wait_for_rpc() {
    local max_wait=90
    local count=0
    echo -n "Waiting for RPC"
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
        local pid=$(cat "${pid_file}")
        kill "${pid}" 2>/dev/null || true
        local wait=0
        while kill -0 "${pid}" 2>/dev/null && [ ${wait} -lt 20 ]; do
            sleep 1; wait=$((wait+1))
        done
        kill -9 "${pid}" 2>/dev/null || true
        rm -f "${pid_file}"
    fi
    # Also kill by name as fallback
    local java_pid
    java_pid=$(ps aux | grep "besu.*--network=dev" | grep -v grep | awk '{print $2}' | head -1)
    [ -n "${java_pid}" ] && kill -9 "${java_pid}" 2>/dev/null || true
    sleep 2
}

run_experiment() {
    local variant="$1"
    local besu_bin="$2"
    local lass_opts="$3"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_ng90_${variant}"
    local gc_log="${RESULTS_SUBDIR}/gc_${variant}.log"
    local pid_file="/tmp/besu_ng90.pid"
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
        echo "  ERROR: Besu died on startup. Check log:"
        tail -30 "${data_dir}/besu_console.log" || true
        return 1
    fi

    wait_for_rpc || { stop_besu "${pid_file}"; return 1; }

    echo "  Deploying contract..."
    python3 deploy_contract.py > "${output_prefix}_deploy.log" 2>&1
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${output_prefix}_deploy.log" | awk '{print $3}')
    echo "  Contract: ${contract_addr:-DEPLOY_FAILED}"
    if [ -z "${contract_addr}" ]; then
        cat "${output_prefix}_deploy.log"
        stop_besu "${pid_file}"
        return 1
    fi

    echo "  Running workload (${WORKLOAD_DURATION}s)..."
    local test_start=$(date +%s)
    python3 extreme_baseline_test.py \
        --workers "${WORKLOAD_WORKERS}" \
        --duration "${WORKLOAD_DURATION}" \
        --slots "${WORKLOAD_SLOTS}" \
        --output "${output_prefix}" \
        > "${output_prefix}_test.log" 2>&1
    local exit_code=$?
    local test_end=$(date +%s)
    echo "  Workload done (exit=${exit_code}). Elapsed: $((test_end - test_start))s"

    echo "  Stopping Besu..."
    stop_besu "${pid_file}"

    cp "${data_dir}/besu_console.log" "${output_prefix}_besu_console.log" 2>/dev/null || true
    echo "  ✓ ${variant} complete"

    # Quick summary
    local tps p99
    tps=$(grep "Total Rate:" "${output_prefix}_test.log" 2>/dev/null | awk '{print $3}')
    p99=$(grep "P99:" "${output_prefix}_test.log" 2>/dev/null | awk '{print $2}')
    echo "  Summary: TPS=${tps:-N/A} P99=${p99:-N/A}"
}

if pgrep -f "besu.*--network=dev" > /dev/null; then
    echo "ERROR: Besu already running. Stop it first."
    exit 1
fi

LASS_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_SUBDIR}/provenance.txt" <<EOF
LASS Sensitivity Analysis v3 Provenance
========================================
Run ID: ${RUN_ID}
Date: $(date)
Host: $(hostname)

Design decision:
  Problem: G1GC default G1MaxNewSizePercent=60% caps Eden at 1500MB.
  Eden fills at 1500MB → GC fires at ~1542MB = 61.7% of 2500MB heap.
  Any LASS threshold above 61.7% never fires before GC.

  Fix: -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20
  This allows Eden to grow to 90% of 2500MB = 2250MB.
  Since GC pauses are ~20ms (well under 200ms target), G1 will use max Eden.
  GC fires at ~2250MB = 90% of heap.

  Provides activation windows:
    LASS-60: fires at 1500MB (750MB / ~23 MB/s = ~33s before GC)
    LASS-75: fires at 1875MB (~16s before GC)
    LASS-90: fires at 2250MB (~1s before GC)

  Same -XX:G1MaxNewSizePercent=90 applied to ALL experiments.

Binaries:
  Baseline: /home/yeochan.yoon/besu-24.1.1/bin/besu (stock 24.1.1, no LASS)
  LASS:     /home/yeochan.yoon/besu-source/build/install/besu/bin/besu
  Commit:   ${LASS_COMMIT}

JVM (ALL experiments):
  Heap:           ${HEAP_SIZE}
  GC:             G1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=4m
  Eden sizing:    -XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20
  Expected GC at: ~90% heap = ~2250MB

Workload:
  Script:   extreme_baseline_test.py
  Workers:  ${WORKLOAD_WORKERS}
  Duration: ${WORKLOAD_DURATION}s
  Slots/tx: ${WORKLOAD_SLOTS}
  Pool:     20000 layer / 10000 prioritized

LASS Thresholds (all with consecutive_samples=1):
  lass60: activate=60%, deactivate=45%  (~33s window before GC)
  lass75: activate=75%, deactivate=60%  (~16s window before GC)
  lass90: activate=90%, deactivate=75%  (~1s window before GC)
EOF

echo "Provenance: ${RESULTS_SUBDIR}/provenance.txt"
echo ""

# Run all 4 experiments
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
