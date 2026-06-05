#!/bin/bash
# ============================================================
# LAST vs LASS Head-to-Head Evaluation — Nethermind @ 1GB Heap
#
# 4 variants × 5 replications = 20 runs (single binary, NETHERMIND_LAST_MODE controls variant)
#   baseline   : NETHERMIND_LAST_MODE=DISABLED, no LASS
#   lass75     : NETHERMIND_LAST_MODE=DISABLED, LASS-75 (GCHighMemPercent=75)
#   last_al    : NETHERMIND_LAST_MODE=AL, no LASS
#   last_lass75: NETHERMIND_LAST_MODE=AL, LASS-75
#
# Binary: nethermind + LAST-patched Nethermind.Consensus.Ethash.dll
#   (LastTxPoolTxSource with DISABLED mode = standard FIFO, AL = address locality)
# Caliper: 120s warmup + 300s measure, 150 TPS, 30 workers
# GC: dotnet-trace (dotnet-counters incompatible with .NET 10)
# Output: results/last_vs_lass_nm/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Binary (single LAST-enabled binary for all variants) ─────────────────────
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"

NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
BENCHCONFIG="benchconfig-last-vs-lass-nm.yaml"
NETWORKCONFIG="networkconfig_nethermind_caliper.json"
DEPLOY_SCRIPT="deploy_multi_contracts_nm.js"

# ── Run parameters ────────────────────────────────────────────────────────────
HEAP_HARD_LIMIT=1000000000
REPLICATIONS=5
LASS75_PCT=75

# ── Output directory ──────────────────────────────────────────────────────────
RUN_ID=$(date +%Y%m%d_%H%M%S)_nm_last_vs_lass
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/last_vs_lass_nm/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}:${HOME}/.dotnet/tools"

echo "======================================================================"
echo "NM LAST vs LASS Evaluation | 150 TPS | 120s+300s | 5 reps"
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
    local variant="$1"   # baseline | lass75 | last_al | last_lass75
    local rep="$2"
    local last_mode="$3" # DISABLED | AL
    local lass_pct="$4"  # "" (no LASS) or "75"
    local nm_dll="${NM_DLL}"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_nm_lvl_${label}_${RUN_ID}"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  binary: ${nm_dll}"
    echo "  LAST:   NETHERMIND_LAST_MODE=${last_mode}"
    echo "  LASS:   ${lass_pct:-none}"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    # Set LAST mode
    export NETHERMIND_LAST_MODE="${last_mode}"
    export LAST_LOG_FILE="${run_dir}/last_metrics.csv"

    # Set LASS (CLR GC) env vars
    if [ -n "${lass_pct}" ]; then
        export DOTNET_GCHeapHardLimit="${HEAP_HARD_LIMIT}"
        export COMPlus_GCHeapHardLimit="${HEAP_HARD_LIMIT}"
        export DOTNET_GCHighMemPercent="${lass_pct}"
        export COMPlus_GCHighMemPercent="${lass_pct}"
        echo "  GC: HeapHardLimit=${HEAP_HARD_LIMIT} GCHighMemPercent=${lass_pct}"
    else
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit 2>/dev/null || true
        unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        echo "  GC: no heap limit"
    fi

    export DOTNET_EnableDiagnostics=1

    nohup "${DOTNET_BIN}" "${nm_dll}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}" \
        --Blocks.MinGasPrice 0 \
        > "${run_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "  Nethermind PID: ${nm_pid}"

    sleep 8
    if ! kill -0 ${nm_pid} 2>/dev/null; then
        echo "  ERROR: Nethermind died at startup."
        tail -20 "${run_dir}/nm_console.log" || true
        echo "failed=startup" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        return 1
    fi

    wait_for_rpc 8545 || {
        stop_nm "${nm_pid}"
        echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        return 1
    }

    echo "  Deploying 30 StateBloater contracts..."
    node "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | awk '{print $3}')
    if [ -z "${contract_addr}" ]; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_nm "${nm_pid}"
        echo "failed=deploy" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE LAST_LOG_FILE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        return 1
    fi
    echo "  First contract: ${contract_addr}"

    sleep 5

    # Start dotnet-trace GC collection
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

    echo "  Running Caliper (120s warmup + 300s measure @ 150 TPS)..."
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

    # Stop dotnet-trace
    if [ -n "${dotnet_trace_pid}" ] && kill -0 "${dotnet_trace_pid}" 2>/dev/null; then
        kill -INT "${dotnet_trace_pid}" 2>/dev/null || true
        sleep 5
        kill "${dotnet_trace_pid}" 2>/dev/null || true
    fi

    cp caliper.log  "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html  "${run_dir}/report.html"  2>/dev/null || true

    echo "  Stopping Nethermind..."
    stop_nm "${nm_pid}"
    rm -rf "${data_dir}"

    # Unset env vars
    unset NETHERMIND_LAST_MODE LAST_LOG_FILE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    # Parse GC metrics from nettrace
    if [ -f "${nettrace_file}" ] && [ -f "${GC_PARSER}" ]; then
        echo "  Parsing GC trace..."
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace_file}" 2>/dev/null \
            | tee "${run_dir}/gc_summary.txt" \
            | sed 's/^/    /'
    fi

    # Quick Caliper measure summary
    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"

    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
