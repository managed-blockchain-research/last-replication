#!/usr/bin/env bash
# RAAC NM eval9 — Dynamic threshold demonstration
# Burst pattern: calm(90s) → attack(120s) → calm(90s) → attack(120s) → calm(60s)
# + 60s warmup.  Total per run ≈ 10 min.
# n=3 RAAC (dynamic threshold) + n=3 baseline interleaved.
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_nm_eval11"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_eval11_run.log"

DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
HEAP_NM=4000000000
NETWORKCONFIG_NM="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
BENCHCONFIG_BASELINE="benchconfig-raac-burst-baseline.yaml"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER="/home/yeochan.yoon/banning/experiments/raac/scripts/parse_gc_nettrace/bin/Release/net10.0/parse_gc_nettrace"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================================================"
echo "RAAC NM eval9 (dynamic threshold, burst attack) | RUN_ID: ${RUN_ID}"
echo "======================================================================"

wait_for_rpc() {
    local port="${1:-8545}"; local max=120; local c=0
    echo -n "  Waiting for RPC"
    while [ $c -lt $max ]; do
        curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:${port} > /dev/null 2>&1 && echo " READY" && return 0
        echo -n "."; sleep 1; c=$((c+1))
    done
    echo " TIMEOUT"; return 1
}

stop_nm() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

restart_ai_service() {
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    nohup python3 serve.py > /tmp/serve_ai.log 2>&1 &
    echo "  AI service restarted (PID $!)"
    sleep 6
    cd /home/yeochan.yoon/caliper-stress-test
}

