#!/bin/bash
# ============================================================
# Scenario A — Sustainable Normal Operations (Besu 4 GB / 40 TPS)
#
# Goal: Measure LAST scheduler warm-hit rate across all 4 variants.
# At 4 GB heap the workload generates ~22 MB/min of old-gen growth;
# LASS never fires. Primary metric = LASTMetricsLogger warm_hit_rate.
#
# Note on confirmed TPS: StateBloater 200-slot txs cost ~4 M gas each.
# At mainnet-realistic block gas limits, Besu confirms ~1–4 TPS despite
# 40 TPS being submitted. The pending queue (~4800 txs after warmup)
# gives the scheduler ample candidates to reorder every block. Warm-hit
# rate is captured server-side and is valid regardless of confirmed TPS.
# This is documented as a characteristic of the workload, not a flaw.
#
# Variants (4 × 3 reps = 12 runs):
#   baseline  : DISABLED
#   last_al   : ADDRESS_LOCALITY
#   last_wsa  : WORKING_SET_AFFINITY
#   last_hfl  : HYBRID_FEE_LOCALITY (alpha=0.5, beta=0.5)
#
# Output: results/scenario_a_besu_4g/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Binaries ──────────────────────────────────────────────────────────────────
BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"

# ── Caliper config ────────────────────────────────────────────────────────────
BENCHCONFIG="benchconfig-scenario-a-40tps.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

# ── Run parameters ────────────────────────────────────────────────────────────
HEAP="4g"
REPLICATIONS=3
# LASS disabled: activation threshold > 1.0 is never reached
NO_LASS="-Dlass.old.gen.activation.threshold=2.0"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"

# ── Output directory ──────────────────────────────────────────────────────────
RUN_ID=$(date +%Y%m%d_%H%M%S)_scenario_a_besu_4g
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/scenario_a_besu_4g/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "Scenario A — Besu 4 GB / 40 TPS / 3 reps / 4 variants"
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

# run_single VARIANT REP LAST_VARIANT_FLAG
run_single() {
    local variant="$1"
    local rep="$2"
    local last_flag="$3"   # e.g. "-Dlast.variant=WORKING_SET_AFFINITY"
    local extra_flags="${4:-}"  # e.g. "-Dlast.alpha=0.5 -Dlast.beta=0.5"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_sca_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"
    local last_csv="${run_dir}/last_metrics.csv"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  LAST: ${last_flag} ${extra_flags}"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=3,filesize=50M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${last_flag} ${extra_flags} \
-Dlast.log.path=${last_csv} \
${NO_LASS}"

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

    echo "  Running Caliper (120s warmup + 300s measure @ 40 TPS)..."
    local t_start
    t_start=$(date +%s)

    timeout 900 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1
    local caliper_exit=$?

    local t_end
    t_end=$(date +%s)
    echo "  Caliper exit: ${caliper_exit}. Elapsed: $((t_end - t_start))s"

    cp caliper.log "${run_dir}/caliper.log"   2>/dev/null || true
    cp report.html "${run_dir}/report.html"   2>/dev/null || true

    echo "  Stopping Besu..."
    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    # Quick summaries
    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"

    if [ -f "${last_csv}" ]; then
        local blocks
        blocks=$(wc -l < "${last_csv}")
        echo "  LASTMetrics: ${blocks} blocks logged → ${last_csv}"
    else
        echo "  LASTMetrics: not produced (LASTMetricsLogger inactive or unsupported variant)"
    fi

    if [ -f "${gc_log}" ]; then
        local full_count
        full_count=$(grep -c "Pause Full" "${gc_log}" || echo 0)
        echo "  GC Full pauses: ${full_count}"
    fi

    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
BESU_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
Scenario A — Besu 4 GB / 40 TPS / LAST Variants
==================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Binary: ${BESU_BIN} (commit: ${BESU_COMMIT})
Heap:   -Xms4g -Xmx4g (G1GC, MaxGCPauseMillis=200)
LASS:   DISABLED (activation.threshold=2.0, never fires at 4 GB in this workload)
Load:   Caliper fixed-rate 40 TPS, 120s warmup + 300s measure, 30 workers
TX:     stateBloat 200 slots/tx (~4 M gas each)

Confirmed TPS note:
  StateBloater 200-slot txs cost ~4 M gas each. With mainnet-realistic
  block gas limits, Besu confirms ~1–4 TPS despite 40 TPS submission.
  The resulting deep mempool (~4800 pending txs after warmup) is the
  ideal environment for measuring LAST scheduler locality: the scheduler
  sees a large candidate set to reorder on every block. Warm-hit rate
  is captured per-block by LASTMetricsLogger (last_metrics.csv) and is
  valid regardless of confirmed TPS.

Variants:
  baseline : DISABLED
  last_al  : ADDRESS_LOCALITY
  last_wsa : WORKING_SET_AFFINITY
  last_hfl : HYBRID_FEE_LOCALITY (alpha=0.5, beta=0.5)

Metrics:
  Primary:   last_metrics.csv (warm_hit_rate, scheduler_overhead_us per block)
  Secondary: gc_besu.log (G1GC unified log — expect Young-only at 4 GB)
EOF

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: Baseline ─────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 1: ${REPLICATIONS}×BASELINE (DISABLED)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "baseline" "${i}" "-Dlast.variant=DISABLED" \
        || echo "  WARNING: baseline_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 2: LAST-AL ──────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 2: ${REPLICATIONS}×LAST-AL (ADDRESS_LOCALITY)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_al" "${i}" "-Dlast.variant=ADDRESS_LOCALITY" \
        || echo "  WARNING: last_al_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 3: LAST-WSA ─────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 3: ${REPLICATIONS}×LAST-WSA (WORKING_SET_AFFINITY)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_wsa" "${i}" "-Dlast.variant=WORKING_SET_AFFINITY" \
        || echo "  WARNING: last_wsa_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 4: LAST-HFL ─────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 4: ${REPLICATIONS}×LAST-HFL (HYBRID_FEE_LOCALITY, α=0.5, β=0.5)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_hfl" "${i}" \
        "-Dlast.variant=HYBRID_FEE_LOCALITY" "-Dlast.alpha=0.5 -Dlast.beta=0.5" \
        || echo "  WARNING: last_hfl_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Final parsing ──────────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PARSING RESULTS"
echo "=============================="

PARSE_SCRIPT="$(dirname "$0")/parse_besu_gc.py"
SUMMARY_SCRIPT="$(dirname "$0")/summarize_last_metrics.py"
OUT_CSV="${RESULTS_DIR}/besu_gc_events.csv"

if python3 "${PARSE_SCRIPT}" \
    --results-dir "${RESULTS_DIR}" \
    --out-csv "${OUT_CSV}" \
    > "${RESULTS_DIR}/gc_summary.md" 2>/dev/null; then
    echo "GC summary → ${RESULTS_DIR}/gc_summary.md"
fi

if python3 "${SUMMARY_SCRIPT}" \
    --results-dir "${RESULTS_DIR}" \
    > "${RESULTS_DIR}/last_metrics_summary.md" 2>/dev/null; then
    echo "LASTMetrics summary → ${RESULTS_DIR}/last_metrics_summary.md"
fi

echo ""
echo "======================================================================"
echo "Scenario A complete. Results: ${RESULTS_DIR}"
echo "======================================================================"
