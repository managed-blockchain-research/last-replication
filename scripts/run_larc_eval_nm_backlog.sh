#!/bin/bash
# ============================================================
# NM LARC Controlled-Backlog Evaluation
#
# Three-phase design to exercise spill/restore under bounded
# pending-pool pressure (nonce backlog > nonce window W=16):
#
#   Phase 1 – Preload  : submit N_SENDERS × TXS_PER_SENDER TXs
#                        from pre-funded keys 2..N_SENDERS+1,
#                        creating a pool backlog per sender that
#                        exceeds the nonce window W=16.
#   Phase 2 – Stabilize: wait STAB_S seconds; confirm spills>0
#                        by polling larc_counters.csv.
#   Phase 3 – Drain    : run Caliper at DRAIN_TPS for DRAIN_S s
#                        from the deployer account (key 1).
#                        NM drains the backlog concurrently;
#                        LARC restores spilled TXs on demand.
#
# Variants : nm_baseline  nm_lass_compat  nm_larc_la
# Threshold : NM_LARC_ACTIVATE_MB (CLR managed heap, GC.GetTotalMemory)
#             — NOT process RSS. Baseline managed heap ~134 MB at load.
#             Default 100 MB triggers reliably during active processing.
#
# Usage:
#   nohup bash scripts/run_larc_eval_nm_backlog.sh \
#         >> /tmp/larc_eval_nm_backlog.log 2>&1 &
#   bash scripts/run_larc_eval_nm_backlog.sh \
#         --senders 30 --txs-per-sender 64 --slots 50 \
#         --activate 100 --variants nm_baseline,nm_lass_compat,nm_larc_la
# ============================================================
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
NETWORKCONFIG="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
PRELOAD_JS="scripts/preload_nm_backlog.js"

# ── Defaults ──────────────────────────────────────────────────────────────────
N_SENDERS=30
TXS_PER_SENDER=17
SLOTS_PER_TX=50
DRAIN_TPS=2
DRAIN_S=240
DRAIN_WORKERS=2
STAB_S=25         # stabilization wait after preload
CALIPER_TIMEOUT=600
COOLDOWN=30

NM_LARC_ACTIVATE_MB=100
NM_LARC_DEACTIVATE_MB=80

VARIANTS=(nm_baseline nm_lass_compat nm_larc_la)
REPLICATIONS=3

RUN_ID="$(date +%Y%m%d_%H%M%S)_larc_backlog_nm"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/larc_eval_nm_backlog/${RUN_ID}"

# ── Parse flags ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --senders)         N_SENDERS="$2"; shift 2 ;;
    --txs-per-sender)  TXS_PER_SENDER="$2"; shift 2 ;;
    --slots)           SLOTS_PER_TX="$2"; shift 2 ;;
    --drain-tps)       DRAIN_TPS="$2"; shift 2 ;;
    --drain-s)         DRAIN_S="$2"; shift 2 ;;
    --stab-s)          STAB_S="$2"; shift 2 ;;
    --activate)        NM_LARC_ACTIVATE_MB="$2"; shift 2 ;;
    --deactivate)      NM_LARC_DEACTIVATE_MB="$2"; shift 2 ;;
    --variants)        IFS=',' read -ra VARIANTS <<< "$2"; shift 2 ;;
    --reps)            REPLICATIONS="$2"; shift 2 ;;
    --run-id)          RUN_ID="$2"
                       RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/larc_eval_nm_backlog/${RUN_ID}"
                       shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

mkdir -p "${RESULTS_DIR}"
export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="/home/yeochan.yoon/.dotnet/tools:${DOTNET_ROOT}:${PATH}"

# ── Resource check ──────────────────────────────────────────────────────────
check_resources() {
    local label="${1:-run}"
    while true; do
        local avail_gb load load_int
        avail_gb=$(free -g | awk '/^Mem/{print $7}')
        load=$(awk '{print $1}' /proc/loadavg)
        load_int=$(printf "%.0f" "${load}" 2>/dev/null || echo "${load%.*}")
        if [[ "${avail_gb}" -lt 30 ]] || [[ "${load_int}" -gt 20 ]]; then
            echo "  [RESOURCE] ${label}: avail=${avail_gb}GB load=${load} → heavy, waiting 10 min..."
            sleep 600
        else
            echo "  [RESOURCE] OK: avail=${avail_gb}GB load=${load}"
            return 0
        fi
    done
}

