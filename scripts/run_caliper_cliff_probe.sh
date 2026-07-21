#!/bin/bash
# ============================================================
# Caliper Cliff Probe: single ctrl run at 1500 TPS, 1g heap
# Confirms whether 1g heap causes GC cliff under real Caliper load.
# Usage: bash scripts/run_caliper_cliff_probe.sh [heap_size]
#   heap_size default: 1g
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

BESU_BIN="/home/yeochan.yoon/besu-24.1.1/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
HEAP="${1:-1g}"

RUN_ID=$(date +%Y%m%d_%H%M%S)_probe_${HEAP}
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/cliff_probe/${RUN_ID}"
DATA_DIR="/home/yeochan.yoon/caliper-stress-test/data_probe_${RUN_ID}"
GC_LOG="${RESULTS_DIR}/gc.log"
PID_FILE="/tmp/besu_probe.pid"

mkdir -p "${RESULTS_DIR}"

NEWGEN_FLAGS="-XX:+UnlockExperimentalVMOptions -XX:G1MaxNewSizePercent=90 -XX:G1NewSizePercent=20"

echo "======================================================================"
echo "Caliper Cliff Probe | Heap: ${HEAP} | 1500 TPS | 120s"
echo "Results: ${RESULTS_DIR}"
echo "======================================================================"

# Kill any stray Besu from prior runs
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
sleep 3

rm -rf "${DATA_DIR}"; mkdir -p "${DATA_DIR}"

export BESU_OPTS="-Xms${HEAP} -Xmx${HEAP} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapWastePercent=5 \
${NEWGEN_FLAGS} \
-Xlog:gc*=info:file=${GC_LOG}:time,uptime,level,tags:filecount=5,filesize=50M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
-Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=9011 \
-Dcom.sun.management.jmxremote.local.only=false \
-Dcom.sun.management.jmxremote.authenticate=false \
-Dcom.sun.management.jmxremote.ssl=false"

nohup "${BESU_BIN}" \
    --network=dev --data-path="${DATA_DIR}" \
    --miner-enabled \
    --miner-coinbase=0xBE0cf996DE312b11990E4BcbBf7Fc156880AcFC8 \
    --rpc-http-enabled --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
    --rpc-http-cors-origins="*" --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
    --rpc-ws-enabled --rpc-ws-host=0.0.0.0 --rpc-ws-port=8546 \
    --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
    --host-allowlist="*" --min-gas-price=0 \
    --tx-pool-layer-max-capacity=1000000 --tx-pool-max-prioritized=1000000 \
    --tx-pool-max-future-by-sender=100000 \
    --logging=INFO \
    > "${DATA_DIR}/besu_console.log" 2>&1 &
BESU_PID=$!
echo "${BESU_PID}" > "${PID_FILE}"
echo "Besu PID: ${BESU_PID}"

# Wait for RPC
echo -n "Waiting for RPC"
for i in $(seq 1 120); do
    if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 > /dev/null 2>&1; then
        echo " READY"; break
    fi
    echo -n "."; sleep 1
done

# Deploy contract so networkconfig.json has correct address for this chain
echo "Deploying contract..."
python3 deploy_contract.py > "${RESULTS_DIR}/deploy.log" 2>&1
CONTRACT=$(grep "Contract Address:" "${RESULTS_DIR}/deploy.log" | awk '{print $3}')
echo "Contract: ${CONTRACT}"
if [ -z "${CONTRACT}" ]; then cat "${RESULTS_DIR}/deploy.log"; kill -9 "${BESU_PID}"; exit 1; fi

echo "Waiting 5s for Besu to stabilize before Caliper..."
sleep 5

# Run Caliper probe
echo ""
echo "Starting Caliper probe (600s @ 1500 TPS)..."
npx caliper launch manager \
    --caliper-workspace ./ \
    --caliper-benchconfig benchconfig-harsh-probe.yaml \
    --caliper-networkconfig networkconfig.json \
    2>&1 | tee "${RESULTS_DIR}/caliper_console.log"
CALIPER_EXIT=${PIPESTATUS[0]}

echo "Caliper exit: ${CALIPER_EXIT}"

# Collect results
cp caliper.log "${RESULTS_DIR}/caliper.log" 2>/dev/null || true
cp report.html "${RESULTS_DIR}/report.html" 2>/dev/null || true
cp "${DATA_DIR}/besu_console.log" "${RESULTS_DIR}/besu_console.log" 2>/dev/null || true

# Kill Besu
kill "${BESU_PID}" 2>/dev/null || true
sleep 5; kill -9 "${BESU_PID}" 2>/dev/null || true
rm -f "${PID_FILE}"

# Analyze GC
echo ""
echo "=== GC CLIFF ANALYSIS ==="
cnt=$(grep -c "Pause Young\|Pause Full\|Pause Mixed" "${GC_LOG}" 2>/dev/null || echo 0)
max=$(grep "Pause" "${GC_LOG}" 2>/dev/null | grep -oP '[\d.]+ms$' | sed 's/ms//' | sort -n | tail -1)
total=$(grep "Pause" "${GC_LOG}" 2>/dev/null | grep -oP '[\d.]+ms$' | sed 's/ms//' | awk '{s+=$1}END{printf "%.1f",s}')
full_cnt=$(grep -c "Pause Full" "${GC_LOG}" 2>/dev/null || echo 0)
full_max=$(grep "Pause Full" "${GC_LOG}" 2>/dev/null | grep -oP '[\d.]+ms$' | sed 's/ms//' | sort -n | tail -1 || echo "0")
echo "Heap: ${HEAP}"
echo "GC events: ${cnt} | MaxGC: ${max}ms | TotalGC: ${total}ms"
echo "Full GC events: ${full_cnt} | Max Full GC: ${full_max}ms"
if [ "${full_cnt}" -gt 0 ] || ([ -n "${max}" ] && awk "BEGIN{exit (${max}+0 > 200) ? 0 : 1}"); then
    echo "*** CLIFF CONFIRMED: Full GC or MaxGC > 200ms ***"
else
    echo "No cliff at ${HEAP}. MaxGC=${max}ms. Try smaller heap or higher load."
fi
echo "Results: ${RESULTS_DIR}"
