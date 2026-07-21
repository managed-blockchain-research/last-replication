#!/bin/bash
# ============================================================
# Nethermind LASS Sensitivity: ctrl + lass60 + lass75 + lass90
# Using Caliper fixed-rate 1500 TPS, 600s, 30 workers.
#
# GC control via CLR env vars:
#   ctrl:   no heap limit
#   lass60: DOTNET_GCHeapHardLimit=1000000000 + GCHighMemPercent=60
#   lass75: DOTNET_GCHeapHardLimit=1000000000 + GCHighMemPercent=75
#   lass90: DOTNET_GCHeapHardLimit=1000000000 + GCHighMemPercent=90
#
# GC metrics collected via dotnet-counters collect (CSV per run).
# Output: results/validation_nethermind/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

NM_DLL="/home/yeochan.yoon/nethermind/src/Nethermind/artifacts/bin/Nethermind.Runner/release/nethermind.dll"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
BENCHCONFIG="benchconfig-nm-sensitivity.yaml"
NETWORKCONFIG="networkconfig_nethermind_caliper.json"
DEPLOY_SCRIPT="deploy_contract_nethermind_caliper.js"

RUN_ID=$(date +%Y%m%d_%H%M%S)_nm_sensitivity
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/validation_nethermind/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

HEAP_HARD_LIMIT=1000000000
REPLICATIONS=5

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}:${HOME}/.dotnet/tools"

echo "======================================================================"
echo "NM Sensitivity: ctrl + lass60 + lass75 + lass90 | 1500 TPS | 600s"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

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

stop_nm() {
    local nm_pid="$1"
    kill "${nm_pid}" 2>/dev/null || true
    local wait=0
    while kill -0 "${nm_pid}" 2>/dev/null && [ ${wait} -lt 30 ]; do
        sleep 1; wait=$((wait+1))
    done
    kill -9 "${nm_pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

run_single() {
    local variant="$1"
    local rep="$2"
    local gc_high_mem_pct="$3"   # empty string = no heap limit (ctrl)

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_nm_caliper_${label}_${RUN_ID}"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    # Set CLR GC env vars
    if [ -n "${gc_high_mem_pct}" ]; then
        export DOTNET_GCHeapHardLimit="${HEAP_HARD_LIMIT}"
        export COMPlus_GCHeapHardLimit="${HEAP_HARD_LIMIT}"
        export DOTNET_GCHighMemPercent="${gc_high_mem_pct}"
        export COMPlus_GCHighMemPercent="${gc_high_mem_pct}"
        echo "  GC: HeapHardLimit=${HEAP_HARD_LIMIT} GCHighMemPercent=${gc_high_mem_pct}"
    else
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit 2>/dev/null || true
        unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        echo "  GC: no heap limit (ctrl)"
    fi

    export DOTNET_EnableDiagnostics=1

    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}" \
        --Blocks.MinGasPrice 0 \
        > "${data_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "  Nethermind PID: ${nm_pid}"

    sleep 8
    if ! kill -0 ${nm_pid} 2>/dev/null; then
        echo "  ERROR: Nethermind died at startup."
        tail -20 "${data_dir}/nm_console.log" || true
        echo "  failed=startup" > "${run_dir}/FAILED"
        # Clear GC env vars before returning
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        return 1
    fi

    wait_for_rpc 8545 || {
        stop_nm "${nm_pid}"
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        return 1
    }

    echo "  Deploying StateBloater contract..."
    node "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | awk '{print $3}')
    if [ -z "${contract_addr}" ]; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_nm "${nm_pid}"
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        return 1
    fi
    echo "  Contract: ${contract_addr}"

    sleep 5

    # Start dotnet-trace GC collection (dotnet-counters incompatible with .NET 10)
    local nettrace_file="${run_dir}/gc_trace.nettrace"
    local dotnet_trace_pid=""
    local DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
    if [ -f "${DT_BIN}" ]; then
        "${DT_BIN}" collect \
            --process-id "${nm_pid}" \
            --providers "Microsoft-Windows-DotNETRuntime:0x1:5" \
            --output "${nettrace_file}" \
            > "${run_dir}/dotnet_trace.log" 2>&1 &
        dotnet_trace_pid=$!
        echo "  dotnet-trace PID: ${dotnet_trace_pid}"
    else
        echo "  WARNING: dotnet-trace not found — GC trace unavailable"
    fi

    echo "  Running Caliper (600s @ 1500 TPS)..."
    local t_start
    t_start=$(date +%s)

    timeout 720 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        --caliper-txTimeout 60 \
        > "${run_dir}/caliper_console.log" 2>&1
    local caliper_exit=$?

    local t_end
    t_end=$(date +%s)
    echo "  Caliper exit: ${caliper_exit}. Elapsed: $((t_end - t_start))s"

    # Stop dotnet-trace (sends SIGINT to finalize the nettrace file)
    if [ -n "${dotnet_trace_pid}" ] && kill -0 "${dotnet_trace_pid}" 2>/dev/null; then
        kill -INT "${dotnet_trace_pid}" 2>/dev/null || true
        sleep 5
        kill "${dotnet_trace_pid}" 2>/dev/null || true
    fi

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    cp "${data_dir}/nm_console.log" "${run_dir}/nm_console.log" 2>/dev/null || true

    echo "  Stopping Nethermind..."
    stop_nm "${nm_pid}"
    rm -rf "${data_dir}"

    # Unset GC env vars
    unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    # Parse GC metrics from nettrace
    local GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"
    if [ -f "${nettrace_file}" ] && [ -f "${GC_PARSER}" ]; then
        echo "  Parsing GC trace..."
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace_file}" 2>/dev/null \
            | tee "${run_dir}/gc_summary.txt" \
            | sed 's/^/    /'
    fi

    echo "  ✓ ${label} complete"
}

