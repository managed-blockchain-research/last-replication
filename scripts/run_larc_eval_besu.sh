#!/bin/bash
# ============================================================
# LARC Evaluation Harness — Besu @ 4 GB heap
#
# 6 variants × REPS replications, interleaved per rep:
#   baseline   : no LARC, no LAST
#   lass_compat: LARC LASS_COMPAT mode (threshold spill + true reclaim)
#   larc_la    : LARC LOCALITY_AWARE, LAST DISABLED
#   larc_al    : LARC LOCALITY_AWARE + LAST ADDRESS_LOCALITY
#   larc_wsa   : LARC LOCALITY_AWARE + LAST WORKING_SET_AFFINITY
#   larc_hfl   : LARC LOCALITY_AWARE + LAST HYBRID_FEE_LOCALITY
#
# Binary: besu-source (patched with build_larc.sh)
# Load:   120s warmup + 300s measure, 150 TPS, 30 workers, 30 contracts
# TX:     stateBloat 200 slots/tx
# GC:     JVM G1GC unified log per run + larc_counters.csv + larc_decisions.csv
# Output: results/larc_eval_besu/<RUN_ID>/
#
# Usage:
#   bash run_larc_eval_besu.sh [--reps N] [--bench smoke|full] [--heap H]
#   bash run_larc_eval_besu.sh --reps 1 --bench smoke    # quick check
#   bash run_larc_eval_besu.sh --reps 3 --bench full     # full experiment
# ============================================================
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
JAVA_HOME_17="/usr/lib/jvm/java-17-openjdk-17.0.13.0.11-3.el8.x86_64"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
REPLICATIONS=3
BENCH="full"
CALIPER_TIMEOUT=1500
COOLDOWN=20

RUN_ID="$(date +%Y%m%d_%H%M%S)_larc_eval_besu"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/larc_eval_besu/${RUN_ID}"

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reps)   REPLICATIONS="$2"; shift 2 ;;
    --bench)  BENCH="$2"; shift 2 ;;
    --heap)   HEAP="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/larc_eval_besu/${RUN_ID}"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

BENCHCONFIG="benchconfig-larc-${BENCH}.yaml"

mkdir -p "${RESULTS_DIR}"

export JAVA_HOME="${JAVA_HOME_17}"
export PATH="${JAVA_HOME_17}/bin:${PATH}"

# ── Variant definitions ───────────────────────────────────────────────────────
declare -A VARIANT_LAST VARIANT_LARC
VARIANT_LAST[baseline]="DISABLED"
VARIANT_LARC[baseline]="DISABLED"

VARIANT_LAST[lass_compat]="DISABLED"
VARIANT_LARC[lass_compat]="LASS_COMPAT"

VARIANT_LAST[larc_la]="DISABLED"
VARIANT_LARC[larc_la]="LOCALITY_AWARE"

VARIANT_LAST[larc_al]="ADDRESS_LOCALITY"
VARIANT_LARC[larc_al]="LOCALITY_AWARE"

VARIANT_LAST[larc_wsa]="WORKING_SET_AFFINITY"
VARIANT_LARC[larc_wsa]="LOCALITY_AWARE"

VARIANT_LAST[larc_hfl]="HYBRID_FEE_LOCALITY"
VARIANT_LARC[larc_hfl]="LOCALITY_AWARE"

VARIANTS=(baseline lass_compat larc_la larc_al larc_wsa larc_hfl)

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max=120 count=0
    echo -n "  Waiting for RPC"
    while [ "${count}" -lt "${max}" ]; do
        if curl -sf --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"; return 0
        fi
        echo -n "."; sleep 1; count=$((count+1))
    done
    echo " TIMEOUT"; return 1
}

