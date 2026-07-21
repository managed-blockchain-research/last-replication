#!/bin/bash
# ============================================================
# NM LARC Evaluation — 3-variant × 3-rep (paper quality)
#
# Variants: nm_baseline, nm_lass_compat, nm_larc_la
# TX workload: 50-slot StateBloater (~1.13M gas/TX)
#   → NM capacity: ~3.5 TPS (9M gas / 1.13M × 0.5 Hz)
#   → TARGET_TPS=2 (well below capacity, ≥95% success expected)
#
# NM_LARC_ACTIVATE_MB=200:
#   NM idle CLR heap ≈ 50-120 MB. Under heavy 50-slot SSTORE
#   processing, heap spikes to ~200-300 MB, triggering LARC.
#
# Monitoring:
#   - pre-run resource check: abort if avail<30GB or load>20, wait 10 min
#   - mid-run: NM-alive check every 30s; abort caliper if NM dies
#   - post-run summary: caliper + dotnet-counters + LARC counters
#   - auto-retry (max 2x) with targeted param fix on bad results:
#       no measure line   → diagnose NM log; retry same params
#       success rate <85% → reduce TPS by 0.5
#       spills=0 (LARC)   → reduce ACTIVATE_MB by 30
#
# Usage:
#   nohup bash scripts/run_larc_eval_nm.sh > /tmp/larc_eval_nm.log 2>&1 &
#   bash scripts/run_larc_eval_nm.sh --variants nm_baseline --reps 1   # smoke
# ============================================================
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
DOTNET_COUNTERS="/home/yeochan.yoon/.dotnet/tools/dotnet-counters"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
NETWORKCONFIG="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"

TARGET_TPS=2
SLOTS_PER_TX=50
NUM_WORKERS=2
MEASURE_S=300
CALIPER_TIMEOUT=600
COOLDOWN=30

# Calibrated from gcdump: NM heap idle ~80 MB, peak under 50-slot TX load ~134 MB
# → activate at 100 MB (reliably hit during processing), deactivate at 80 MB
NM_LARC_ACTIVATE_MB=100
NM_LARC_DEACTIVATE_MB=80

VARIANTS=(nm_baseline nm_lass_compat nm_larc_la)
REPLICATIONS=3

RUN_ID="$(date +%Y%m%d_%H%M%S)_larc_eval_nm"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/larc_eval_nm/${RUN_ID}"

# ── Parse flags ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variants) IFS=',' read -ra VARIANTS <<< "$2"; shift 2 ;;
    --reps)     REPLICATIONS="$2"; shift 2 ;;
    --tps)      TARGET_TPS="$2"; shift 2 ;;
    --slots)    SLOTS_PER_TX="$2"; shift 2 ;;
    --run-id)   RUN_ID="$2"; RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/larc_eval_nm/${RUN_ID}"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

mkdir -p "${RESULTS_DIR}"
export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="/home/yeochan.yoon/.dotnet/tools:${DOTNET_ROOT}:${PATH}"
export DOTNET_EnableDiagnostics=1

# ── Resource check ─────────────────────────────────────────────────────────
# Waits in 10-min loops until avail ≥ 30 GB AND load ≤ 20.
check_resources() {
    local label="${1:-run}"
    local waited=0
    while true; do
        local avail_gb load load_int
        avail_gb=$(free -g | awk '/^Mem/{print $7}')
        load=$(awk '{print $1}' /proc/loadavg)
        load_int=$(printf "%.0f" "${load}" 2>/dev/null || echo "${load%.*}")
        if [[ "${avail_gb}" -lt 30 ]] || [[ "${load_int}" -gt 20 ]]; then
            echo "  [RESOURCE] ${label}: avail=${avail_gb}GB load=${load} → heavy, waiting 10 min (waited=${waited}min so far)..."
            sleep 600
            waited=$((waited + 10))
        else
            echo "  [RESOURCE] OK: avail=${avail_gb}GB load=${load}"
            return 0
        fi
    done
}

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
    local tps="$1" workers="$2" dur="$3" slots="$4" outfile="$5"
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
          slotsPerTx: ${slots}
          numContracts: 30
          contractPrefix: SB
