#!/bin/bash
# ============================================================
# Saturation Throughput Test — Besu @ 4GB Heap, 100 TPS
#
# Tests 4 variants × 2 reps with realistic load (100 TPS).
# Measures confirmed TPS and latency to demonstrate LAST/LASS
# throughput improvements without mempool DDOS effect.
#
# Variants (same binaries as 4g experiment):
#   baseline   : DISABLED LAST, no LASS
#   lass75     : DISABLED LAST, LASS-75
#   last_al    : ADDRESS_LOCALITY, no LASS
#   last_lass75: ADDRESS_LOCALITY, LASS-75
#
# Caliper: 60s warmup + 120s measure, 100 TPS, 30 workers
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_LASS="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-throughput-40tps.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
REPLICATIONS=2
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
LASS75_OPTS="-Dlass.old.gen.activation.threshold=0.75 -Dlass.old.gen.deactivation.threshold=0.60 -Dlass.old.gen.consecutive.samples=1"
LAST_AL_OPTS="-Dlast.variant=ADDRESS_LOCALITY -Dlass.old.gen.activation.threshold=2.0"
DISABLED_LAST="-Dlast.variant=DISABLED -Dlass.old.gen.activation.threshold=2.0"

RUN_ID=$(date +%Y%m%d_%H%M%S)_throughput_40tps
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/throughput_40tps/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "Besu Throughput Test | 40 TPS | 120s warmup + 180s measure | 2 reps"
echo "Run ID: ${RUN_ID}"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

wait_for_rpc() {
    local max_wait=120 count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " READY"; return 0
        fi
        echo -n "."; sleep 1; count=$((count + 1))
    done
    echo " TIMEOUT"; return 1
}

stop_besu() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0
    while kill -0 "${pid}" 2>/dev/null && [ ${w} -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

run_single() {
    local variant="$1" rep="$2" last_opt="$3" lass_opt="$4"
    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_lvl_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc.log"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  LAST: ${last_opt}"
    echo "  LASS: ${lass_opt:-none}"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
    rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapWastePercent=5 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=3,filesize=20M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${last_opt} \
${lass_opt}"

    export BESU_OPTS="${java_opts}"

    nohup "${BESU_LASS}" \
        --network=dev \
        --miner-enabled \
        --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
        --data-path="${data_dir}" \
        --rpc-http-enabled --rpc-http-port=8545 --rpc-http-host=0.0.0.0 \
        --rpc-http-cors-origins="*" \
        --rpc-ws-enabled --rpc-ws-port=8546 --rpc-ws-max-active-connections=200 \
        --host-allowlist="*" \
        --min-gas-price=0 \
        --tx-pool-layer-max-capacity=1000000 \
        --tx-pool-max-prioritized=1000000 \
        --tx-pool-max-future-by-sender=100000 \
        > "${run_dir}/besu_console.log" 2>&1 &
    local besu_pid=$!
    echo "  Besu PID: ${besu_pid}"

    sleep 8
    if ! kill -0 ${besu_pid} 2>/dev/null; then
        echo "  ERROR: Besu died at startup."
        tail -20 "${run_dir}/besu_console.log" || true
        return 1
    fi

    wait_for_rpc || { stop_besu "${besu_pid}"; return 1; }

    echo "  Deploying 30 StateBloater contracts..."
    python3 "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_besu "${besu_pid}"
        return 1
    fi
    echo "  First contract: $(grep 'Contract Address:' "${run_dir}/deploy.log" | head -1 | awk '{print $3}')"
    sleep 3

    echo "  Running Caliper (120s warmup + 180s measure @ 40 TPS)..."
    local t_start; t_start=$(date +%s)
    timeout 900 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG}" \
        --caliper-networkconfig "${NETWORKCONFIG}" \
        > "${run_dir}/caliper_console.log" 2>&1
    local caliper_exit=$?
    local t_end; t_end=$(date +%s)
    echo "  Caliper exit: ${caliper_exit}. Elapsed: $((t_end - t_start))s"

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true

    echo "  Stopping Besu..."
    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"
    echo "  ✓ ${label} complete"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 3

# ── Phase 1: Baseline ────────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 1: ${REPLICATIONS}×BASELINE"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "baseline" "${i}" "${DISABLED_LAST}" "" || echo "  WARNING: baseline_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && echo "  (pause 20s)" && sleep 20
done

# ── Phase 2: LASS-75 ─────────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 2: ${REPLICATIONS}×LASS-75"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "lass75" "${i}" "${DISABLED_LAST}" "${LASS75_OPTS}" || echo "  WARNING: lass75_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && echo "  (pause 20s)" && sleep 20
done

# ── Phase 3: LAST-AL ─────────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 3: ${REPLICATIONS}×LAST-AL"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_al" "${i}" "${LAST_AL_OPTS}" "" || echo "  WARNING: last_al_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && echo "  (pause 20s)" && sleep 20
done

# ── Phase 4: LAST+LASS-75 ────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 4: ${REPLICATIONS}×LAST+LASS-75"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_single "last_lass75" "${i}" "${LAST_AL_OPTS}" "${LASS75_OPTS}" || echo "  WARNING: last_lass75_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && echo "  (pause 20s)" && sleep 20
done

# ── Inline Analysis ───────────────────────────────────────────────────────────
echo ""; echo "======================================================================"; echo "ALL RUNS COMPLETE — generating throughput report"
echo "======================================================================"

REPORT="${RESULTS_DIR}/throughput_comparison_40tps.md"
cat > "${REPORT}" <<REPORTEOF
# Besu Throughput Comparison @ 40 TPS Sustained Load

**Generated:** $(date '+%Y-%m-%d %H:%M:%S')
**Run ID:** ${RUN_ID}
**Results:** ${RESULTS_DIR}

## Configuration

| Parameter | Value |
|-----------|-------|
| Client | Hyperledger Besu (dev network) |
| Heap | 4g (-Xms4g -Xmx4g, G1GC) |
| Target TPS | 40 (sustained, below ~70 TPS EVM capacity) |
| Warmup | 120s |
| Measure | 180s |
| Workers | 30 |
| Workload | stateBloat, 200 slots/tx |
| Replications | ${REPLICATIONS} per variant |

## Per-Run Results

| Run | Succ | Fail | Send Rate (TPS) | Max Lat (s) | Min Lat (s) | Avg Lat (s) | Throughput (TPS) |
|-----|------|------|----------------|-------------|-------------|-------------|-----------------|
REPORTEOF

for variant in baseline lass75 last_al last_lass75; do
    for i in $(seq 1 ${REPLICATIONS}); do
        run_dir="${RESULTS_DIR}/${variant}_${i}"
        line=$(grep "| measure " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || echo "")
        if [ -n "${line}" ]; then
            succ=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
            fail=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
            send=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$5); print $5}')
            maxl=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$6); print $6}')
            minl=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$7); print $7}')
            avgl=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$8); print $8}')
            tput=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$9); print $9}')
            echo "| ${variant}_${i} | ${succ} | ${fail} | ${send} | ${maxl} | ${minl} | ${avgl} | ${tput} |" >> "${REPORT}"
        else
            echo "| ${variant}_${i} | N/A | N/A | N/A | N/A | N/A | N/A | N/A |" >> "${REPORT}"
        fi
    done