NM_COMMIT=$(cd /home/yeochan.yoon/nethermind && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
LAST vs LASS Head-to-Head Evaluation @ 1GB Heap (Nethermind)
=============================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Binary: ${NM_DLL}
  nethermind.dll from stock nethermind (commit: ${NM_COMMIT})
  Nethermind.Consensus.Ethash.dll: LAST-patched (LastTxPoolTxSource, applied to same commit)
  NETHERMIND_LAST_MODE env var selects behavior per variant

LAST patch: nethermind/src/Nethermind/Nethermind.Consensus.Ethash/LastTxPoolTxSource.cs
LAST mode:  NETHERMIND_LAST_MODE=AL (ADDRESS_LOCALITY) or DISABLED (FIFO)
LASS-75:    DOTNET_GCHeapHardLimit=1000000000 + DOTNET_GCHighMemPercent=75

Heap:    no limit (baseline/last_al) or GCHeapHardLimit=1GB (lass75/last_lass75)
GC:      CLR default (.NET Server GC)
Load:    Caliper fixed-rate 150 TPS, 120s warmup + 300s measure, 30 workers
TX:      stateBloat 200 slots/tx

Variants:
  baseline   : NETHERMIND_LAST_MODE=DISABLED, no LASS
  lass75     : NETHERMIND_LAST_MODE=DISABLED, LASS-75 (GCHighMemPercent=75)
  last_al    : NETHERMIND_LAST_MODE=AL, no LASS
  last_lass75: NETHERMIND_LAST_MODE=AL, LASS-75
EOF

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: Baseline (FIFO, no LASS) ────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 1: 5×BASELINE"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "baseline" "${i}" "DISABLED" "" \
        || echo "  WARNING: baseline_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# ── Phase 2: LASS-75 only ─────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 2: 5×LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass75" "${i}" "DISABLED" "${LASS75_PCT}" \
        || echo "  WARNING: lass75_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# ── Phase 3: LAST-AL only ─────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 3: 5×LAST-AL"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_al" "${i}" "AL" "" \
        || echo "  WARNING: last_al_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# ── Phase 4: LAST-AL + LASS-75 (Synergy) ─────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 4: 5×LAST+LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_lass75" "${i}" "AL" "${LASS75_PCT}" \
        || echo "  WARNING: last_lass75_${i} failed, continuing"
    if [ "${i}" -lt "${REPLICATIONS}" ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

# ── Analysis ──────────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo "ALL RUNS COMPLETE — running analysis"
echo "======================================================================"

python3 scripts/analyze_last_vs_lass_nm.py "${RESULTS_DIR}" \
    > "${RESULTS_DIR}/analysis.log" 2>&1 && \
    echo "Report: ${RESULTS_DIR}/final_NM_LAST_vs_LASS_1GB_Evaluation.md" || \
    echo "WARNING: analysis script failed — check ${RESULTS_DIR}/analysis.log"

echo "Done. Results: ${RESULTS_DIR}"