EOF
}

# ── Post-run cleanup ──────────────────────────────────────────────────────
# Removes bulk files that are not needed for analysis.
# Keeps: caliper_console.log, dotnet_counters.csv, larc_counters.csv,
#        larc_decisions.csv, result.json, report.html, diagnosis.txt
cleanup_run() {
    local run_dir="$1" data_dir="$2" variant="$3" rep="$4" succeeded="$5"

    # Always remove: NM blockchain DB (can be GB), temp benchconfig, PID file
    rm -rf "${data_dir}" 2>/dev/null || true
    rm -f  "/tmp/benchconfig_nm_larc_${variant}_rep${rep}.yaml" 2>/dev/null || true
    rm -f  "${run_dir}/nm.pid" 2>/dev/null || true
    # rss_monitor.csv is kept (primary heap metric); no .log to remove
    rm -f  "${run_dir}/deploy.log" 2>/dev/null || true

    # nm_console.log: keep last 200 lines on failure, delete on success
    if [[ "${succeeded}" == "1" ]]; then
        rm -f "${run_dir}/nm_console.log" 2>/dev/null || true
    else
        local nm_log="${run_dir}/nm_console.log"
        if [[ -f "${nm_log}" ]]; then
            local tmp; tmp=$(tail -200 "${nm_log}")
            echo "${tmp}" > "${nm_log}"
        fi
    fi

    # caliper.log (structured caliper file, often large): keep only if non-empty and distinct
    if [[ -f "${run_dir}/caliper.log" ]]; then
        local sz; sz=$(wc -c < "${run_dir}/caliper.log" 2>/dev/null || echo 0)
        if [[ ${sz} -gt 5242880 ]]; then  # >5 MB: truncate to last 500 lines
            local tmp; tmp=$(tail -500 "${run_dir}/caliper.log")
            echo "${tmp}" > "${run_dir}/caliper.log"
        fi
    fi

    echo "  [CLEANUP] done — removed NM DB, tmp files, process logs"
}

# ── Post-run log summary ───────────────────────────────────────────────────
print_run_summary() {
    local run_dir="$1" variant="$2" rep="$3"
    echo ""
    echo "  ┌─ Summary: ${variant}_rep${rep} ─────────────────────────────────────"

    # Caliper measure line
    local mline
    mline=$(grep "| measure " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || true)
    if [[ -n "${mline}" ]]; then
        echo "  │ Caliper : ${mline}"
    else
        echo "  │ Caliper : (no measure line)"
        # Show last 5 caliper lines for diagnosis
        echo "  │ Caliper tail:"
        tail -5 "${run_dir}/caliper_console.log" 2>/dev/null | sed 's/^/  │   /' || true
    fi

    # RSS monitor summary
    local rss_csv="${run_dir}/rss_monitor.csv"
    if [[ -f "${rss_csv}" ]] && [[ -s "${rss_csv}" ]]; then
        local rss_max rss_min rss_samples
        rss_max=$(tail -n +2 "${rss_csv}" | awk -F',' '{print $2}' | sort -rn | head -1 | tr -d ' \r' || echo "?")
        rss_min=$(tail -n +2 "${rss_csv}" | awk -F',' '{print $2}' | sort -n  | head -1 | tr -d ' \r' || echo "?")
        rss_samples=$(tail -n +2 "${rss_csv}" | wc -l 2>/dev/null || echo "?")
        echo "  │ RSS     : max=${rss_max}MB min=${rss_min}MB samples=${rss_samples}"
    else
        echo "  │ RSS     : (no rss_monitor.csv)"
    fi

    # LARC counters (NmLarcMetrics writes nm_larc_counters.csv)
    local larc_csv="${run_dir}/nm_larc_counters.csv"
    if [[ -f "${larc_csv}" ]] && [[ -s "${larc_csv}" ]]; then
        local last; last=$(tail -1 "${larc_csv}" 2>/dev/null || true)
        echo "  │ LARC    : ${last}"
    else
        echo "  │ LARC    : (no larc_counters.csv)"
    fi

    # result.json
    if [[ -f "${run_dir}/result.json" ]]; then
        echo "  │ result  : $(cat "${run_dir}/result.json")"
    fi

    echo "  └──────────────────────────────────────────────────────────────────"
}

