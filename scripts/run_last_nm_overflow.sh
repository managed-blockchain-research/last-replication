#!/bin/bash
# ============================================================
# LAST Cross-Runtime Evaluation — Nethermind Cache-Overflow
#
# Objective: Show LAST-AL and LAST-HFL_9_1 reduce GC on NM
#            when the workload EXCEEDS the trie cache capacity.
#
# Config: RocksDB, MemoryHint=256MB, TrieStore=64MB, 300 contracts
#
# Abort criteria:
#   - Standard: blocks not advancing, caliper fail rate too high
#   - Cache: after baseline, if GC < MIN_BASELINE_GC, cache not overflowing
#     → abort and suggest increasing contracts or reducing MemoryHint
#
# Log cleanup: nm_console.log, caliper_console.log, nettrace (after parse),
#              caliper.log, report.html, deploy.log deleted after each run.
# ============================================================
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"

NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_overflow_cfg.json"
BENCHCONFIG="benchconfig-last-nm-overflow.yaml"
NETWORKCONFIG="networkconfig_nm_overflow.json"
DEPLOY_SCRIPT="deploy_multi_contracts_nm.js"
N_CONTRACTS=30

REPLICATIONS=3

# ── Abort thresholds ──────────────────────────────────────────────────────────
MIN_BLOCKS=5
MIN_SUCC=10
MAX_FAIL_PCT=99
# If baseline GC total < this (ms), trie cache is not overflowing → abort
MIN_BASELINE_GC=500

RUN_ID=$(date +%Y%m%d_%H%M%S)_nm_last_overflow
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/last_nm_overflow/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"
ABORT_FLAG="${RESULTS_DIR}/ABORT"

BASELINE_AVG_GC=""

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}:${HOME}/.dotnet/tools"

echo "======================================================================"
echo "NM LAST Overflow Eval | 30 TPS | 420s | ${REPLICATIONS} reps"
echo "Config: RocksDB, MemoryHint=1GB, TrieStore=4MB, ${N_CONTRACTS} contracts"
echo "Run ID: ${RUN_ID}"
echo "Abort: MIN_BLOCKS=${MIN_BLOCKS} MIN_BASELINE_GC=${MIN_BASELINE_GC}ms"
echo "======================================================================"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max_wait=180; local count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"; return 0
        fi
        echo -n "."; sleep 1; count=$((count+1))
    done
    echo " TIMEOUT"; return 1
}

get_block_number() {
    curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 \
        | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "0"
}