done

cat >> "${REPORT}" <<REPORTEOF2

## Summary (mean across reps)

| Variant | Confirmed TPS | Avg Latency (s) | Max Latency (s) |
|---------|-------------|-----------------|-----------------|
REPORTEOF2

for variant in baseline lass75 last_al last_lass75; do
    tputs="" avglats="" maxlats=""
    for i in $(seq 1 ${REPLICATIONS}); do
        run_dir="${RESULTS_DIR}/${variant}_${i}"
        line=$(grep "| measure " "${run_dir}/caliper_console.log" 2>/dev/null | tail -1 || echo "")
        if [ -n "${line}" ]; then
            tput=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$9); print $9}')
            avgl=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$8); print $8}')
            maxl=$(echo "${line}" | awk -F'|' '{gsub(/ /,"",$6); print $6}')
            tputs="${tputs} ${tput}"
            avglats="${avglats} ${avgl}"
            maxlats="${maxlats} ${maxl}"
        fi
    done
    mean_tput=$(echo "${tputs}" | tr ' ' '\n' | grep -v '^$' | awk '{s+=$1;n++} END {if(n>0) printf "%.1f",s/n; else print "N/A"}')
    mean_avgl=$(echo "${avglats}" | tr ' ' '\n' | grep -v '^$' | awk '{s+=$1;n++} END {if(n>0) printf "%.3f",s/n; else print "N/A"}')
    mean_maxl=$(echo "${maxlats}" | tr ' ' '\n' | grep -v '^$' | awk '{s+=$1;n++} END {if(n>0) printf "%.3f",s/n; else print "N/A"}')
    echo "| ${variant} | ${mean_tput} | ${mean_avgl} | ${mean_maxl} |" >> "${REPORT}"
done

echo "" >> "${REPORT}"
echo "---" >> "${REPORT}"
echo "*Report generated by run_throughput_100tps_besu.sh*" >> "${REPORT}"

echo "Report: ${REPORT}"
echo "Done. Results: ${RESULTS_DIR}"