# ── NM helpers ───────────────────────────────────────────────────────────────
wait_for_rpc() {
    local max=120 count=0
    echo -n "  Waiting for RPC"
    while [[ "${count}" -lt "${max}" ]]; do
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
        while kill -0 "${pid}" 2>/dev/null && [[ "${w}" -lt 30 ]]; do sleep 1; w=$((w+1)); done
    fi
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

# ── Phase 2: stabilization check ────────────────────────────────────────────
# Wait up to STAB_S seconds for spills > 0 (LARC variants only).
# Returns 0 if spills>0 or variant=baseline; returns 3 if timeout with spills=0.
wait_for_larc_activation() {
    local larc_mode="$1" run_dir="$2"
    local larc_csv="${run_dir}/nm_larc_counters.csv"

    if [[ "${larc_mode}" == "DISABLED" ]]; then
        sleep "${STAB_S}"
        echo "  [STAB] baseline — no LARC activation expected"
        return 0
    fi

    echo "  [STAB] Waiting up to ${STAB_S}s for LARC spills>0 ..."
    local waited=0 spills=0
    while [[ "${waited}" -lt "${STAB_S}" ]]; do
        sleep 5; waited=$((waited+5))
        if [[ -f "${larc_csv}" ]] && [[ -s "${larc_csv}" ]]; then
            local last; last=$(tail -n +2 "${larc_csv}" 2>/dev/null | tail -1 || true)
            spills=$(echo "${last}" | awk -F',' '{print $2}' | grep -E '^[0-9]+$' || echo 0)
            spills="${spills:-0}"
            echo "  [STAB] t=${waited}s — larc_counters last_data: ${last}"
            if [[ "${spills}" -gt 0 ]]; then
                echo "  [STAB] LARC activated: spills=${spills}"
                return 0
            fi
        else
            echo "  [STAB] t=${waited}s — larc_counters.csv not yet written (30s dump interval)"
        fi
    done

    # Counters CSV is dumped every 30s; check nm_larc_decisions.csv for immediate signal
    local decisions_csv="${run_dir}/nm_larc_decisions.csv"
    if [[ -f "${decisions_csv}" ]]; then
        local n_spills; n_spills=$(grep -c ",SPILL," "${decisions_csv}" 2>/dev/null || echo 0)
        echo "  [STAB] nm_larc_decisions.csv: ${n_spills} spill events"
        if [[ "${n_spills:-0}" -gt 0 ]]; then
            echo "  [STAB] LARC activated (via decisions CSV): spills=${n_spills}"
            return 0
        fi
    fi

    echo "  [STAB] WARNING: spills=0 after ${STAB_S}s — LARC may not have activated"
    echo "  [STAB] Continuing — will collect metrics regardless"
    return 0  # don't abort; collect data and report
}

# ── RSS monitor ─────────────────────────────────────────────────────────────
start_rss_monitor() {
    local nm_pid="$1" rss_csv="$2"
    echo "timestamp_s,rss_mb" > "${rss_csv}"
    # >/dev/null: close $() pipe in background subshell to prevent deadlock
    (
        local nm_watch="${nm_pid}"
        while kill -0 "${nm_watch}" 2>/dev/null; do
            local rss_kb ts
            rss_kb=$(grep VmRSS /proc/${nm_watch}/status 2>/dev/null | awk '{print $2}' || echo 0)
            ts=$(date +%s)
            printf "%s,%.1f\n" "${ts}" "$(echo "${rss_kb}/1024" | bc -l)" >> "${rss_csv}"
            sleep 1
        done
    ) >/dev/null 2>/dev/null &
    echo $!
}

# ── Cleanup ─────────────────────────────────────────────────────────────────
cleanup_run() {
    local run_dir="$1" data_dir="$2" variant="$3" rep="$4" succeeded="$5"
    rm -rf "${data_dir}" 2>/dev/null || true
    rm -f  "${run_dir}/nm.pid" 2>/dev/null || true
    rm -f  "${run_dir}/deploy.log" 2>/dev/null || true
    if [[ "${succeeded}" == "1" ]]; then
        rm -f "${run_dir}/nm_console.log" 2>/dev/null || true
    else
        local nm_log="${run_dir}/nm_console.log"
        if [[ -f "${nm_log}" ]]; then
            local tmp; tmp=$(tail -200 "${nm_log}")
            printf '%s\n' "${tmp}" > "${nm_log}"
        fi
    fi
    if [[ -f "${run_dir}/caliper_console.log" ]]; then
        local sz; sz=$(wc -c < "${run_dir}/caliper_console.log" 2>/dev/null || echo 0)
        if [[ ${sz} -gt 5242880 ]]; then
            local tmp; tmp=$(tail -500 "${run_dir}/caliper_console.log")
            printf '%s\n' "${tmp}" > "${run_dir}/caliper_console.log"
        fi
    fi
    echo "  [CLEANUP] done"
}

# ── print_run_summary ────────────────────────────────────────────────────────
print_run_summary() {
    local run_dir="$1" variant="$2" rep="$3"
    echo ""
    echo "  ┌─ Summary: ${variant}_rep${rep} ──────────────────────────────────"

    local mline
    mline=$(grep "| drain \|| measure " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || true)
    [[ -n "${mline}" ]] && echo "  │ Caliper : ${mline}" || echo "  │ Caliper : (no measure line)"

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

    local larc_csv="${run_dir}/nm_larc_counters.csv"
    if [[ -f "${larc_csv}" ]] && [[ -s "${larc_csv}" ]]; then
        local last spills restores externalized failed nonce_blocked
        last=$(tail -n +2 "${larc_csv}" | tail -1 2>/dev/null || true)
        spills=$(echo "${last}"      | awk -F',' '{print $2}' | grep -E '^[0-9]+$' || echo 0)
        restores=$(echo "${last}"    | awk -F',' '{print $3}' | grep -E '^[0-9]+$' || echo 0)
        externalized=$(echo "${last}"| awk -F',' '{print $4}' | grep -E '^[0-9]+$' || echo 0)
        failed=$(echo "${last}"      | awk -F',' '{print $5}' | grep -E '^[0-9]+$' || echo 0)
        nonce_blocked=$(echo "${last}"| awk -F',' '{print $6}' | grep -E '^[0-9]+$' || echo 0)
        echo "  │ LARC    : spills=${spills} restores=${restores} externalized=${externalized} failed_restores=${failed} nonce_gap_blocked=${nonce_blocked}"
    else
        echo "  │ LARC    : (no nm_larc_counters.csv)"
    fi

    local decisions_csv="${run_dir}/nm_larc_decisions.csv"
    if [[ -f "${decisions_csv}" ]] && [[ -s "${decisions_csv}" ]]; then
        local n_spill n_restore
        n_spill=$(grep -c ",SPILL,"   "${decisions_csv}" 2>/dev/null || echo 0)
        n_restore=0
        echo "  │ Decisions: spill_events=${n_spill} restore_events=${n_restore}"
    fi

    [[ -f "${run_dir}/result.json" ]] && echo "  │ result  : $(cat "${run_dir}/result.json")"
    echo "  └──────────────────────────────────────────────────────────────────"
}

# ── Single run (one variant, one rep) ───────────────────────────────────────
run_backlog_once() {
    local variant="$1" rep="$2"
    local run_dir="${RESULTS_DIR}/${variant}_rep${rep}"
    local data_dir="/tmp/larc_nm_backlog_${variant}_rep${rep}_${RUN_ID}"

    local larc_mode="DISABLED"
    case "${variant}" in
        nm_lass_compat) larc_mode="LASS_COMPAT" ;;
        nm_larc_la)     larc_mode="LOCALITY_AWARE" ;;
    esac

    mkdir -p "${run_dir}"

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "VARIANT=${variant} REP=${rep} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "MODE=${larc_mode} | ACTIVATE=${NM_LARC_ACTIVATE_MB}MB DEACTIVATE=${NM_LARC_DEACTIVATE_MB}MB"
    echo "Preload: ${N_SENDERS} senders × ${TXS_PER_SENDER} TXs (${SLOTS_PER_TX} slots each)"
    echo "Drain  : ${DRAIN_TPS} TPS for ${DRAIN_S}s"
    echo "════════════════════════════════════════════════════════════════"

    stop_nm
    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    # ── Start NM ─────────────────────────────────────────────────────────────
    echo "  [Phase 0] Starting Nethermind ..."
    NM_LARC_MODE="${larc_mode}" \
    NM_LARC_ACTIVATE_MB="${NM_LARC_ACTIVATE_MB}" \
    NM_LARC_DEACTIVATE_MB="${NM_LARC_DEACTIVATE_MB}" \
    NM_LARC_DATA_DIR="${run_dir}" \
    NM_LARC_MONITOR_MS="500" \
    NM_LARC_NONCE_WINDOW="8" \
    NM_LARC_SPILL_BATCH="20" \
    NM_LARC_RESTORE_BATCH="10" \
    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}/nm_db" \
        --Init.LogFileName "${data_dir}/nm.log" \
        > "${run_dir}/nm_console.log" 2>&1 &
    local nm_pid=$!
    echo "${nm_pid}" > "${run_dir}/nm.pid"

    if ! wait_for_rpc; then
        echo "  ERROR: RPC timeout" | tee "${run_dir}/diagnosis.txt"
        echo '{"result":"rpc_timeout"}' > "${run_dir}/result.json"
        stop_nm "${nm_pid}"; return 1
    fi

    # ── Deploy contracts ──────────────────────────────────────────────────────
    echo "  [Phase 0] Deploying 30 StateBloater contracts ..."
    node "${DEPLOY_NM}" 30 "${NETWORKCONFIG}" > "${run_dir}/deploy.log" 2>&1 || true
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed" | tee "${run_dir}/diagnosis.txt"
        echo '{"result":"deploy_failed"}' > "${run_dir}/result.json"
        stop_nm "${nm_pid}"; return 1
    fi
    sleep 3

    # ── Start RSS monitor ─────────────────────────────────────────────────────
    local rss_csv="${run_dir}/rss_monitor.csv"
    local dc_pid; dc_pid=$(start_rss_monitor "${nm_pid}" "${rss_csv}")
    echo "  RSS monitor PID=${dc_pid}"

    # ── Phase 1: Preload ──────────────────────────────────────────────────────
    echo ""
    echo "  [Phase 1] Preloading ${N_SENDERS} × ${TXS_PER_SENDER} = $((N_SENDERS * TXS_PER_SENDER)) TXs ..."
    local preload_out
    preload_out=$(node "${PRELOAD_JS}" "${N_SENDERS}" "${TXS_PER_SENDER}" "${SLOTS_PER_TX}" \
                       "${NETWORKCONFIG}" 2>&1) || true
    echo "${preload_out}" | grep -E "^\[preload\]|^PRELOAD_SUMMARY" | sed 's/^/  /'
    local pending_count=0
    pending_count=$(echo "${preload_out}" | grep "PRELOAD_SUMMARY:" | \
        python3 -c "import json,sys; d=json.loads(sys.stdin.read().split('PRELOAD_SUMMARY:')[-1]); print(d.get('pending_after_1s',-1))" 2>/dev/null || echo -1)
    echo "  [Phase 1] Pending pool after preload: ${pending_count}"

    if ! kill -0 "${nm_pid}" 2>/dev/null; then
        echo "  ERROR: NM died during preload" | tee "${run_dir}/diagnosis.txt"
        echo '{"result":"nm_died_preload"}' > "${run_dir}/result.json"
        kill "${dc_pid}" 2>/dev/null || true; wait "${dc_pid}" 2>/dev/null || true
        return 1
    fi

    # ── Phase 2: Stabilization ────────────────────────────────────────────────
    echo ""
    echo "  [Phase 2] Stabilization (${STAB_S}s) ..."
    wait_for_larc_activation "${larc_mode}" "${run_dir}"

    # ── Phase 3: Drain (Caliper) ──────────────────────────────────────────────
    echo ""
    echo "  [Phase 3] Running Caliper drain at ${DRAIN_TPS} TPS for ${DRAIN_S}s ..."
    local t_start; t_start=$(date +%s)
    timeout "${CALIPER_TIMEOUT}" npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig benchconfig-larc-backlog-nm.yaml \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1 &
    local caliper_pid=$!

    # Mid-drain monitoring
    local elapsed_mon=0
    while kill -0 "${caliper_pid}" 2>/dev/null; do
        sleep 30; elapsed_mon=$((elapsed_mon+30))
        if ! kill -0 "${nm_pid}" 2>/dev/null; then
            echo "  [MONITOR] NM died at ~${elapsed_mon}s → killing caliper"
            kill "${caliper_pid}" 2>/dev/null || true; break
        fi
        local avail_gb; avail_gb=$(free -g | awk '/^Mem/{print $7}')
        # Check spills from decisions CSV (dumped continuously)
        local n_spill=0
        [[ -f "${run_dir}/nm_larc_decisions.csv" ]] && \
            n_spill=$(grep -c ",SPILL," "${run_dir}/nm_larc_decisions.csv" 2>/dev/null || echo 0)
        echo "  [MONITOR] t=${elapsed_mon}s | NM alive | avail=${avail_gb}GB | spill_events=${n_spill}"
    done

    wait "${caliper_pid}" 2>/dev/null || true
    local t_end; t_end=$(date +%s)
    echo "  Caliper done. Elapsed: $((t_end - t_start))s"

    # ── Kill RSS monitor ─────────────────────────────────────────────────────
    kill "${dc_pid}" 2>/dev/null || true
    wait "${dc_pid}" 2>/dev/null || true
    stop_nm "${nm_pid}"

    # ── Parse caliper result ─────────────────────────────────────────────────
    local mline
    mline=$(grep "| drain " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || true)
    if [[ -z "${mline}" ]]; then
        echo "  ERROR: No measure line in caliper output" | tee "${run_dir}/diagnosis.txt"
        echo '{"result":"no_measure_line"}' > "${run_dir}/result.json"
        cleanup_run "${run_dir}" "${data_dir}" "${variant}" "${rep}" "0"; return 1
    fi

    local succ fail tps_actual avg_s
    succ=$(echo "${mline}"      | awk -F'|' '{gsub(/ /,""); print $3}')
    fail=$(echo "${mline}"      | awk -F'|' '{gsub(/ /,""); print $4}')
    tps_actual=$(echo "${mline}"| awk -F'|' '{gsub(/ /,""); print $5}')
    avg_s=$(echo "${mline}"     | awk -F'|' '{gsub(/ /,""); print $8}')

    local total=$((${succ:-0} + ${fail:-0}))
    local success_rate=0
    [[ "${total}" -gt 0 ]] && success_rate=$(python3 -c \
        "print(round(${succ:-0}/${total}*100,1))" 2>/dev/null || echo 0)

    # Parse RSS
    local rss_max rss_min rss_samples
    rss_max=$(tail -n +2 "${rss_csv}" | awk -F',' '{print $2}' | sort -rn | head -1 | tr -d ' \r' || echo 0)
    rss_min=$(tail -n +2 "${rss_csv}" | awk -F',' '{print $2}' | sort -n  | head -1 | tr -d ' \r' || echo 0)
    rss_samples=$(tail -n +2 "${rss_csv}" | wc -l 2>/dev/null || echo 0)

    # Parse LARC counters (final snapshot)
    local larc_spills=0 larc_restores=0 larc_externalized=0 larc_failed=0 nonce_blocked=0
    local larc_csv="${run_dir}/nm_larc_counters.csv"
    if [[ -f "${larc_csv}" ]] && [[ -s "${larc_csv}" ]]; then
        local last; last=$(tail -n +2 "${larc_csv}" | tail -1 2>/dev/null || true)
        larc_spills=$(echo "${last}"      | awk -F',' '{print $2}' | grep -E '^[0-9]+$' || echo 0)
        larc_restores=$(echo "${last}"    | awk -F',' '{print $3}' | grep -E '^[0-9]+$' || echo 0)
        larc_externalized=$(echo "${last}"| awk -F',' '{print $4}' | grep -E '^[0-9]+$' || echo 0)
        larc_failed=$(echo "${last}"      | awk -F',' '{print $5}' | grep -E '^[0-9]+$' || echo 0)
        nonce_blocked=$(echo "${last}"    | awk -F',' '{print $6}' | grep -E '^[0-9]+$' || echo 0)
    fi
    # Also count from decisions CSV (granular; only SPILL events written, no RESTORE)
    local n_spill_events=0 n_restore_events=0
    if [[ -f "${run_dir}/nm_larc_decisions.csv" ]]; then
        n_spill_events=$(grep -c ",SPILL," "${run_dir}/nm_larc_decisions.csv" 2>/dev/null || echo 0)
    fi

    echo "  RESULT: Succ=${succ} Fail=${fail} Rate=${success_rate}% TPS=${tps_actual} Lat=${avg_s}s"
    echo "  LARC  : Spills=${larc_spills} Restores=${larc_restores} Externalized=${larc_externalized} NonceBlocked=${nonce_blocked}"
    echo "  RSS   : max=${rss_max}MB min=${rss_min}MB samples=${rss_samples}"

    cat > "${run_dir}/result.json" << EOJSON
{"variant":"${variant}","rep":${rep},"succ":${succ:-0},"fail":${fail:-0},"success_rate_pct":${success_rate},"tps_actual":${tps_actual:-0},"avg_lat_s":${avg_s:-0},"larc_mode":"${larc_mode}","slots_per_tx":${SLOTS_PER_TX},"n_senders":${N_SENDERS},"txs_per_sender":${TXS_PER_SENDER},"pending_after_preload":${pending_count},"spills":${larc_spills:-0},"restores":${larc_restores:-0},"externalized":${larc_externalized:-0},"failed_restores":${larc_failed:-0},"nonce_gap_blocked":${nonce_blocked:-0},"spill_events":${n_spill_events:-0},"restore_events":${n_restore_events:-0},"rss_max_mb":${rss_max:-0},"rss_min_mb":${rss_min:-0},"rss_samples":${rss_samples:-0},"activate_mb":${NM_LARC_ACTIVATE_MB},"deactivate_mb":${NM_LARC_DEACTIVATE_MB}}
EOJSON

    # Validity check
    local sr_int; sr_int=$(python3 -c "print(int(${success_rate}))" 2>/dev/null || echo 0)
    if [[ "${larc_mode}" != "DISABLED" ]] && [[ "${larc_spills:-0}" -eq 0 ]] && [[ "${n_spill_events:-0}" -eq 0 ]]; then
        echo "  [VALIDITY] LARC spills=0 — label as: no_spill (pool empty or threshold issue)"
        echo "no_spill" > "${run_dir}/validity.txt"
    elif [[ "${sr_int}" -lt 85 ]]; then
        echo "  [VALIDITY] Low success rate — label as: low_success"
        echo "low_success" > "${run_dir}/validity.txt"
    else
        echo "  [VALIDITY] OK"
        echo "ok" > "${run_dir}/validity.txt"
    fi

    cleanup_run "${run_dir}" "${data_dir}" "${variant}" "${rep}" "1"
    return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "NM LARC Backlog Evaluation  RUN_ID=${RUN_ID}"