stop_besu() {
    local pid="${1:-}"
    if [[ -n "${pid}" ]]; then
        kill "${pid}" 2>/dev/null || true
        local w=0
        while kill -0 "${pid}" 2>/dev/null && [ "${w}" -lt 30 ]; do sleep 1; w=$((w+1)); done
    fi
    pkill -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

run_single() {
    local variant="$1"
    local rep="$2"
    local last_flag="${VARIANT_LAST[$variant]}"
    local larc_flag="${VARIANT_LARC[$variant]}"

    local label="${variant}_rep${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/tmp/larc_besu_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"
    local last_csv="${run_dir}/last_metrics.csv"
    local larc_decisions="${run_dir}/larc_decisions.csv"
    local larc_counters="${run_dir}/larc_counters.csv"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | last=${last_flag} larc=${larc_flag} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    stop_besu
    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
-XX:+UnlockExperimentalVMOptions \
-XX:G1MaxNewSizePercent=90 \
-XX:G1NewSizePercent=20 \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=3,filesize=50M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
-Dlast.variant=${last_flag} \
-Dlast.log.path=${last_csv} \
-Dlarc.mode=${larc_flag} \
-Dlarc.decision.log=${larc_decisions} \
-Dlarc.counter.log=${larc_counters} \
-Dlarc.activate.heap.ratio=0.70 \
-Dlarc.deactivate.heap.ratio=0.55"

    export BESU_OPTS="${java_opts}"

    echo "  Starting Besu (heap=${HEAP}) ..."
    nohup "${BESU_BIN}" \
        --network=dev \
        --miner-enabled \
        --miner-coinbase=0xBE0cf996DE312b11990E4BcbBf7Fc156880AcFC8 \
        --data-path="${data_dir}" \
        --rpc-http-enabled --rpc-http-port=8545 --rpc-http-host=0.0.0.0 \
        --rpc-http-cors-origins="*" \
        --rpc-ws-enabled --rpc-ws-port=8546 \
        --rpc-ws-max-active-connections=200 \
        --rpc-http-max-active-connections=200 \
        --host-allowlist="*" \
        --min-gas-price=0 \
        --tx-pool-layer-max-capacity=1000000 \
        --tx-pool-max-prioritized=1000000 \
        --tx-pool-max-future-by-sender=100000 \
        --logging=INFO \
        > "${run_dir}/besu_console.log" 2>&1 &
    local besu_pid=$!
    echo "${besu_pid}" > "${run_dir}/besu.pid"

    if ! wait_for_rpc; then
        echo "  ERROR: RPC not ready"
        echo "failed=rpc" > "${run_dir}/FAILED"
        stop_besu "${besu_pid}"; return 1
    fi

    echo "  Deploying 30 StateBloater contracts ..."
    python3 "${DEPLOY_SCRIPT}" 30 > "${run_dir}/deploy.log" 2>&1
    if ! grep -q "Contract Address:\|All 30 contracts deployed" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed:"
        tail -5 "${run_dir}/deploy.log"
        echo "failed=deploy" > "${run_dir}/FAILED"
        stop_besu "${besu_pid}"; return 1
    fi
    sleep 3

    echo "  Running Caliper (${BENCHCONFIG}) ..."
    local t_start; t_start=$(date +%s)
    timeout "${CALIPER_TIMEOUT}" npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true
    local t_end; t_end=$(date +%s)
    echo "  Caliper done. Elapsed: $(( t_end - t_start ))s"

    cp caliper.log  "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html  "${run_dir}/report.html"  2>/dev/null || true

    stop_besu "${besu_pid}"

    # Extract key metrics from caliper console
    local measure_line; measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    if [[ -n "${measure_line}" ]]; then
        echo "  ${measure_line}"
        # Columns: | Name | Succ | Fail | SendRate | MaxLat | MinLat | AvgLat | Throughput |
        #            $2     $3     $4    $5         $6       $7       $8       $9
        local tps avg_s
        tps=$(echo "${measure_line}" | awk -F'|' '{print $9}' | tr -d ' ')
        avg_s=$(echo "${measure_line}" | awk -F'|' '{print $8}' | tr -d ' ')
        echo "{\"tps\": ${tps:-null}, \"p99_s\": ${avg_s:-null}}" > "${run_dir}/metrics.json" 2>/dev/null || true
    fi

    echo "  Saved → ${run_dir}"
    sleep "${COOLDOWN}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "LARC Evaluation — Besu  RUN_ID=${RUN_ID}"
echo "Variants: ${VARIANTS[*]}"
echo "Reps    : ${REPLICATIONS}"
echo "Bench   : ${BENCHCONFIG}"
echo "Heap    : ${HEAP}"
echo "Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

TOTAL=$(( ${#VARIANTS[@]} * REPLICATIONS ))
RUN_NUM=0

# Interleaved: rep1 of all variants → rep2 of all variants → ...
for rep in $(seq 1 "${REPLICATIONS}"); do
    for variant in "${VARIANTS[@]}"; do
        RUN_NUM=$((RUN_NUM+1))
        echo ""
        echo "[${RUN_NUM}/${TOTAL}] ${variant} rep${rep}"
        run_single "${variant}" "${rep}" || echo "  SKIPPED (error)"
    done
    echo ""
    echo "=== Rep ${rep}/${REPLICATIONS} complete. Inter-rep cooldown 60s ==="
    sleep 60
done

echo ""
echo "======================================================================"
echo "LARC Besu eval COMPLETE. Results: ${RESULTS_DIR}"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
