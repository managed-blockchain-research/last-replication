#!/bin/bash
# Baseline backfill — 4 additional baseline runs (baseline_6–9)
# Extends the original 4g experiment to N=5 valid baseline runs.
# Appends results into the original RESULTS_DIR.
set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_LASS="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
BENCHCONFIG="benchconfig-last-vs-lass-4g.yaml"
NETWORKCONFIG="networkconfig.json"
DEPLOY_SCRIPT="deploy_multi_contracts.py"

HEAP="4g"
NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"
DISABLED_LAST="-Dlast.variant=DISABLED -Dlass.old.gen.activation.threshold=2.0"

RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/last_vs_lass_4g/20260424_045512_last_vs_lass_4g"
RUN_ID="20260424_backfill"

echo "======================================================================"
echo "BASELINE BACKFILL — 4 runs (baseline_6–9) @ 4g heap"
echo "Results dir: ${RESULTS_DIR}"
echo "======================================================================"

wait_for_rpc() {
    local max_wait=120
    local count=0
    echo -n "  Waiting for RPC"
    while [ ${count} -lt ${max_wait} ]; do
        if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
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

stop_besu() {
    local besu_pid="$1"
    kill "${besu_pid}" 2>/dev/null || true
    local wait=0
    while kill -0 "${besu_pid}" 2>/dev/null && [ ${wait} -lt 30 ]; do
        sleep 1; wait=$((wait+1))
    done
    kill -9 "${besu_pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

run_single() {
    local variant="$1"
    local rep="$2"
    local besu_bin="$3"
    local last_opt="$4"
    local lass_opt="$5"

    local label="${variant}_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"
    mkdir -p "${run_dir}"

    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_lvl_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc.log"

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  binary: $(basename $(dirname ${besu_bin}))/$(basename ${besu_bin})"
    echo "  LAST:   ${last_opt}"
    echo "  LASS:   ${lass_opt:-none}"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5

    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
-XX:G1HeapWastePercent=5 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=3,filesize=20M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
${last_opt} \
${lass_opt}"

    export BESU_OPTS="${java_opts}"

    nohup "${besu_bin}" \
        --network=dev \
        --miner-enabled \
        --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
        --data-path="${data_dir}" \
        --rpc-http-enabled \
        --rpc-http-port=8545 \
        --rpc-http-host=0.0.0.0 \
        --rpc-http-cors-origins="*" \
        --rpc-ws-enabled \
        --rpc-ws-port=8546 \
        --rpc-ws-max-active-connections=200 \
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
        echo "failed=startup" > "${run_dir}/FAILED"
        return 1
    fi

    wait_for_rpc || {
        stop_besu "${besu_pid}"
        echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        return 1
    }

    echo "  Deploying 30 StateBloater contracts..."
    python3 "${DEPLOY_SCRIPT}" > "${run_dir}/deploy.log" 2>&1
    if ! grep -q "Contract Address:" "${run_dir}/deploy.log" 2>/dev/null; then
        echo "  ERROR: Deploy failed."
        cat "${run_dir}/deploy.log"
        stop_besu "${besu_pid}"
        echo "failed=deploy" > "${run_dir}/FAILED"
        return 1
    fi
    local contract_addr
    contract_addr=$(grep "Contract Address:" "${run_dir}/deploy.log" | awk '{print $3}')
    echo "  First contract: ${contract_addr}"

    sleep 3

    echo "  Running Caliper (120s warmup + 300s measure @ 1500 TPS)..."
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

    cp caliper.log  "${run_dir}/caliper.log"  2>/dev/null || true
    cp report.html  "${run_dir}/report.html"  2>/dev/null || true

    echo "  Stopping Besu..."
    stop_besu "${besu_pid}"
    rm -rf "${data_dir}"

    local measure_line
    measure_line=$(grep "| measure " "${run_dir}/caliper_console.log" | tail -1 || true)
    echo "  Caliper measure: ${measure_line}"

    echo "  ✓ ${label} complete"
}

pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 3

echo ""
echo "=============================="
echo "BASELINE BACKFILL: runs 6–9"
echo "=============================="

for i in 6 7 8 9; do
    run_single "baseline" "${i}" "${BESU_LASS}" "${DISABLED_LAST}" "" \
        || echo "  WARNING: baseline_${i} failed, continuing"
    if [ "${i}" -lt 9 ]; then
        echo "  (pause 30s between runs)"
        sleep 30
    fi
done

echo ""
echo "======================================================================"
echo "BACKFILL COMPLETE — baseline_6 through baseline_9"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"