# ── Single run (one variant, one rep) with monitoring ─────────────────────
# Returns 0 on success (measure line found, success_rate ≥ 85%)
# Writes diagnosis to run_dir/diagnosis.txt on failure
run_once() {
    local variant="$1" rep="$2" tps_override="$3" activate_mb_override="$4"
    local run_dir="${RESULTS_DIR}/${variant}_rep${rep}"
    mkdir -p "${run_dir}"

    local larc_mode="DISABLED"
    case "${variant}" in
        nm_lass_compat) larc_mode="LASS_COMPAT" ;;
        nm_larc_la)     larc_mode="LOCALITY_AWARE" ;;
    esac

    local cur_tps="${tps_override:-${TARGET_TPS}}"
    local cur_activate="${activate_mb_override:-${NM_LARC_ACTIVATE_MB}}"
    local data_dir="/tmp/larc_nm_${variant}_rep${rep}_${RUN_ID}"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "VARIANT=${variant} REP=${rep} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "MODE=${larc_mode} TPS=${cur_tps} SLOTS=${SLOTS_PER_TX} MEASURE=${MEASURE_S}s"
    echo "ACTIVATE_MB=${cur_activate} DEACTIVATE_MB=${NM_LARC_DEACTIVATE_MB}"
    echo "────────────────────────────────────────────────────────────────"

    stop_nm
    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    echo "  Starting Nethermind ..."
    NM_LARC_MODE="${larc_mode}" \
    NM_LARC_ACTIVATE_MB="${cur_activate}" \
    NM_LARC_DEACTIVATE_MB="${NM_LARC_DEACTIVATE_MB}" \
    NM_LARC_DATA_DIR="${run_dir}" \
    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}/nm_db" \
        --Init.LogFileName "${data_dir}/nm.log" \
        > "${run_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "${nm_pid}" > "${run_dir}/nm.pid"

    if ! wait_for_rpc; then
        echo "  ERROR: RPC not ready" | tee "${run_dir}/diagnosis.txt"
        echo '{"result":"rpc_timeout"}' > "${run_dir}/result.json"
        stop_nm "${nm_pid}"; return 1
    fi

    echo "  Deploying 30 StateBloater contracts ..."
    node "${DEPLOY_NM}" 30 "${NETWORKCONFIG}" > "${run_dir}/deploy.log" 2>&1 || true
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed" | tee "${run_dir}/diagnosis.txt"
        echo '{"result":"deploy_failed"}' > "${run_dir}/result.json"
        stop_nm "${nm_pid}"; return 1
    fi
    sleep 3

    local benchcfg="/tmp/benchconfig_nm_larc_${variant}_rep${rep}.yaml"
    make_benchconfig "${cur_tps}" "${NUM_WORKERS}" "${MEASURE_S}" "${SLOTS_PER_TX}" "${benchcfg}"

    # RSS monitor (dotnet-counters doesn't work on .NET 10 NM due to Meter API change)
    # Samples /proc/<pid>/status VmRSS every 1s until NM dies
    local rss_csv="${run_dir}/rss_monitor.csv"
    echo "timestamp_s,rss_mb" > "${rss_csv}"
    (
        local nm_watch="${nm_pid}"
        while kill -0 "${nm_watch}" 2>/dev/null; do
            local rss_kb ts
            rss_kb=$(grep VmRSS /proc/${nm_watch}/status 2>/dev/null | awk '{print $2}' || echo 0)
            ts=$(date +%s)
            printf "%s,%.1f\n" "${ts}" "$(echo "${rss_kb}/1024" | bc -l)" >> "${rss_csv}"
            sleep 1
        done
    ) &
    local dc_pid=$!
    echo "  RSS monitor PID=${dc_pid}"

    # Run caliper in background so we can monitor mid-run
    echo "  Running Caliper at ${cur_tps} TPS (${SLOTS_PER_TX}-slot TXs) for ${MEASURE_S}s ..."
    local t_start; t_start=$(date +%s)
    timeout "${CALIPER_TIMEOUT}" npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${benchcfg}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 &
    local caliper_pid=$!

    # Mid-run monitoring: check NM alive every 30s; abort caliper if NM dies
    local monitor_abort=0
    local elapsed_monitor=0
    while kill -0 "${caliper_pid}" 2>/dev/null; do
        sleep 30
        elapsed_monitor=$((elapsed_monitor + 30))

        if ! kill -0 "${nm_pid}" 2>/dev/null; then
            echo "  [MONITOR] NM (PID=${nm_pid}) died at ~${elapsed_monitor}s → killing caliper"
            kill "${caliper_pid}" 2>/dev/null || true
            monitor_abort=1
            break
        fi

        # After 90s: check for caliper log growing (stuck detection)
        if [[ ${elapsed_monitor} -ge 90 ]]; then
            local log_size; log_size=$(wc -c < "${run_dir}/caliper_console.log" 2>/dev/null || echo 0)
            if [[ ${log_size} -lt 100 ]]; then
                echo "  [MONITOR] Caliper log not growing at ${elapsed_monitor}s (${log_size} bytes) → may be stuck"
            fi
        fi

        echo "  [MONITOR] t=${elapsed_monitor}s | NM alive | avail=$(free -g | awk '/^Mem/{print $7}')GB"
    done

    wait "${caliper_pid}" 2>/dev/null || true
    local t_end; t_end=$(date +%s)
    echo "  Caliper done. Elapsed: $(( t_end - t_start ))s"

    cp caliper.log  "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html  "${run_dir}/report.html"  2>/dev/null || true
    # Kill RSS monitor explicitly (it loops until NM dies, causing deadlock if waited)
    kill "${dc_pid}" 2>/dev/null || true
    wait "${dc_pid}" 2>/dev/null || true
    stop_nm "${nm_pid}"

    if [[ ${monitor_abort} -eq 1 ]]; then
        local nm_tail; nm_tail=$(tail -10 "${run_dir}/nm_console.log" 2>/dev/null || true)
        {
            echo "CAUSE: NM died mid-run"
            echo "NM log tail:"
            echo "${nm_tail}"
        } > "${run_dir}/diagnosis.txt"
        echo "  DIAGNOSIS written → ${run_dir}/diagnosis.txt"
        echo '{"result":"nm_died_mid_run"}' > "${run_dir}/result.json"
        cleanup_run "${run_dir}" "${data_dir}" "${variant}" "${rep}" "0"
        return 1
    fi

    # Parse results
    local measure_line succ fail tps_actual avg_s success_rate
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || true)

    if [[ -z "${measure_line}" ]]; then
        local diag="CAUSE: no measure line\n"
        if grep -qi "out of memory\|OutOfMemory\|OOM" "${run_dir}/nm_console.log" 2>/dev/null; then
            diag+="NM OOM detected in nm_console.log\n"
        fi
        if grep -qi "connection refused\|ECONNREFUSED" "${run_dir}/caliper_console.log" 2>/dev/null; then
            diag+="Caliper connection refused — NM may have crashed early\n"
        fi
        local nm_errs; nm_errs=$(grep -i 'error\|exception' "${run_dir}/nm_console.log" 2>/dev/null | tail -3 || true)
        if [[ -n "${nm_errs}" ]]; then
            diag+="NM errors: ${nm_errs}\n"
        fi
        printf "%b" "${diag}" > "${run_dir}/diagnosis.txt"
        echo "  DIAGNOSIS: no measure line"
        cat "${run_dir}/diagnosis.txt"
        echo '{"result":"no_measure_line"}' > "${run_dir}/result.json"
        cleanup_run "${run_dir}" "${data_dir}" "${variant}" "${rep}" "0"
        return 1
    fi

    succ=$(echo "${measure_line}" | awk -F'|' '{print $3}' | tr -d ' ')
    fail=$(echo "${measure_line}" | awk -F'|' '{print $4}' | tr -d ' ')
    tps_actual=$(echo "${measure_line}" | awk -F'|' '{print $9}' | tr -d ' ')
    avg_s=$(echo "${measure_line}" | awk -F'|' '{print $8}' | tr -d ' ')
    local total=$(( ${succ:-0} + ${fail:-0} ))
    success_rate=0
    if [[ "${total}" -gt 0 ]]; then
        success_rate=$(python3 -c "print(round(100.0*${succ:-0}/${total},1))")
    fi

    # Parse LARC counters (NmLarcMetrics writes nm_larc_counters.csv)
    local larc_csv="${run_dir}/nm_larc_counters.csv"
    local spills=0 restores=0 externalized=0
    if [[ -f "${larc_csv}" ]]; then
        local last_line; last_line=$(tail -1 "${larc_csv}" 2>/dev/null || true)
        if [[ -n "${last_line}" ]]; then
            spills=$(echo "${last_line}" | awk -F',' '{print $2}')
            restores=$(echo "${last_line}" | awk -F',' '{print $3}')
            externalized=$(echo "${last_line}" | awk -F',' '{print $4}')
        fi
    fi

    # Parse RSS monitor (replaces dotnet-counters which doesn't work on .NET 10)
    local rss_csv="${run_dir}/rss_monitor.csv"
    local gen0=0 gen1=0 gen2=0 heap_mb=0
    if [[ -f "${rss_csv}" ]] && [[ -s "${rss_csv}" ]]; then
        heap_mb=$(tail -n +2 "${rss_csv}" | awk -F',' '{print $2}' | sort -rn | head -1 | tr -d ' \r' || echo 0)
    fi

    cat > "${run_dir}/result.json" << EOJSON
{"variant":"${variant}","rep":${rep},"succ":${succ:-0},"fail":${fail:-0},"success_rate_pct":${success_rate},"tps_actual":${tps_actual:-0},"avg_lat_s":${avg_s:-0},"larc_mode":"${larc_mode}","slots_per_tx":${SLOTS_PER_TX},"spills":${spills:-0},"restores":${restores:-0},"externalized":${externalized:-0},"gen0_gc":${gen0:-0},"gen1_gc":${gen1:-0},"gen2_gc":${gen2:-0},"max_heap_mb":${heap_mb:-0},"activate_mb":${cur_activate},"tps_used":${cur_tps}}
EOJSON

    echo "  RESULT: Succ=${succ} Fail=${fail} Rate=${success_rate}% TPS=${tps_actual} Spills=${spills} Restores=${restores} RssMax=${heap_mb}MB"

    # Validate: success_rate check
    local sr_int; sr_int=$(python3 -c "print(int(${success_rate}))" 2>/dev/null || echo 0)
    if [[ ${sr_int} -lt 85 ]]; then
        {
            echo "CAUSE: success_rate=${success_rate}% < 85% (succ=${succ} fail=${fail})"
            echo "ACTION: reduce TPS by 0.5"
        } > "${run_dir}/diagnosis.txt"
        echo "  [VALIDATE] success_rate=${success_rate}% < 85% → marked for retry with lower TPS"
        cleanup_run "${run_dir}" "${data_dir}" "${variant}" "${rep}" "0"
        return 2
    fi

    # Note: at 2 TPS, NM pool stays near-empty due to nonce window W=16 protection.
    # spills=0 is expected and accepted — not a retry condition.

    rm -f "${run_dir}/diagnosis.txt"
    cleanup_run "${run_dir}" "${data_dir}" "${variant}" "${rep}" "1"
    return 0
}

