#!/bin/bash
# Start Besu with the fixed LASS implementation (E-Spill now actually removes from pool)
# Uses 4GB heap + Old Gen 20% threshold for quick triggering in short experiments

set -e

BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
DATA_DIR="/home/yeochan.yoon/caliper-stress-test/data_lass_fixed"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GC_LOG_FILE="/home/yeochan.yoon/caliper-stress-test/lass_fixed_gc_${TIMESTAMP}.log"

echo "======================================================================"
echo "Starting Besu with FIXED LASS (E-Spill v2)"
echo "======================================================================"
echo "Heap: 4GB  |  Old Gen activation: 20%  |  Build: besu-source"
echo ""

if pgrep -f "besu.*--network=dev" > /dev/null; then
    echo "ERROR: Besu is already running. Stop with: ./scripts/stop_besu.sh"
    exit 1
fi

mkdir -p "${DATA_DIR}"

JAVA_OPTS="-Xms4g -Xmx4g \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
-XX:G1HeapRegionSize=4m \
-Xlog:gc*=info:file=${GC_LOG_FILE}:time,level,tags:filecount=5,filesize=50M \
-Dlog4j.configurationFile=/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml \
-Dlass.old.gen.activation.threshold=0.15 \
-Dlass.old.gen.deactivation.threshold=0.08 \
-Dlass.old.gen.consecutive.samples=3 \
-Dcom.sun.management.jmxremote \
-Dcom.sun.management.jmxremote.port=9011 \
-Dcom.sun.management.jmxremote.local.only=false \
-Dcom.sun.management.jmxremote.authenticate=false \
-Dcom.sun.management.jmxremote.ssl=false"

export BESU_OPTS="${JAVA_OPTS}"

nohup "${BESU_BIN}" \
    --network=dev \
    --data-path="${DATA_DIR}" \
    --miner-enabled \
    --miner-coinbase=0xBE0cf996DE312b11990E4BcbBf7Fc156880AcFC8 \
    --rpc-http-enabled \
    --rpc-http-host=0.0.0.0 \
    --rpc-http-port=8545 \
    --rpc-http-cors-origins="*" \
    --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
    --rpc-ws-enabled \
    --rpc-ws-host=0.0.0.0 \
    --rpc-ws-port=8546 \
    --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
    --host-allowlist="*" \
    --min-gas-price=0 \
    --tx-pool-layer-max-capacity=20000 \
    --tx-pool-max-prioritized=10000 \
    --logging=INFO \
    > "${DATA_DIR}/besu_console.log" 2>&1 &

BESU_PID=$!
echo "PID: ${BESU_PID}"
echo "${BESU_PID}" > /tmp/besu_lass_fixed.pid

sleep 5
if ! kill -0 ${BESU_PID} 2>/dev/null; then
    echo "ERROR: Besu died. Check: tail -50 ${DATA_DIR}/besu_console.log"
    exit 1
fi

MAX_WAIT=60; WAIT_COUNT=0
while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
    if curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 > /dev/null 2>&1; then
        echo "Besu RPC ready!"
        break
    fi
    echo -n "."; sleep 1; WAIT_COUNT=$((WAIT_COUNT + 1))
done

echo ""
echo "GC log:      ${GC_LOG_FILE}"
echo "Console log: ${DATA_DIR}/besu_console.log"
echo ""
echo "Monitor LASS activity:"
echo "  grep 'E-SPILL' ${DATA_DIR}/besu_console.log"
echo ""