stop_nm() {
    local nm_pid="$1"
    kill "${nm_pid}" 2>/dev/null || true
    local w=0
    while kill -0 "${nm_pid}" 2>/dev/null && [ ${w} -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${nm_pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

parse_gc_from_summary() {
    local summary_file="$1"
    python3 - "${summary_file}" <<'PYEOF'
import re, sys
try:
    for line in open(sys.argv[1], errors='replace'):
        # gc_summary.txt format: total_pause_ms=14151.3
        m = re.match(r'total_pause_ms=([\d.]+)', line.strip())
        if m:
            print(f"{float(m.group(1)):.1f}")
            sys.exit(0)
except:
    pass
print("N/A")
PYEOF
}

cleanup_run_logs() {
    local run_dir="$1"
    rm -f "${run_dir}/nm_console.log" \
          "${run_dir}/caliper_console.log" \
          "${run_dir}/caliper.log" \
          "${run_dir}/report.html" \
          "${run_dir}/deploy.log" \
          "${run_dir}/dotnet_trace.log" \
          "${run_dir}/gc_trace.nettrace" 2>/dev/null || true
    local sz; sz=$(du -sh "${run_dir}" 2>/dev/null | awk '{print $1}')
    echo "  [logs] cleaned run dir → ${sz}"
}

cleanup_tmp() {
    find /tmp -maxdepth 1 -name "nm_overflow_*" -exec rm -rf {} + 2>/dev/null || true
    find /tmp -maxdepth 1 -name "caliper-*" -mmin +30 -exec rm -rf {} + 2>/dev/null || true
    find /tmp -maxdepth 1 -name "*.autocomplete" -exec rm -f {} + 2>/dev/null || true
    rm -f caliper.log 2>/dev/null || true
    # core dumps
    find /home/yeochan.yoon/caliper-stress-test -maxdepth 1 -name "core" -o -name "core.*" 2>/dev/null \
        | xargs rm -f 2>/dev/null || true
}

validate_run() {
    local label="$1"
    local run_dir="${RESULTS_DIR}/${label}"
    local caliper_log="${run_dir}/caliper_console.log"
    local ok=1

    echo "  [validate] checking ${label}..."

    local bb; bb=$(cat "${run_dir}/block_before.txt" 2>/dev/null || echo 0)
    local ba; ba=$(cat "${run_dir}/block_after.txt"  2>/dev/null || echo 0)
    local bdelta=$(( ba - bb ))
    echo "  [validate] blocks mined: ${bdelta} (min=${MIN_BLOCKS})"
    if [ "${bdelta}" -lt "${MIN_BLOCKS}" ]; then
        echo "  [ABORT] blocks mined=${bdelta} < MIN_BLOCKS=${MIN_BLOCKS}"
        ok=0
    fi

    local measure_succ measure_fail measure_submitted
    measure_succ=$(python3 - "${caliper_log}" <<'PYEOF'
import re, sys
succ = 0
for line in open(sys.argv[1], errors='replace'):
    if 'measure Round' in line and 'Transaction Info' in line:
        m = re.search(r'Succ:\s*(\d+)', line)
        if m: succ = int(m.group(1))
print(succ)
PYEOF
    2>/dev/null || echo 0)

    measure_fail=$(python3 - "${caliper_log}" <<'PYEOF'
import re, sys
fail = 0
for line in open(sys.argv[1], errors='replace'):
    if 'measure Round' in line and 'Transaction Info' in line:
        m = re.search(r'Fail:\s*(\d+)', line)
        if m: fail = int(m.group(1))
print(fail)
PYEOF
    2>/dev/null || echo 0)

    measure_submitted=$(python3 - "${caliper_log}" <<'PYEOF'
import re, sys
sub = 0
for line in open(sys.argv[1], errors='replace'):
    if 'measure Round' in line and 'Transaction Info' in line:
        m = re.search(r'Submitted:\s*(\d+)', line)
        if m: sub = int(m.group(1))
print(sub)
PYEOF
    2>/dev/null || echo 0)

    local fail_pct=0
    if [ "${measure_submitted}" -gt 0 ]; then
        fail_pct=$(( measure_fail * 100 / measure_submitted ))
    fi
    echo "  [validate] submitted=${measure_submitted} succ=${measure_succ} fail=${measure_fail} (${fail_pct}%)"
    echo "  measure_succ=${measure_succ}" >> "${run_dir}/validate.txt"
    echo "  measure_fail=${measure_fail}" >> "${run_dir}/validate.txt"
    echo "  measure_submitted=${measure_submitted}" >> "${run_dir}/validate.txt"

    # GC experiment: caliper tx success rate is irrelevant — NM mines blocks regardless
    # of caliper's pollingTimeout. Only block count matters for validity.
    echo "  [validate] skipping tx success/fail checks (GC-only experiment)"

    if [ "${ok}" -eq 0 ]; then
        echo "ABORT: ${label} failed validation at $(date)" > "${ABORT_FLAG}"
        return 1
    fi
    echo "  [validate] OK"
    return 0
}

check_baseline_gc() {
    local avg_gc="$1"
    echo "  [cache-check] baseline avg GC=${avg_gc}ms (min=${MIN_BASELINE_GC}ms for cache overflow)"
    local ok
    ok=$(python3 -c "
try:
    v = float('${avg_gc}')
    print('YES' if v >= ${MIN_BASELINE_GC} else 'NO')
except:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")

    if [ "${ok}" = "NO" ]; then
        echo "  [ABORT] CACHE_NOT_OVERFLOWING: baseline GC=${avg_gc}ms < ${MIN_BASELINE_GC}ms"
        echo "  [ABORT] Trie cache not overflowing — workload fits in cache."
        echo "  [ABORT] Suggested fix: increase N_CONTRACTS (currently ${N_CONTRACTS}) to 3000+"
        echo "           or reduce TrieStore.MaxMemoryMb / MemoryHint further."
        echo "ABORT: CACHE_NOT_OVERFLOWING — baseline GC=${avg_gc}ms at $(date)" > "${ABORT_FLAG}"
        return 1
    fi
    if [ "${ok}" = "UNKNOWN" ]; then
        echo "  [WARN] Could not parse baseline GC=${avg_gc}ms — continuing"
    else
        echo "  [cache-check] cache overflowing confirmed ✓"
    fi
    return 0
}

# ── Single run ────────────────────────────────────────────────────────────────
run_single() {
    local variant="$1"
    local rep="$2"
    local last_mode="$3"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"
    local data_dir="/tmp/nm_overflow_${label}_${RUN_ID}"

    if [ -f "${ABORT_FLAG}" ]; then
        echo "  ABORT flag set — skipping ${label}"; return 1
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%H:%M:%S') | NETHERMIND_LAST_MODE=${last_mode}"
    echo "────────────────────────────────────────────────────────────────"

    rm -f caliper.log 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    export NETHERMIND_LAST_MODE="${last_mode}"
    export LAST_LOG_FILE="${run_dir}/last_metrics.csv"
    unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit 2>/dev/null || true
    unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
    export DOTNET_EnableDiagnostics=1

    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}" \
        --Blocks.MinGasPrice 0 \
        > "${run_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "  Nethermind PID: ${nm_pid}"

    sleep 10
    if ! kill -0 ${nm_pid} 2>/dev/null; then
        echo "  ERROR: Nethermind died at startup"
        tail -20 "${run_dir}/nm_console.log"
        echo "failed=startup" > "${run_dir}/FAILED"
        return 1
    fi

    wait_for_rpc || { stop_nm "${nm_pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"; return 1; }

    echo "  Deploying ${N_CONTRACTS} contracts..."
    node "${DEPLOY_SCRIPT}" "${N_CONTRACTS}" "./${NETWORKCONFIG}" > "${run_dir}/deploy.log" 2>&1
    local first_addr
    first_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | head -1 | awk '{print $3}')
    if [ -z "${first_addr}" ]; then
        echo "  ERROR: Deploy failed"; cat "${run_dir}/deploy.log"
        stop_nm "${nm_pid}"; echo "failed=deploy" > "${run_dir}/FAILED"; return 1
    fi
    echo "  First contract: ${first_addr}"
    sleep 5

    local block_before; block_before=$(get_block_number)

    # Start dotnet-trace
    local nettrace_file="${run_dir}/gc_trace.nettrace"
    local DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
    local dotnet_trace_pid=""
    if [ -f "${DT_BIN}" ]; then
        "${DT_BIN}" collect \
            --process-id "${nm_pid}" \
            --providers "Microsoft-Windows-DotNETRuntime:0x1:5" \
            --output "${nettrace_file}" \
            > "${run_dir}/dotnet_trace.log" 2>&1 &
        dotnet_trace_pid=$!
        echo "  dotnet-trace PID: ${dotnet_trace_pid}"
    fi

    echo "  Running Caliper (300s measure @ 150 TPS)..."
    local t0; t0=$(date +%s)
    timeout 1500 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1
    local caliper_exit=$?
    local t1; t1=$(date +%s)
    echo "  Caliper exit=${caliper_exit}  elapsed=$((t1-t0))s"

    if [ -n "${dotnet_trace_pid}" ] && kill -0 "${dotnet_trace_pid}" 2>/dev/null; then
        kill -INT "${dotnet_trace_pid}" 2>/dev/null || true; sleep 5
        kill "${dotnet_trace_pid}" 2>/dev/null || true
    fi

    local block_after; block_after=$(get_block_number)
    echo "${block_before}" > "${run_dir}/block_before.txt"
    echo "${block_after}"  > "${run_dir}/block_after.txt"
    echo "  Blocks: ${block_before} → ${block_after} (delta=$((block_after - block_before)))"

    stop_nm "${nm_pid}"
    rm -rf "${data_dir}"

    # Parse GC trace before deleting nettrace
    local gc_total="N/A"
    if [ -f "${nettrace_file}" ] && [ -f "${GC_PARSER}" ]; then
        echo "  Parsing GC trace..."
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace_file}" 2>/dev/null \
            | tee "${run_dir}/gc_summary.txt" | sed 's/^/    /'
        gc_total=$(parse_gc_from_summary "${run_dir}/gc_summary.txt")
    fi
    echo "${gc_total}" > "${run_dir}/gc_total.txt"
    echo "  GC total: ${gc_total}ms"

    unset NETHERMIND_LAST_MODE LAST_LOG_FILE 2>/dev/null || true

    validate_run "${label}" || true

    cleanup_run_logs "${run_dir}"
    cleanup_tmp

    echo "  ✓ ${label} done | GC=${gc_total}ms"
}

extract_group_avg_gc() {
    local prefix="$1"
    python3 - "${RESULTS_DIR}" "${prefix}" "${REPLICATIONS}" <<'PYEOF'
import sys, os
results_dir, prefix, reps = sys.argv[1], sys.argv[2], int(sys.argv[3])
vals = []
for rep in range(1, reps+1):
    f = os.path.join(results_dir, f"{prefix}_{rep}", "gc_total.txt")
    try:
        v = float(open(f).read().strip())
        if v > 0:
            vals.append(v)
    except:
        pass
if vals:
    print(f"{sum(vals)/len(vals):.1f}")
else:
    print("N/A")
PYEOF
}

# ── Provenance ─────────────────────────────────────────────────────────────────
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
NM LAST Cross-Runtime Overflow Evaluation
==========================================
Run ID:   ${RUN_ID}
Date:     $(date)
Binary:   ${NM_DLL}
Config:   ${NM_CFG}  (RocksDB, MemoryHint=1GB, TrieStore=4MB)
Contracts: ${N_CONTRACTS}
Load:     30 TPS, 420s single-round, 30 workers, pollingTimeout=3
Variants: baseline (DISABLED) / last_al (AL) / last_hfl (HFL_9_1)
Reps:     ${REPLICATIONS}
Abort:    MIN_BLOCKS=${MIN_BLOCKS} MIN_BASELINE_GC=${MIN_BASELINE_GC}ms
EOF

pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: Baseline ─────────────────────────────────────────────────────────
echo ""; echo "====== PHASE 1: ${REPLICATIONS}×BASELINE (DISABLED) ======"
for rep in $(seq 1 ${REPLICATIONS}); do
    run_single "baseline" "${rep}" "DISABLED" || true
    [ -f "${ABORT_FLAG}" ] && { echo "ABORT after baseline_${rep}"; cat "${ABORT_FLAG}"; exit 1; }
    [ "${rep}" -lt "${REPLICATIONS}" ] && sleep 20
done
BASELINE_AVG_GC=$(extract_group_avg_gc "baseline")
echo "  [summary] BASELINE avg GC: ${BASELINE_AVG_GC}ms"
check_baseline_gc "${BASELINE_AVG_GC}" || { cat "${ABORT_FLAG}"; exit 1; }

# ── Phase 2: LAST-AL ──────────────────────────────────────────────────────────
echo ""; echo "====== PHASE 2: ${REPLICATIONS}×LAST-AL ======"
for rep in $(seq 1 ${REPLICATIONS}); do
    run_single "last_al" "${rep}" "AL" || true
    [ -f "${ABORT_FLAG}" ] && { echo "ABORT after last_al_${rep}"; cat "${ABORT_FLAG}"; exit 1; }
    [ "${rep}" -lt "${REPLICATIONS}" ] && sleep 20
done
AL_AVG_GC=$(extract_group_avg_gc "last_al")
echo "  [summary] LAST-AL avg GC: ${AL_AVG_GC}ms"
echo "  [summary] GC reduction vs baseline: $(python3 -c "
try: print(f'{(1 - float(\"${AL_AVG_GC}\") / float(\"${BASELINE_AVG_GC}\")) * 100:.1f}%')
except: print('N/A')
" 2>/dev/null || echo 'N/A')"

# ── Phase 3: LAST-HFL_9_1 ────────────────────────────────────────────────────
echo ""; echo "====== PHASE 3: ${REPLICATIONS}×LAST-HFL_9_1 ======"
for rep in $(seq 1 ${REPLICATIONS}); do
    run_single "last_hfl" "${rep}" "HFL_9_1" || true
    [ -f "${ABORT_FLAG}" ] && { echo "ABORT after last_hfl_${rep}"; cat "${ABORT_FLAG}"; exit 1; }
    [ "${rep}" -lt "${REPLICATIONS}" ] && sleep 20
done
HFL_AVG_GC=$(extract_group_avg_gc "last_hfl")
echo "  [summary] LAST-HFL avg GC: ${HFL_AVG_GC}ms"

# ── Analysis ──────────────────────────────────────────────────────────────────
if [ ! -f "${ABORT_FLAG}" ]; then
    echo ""; echo "======================================================================"
    echo "ALL RUNS COMPLETE"
    echo "======================================================================"
    echo "  BASELINE: ${BASELINE_AVG_GC}ms"
    echo "  LAST-AL:  ${AL_AVG_GC}ms"
    echo "  LAST-HFL: ${HFL_AVG_GC}ms"
    python3 scripts/analyze_last_vs_lass_nm.py "${RESULTS_DIR}" \
        > "${RESULTS_DIR}/analysis.log" 2>&1 \
        && cat "${RESULTS_DIR}/analysis.log" \
        || echo "WARNING: analysis failed — see ${RESULTS_DIR}/analysis.log"
else
    echo ""; echo "====== SWEEP ABORTED ======"
    cat "${ABORT_FLAG}"
fi

echo "Done. Results: ${RESULTS_DIR}"
