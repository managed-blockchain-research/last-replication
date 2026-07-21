#!/bin/bash
# ============================================================
# 5×ctrl vs 5×lass75  —  HEAP STARVATION EDITION
#
# Identical to run_5x_validation.sh EXCEPT heap is slashed to
# 1g (fallback 1536m) to force a catastrophic GC Latency Cliff.
#
# With 1g heap and 100+ TPS allocation rate:
#   - G1 Eden ≤ 90% × 1024MB = ~922MB
#   - LASS-75 fires at 75% × 1024MB = ~768MB
#   - GC events will be frequent and long (potential Full STW)
#   - ctrl expected: MaxGC >> 100ms, possible 1000ms+ Full GC
#   - lass75: aggressively spills TXs to neutralise the cliff
#
# Output: final_evaluation_results_1GB.md
# ============================================================

set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_CTRL_BIN="/home/yeochan.yoon/besu-24.1.1/bin/besu"
BESU_LASS_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"

RUN_ID=$(date +%Y%m%d_%H%M%S)_1gb
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/validation_1gb/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

# 512m: Old Gen (50MB) + max Eden (90%×512=461MB) ≈ 511MB = 99.8% of heap.
# With no free regions at GC time → evacuation failure → Full GC (serial STW).
# Fallback to 768m if 512m OOMs at startup.
HEAP_PRIMARY="512m"
HEAP_FALLBACK="768m"

WORKERS=20
WARMUP_DURATION=120
MEASURE_DURATION=300
SLOTS=200
REPLICATIONS=5

# G1MaxNewSizePercent=90 so LASS-75 fires before GC at 90%.
# Remove explicit G1HeapRegionSize — let JVM auto-size for 1g heap
# (auto = 2MB regions → 512 regions, better than forcing 4m/256 regions).
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
LASS75_OPTS="-Dlass.old.gen.activation.threshold=0.75 -Dlass.old.gen.deactivation.threshold=0.60 -Dlass.old.gen.consecutive.samples=1"

echo "======================================================================"
echo "5x ctrl vs 5x lass75  —  HEAP STARVATION (512m)"
echo "Run ID: ${RUN_ID}"
echo "Heap: ${HEAP_PRIMARY} (fallback ${HEAP_FALLBACK}) | Workers: ${WORKERS}"
echo "Warmup: ${WARMUP_DURATION}s | Measure: ${MEASURE_DURATION}s | Slots: ${SLOTS}"
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
    local java_pid
    java_pid=$(pgrep -f "besu.*--network=dev" 2>/dev/null | head -1 || true)
    [ -n "${java_pid}" ] && kill -9 "${java_pid}" 2>/dev/null || true
    sleep 3
}

start_besu() {
    local besu_bin="$1"
    local data_dir="$2"
    local gc_log="$3"
    local heap="$4"
    local lass_opts="$5"
    local pid_file="$6"
    local console_log="${data_dir}/besu_console.log"

    local java_opts="-Xms${heap} -Xmx${heap} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
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
        > "${console_log}" 2>&1 &

    echo $!
}

