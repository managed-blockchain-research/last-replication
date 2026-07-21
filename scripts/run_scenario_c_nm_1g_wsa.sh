#!/bin/bash
# ============================================================
# Scenario C — Heap-Constrained Steady Stress (NM 1 GB / 150 TPS)
#
# Goal: Show WSA increases mean/tail GC pauses vs Baseline (live-set
#       amplification), and WSA+LASS-75 neutralizes the effect.
#
# Variants (3 × 5 reps = 15 runs):
#   baseline       : DISABLED, no LASS
#   last_wsa       : WSA, no LASS
#   last_wsa_lass75: WSA, LASS-75
#
# NM binary: nethermind-last/nethermind.dll
#   WSA confirmed in Nethermind.Consensus.Ethash.dll
#   (LastTxPoolTxSource, NETHERMIND_LAST_MODE=WSA)
#
# GC collection: dotnet-trace → gc_trace.nettrace → NettraceGcParser.dll --csv
# Output: results/scenario_c_nm_1g_wsa/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Binaries ──────────────────────────────────────────────────────────────────
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"

NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"

# ── Caliper config ────────────────────────────────────────────────────────────
BENCHCONFIG="benchconfig-last-vs-lass-nm.yaml"
NETWORKCONFIG="networkconfig_nethermind_caliper.json"
DEPLOY_SCRIPT="deploy_multi_contracts_nm.js"

# ── Run parameters ────────────────────────────────────────────────────────────
HEAP_HARD_LIMIT=1000000000   # 1 GB
REPLICATIONS=5
LASS75_PCT=75

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}:${HOME}/.dotnet/tools"

# ── Output directory ──────────────────────────────────────────────────────────
RUN_ID=$(date +%Y%m%d_%H%M%S)_scenario_c_nm_1g_wsa
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/scenario_c_nm_1g_wsa/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "Scenario C — NM 1 GB / 150 TPS / 5 reps / 3 variants (WSA)"
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
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0
    while kill -0 "${pid}" 2>/dev/null && [ ${w} -lt 30 ]; do
        sleep 1; w=$((w+1))
    done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

# run_single VARIANT REP LAST_MODE LASS_PCT
#   LAST_MODE: DISABLED | WSA
#   LASS_PCT:  "" (no LASS) | "75"
run_single() {
    local variant="$1"
    local rep="$2"
    local last_mode="$3"
    local lass_pct="$4"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_scc_${label}_${RUN_ID}"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  LAST: NETHERMIND_LAST_MODE=${last_mode}"
    echo "  LASS: ${lass_pct:-none}"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    # LAST mode
    export NETHERMIND_LAST_MODE="${last_mode}"

    # LASS: CLR GC heap control
    if [ -n "${lass_pct}" ]; then
        export DOTNET_GCHeapHardLimit="${HEAP_HARD_LIMIT}"
        export COMPlus_GCHeapHardLimit="${HEAP_HARD_LIMIT}"
        export DOTNET_GCHighMemPercent="${lass_pct}"
        export COMPlus_GCHighMemPercent="${lass_pct}"
        echo "  GC: HeapHardLimit=${HEAP_HARD_LIMIT}  GCHighMemPercent=${lass_pct}"
    else
        export DOTNET_GCHeapHardLimit="${HEAP_HARD_LIMIT}"
        export COMPlus_GCHeapHardLimit="${HEAP_HARD_LIMIT}"
        unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
        echo "  GC: HeapHardLimit=${HEAP_HARD_LIMIT}  GCHighMemPercent=none"
    fi

    export DOTNET_EnableDiagnostics=1

    nohup "${DOTNET_BIN}" "${NM_DLL}" \
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
        _cleanup_env
        return 1
    fi

    wait_for_rpc 8545 || {
        stop_nm "${nm_pid}"
        echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        _cleanup_env
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
        _cleanup_env
        return 1
    fi
    echo "  First contract: ${contract_addr}"

    sleep 5

    # Start dotnet-trace GC collection
    local nettrace_file="${run_dir}/gc_trace.nettrace"
    local dotnet_trace_pid=""
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

    cp caliper.log "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html "${run_dir}/report.html"  2>/dev/null || true

    echo "  Stopping Nethermind..."
    stop_nm "${nm_pid}"
    rm -rf "${data_dir}"

    _cleanup_env

    # Parse GC trace → per-event CSV
    if [ -f "${nettrace_file}" ] && [ -f "${GC_PARSER}" ]; then
        echo "  Parsing GC trace..."
        # Summary stats
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace_file}" 2>/dev/null \
            | tee "${run_dir}/gc_summary.txt" \
            | sed 's/^/    /'
        # Per-event CSV (variant + run columns prepended)
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace_file}" --csv 2>/dev/null \
            | awk -v v="${variant}" -v r="${rep}" \
                'NR==1{print "variant,run,"$0} NR>1{print v","r","$0}' \
            > "${run_dir}/gc_events.csv"
        echo "  Per-event CSV → ${run_dir}/gc_events.csv"
    fi

    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"

    echo "  ✓ ${label} complete"
}

