#!/bin/bash
# ============================================================
# NM LARC Sanity Check — 3-variant × 1-rep
#
# PURPOSE: SANITY CHECK ONLY — not paper-quality data.
# Verifies instrumentation correctness at 1 TPS / 200-slot TXs.
# Results → results/larc/nm_sanity_1tps_200slot/
#
# Variants: nm_baseline, nm_lass_compat, nm_larc_la
# Usage:
#   bash scripts/run_nm_sanity_1tps.sh
#   bash scripts/run_nm_sanity_1tps.sh --variants nm_baseline
# ============================================================
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
NETWORKCONFIG="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"

# Calibrated settings: 1 TPS = NM's effective ceiling for 200-slot TXs
TARGET_TPS=1
NUM_WORKERS=2
MEASURE_S=120
CALIPER_TIMEOUT=300
COOLDOWN=20

VARIANTS=(nm_baseline nm_lass_compat nm_larc_la)
REPLICATIONS=1

RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/larc/nm_sanity_1tps_200slot"
RUN_ID="nm_sanity_1tps_200slot"

# ── Parse flags ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variants) IFS=',' read -ra VARIANTS <<< "$2"; shift 2 ;;
    --reps)     REPLICATIONS="$2"; shift 2 ;;
    --tps)      TARGET_TPS="$2"; shift 2 ;;
    --run-id)   RUN_ID="$2"; RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/larc/nm_sanity_1tps_200slot/${RUN_ID}"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

mkdir -p "${RESULTS_DIR}"
export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}"
export DOTNET_EnableDiagnostics=1

# ── Helpers ────────────────────────────────────────────────────────────────
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