# ── run_variant_rep: wraps run_once with up to 2 retries ──────────────────
run_variant_rep() {
    local variant="$1" rep="$2"
    local cur_tps="${TARGET_TPS}"
    local cur_activate="${NM_LARC_ACTIVATE_MB}"
    local attempt=0
    local max_retries=3

    # Pre-run resource check
    check_resources "${variant}_rep${rep}"

    while [[ ${attempt} -le ${max_retries} ]]; do
        if [[ ${attempt} -gt 0 ]]; then
            echo ""
            echo "  *** RETRY ${attempt}/${max_retries} for ${variant}_rep${rep} ***"
            echo "  TPS=${cur_tps} ACTIVATE_MB=${cur_activate}"
            # Back up previous run dir and start fresh
            local prev="${RESULTS_DIR}/${variant}_rep${rep}"
            local bk="${prev}_attempt${attempt}"
            mv "${prev}" "${bk}" 2>/dev/null || true
            echo "  Previous attempt saved → ${bk}"
            check_resources "${variant}_rep${rep} retry${attempt}"
        fi

        run_once "${variant}" "${rep}" "${cur_tps}" "${cur_activate}"
        local rc=$?

        print_run_summary "${RESULTS_DIR}/${variant}_rep${rep}" "${variant}" "${rep}"

        if [[ ${rc} -eq 0 ]]; then
            return 0
        elif [[ ${rc} -eq 2 ]]; then
            # Success rate too low → reduce TPS
            cur_tps=$(python3 -c "print(round(${cur_tps}-0.5,1))")
            echo "  [RETRY] Reducing TPS to ${cur_tps}"
        elif [[ ${rc} -eq 3 ]]; then
            # LARC not triggering → reduce ACTIVATE_MB (keep DEACTIVATE 20 below)
            cur_activate=$(( cur_activate - 30 ))
            NM_LARC_DEACTIVATE_MB=$(( cur_activate - 20 ))
            [[ ${NM_LARC_DEACTIVATE_MB} -lt 20 ]] && NM_LARC_DEACTIVATE_MB=20
            echo "  [RETRY] Reducing ACTIVATE_MB to ${cur_activate}, DEACTIVATE_MB to ${NM_LARC_DEACTIVATE_MB}"
        else
            # Hard failure (NM died, deploy failed, etc.)
            echo "  [RETRY] Hard failure (rc=${rc}); retrying with same params"
        fi

        attempt=$((attempt + 1))
    done

    echo "  [GIVE UP] ${variant}_rep${rep} failed after ${max_retries} retries"
    return 1
}