_cleanup_env() {
    unset NETHERMIND_LAST_MODE \
          DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent \
          2>/dev/null || true
}

# ── Provenance ────────────────────────────────────────────────────────────────
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
Scenario C — NM 1 GB / 150 TPS / LAST-WSA + LASS-75
=====================================================
Run ID: ${RUN_ID}
Date:   $(date)
Host:   $(hostname)

Binary: ${NM_DLL}
  Nethermind.Consensus.Ethash.dll: LAST-patched (WSA confirmed)
  NETHERMIND_LAST_MODE env var selects variant

Heap:   DOTNET_GCHeapHardLimit=1000000000 (1 GB hard limit, all variants)
LASS-75: additionally DOTNET_GCHighMemPercent=75
GC:     CLR Server GC (dotnet-trace + NettraceGcParser)
Load:   Caliper fixed-rate 150 TPS, 120s warmup + 300s measure, 30 workers
TX:     stateBloat 200 slots/tx

Variants:
  baseline       : DISABLED, no LASS threshold
  last_wsa       : WSA, no LASS threshold
  last_wsa_lass75: WSA, LASS-75 (GCHighMemPercent=75)

Primary metrics: mean/p50/p95/p99/max GC pause (ms), total GC events
EOF

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: Baseline ─────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 1: ${REPLICATIONS}×BASELINE (DISABLED, no LASS)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "baseline" "${i}" "DISABLED" "" \
        || echo "  WARNING: baseline_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 2: LAST-WSA (no LASS) ───────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 2: ${REPLICATIONS}×LAST-WSA (no LASS)"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_wsa" "${i}" "WSA" "" \
        || echo "  WARNING: last_wsa_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 3: LAST-WSA + LASS-75 ───────────────────────────────────────────────
echo ""
echo "=============================="
echo "PHASE 3: ${REPLICATIONS}×LAST-WSA + LASS-75"
echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_wsa_lass75" "${i}" "WSA" "${LASS75_PCT}" \
        || echo "  WARNING: last_wsa_lass75_${i} failed, continuing"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Consolidate per-event CSVs ────────────────────────────────────────────────
echo ""
echo "=============================="
echo "CONSOLIDATING RESULTS"
echo "=============================="

OUT_CSV="${RESULTS_DIR}/nm_gc_per_event.csv"
header_written=0
for f in "${RESULTS_DIR}"/*/gc_events.csv; do
    [ -f "${f}" ] || continue
    if [ ${header_written} -eq 0 ]; then
        cat "${f}" >> "${OUT_CSV}"
        header_written=1
    else
        tail -n +2 "${f}" >> "${OUT_CSV}"
    fi
done

if [ -f "${OUT_CSV}" ]; then
    echo "Consolidated CSV: ${OUT_CSV}  ($(wc -l < "${OUT_CSV}") rows)"
fi

# Quick aggregate per variant
if python3 - <<'PYEOF' 2>/dev/null
import csv, sys, os
from collections import defaultdict
import numpy as np

path = os.environ.get("OUT_CSV")
if not path or not os.path.exists(path):
    sys.exit(0)

data = defaultdict(list)
with open(path) as f:
    for row in csv.DictReader(f):
        data[row["variant"]].append(float(row["pause_ms"]))

print("\n## Scenario C — Quick GC Pause Summary\n")
print("| Variant | n | Mean (ms) | p50 | p95 | p99 | Max |")
print("|---------|---|-----------|-----|-----|-----|-----|")
for v in ["baseline", "last_wsa", "last_wsa_lass75"]:
    d = data.get(v, [])
    if not d:
        continue
    print(f"| {v} | {len(d)} | {np.mean(d):.0f} | {np.percentile(d,50):.0f} | "
          f"{np.percentile(d,95):.0f} | {np.percentile(d,99):.0f} | {max(d):.0f} |")
PYEOF
    OUT_CSV="${OUT_CSV}"
    export OUT_CSV
    python3 - <<'PYEOF' > "${RESULTS_DIR}/gc_summary.md" 2>/dev/null
import csv, sys, os
from collections import defaultdict
import numpy as np

path = os.environ.get("OUT_CSV")
if not path or not os.path.exists(path):
    sys.exit(0)

data = defaultdict(list)
with open(path) as f:
    for row in csv.DictReader(f):
        data[row["variant"]].append(float(row["pause_ms"]))

print("## Scenario C — GC Pause CDF Summary\n")
print("| Variant | n | Mean (ms) | p50 | p95 | p99 | Max |")
print("|---------|---|-----------|-----|-----|-----|-----|")
for v in ["baseline", "last_wsa", "last_wsa_lass75"]:
    d = data.get(v, [])
    if not d:
        continue
    print(f"| {v} | {len(d)} | {np.mean(d):.0f} | {np.percentile(d,50):.0f} | "
          f"{np.percentile(d,95):.0f} | {np.percentile(d,99):.0f} | {max(d):.0f} |")
PYEOF
    echo "GC summary → ${RESULTS_DIR}/gc_summary.md"
fi

echo ""
echo "======================================================================"
echo "Scenario C complete. Results: ${RESULTS_DIR}"
echo "======================================================================"