run_single() {
    local variant="$1"
    local rep="$2"
    local besu_bin="$3"
    local lass_opts="$4"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_1gb_${label}"
    local gc_log="${run_dir}/gc.log"
    local pid_file="/tmp/besu_1gb.pid"

    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────"

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    # Try primary heap first
    local heap="${HEAP_PRIMARY}"
    local besu_pid
    besu_pid=$(start_besu "${besu_bin}" "${data_dir}" "${gc_log}" "${heap}" "${lass_opts}" "${pid_file}")
    echo "${besu_pid}" > "${pid_file}"
    echo "  Besu PID: ${besu_pid} | Heap: ${heap} | Binary: $(basename ${besu_bin})"

    sleep 6
    if ! kill -0 ${besu_pid} 2>/dev/null; then
        echo "  WARN: Besu died with ${heap}; checking for OOM..."
        if grep -q "OutOfMemoryError\|Cannot allocate memory\|insufficient memory" "${data_dir}/besu_console.log" 2>/dev/null; then
            echo "  OOM confirmed — retrying with fallback heap ${HEAP_FALLBACK}"
            rm -rf "${data_dir}" && mkdir -p "${data_dir}"
            local fallback_gc="${run_dir}/gc_fallback.log"
            heap="${HEAP_FALLBACK}"
            besu_pid=$(start_besu "${besu_bin}" "${data_dir}" "${fallback_gc}" "${heap}" "${lass_opts}" "${pid_file}")
            echo "${besu_pid}" > "${pid_file}"
            # Use fallback gc log for this run
            gc_log="${fallback_gc}"
            echo "  Besu PID: ${besu_pid} | Heap: ${heap} (fallback)"
            sleep 6
        fi
        if ! kill -0 ${besu_pid} 2>/dev/null; then
            echo "  ERROR: Besu died even with fallback heap. Skipping run."
            tail -20 "${data_dir}/besu_console.log" || true
            echo "  heap_used=${heap}" > "${run_dir}/FAILED"
            return 1
        fi
    fi

    echo "  heap_used=${heap}" > "${run_dir}/heap_used.txt"

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

    local tps p99
    tps=$(grep "Total Rate:" "${run_dir}/test.log" 2>/dev/null | awk '{print $3}')
    p99=$(grep -E "^\s+P99:" "${run_dir}/test.log" 2>/dev/null | awk '{print $2}')
    local maxgc
    maxgc=$(grep "Pause" "${run_dir}/gc.log" 2>/dev/null | grep -oP '[\d.]+ms$' | sed 's/ms//' | sort -n | tail -1)
    echo "  RESULT: TPS=${tps:-N/A} P99=${p99:-N/A}ms MaxGC=${maxgc:-N/A}ms heap=${heap}"
    echo "  ✓ ${label} complete"
}

# Pre-flight
if pgrep -f "besu.*--network=dev" > /dev/null; then
    echo "ERROR: Besu already running. Stop it first."
    exit 1
fi

LASS_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
5x ctrl vs 5x lass75 — Heap Starvation Edition
===============================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Change from baseline run: Heap slashed from 4g → ${HEAP_PRIMARY} (fallback ${HEAP_FALLBACK})
Rationale: Force evacuation-failure Full GC via heap starvation.
  Old Gen stable at ~50MB (Besu startup fixed cost).
  Old Gen (50MB) + max Eden (90%×512MB=461MB) = 511MB ≈ 512MB (heap full).
  G1 has zero free regions at GC time → evacuation failure → serial Full GC STW.
  Expected ctrl MaxGC: >>200ms, potential 1000ms+ Full STW pauses.
  LASS-75 fires at 75%×512MB=384MB before heap saturates, freeing TX pool objects.

Binaries:
  ctrl:   ${BESU_CTRL_BIN}
  lass75: ${BESU_LASS_BIN} (commit: ${LASS_COMMIT})

JVM flags (same as baseline except heap):
  Heap:   ${HEAP_PRIMARY} (-Xms=-Xmx, no heap expansion)
  GC:     G1GC MaxGCPauseMillis=200 (adaptive)
  Eden:   G1MaxNewSizePercent=90 G1NewSizePercent=20
  LASS:   threshold=0.75 deactivate=0.60 consecutive_samples=1
EOF

# 5x ctrl
echo ""
echo "=============================="
echo "PHASE 1: 5× CTRL  (heap=${HEAP_PRIMARY} → evacuation-failure cliff expected)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "ctrl" "${i}" "${BESU_CTRL_BIN}" ""
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 15s)"
        sleep 15
    fi
done

# 5x lass75
echo ""
echo "=============================="
echo "PHASE 2: 5× LASS-75  (heap=${HEAP_PRIMARY} → LASS fires at 75%=384MB, before evacuation failure)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass75" "${i}" "${BESU_LASS_BIN}" "${LASS75_OPTS}"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 15s)"
        sleep 15
    fi
done

echo ""
echo "======================================================================"
echo "ALL RUNS COMPLETE — generating final_evaluation_results_1GB.md"
echo "======================================================================"

python3 scripts/analyze_5x_1gb.py "${RESULTS_DIR}" > "${RESULTS_DIR}/analysis.log" 2>&1
echo "Report: ${RESULTS_DIR}/final_evaluation_results_1GB.md"

cp "${RESULTS_DIR}/final_evaluation_results_1GB.md" \
   "/home/yeochan.yoon/caliper-stress-test/final_evaluation_results_1GB.md" 2>/dev/null || true

echo "Done. Results: ${RESULTS_DIR}"
