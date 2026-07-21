#!/bin/bash

# E-Spill Baseline: Start Besu in Dev Mode with Comprehensive GC Logging
# This script launches Besu with detailed GC monitoring for baseline measurements

set -e

BESU_HOME="/home/yeochan.yoon/besu-24.1.1"
BESU_BIN="${BESU_HOME}/bin/besu"
DATA_DIR="/home/yeochan.yoon/caliper-stress-test/data_bl"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GC_LOG_FILE="/home/yeochan.yoon/caliper-stress-test/baseline_gc_${TIMESTAMP}.log"

echo "======================================"
echo "Starting Besu in Dev Mode (Baseline)"
echo "======================================"
echo "GC Log: ${GC_LOG_FILE}"
echo "Data Dir: ${DATA_DIR}"
echo ""

# Check if Besu is already running
if pgrep -f "besu.*--network=dev" > /dev/null; then
    echo "ERROR: Besu appears to be already running in dev mode"
    echo "Please stop it first with: ./scripts/stop_besu.sh"
    exit 1
fi

# Ensure data directory exists
mkdir -p "${DATA_DIR}"

# JVM Configuration for Baseline Testing
# - 90GB heap (matching original config)
# - G1 GC (industry standard for large heaps)
# - Comprehensive GC logging for analysis
# - JMX enabled for runtime monitoring
JAVA_OPTS="-Xms90g -Xmx90g \
-XX:+UseG1GC \
-XX:MaxGCPauseMillis=200 \
-XX:G1HeapRegionSize=32m \
-Xlog:gc*=info:file=${GC_LOG_FILE}:time,level,tags:filecount=10,filesize=100M \
-XX:+HeapDumpOnOutOfMemoryError \
-XX:HeapDumpPath=${DATA_DIR}/heap_dump.hprof \
-Dcom.sun.management.jmxremote \
-Dcom.sun.management.jmxremote.port=9010 \
-Dcom.sun.management.jmxremote.local.only=false \
-Dcom.sun.management.jmxremote.authenticate=false \
-Dcom.sun.management.jmxremote.ssl=false"

# Export for Besu to pick up
export BESU_OPTS="${JAVA_OPTS}"

echo "Starting Besu with JVM options:"
echo "${JAVA_OPTS}" | tr ' ' '\n' | grep -E "^-"
echo ""

# Start Besu in dev mode
# Dev mode creates a single-node network with instant block mining
# Perfect for stress testing without network dependencies
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
    --tx-pool-layer-max-capacity=10000 \
    --tx-pool-max-prioritized=5000 \
    --logging=INFO \
    > "${DATA_DIR}/besu_console.log" 2>&1 &

BESU_PID=$!
echo "Besu started with PID: ${BESU_PID}"
echo "${BESU_PID}" > /tmp/besu_baseline.pid

echo ""
echo "Waiting for Besu to initialize..."
sleep 5

# Check if Besu is still running
if ! kill -0 ${BESU_PID} 2>/dev/null; then
    echo "ERROR: Besu process died during startup"
    echo "Check logs: tail -50 ${DATA_DIR}/besu_console.log"
    exit 1
fi

# Wait for RPC to be ready
MAX_WAIT=60
WAIT_COUNT=0
while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
    if curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 > /dev/null 2>&1; then
        echo "✓ Besu RPC is ready!"
        break
    fi
    echo -n "."
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

echo ""

if [ ${WAIT_COUNT} -ge ${MAX_WAIT} ]; then
    echo "ERROR: Besu RPC did not become ready within ${MAX_WAIT} seconds"
    echo "Check logs: tail -50 ${DATA_DIR}/besu_console.log"
    exit 1
fi

# Display current block number
BLOCK_NUM=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://localhost:8545 | grep -o '"result":"0x[0-9a-f]*"' | cut -d'"' -f4)

echo ""
echo "======================================"
echo "Besu is ready for baseline testing!"
echo "======================================"
echo "WebSocket RPC: ws://localhost:8546"
echo "HTTP RPC: http://localhost:8545"
echo "Current Block: ${BLOCK_NUM}"
echo "GC Log: ${GC_LOG_FILE}"
echo "Console Log: ${DATA_DIR}/besu_console.log"
echo "PID File: /tmp/besu_baseline.pid"
echo ""
echo "Monitor logs with:"
echo "  tail -f ${DATA_DIR}/besu_console.log"
echo "  tail -f ${GC_LOG_FILE}"
echo ""