ensure_ai_service() {
    # Restart to pick up dynamic threshold changes in serve.py
    if ! pgrep -f "serve\.py" > /dev/null 2>&1; then
        echo "  AI service not running — starting..."
        restart_ai_service
    fi
    local c=0
    while [ $c -lt 20 ]; do
        result=$(curl -s --max-time 3 http://127.0.0.1:8000/ 2>/dev/null)
        if echo "${result}" | grep -q '"dynamic_threshold"'; then
            dyn=$(echo "${result}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'threshold={d[\"dynamic_threshold\"]} gc_pressure={d[\"gc_pressure\"]}')" 2>/dev/null || echo "ok")
            echo "  AI service (dynamic): ${dyn}"
            return 0
        fi
        sleep 2; c=$((c+1))
    done
    echo "  AI service failed to respond"; return 1
}

run_nm_single() {
    local variant="$1"; local rep="$2"; local benchcfg="$3"
    local label="${variant}_nm_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"
    local nettrace="${run_dir}/gc_trace.nettrace"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S') | benchcfg=${benchcfg}"
    echo "────────────────────────────────────────────────────────────────"

    if [ "${variant}" = "raac" ]; then
        ensure_ai_service || {
            echo "failed=ai_service_down" > "${run_dir}/FAILED"
            unset RAAC_LOG_DIR 2>/dev/null || true
            return 1; }
    else
        echo "  Baseline run — AI service not required"
    fi

    local raac_log_dir=""
    if [ "${variant}" = "raac" ]; then
        raac_log_dir="${run_dir}/raac_logs"
        rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
        export RAAC_LOG_DIR="${raac_log_dir}"
    else
        unset RAAC_LOG_DIR 2>/dev/null || true
    fi

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    export NETHERMIND_LAST_MODE="DISABLED"
    export DOTNET_GCHeapHardLimit="${HEAP_NM}"
    export COMPlus_GCHeapHardLimit="${HEAP_NM}"
    export COMPlus_GCServer=0
    export DOTNET_GCServer=0
    export DOTNET_EnableDiagnostics=1
    unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    nohup "${DOTNET_BIN}" "${NM_DLL}" --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}" \
        --Blocks.MinGasPrice 0 \
        --TxPool.Size 4096 \
        > "${run_dir}/nm_console.log" 2>&1 &
    local pid=$!; echo "  NM PID: ${pid}"

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
              COMPlus_GCServer DOTNET_GCServer
        unset RAAC_LOG_DIR 2>/dev/null || true
        return 1
    fi
    wait_for_rpc || {
        stop_nm "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
              COMPlus_GCServer DOTNET_GCServer
        unset RAAC_LOG_DIR 2>/dev/null || true
        return 1; }

    node "${DEPLOY_NM}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:\|SB0:" "${run_dir}/deploy.log" || {
        stop_nm "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
              COMPlus_GCServer DOTNET_GCServer
        unset RAAC_LOG_DIR 2>/dev/null || true
        return 1; }
    sleep 5

    local dt_pid=""
    [ -f "${DT_BIN}" ] && {
        "${DT_BIN}" collect --process-id "${pid}" \
            --profile gc-collect \
            --output "${nettrace}" > "${run_dir}/dotnet_trace.log" 2>&1 &
        dt_pid=$!; echo "  dotnet-trace PID: ${dt_pid}"; }

    # Save AI service threshold log for this run
    if [ "${variant}" = "raac" ]; then
        cp /tmp/serve_ai.log "${run_dir}/ai_service.log" 2>/dev/null || true
    fi

    echo "  Running Caliper (60s warmup + 90+120+90+120+60s burst pattern)..."
    timeout 2400 npx caliper launch manager \
        --caliper-workspace ./ --caliper-benchconfig "${benchcfg}" \
        --caliper-networkconfig "${NETWORKCONFIG_NM}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    # Save AI threshold log (captures dynamic adjustments during run)
    if [ "${variant}" = "raac" ]; then
        cp /tmp/serve_ai.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
    fi

    [ -n "${dt_pid}" ] && kill -INT "${dt_pid}" 2>/dev/null || true
    sleep 8; [ -n "${dt_pid}" ] && kill "${dt_pid}" 2>/dev/null || true

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    stop_nm "${pid}"; rm -rf "${data_dir}"
    unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
          COMPlus_GCServer DOTNET_GCServer \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    if [ -f "${nettrace}" ] && [ -f "${GC_PARSER}" ]; then
        local gc_out
        gc_out=$("${GC_PARSER}" "${nettrace}" 2>/dev/null || echo "parse_error")
        echo "${gc_out}" > "${run_dir}/gc_summary.txt"
        echo "  GC: ${gc_out}"
    fi

    if [ "${variant}" = "raac" ] && [ -n "${raac_log_dir}" ]; then
        local total rejects tpr_per_round
        total=$(cat "${raac_log_dir}"/*.jsonl 2>/dev/null | wc -l || echo 0)
        rejects=$(grep -h '"ai_action":"reject"' "${raac_log_dir}"/*.jsonl 2>/dev/null | wc -l || echo 0)
        # Per-round TPR (attack1, attack2)
        for burst in attack1 attack2; do
            local b_total b_rejects
            b_total=$(cat "${raac_log_dir}"/*_${burst}_*.jsonl 2>/dev/null | wc -l || echo 0)
            b_rejects=$(grep -h '"ai_action":"reject"' "${raac_log_dir}"/*_${burst}_*.jsonl 2>/dev/null | wc -l || echo 0)
            [ "${b_total}" -gt 0 ] && echo "  ${burst}: rejects=${b_rejects}/${b_total} TPR=$(echo "scale=1; ${b_rejects}*100/${b_total}" | bc)%"
        done
        echo "  RAAC total: rejects=${rejects}/${total}"
        unset RAAC_LOG_DIR
    fi

    grep "| attack-burst\|calm\|warmup" "${run_dir}/caliper_console.log" 2>/dev/null | \
        grep "Transaction\|Summary" | tail -10 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}

# Restart AI service with dynamic threshold serve.py
echo ""
echo "=============================="
echo "Restarting AI service (dynamic threshold)..."
echo "=============================="
restart_ai_service

echo ""
echo "=============================="; echo "Interleaved: 3×RAAC + 3×BASELINE (burst pattern)"; echo "=============================="

for i in 1 2 3; do
    run_nm_single "raac"     "${i}" "${BENCHCONFIG_RAAC}"     || echo "  WARNING: raac_nm_${i} failed"
    sleep 15
    run_nm_single "baseline" "${i}" "${BENCHCONFIG_BASELINE}" || echo "  WARNING: baseline_nm_${i} failed"
    [ "${i}" -lt 3 ] && sleep 15
done

echo ""
echo "======================================================================"
echo "eval9 COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"