stop_nm() {
    local pid="${1:-}"
    if [[ -n "${pid}" ]]; then
        kill "${pid}" 2>/dev/null || true
        local w=0
        while kill -0 "${pid}" 2>/dev/null && [ "${w}" -lt 30 ]; do sleep 1; w=$((w+1)); done
    fi
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

make_benchconfig() {
    local tps="$1" workers="$2" dur="$3" outfile="$4"
    cat > "${outfile}" << EOF
test:
  name: NM LARC Eval
  description: LARC portability evaluation on Nethermind CLR runtime
  workers:
    number: ${workers}
  rounds:
    - label: measure
      txDuration: ${dur}
      rateControl:
        type: fixed-rate
        opts:
          tps: ${tps}
      workload:
        module: benchmarks/stateBloat.js
        arguments:
          slotsPerTx: 200
          numContracts: 30
          contractPrefix: SB
EOF
}

run_variant_rep() {
    local variant="$1" rep="$2"
    local run_dir="${RESULTS_DIR}/${variant}_rep${rep}"
    mkdir -p "${run_dir}"

    # Map variant name to LARC mode
    local larc_mode="DISABLED"
    case "${variant}" in
        nm_lass_compat) larc_mode="LASS_COMPAT" ;;
        nm_larc_la)     larc_mode="LOCALITY_AWARE" ;;
    esac

    local data_dir="/tmp/larc_nm_${variant}_rep${rep}_${RUN_ID}"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "VARIANT=${variant} REP=${rep} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "NM_LARC_MODE=${larc_mode} | TPS=${TARGET_TPS} | MEASURE=${MEASURE_S}s"
    echo "────────────────────────────────────────────────────────────────"

    stop_nm
    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    echo "  Starting Nethermind ..."
    NM_LARC_MODE="${larc_mode}" \
    NM_LARC_ACTIVATE_MB="300" \
    NM_LARC_DEACTIVATE_MB="200" \
    NM_LARC_DATA_DIR="${run_dir}" \
    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}/nm_db" \
        --Init.LogFileName "${data_dir}/nm.log" \
        > "${run_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "${nm_pid}" > "${run_dir}/nm.pid"

    if ! wait_for_rpc; then
        echo "  ERROR: RPC not ready"
        echo '{"result":"rpc_timeout"}' > "${run_dir}/result.json"
        stop_nm "${nm_pid}"; return 1
    fi

    echo "  Deploying 30 StateBloater contracts ..."
    node "${DEPLOY_NM}" 30 "${NETWORKCONFIG}" > "${run_dir}/deploy.log" 2>&1 || true
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed"
        echo '{"result":"deploy_failed"}' > "${run_dir}/result.json"
        stop_nm "${nm_pid}"; return 1
    fi
    sleep 3

    local benchcfg="/tmp/benchconfig_nm_larc_${variant}_rep${rep}.yaml"
    make_benchconfig "${TARGET_TPS}" "${NUM_WORKERS}" "${MEASURE_S}" "${benchcfg}"

    # dotnet-counters: 10 min covers 300s measure + buffer
    local dc_dur="00:10:00"
    "${DOTNET_BIN}" dotnet-counters collect \
        --process-id "${nm_pid}" \
        --counters "System.Runtime" \
        --refresh-interval 1 \
        --duration "${dc_dur}" \
        --format csv \
        --output "${run_dir}/dotnet_counters.csv" \
        > "${run_dir}/dotnet_counters.log" 2>&1 &
    local dc_pid=$!
    echo "  dotnet-counters PID=${dc_pid}"

    echo "  Running Caliper at ${TARGET_TPS} TPS for ${MEASURE_S}s ..."
    local t_start; t_start=$(date +%s)
    timeout "${CALIPER_TIMEOUT}" npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${benchcfg}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true
    local t_end; t_end=$(date +%s)
    echo "  Caliper done. Elapsed: $(( t_end - t_start ))s"

    cp caliper.log  "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html  "${run_dir}/report.html"  2>/dev/null || true
    wait "${dc_pid}" 2>/dev/null || true
    stop_nm "${nm_pid}"

    # Parse measure results
    local measure_line succ fail tps_actual avg_s
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || true)
    if [[ -n "${measure_line}" ]]; then
        echo "  MEASURE: ${measure_line}"
        succ=$(echo "${measure_line}" | awk -F'|' '{print $3}' | tr -d ' ')
        fail=$(echo "${measure_line}" | awk -F'|' '{print $4}' | tr -d ' ')
        tps_actual=$(echo "${measure_line}" | awk -F'|' '{print $9}' | tr -d ' ')
        avg_s=$(echo "${measure_line}" | awk -F'|' '{print $8}' | tr -d ' ')
        local total=$(( ${succ:-0} + ${fail:-0} ))
        local success_rate=0
        if [[ "${total}" -gt 0 ]]; then
            success_rate=$(python3 -c "print(round(100.0*${succ:-0}/${total},1))")
        fi
        cat > "${run_dir}/result.json" << EOJSON
{"variant":"${variant}","rep":${rep},"succ":${succ:-0},"fail":${fail:-0},"success_rate_pct":${success_rate},"tps_actual":${tps_actual:-0},"avg_lat_s":${avg_s:-0},"larc_mode":"${larc_mode}"}
EOJSON
        echo "  RESULT: Succ=${succ} Fail=${fail} Rate=${success_rate}% TPS=${tps_actual}"
    else
        echo "  RESULT: No measure line (stuck/timeout)"
        echo '{"result":"no_measure_line"}' > "${run_dir}/result.json"
    fi
    echo "  Saved → ${run_dir}"
    sleep "${COOLDOWN}"
}

# ── Main ────────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "NM LARC Evaluation  RUN_ID=${RUN_ID}"
echo "Variants: ${VARIANTS[*]}"
echo "Reps    : ${REPLICATIONS}"
echo "TPS     : ${TARGET_TPS} (calibrated for NM 200-slot capacity)"
echo "Measure : ${MEASURE_S}s"
echo "NM DLL  : ${NM_DLL}"
echo "Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

for variant in "${VARIANTS[@]}"; do
    for rep in $(seq 1 "${REPLICATIONS}"); do
        run_variant_rep "${variant}" "${rep}" || echo "  SKIPPED (error)"
    done
done

echo ""
echo "======================================================================"
echo "NM LARC Eval COMPLETE. Results: ${RESULTS_DIR}"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

echo ""; echo "=== SUMMARY ==="
for variant in "${VARIANTS[@]}"; do
    echo "--- ${variant} ---"
    for rep in $(seq 1 "${REPLICATIONS}"); do
        local_dir="${RESULTS_DIR}/${variant}_rep${rep}"
        [[ -f "${local_dir}/result.json" ]] && cat "${local_dir}/result.json" || echo "  (missing)"
    done
done
