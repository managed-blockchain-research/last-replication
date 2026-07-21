#!/bin/bash

set -e

ROOT_DIR="/home/yeochan.yoon/nethermind"
RUNNER_DLL="${ROOT_DIR}/src/Nethermind/artifacts/bin/Nethermind.Runner/release/nethermind.dll"
DATA_DIR="/home/yeochan.yoon/caliper-stress-test/data_nethermind"
LOG_FILE="${DATA_DIR}/nethermind_spaceneth.log"

mkdir -p "${DATA_DIR}"

if pgrep -f "nethermind.dll.*spaceneth" > /dev/null; then
    echo "ERROR: Nethermind spaceneth appears to be already running"
    exit 1
fi

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="/home/yeochan.yoon/.dotnet:${PATH}"
export DOTNET_EnableDiagnostics=1
export DOTNET_DiagnosticPorts="/tmp/diag.sock,connect,nosuspend"
export DOTNET_EnableEventPipe=1
export COMPlus_EnableEventPipe=1
export DOTNET_GCLogFile="${DATA_DIR}/nethermind_gc_%p_%t.log"
export DOTNET_GCLogFileSize=50
export COMPlus_GCLogFile="${DATA_DIR}/nethermind_gc_%p_%t.log"
export COMPlus_GCLogFileSize=50

# Optional GC tuning knobs used by the "LASS/espill" experiments.
# These are applied only when the env vars are set by the caller script.
#
# - NETHERMIND_GC_WORKSTATION=1: Use Workstation GC (COMPlus_GCServer=0)
# - NETHERMIND_HEAP_MB=<int>: Cap managed heap (COMPlus_GCHeapHardLimit) e.g. 2048 or 4096
if [ -n "${NETHERMIND_GC_WORKSTATION:-}" ]; then
    export COMPlus_GCServer=0
fi
if [ -n "${NETHERMIND_HEAP_MB:-}" ]; then
    HEAP_BYTES=$((NETHERMIND_HEAP_MB * 1024 * 1024))
    export COMPlus_GCHeapHardLimit="0x$(printf '%x' "${HEAP_BYTES}")"
fi

nohup dotnet "${RUNNER_DLL}" \
    -c spaceneth \
    --Init.BaseDbPath "${DATA_DIR}" \
    --Init.WebSocketsEnabled true \
    --JsonRpc.Enabled true \
    --JsonRpc.Host 0.0.0.0 \
    --JsonRpc.Port 8545 \
    --JsonRpc.WebSocketsPort 8546 \
    --HealthChecks.LowStorageSpaceWarningThreshold 0 \
    --HealthChecks.LowStorageSpaceShutdownThreshold 0 \
    > "${LOG_FILE}" 2>&1 &

NM_PID=$!
echo "Nethermind started with PID: ${NM_PID}"
echo "${NM_PID}" > /tmp/nethermind_spaceneth.pid

echo "Waiting for Nethermind RPC to be ready..."
MAX_WAIT=60
WAIT_COUNT=0
while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
    if curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 > /dev/null 2>&1; then
        echo "✓ Nethermind RPC is ready!"
        break
    fi
    echo -n "."
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

echo ""
if [ ${WAIT_COUNT} -ge ${MAX_WAIT} ]; then
    echo "ERROR: Nethermind RPC did not become ready within ${MAX_WAIT} seconds"
    echo "Check logs: tail -50 ${LOG_FILE}"
    exit 1
fi

echo "Nethermind spaceneth is ready at http://localhost:8545 / ws://localhost:8546"
