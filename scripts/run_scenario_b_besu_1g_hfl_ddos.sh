#!/bin/bash
# ============================================================
# Scenario B — DDoS Mempool Saturation (Besu 1 GB / 1500 TPS)
#
# Goal: Prove HFL collapses (massive Full GCs) without LASS,
#       and that HFL+LASS-75 eliminates Full GCs entirely.
#
# Variants (3 × 5 reps = 15 runs):
#   baseline        : DISABLED, no LASS
#   last_hfl        : HYBRID_FEE_LOCALITY (α=0.5, β=0.5), no LASS
#   last_hfl_lass75 : HYBRID_FEE_LOCALITY (α=0.5, β=0.5), LASS-75
#
# Primary metrics: Full GC count, Total GC Time, Max GC Pause
# Benchconfig: benchconfig-last-vs-lass.yaml (1500 TPS, 120s+300s)
# Output: results/scenario_b_besu_1g_ddos/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Binaries ──────────────────────────────────────────────────────────────────
BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"

# ── Caliper config ────────────────────────────────────────────────────────────
BENCHCONFIG="benchconfig-last-vs-lass.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

# ── Run parameters ────────────────────────────────────────────────────────────
HEAP="1g"
REPLICATIONS=5
HFL_ALPHA="0.5"
HFL_BETA="0.5"

# LASS options
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"
LASS75_OPTS="-Dlass.old.gen.activation.threshold=0.75 \
-Dlass.old.gen.deactivation.threshold=0.60 \
-Dlass.old.gen.consecutive.samples=1"

# ── Output directory ──────────────────────────────────────────────────────────
RUN_ID=$(date +%Y%m%d_%H%M%S)_scenario_b_besu_1g_ddos
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/scenario_b_besu_1g_ddos/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "Scenario B — Besu 1 GB / 1500 TPS DDoS / 5 reps / 3 variants"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local port="${1:-8545}"
    local max_wait=120
    local count=0
    echo -n "  Waiting for RPC (port ${port})"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:${port} > /dev/null 2>&1; then
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
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0
    while kill -0 "${pid}" 2>/dev/null && [ ${w} -lt 30 ]; do
        sleep 1; w=$((w+1))
    done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

# run_single VARIANT REP LAST_VARIANT LASS_OPTS_STR
run_single() {
    local variant="$1"
    local rep="$2"
    local last_variant="$3"   # e.g. "DISABLED" or "HYBRID_FEE_LOCALITY"
    local lass_opts="$4"       # NO_LASS or LASS75_OPTS

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_scb_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"
    local last_csv="${run_dir}/last_metrics.csv"

    local last_flag="-Dlast.variant=${last_variant}"
    local hfl_flag=""
    if [ "${last_variant}" = "HYBRID_FEE_LOCALITY" ]; then
        hfl_flag="-Dlast.alpha=${HFL_ALPHA} -Dlast.beta=${HFL_BETA}"
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  LAST:  ${last_flag} ${hfl_flag}"
    echo "  LASS:  $(echo "${lass_opts}" | head -c 60)..."
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
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=5,filesize=100M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${last_flag} ${hfl_flag} \
-Dlast.log.path=${last_csv} \
${lass_opts}"

    export BESU_OPTS="${java_opts}"

    nohup "${BESU_BIN}" \
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

    cp caliper.log "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html "${run_dir}/report.html"  2>/dev/null || true

    echo "  Stopping Besu..."
    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    # Quick GC summary
    if [ -f "${gc_log}" ]; then
        local full_count young_count mixed_count total_ms
        full_count=$(grep -c "Pause Full" "${gc_log}" 2>/dev/null || echo 0)
        young_count=$(grep -c "Pause Young" "${gc_log}" 2>/dev/null || echo 0)
        mixed_count=$(grep -c "Pause Mixed" "${gc_log}" 2>/dev/null || echo 0)
        echo "  GC: Young=${young_count} Mixed=${mixed_count} Full=${full_count}"
    fi

    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"

    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
BESU_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
Scenario B — Besu 1 GB / 1500 TPS DDoS / HFL + LASS
=====================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Binary: ${BESU_BIN} (commit: ${BESU_COMMIT})
Heap:   -Xms1g -Xmx1g (G1GC, MaxGCPauseMillis=200)
Load:   Caliper fixed-rate 1500 TPS, 120s warmup + 300s measure, 30 workers
TX:     stateBloat 200 slots/tx
LASS-75: activation=0.75, deactivation=0.60, consecutive_samples=1
HFL:    alpha=${HFL_ALPHA}, beta=${HFL_BETA}

Variants:
  baseline        : DISABLED, no LASS
  last_hfl        : HYBRID_FEE_LOCALITY, no LASS
  last_hfl_lass75 : HYBRID_FEE_LOCALITY, LASS-75

Primary metrics: Full GC count, Total GC Time (ms), Max Pause (ms)
EOF

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: Baseline ─────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 1: ${REPLICATIONS}×BASELINE (DISABLED, no LASS)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "baseline" "${i}" "DISABLED" "${NO_LASS}" \
        || echo "  WARNING: baseline_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 2: LAST-HFL (no LASS) ───────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 2: ${REPLICATIONS}×LAST-HFL (no LASS)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_hfl" "${i}" "HYBRID_FEE_LOCALITY" "${NO_LASS}" \
        || echo "  WARNING: last_hfl_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 3: LAST-HFL + LASS-75 ───────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 3: ${REPLICATIONS}×LAST-HFL + LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_hfl_lass75" "${i}" "HYBRID_FEE_LOCALITY" "${LASS75_OPTS}" \
        || echo "  WARNING: last_hfl_lass75_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Final parsing ──────────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PARSING RESULTS"
echo "=============================="

PARSE_SCRIPT="$(dirname "$0")/parse_besu_gc.py"
OUT_CSV="${RESULTS_DIR}/besu_gc_events.csv"

if python3 "${PARSE_SCRIPT}" \
    --results-dir "${RESULTS_DIR}" \
    --out-csv "${OUT_CSV}" \
    > "${RESULTS_DIR}/gc_summary.md" 2>/dev/null; then
    echo "GC summary → ${RESULTS_DIR}/gc_summary.md"
fi

echo ""
echo "======================================================================"
echo "Scenario B complete. Results: ${RESULTS_DIR}"
echo "======================================================================"