# Pre-flight
pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 3

LASS_COMMIT=$(cd /home/yeochan.yoon/nethermind && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
Nethermind Sensitivity — ctrl + LASS-60 + LASS-75 + LASS-90
=============================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Binary: ${NM_DLL} (commit: ${LASS_COMMIT})
Config: ${NM_CFG}
GC:     COMPlus_GCHeapHardLimit=1000000000 + COMPlus_GCHighMemPercent=60/75/90
Load:   Caliper fixed-rate tps=1500, 600s, 30 workers
TX:     stateBloat 200 slots/tx

ctrl:   no heap hard limit, default CLR GC
LASS-60: HeapHardLimit=1GB, GCHighMemPercent=60 (GC aggressive at 600MB)
LASS-75: HeapHardLimit=1GB, GCHighMemPercent=75 (GC aggressive at 750MB)
LASS-90: HeapHardLimit=1GB, GCHighMemPercent=90 (GC aggressive at 900MB)
EOF

# Phase 1: ctrl (5×)
echo ""
echo "=============================="
echo "PHASE 1: 5×CTRL"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "ctrl" "${i}" "" || echo "  WARNING: ctrl_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# Phase 2: lass60 (5×)
echo ""
echo "=============================="
echo "PHASE 2: 5×LASS-60"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass60" "${i}" "60" || echo "  WARNING: lass60_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# Phase 3: lass75 (5×)
echo ""
echo "=============================="
echo "PHASE 3: 5×LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass75" "${i}" "75" || echo "  WARNING: lass75_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# Phase 4: lass90 (5×)
echo ""
echo "=============================="
echo "PHASE 4: 5×LASS-90"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass90" "${i}" "90" || echo "  WARNING: lass90_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

echo ""
echo "======================================================================"
echo "ALL NM SENSITIVITY RUNS COMPLETE"
echo "======================================================================"

python3 scripts/analyze_nm_sensitivity.py "${RESULTS_DIR}" \
    > "${RESULTS_DIR}/analysis.log" 2>&1

echo "Report: ${RESULTS_DIR}/final_nethermind_evaluation_1GB.md"
cp "${RESULTS_DIR}/final_nethermind_evaluation_1GB.md" \
   "/home/yeochan.yoon/caliper-stress-test/final_nethermind_evaluation_1GB.md" 2>/dev/null || true

echo "Done. Results: ${RESULTS_DIR}"