# ── Main ────────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "NM LARC Evaluation  RUN_ID=${RUN_ID}"
echo "Variants: ${VARIANTS[*]}"
echo "Reps    : ${REPLICATIONS}"
echo "TPS     : ${TARGET_TPS} | Slots: ${SLOTS_PER_TX}/TX"
echo "NM capacity at ${SLOTS_PER_TX}-slot TXs: ~3.5 TPS → using ${TARGET_TPS} TPS"
echo "LARC_ACTIVATE: ${NM_LARC_ACTIVATE_MB} MB | DEACTIVATE: ${NM_LARC_DEACTIVATE_MB} MB"
echo "Measure : ${MEASURE_S}s | Max retries: 2"
echo "NM DLL  : ${NM_DLL}"
echo "Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

for rep in $(seq 1 "${REPLICATIONS}"); do
    for variant in "${VARIANTS[@]}"; do
        if [[ -f "${RESULTS_DIR}/${variant}_rep${rep}/result.json" ]]; then
            echo "  [SKIP] ${variant}_rep${rep} — result.json already exists"
            continue
        fi
        run_variant_rep "${variant}" "${rep}" || echo "  SKIPPED (exhausted retries)"
        sleep "${COOLDOWN}"
    done
    echo ""
    echo "=== Rep ${rep}/${REPLICATIONS} complete. Inter-rep cooldown 60s ==="
    sleep 60
done

echo ""
echo "======================================================================"
echo "NM LARC Eval COMPLETE. Results: ${RESULTS_DIR}"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

echo ""; echo "=== FINAL SUMMARY ==="
for variant in "${VARIANTS[@]}"; do
    echo "--- ${variant} ---"
    for rep in $(seq 1 "${REPLICATIONS}"); do
        local_dir="${RESULTS_DIR}/${variant}_rep${rep}"
        [[ -f "${local_dir}/result.json" ]] && cat "${local_dir}/result.json" || echo "  (missing)"
    done
done
