#!/bin/bash
# ============================================================
# NM Capacity Sweep — find highest stable TPS for StateBloater workload
#
# Runs NM smoke test at 25, 50, 75, 100, 150 TPS.
# Selects highest TPS with >=95% success rate and valid GC data.
#
# Usage:
#   bash scripts/run_nm_capacity_sweep.sh
#   bash scripts/run_nm_capacity_sweep.sh --tps 25,50,75,100,150
# ============================================================
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
NETWORKCONFIG="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
CALIPER_TIMEOUT=600
WARMUP_S=60
MEASURE_S=120

RUN_ID="$(date +%Y%m%d_%H%M%S)_nm_capacity_sweep"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/nm_capacity_sweep/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

TPS_LEVELS=(25 50 75 100 150)

# Parse --tps flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tps) IFS=',' read -ra TPS_LEVELS <<< "$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}"
export DOTNET_EnableDiagnostics=1

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
    local tps="$1" outfile="$2"
    local workers=30
    # Scale workers for very low TPS (at least 5 workers)
    if [[ "${tps}" -le 25 ]]; then workers=10; fi
    if [[ "${tps}" -le 10 ]]; then workers=5; fi
    cat > "${outfile}" <<EOF
test:
  name: nm-sweep-${tps}tps
  description: NM capacity sweep at ${tps} TPS, ${WARMUP_S}s warmup + ${MEASURE_S}s measure
  workers:
    type: local
    number: ${workers}
  rounds:
    - label: warmup
      txDuration: ${WARMUP_S}
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
    - label: measure
      txDuration: ${MEASURE_S}
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

run_sweep_rep() {
    local tps="$1"
    local run_dir="${RESULTS_DIR}/nm_sweep_${tps}tps"
    mkdir -p "${run_dir}"
    local benchcfg="/tmp/benchconfig_nm_sweep_${tps}tps.yaml"
    make_benchconfig "${tps}" "${benchcfg}"
    local data_dir="/tmp/larc_nm_sweep_${tps}_${RUN_ID}"

    echo ""
    echo "──────────────────────────────────────────────────────────────"
    echo "SWEEP: ${tps} TPS | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "──────────────────────────────────────────────────────────────"

    stop_nm
    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    echo "  Starting Nethermind ..."
    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}/nm_db" \
        --Init.LogFileName "${data_dir}/nm.log" \
        > "${run_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "${nm_pid}" > "${run_dir}/nm.pid"

    if ! wait_for_rpc; then
        echo "  ERROR: RPC not ready"
        echo '{"result":"rpc_timeout"}' > "${run_dir}/sweep_result.json"
        stop_nm "${nm_pid}"; return 1
    fi

    echo "  Deploying 30 StateBloater contracts ..."
    node "${DEPLOY_NM}" 30 "${NETWORKCONFIG}" > "${run_dir}/deploy.log" 2>&1 || true
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed"
        echo '{"result":"deploy_failed"}' > "${run_dir}/sweep_result.json"
        stop_nm "${nm_pid}"; return 1
    fi
    sleep 3

    # Start dotnet-counters
    local counter_dur="00:04:00"  # 4 min should cover 60s warmup + 120s measure + buffer
    "${DOTNET_BIN}" dotnet-counters collect \
        --process-id "${nm_pid}" \
        --counters "System.Runtime" \
        --refresh-interval 1 \
        --duration "${counter_dur}" \
        --format csv \
        --output "${run_dir}/dotnet_counters.csv" \
        > "${run_dir}/dotnet_counters.log" 2>&1 &
    local dc_pid=$!
    echo "  dotnet-counters PID=${dc_pid}"

    echo "  Running Caliper at ${tps} TPS ..."
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

    # Parse results
    local measure_line succ fail tps_actual avg_s
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    if [[ -n "${measure_line}" ]]; then
        echo "  MEASURE: ${measure_line}"
        succ=$(echo "${measure_line}" | awk -F'|' '{print $3}' | tr -d ' ')
        fail=$(echo "${measure_line}" | awk -F'|' '{print $4}' | tr -d ' ')
        tps_actual=$(echo "${measure_line}" | awk -F'|' '{print $9}' | tr -d ' ')
        avg_s=$(echo "${measure_line}" | awk -F'|' '{print $8}' | tr -d ' ')
        local total=$(( ${succ:-0} + ${fail:-0} ))
        local success_rate=0
        if [[ "${total}" -gt 0 ]]; then
            success_rate=$(awk "BEGIN{printf \"%.1f\", ${succ:-0}/${total}*100}")
        fi
        # Check if dotnet_counters.csv has GC data
        local has_gc_data="false"
        if [[ -f "${run_dir}/dotnet_counters.csv" ]] && \
           grep -qi "time-in-gc\|gen-0\|gen-1\|gen-2\|gc" "${run_dir}/dotnet_counters.csv" 2>/dev/null; then
            has_gc_data="true"
        fi
        local result="{\"tps_target\": ${tps}, \"tps_actual\": ${tps_actual:-0}, \"succ\": ${succ:-0}, \"fail\": ${fail:-0}, \"total\": ${total}, \"success_rate_pct\": ${success_rate}, \"avg_lat_s\": \"${avg_s:-null}\", \"has_gc_data\": ${has_gc_data}}"
        echo "${result}" > "${run_dir}/sweep_result.json"
        echo "  RESULT: succ=${succ} fail=${fail} rate=${success_rate}% tps=${tps_actual} gc_data=${has_gc_data}"
    else
        echo '{"result":"no_measure_line"}' > "${run_dir}/sweep_result.json"
        echo "  RESULT: No measure line found (stuck/timeout)"
    fi

    rm -f "${benchcfg}"
    echo "  Saved → ${run_dir}"
    sleep 30  # cooldown between runs
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "NM Capacity Sweep  RUN_ID=${RUN_ID}"
echo "TPS levels: ${TPS_LEVELS[*]}"
echo "Workload: StateBloater 200 slots/tx, 30 contracts"
echo "Duration: ${WARMUP_S}s warmup + ${MEASURE_S}s measure per level"
echo "Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

for tps in "${TPS_LEVELS[@]}"; do
    run_sweep_rep "${tps}" || echo "  Level ${tps} TPS failed, continuing..."
done

echo ""
echo "======================================================================"
echo "SWEEP COMPLETE. Summary:"
echo ""
for tps in "${TPS_LEVELS[@]}"; do
    rf="${RESULTS_DIR}/nm_sweep_${tps}tps/sweep_result.json"
    if [[ -f "${rf}" ]]; then
        echo "  ${tps} TPS: $(cat ${rf})"
    fi
done
echo ""
echo "Results: ${RESULTS_DIR}"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