echo "Variants  : ${VARIANTS[*]}"
echo "Reps      : ${REPLICATIONS}"
echo "Preload   : ${N_SENDERS} senders × ${TXS_PER_SENDER} TXs × ${SLOTS_PER_TX} slots"
echo "  Spillable estimate: ~$((N_SENDERS * (TXS_PER_SENDER > 9 ? TXS_PER_SENDER - 9 : 0))) TXs (nonce > min+8, W=8)"
echo "Drain     : ${DRAIN_TPS} TPS for ${DRAIN_S}s"
echo "LARC      : ACTIVATE=${NM_LARC_ACTIVATE_MB}MB (CLR managed heap, not RSS)"
echo "           DEACTIVATE=${NM_LARC_DEACTIVATE_MB}MB"
echo "Results   : ${RESULTS_DIR}"
echo "NM DLL    : ${NM_DLL}"
echo "Started   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

check_resources "startup"

for rep in $(seq 1 "${REPLICATIONS}"); do
    for variant in "${VARIANTS[@]}"; do
        if [[ -f "${RESULTS_DIR}/${variant}_rep${rep}/result.json" ]]; then
            echo "  [SKIP] ${variant}_rep${rep} — result.json exists"
            continue
        fi
        check_resources "${variant}_rep${rep}"
        run_backlog_once "${variant}" "${rep}" || echo "  [FAILED] ${variant}_rep${rep}"
        print_run_summary "${RESULTS_DIR}/${variant}_rep${rep}" "${variant}" "${rep}"
        sleep "${COOLDOWN}"
    done
    echo ""
    echo "=== Rep ${rep}/${REPLICATIONS} complete. Inter-rep cooldown 60s ==="
    sleep 60
done

echo ""
echo "======================================================================"
echo "NM LARC Backlog Eval COMPLETE. Results: ${RESULTS_DIR}"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

echo ""
echo "=== FINAL SUMMARY ==="
for variant in "${VARIANTS[@]}"; do
    echo "--- ${variant} ---"
    for rep in $(seq 1 "${REPLICATIONS}"); do
        local_dir="${RESULTS_DIR}/${variant}_rep${rep}"
        if [[ -f "${local_dir}/result.json" ]]; then
            validity=""; [[ -f "${local_dir}/validity.txt" ]] && validity=" [$(cat "${local_dir}/validity.txt")]"
            echo "  rep${rep}${validity}: $(cat "${local_dir}/result.json")"
        else
            echo "  rep${rep}: (missing)"
        fi
    done
done
