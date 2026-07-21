#!/usr/bin/env bash
# Smoke test for fragmentation_fuzz.py — small scale (k=1,5 only, drip_delay=0)
# against a lightweight Besu instance, RAAC in its real (non-ablation) config.
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

RUN_ID="$(date +%Y%m%d_%H%M%S)_frag_smoke"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
CPU_LIMIT="nice -n 19"
HEAP_BESU="1g"
DATA_DIR="/home/yeochan.yoon/caliper-stress-test/data_frag_smoke_${RUN_ID}"
GC_LOG="${RESULTS_DIR}/gc_besu.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${RESULTS_DIR}/run.log") 2>&1

echo "======================================================================"
echo "Fragmentation fuzz-loop smoke test | k=1,5 drip_delay=0 | RUN_ID: ${RUN_ID}"
echo "======================================================================"

wait_for_rpc() {
    local port="${1:-8545}"; local max=120; local c=0
    echo -n "  Waiting for RPC"
    while [ $c -lt $max ]; do
        curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:${port} > /dev/null 2>&1 && echo " READY" && return 0
        echo -n "."; sleep 1; c=$((c+1))
    done
    echo " TIMEOUT"; return 1
}

pkill -f "serve\.py" 2>/dev/null || true
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 3

echo "  Starting AI service (raac mode, real thresholds)..."
cd "${AI_SERVICE_DIR}"
OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
AI_MODE="raac" AI_THRESHOLD_BASE="0.95" AI_THRESHOLD_MIN="0.70" \
AI_GC_LOG_PATH="${GC_LOG}" AI_GC_OCCU_LOW="0.10" AI_GC_OCCU_HIGH="0.25" \
${CPU_LIMIT} python3 serve.py > /tmp/serve_ai_frag_smoke.log 2>&1 &
AI_PID=$!
cd /home/yeochan.yoon/caliper-stress-test
sleep 6

c=0
while [ $c -lt 20 ]; do
    result=$(curl -s --max-time 3 http://127.0.0.1:8000/ 2>/dev/null)
    echo "${result}" | grep -q '"dynamic_threshold"' && { echo "  AI service ready: ${result}"; break; }
    sleep 2; c=$((c+1))
done

rm -rf "${DATA_DIR}"; mkdir -p "${DATA_DIR}"
java_opts="-Xms${HEAP_BESU} -Xmx${HEAP_BESU} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 \
-Xlog:gc*=info:file=${GC_LOG}:time,uptime,level,tags:filecount=5,filesize=100M \
-Dlog4j.configurationFile=${LOG4J_CONFIG}"
export BESU_OPTS="${java_opts}"

${CPU_LIMIT} nohup "${BESU_BIN}" \
    --network=dev --miner-enabled \
    --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
    --data-path="${DATA_DIR}" \
    --rpc-http-enabled --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
    --rpc-http-cors-origins="*" --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
    --host-allowlist="*" --min-gas-price=0 \
    --tx-pool-max-prioritized=2048 --tx-pool-layer-max-capacity=2048 \
    --logging=INFO > "${RESULTS_DIR}/besu_console.log" 2>&1 &
BESU_PID=$!
unset BESU_OPTS
echo "  Besu PID: ${BESU_PID}"

sleep 8
wait_for_rpc || { echo "FAILED: rpc timeout"; exit 1; }

echo "  Deploying 1 contract..."
python3 deploy_multi_contracts.py 1 > "${RESULTS_DIR}/deploy.log" 2>&1
grep -q "Contract Address:" "${RESULTS_DIR}/deploy.log" || { echo "FAILED: deploy"; exit 1; }
CONTRACT_ADDR=$(python3 -c "import json; print(json.load(open('deployed_contracts.json'))['addresses'][0])")
echo "  Contract: ${CONTRACT_ADDR}"

echo "  Running fragmentation_fuzz.py (k=1,5)..."
python3.11 scripts/fragmentation_fuzz.py \
    --ai-url http://127.0.0.1:8000 \
    --contract-address "${CONTRACT_ADDR}" \
    --contract-abi StateBloater.json \
    --k-values 1,5 \
    --drip-delay 0 \
    --out "${RESULTS_DIR}/fuzz_results.json"

echo "  Fuzz results summary:"
python3 -c "
import json
d = json.load(open('${RESULTS_DIR}/fuzz_results.json'))
for k, r in d['results'].items():
    print(f\"  k={k}: accepted={r['accepted_count']}/{r['total_fragments']} total_gas={r['total_gas_used']} real_mult={r['real_gas_multiplier']} base_mult={r['base_gas_multiplier']}\")
"

kill "${BESU_PID}" 2>/dev/null || true
sleep 3
kill -9 "${BESU_PID}" 2>/dev/null || true
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
kill "${AI_PID}" 2>/dev/null || true
rm -rf "${DATA_DIR}"

echo "======================================================================"
echo "Fragmentation smoke test COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"
