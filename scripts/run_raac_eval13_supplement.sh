#!/usr/bin/env bash
# Supplemental runs for eval13 incomplete data
#
# Besu : 1 additional static rep  → Table 2 (static only has 2 valid reps)
# NM   : 1 additional moderate rep → Table 3 (moderate_nm_3 was outlier)
#
# Results append to same parent dirs as original eval13 runs, under rep index 4.
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_eval13_supplement.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "eval13 SUPPLEMENT  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Besu  : +1 static    (replace excluded static_besu_2)"
echo "  NM    : +1 moderate  (replace outlier moderate_nm_3)"
echo "======================================================================"

# ═══════════════════════════════════════════════════════════════════════════
# PART 1 — Besu static rep 4
# ═══════════════════════════════════════════════════════════════════════════

BESU_RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260506_081542_raac_besu_eval13"
BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
HEAP_BESU="1g"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
NETWORKCONFIG_BESU="networkconfig.json"
DEPLOY_BESU="deploy_multi_contracts.py"
GC_PARSER="scripts/parse_besu_gc.py"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"

wait_for_rpc_besu() {
    local max=120 c=0
    echo -n "  Waiting for RPC"
    while [ $c -lt $max ]; do
        curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1 && echo " READY" && return 0
        echo -n "."; sleep 1; c=$((c+1))
    done
    echo " TIMEOUT"; return 1
}

stop_besu() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

restart_ai_besu() {
    local base_thr="$1" min_thr="$2" occu_high="$3" gc_log_path="$4"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" \
    AI_GC_LOG_PATH="${gc_log_path}" AI_GC_OCCU_LOW="0.10" AI_GC_OCCU_HIGH="${occu_high}" \
    nohup python3 serve.py > /tmp/serve_ai.log 2>&1 &
    echo "  AI service started: base=${base_thr} min=${min_thr} occu_high=${occu_high} (PID $!)"
    sleep 6
    cd /home/yeochan.yoon/caliper-stress-test
}

ensure_ai_besu() {
    local c=0
    while [ $c -lt 20 ]; do
        result=$(curl -s --max-time 3 http://127.0.0.1:8000/ 2>/dev/null)
        echo "${result}" | grep -q '"dynamic_threshold"' && \
            echo "  AI ready: $(echo "${result}" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(f'thr={d[\"dynamic_threshold\"]} pressure={d[\"gc_pressure\"]}')" \
                2>/dev/null)" && return 0
        sleep 2; c=$((c+1))
    done
    echo "  ERROR: AI service not ready"; return 1
}

echo ""
echo "══════════════════════════════════════════"
echo "PART 1 — Besu static rep 4"
echo "══════════════════════════════════════════"

label="static_besu_4"
run_dir="${BESU_RESULTS_DIR}/${label}"
mkdir -p "${run_dir}"
gc_log="${run_dir}/gc_besu.log"
data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_supplement"
raac_log_dir="${run_dir}/raac_logs"
rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
export RAAC_LOG_DIR="${raac_log_dir}"

restart_ai_besu "0.95" "0.95" "0.25" "${gc_log}"
ensure_ai_besu || { echo "AI service failed"; exit 1; }

pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

java_opts="-Xms${HEAP_BESU} -Xmx${HEAP_BESU} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=5,filesize=100M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
-Dlast.variant=DISABLED \
-Dlass.old.gen.activation.threshold=2.0"
export BESU_OPTS="${java_opts}"

nohup "${BESU_BIN}" \
    --network=dev --miner-enabled \
    --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
    --data-path="${data_dir}" \
    --rpc-http-enabled --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
    --rpc-http-cors-origins="*" \
    --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
    --rpc-ws-enabled --rpc-ws-host=0.0.0.0 --rpc-ws-port=8546 \
    --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
    --host-allowlist="*" --min-gas-price=0 \
    --tx-pool-max-prioritized=2048 --tx-pool-layer-max-capacity=2048 \
    --logging=INFO \
    > "${run_dir}/besu_console.log" 2>&1 &
besu_pid=$!; echo "  Besu PID: ${besu_pid}"
unset BESU_OPTS

sleep 8
kill -0 ${besu_pid} 2>/dev/null || { echo "  Besu failed to start"; unset RAAC_LOG_DIR; exit 1; }
wait_for_rpc_besu || { stop_besu ${besu_pid}; unset RAAC_LOG_DIR; exit 1; }

python3 "${DEPLOY_BESU}" > "${run_dir}/deploy.log" 2>&1
grep -q "Contract Address:" "${run_dir}/deploy.log" || { stop_besu ${besu_pid}; unset RAAC_LOG_DIR; exit 1; }
sleep 5

echo "  Running Caliper..."
timeout 2400 npx caliper launch manager \
    --caliper-workspace ./ \
    --caliper-benchconfig "${BENCHCONFIG_RAAC}" \
    --caliper-networkconfig "${NETWORKCONFIG_BESU}" \
    > "${run_dir}/caliper_console.log" 2>&1 || true

cp /tmp/serve_ai.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
cp report.html "${run_dir}/report.html" 2>/dev/null || true
stop_besu ${besu_pid}; rm -rf "${data_dir}"
unset RAAC_LOG_DIR 2>/dev/null || true

if [ -f "${gc_log}" ]; then
    gc_out=$(python3 "${GC_PARSER}" --log "${gc_log}" --variant "static" --run "4" 2>&1 \
        | grep "total_ms=" | sed 's/.*total_ms=\([0-9.]*\).*/\1/' || echo "parse_error")
    [ -z "${gc_out}" ] && gc_out="no_gc_events"
    echo "${gc_out}" > "${run_dir}/gc_summary.txt"
    echo "  GC total STW: ${gc_out} ms"
fi

# Attack-2 phase window (uptime 360-480s) — manual parse from CSV
if [ -f "${gc_log}" ]; then
    python3 - <<PYEOF 2>/dev/null | tee "${run_dir}/gc_attack2.txt" || true
import re, sys
gc_re = re.compile(r'\[(\d+\.\d+)s\].*?Pause.*?(\d+\.\d+)ms')
total=0.0; events=0
with open("${gc_log}","r",errors="replace") as f:
    for line in f:
        m = gc_re.search(line)
        if m:
            uptime=float(m.group(1)); pause=float(m.group(2))
            if 360 <= uptime <= 480:
                total += pause; events += 1
print(f"attack2_window=[360,480]s  events={events}  total_stw={total:.1f}ms")
PYEOF
fi

if ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
    total=$(cat "${raac_log_dir}"/*.jsonl | wc -l || echo 0)
    rejects=$(grep -h '"ai_action":"reject"' "${raac_log_dir}"/*.jsonl 2>/dev/null | wc -l || echo 0)
    echo "  RAAC: rejects=${rejects}/${total}"
fi
echo "  DONE: ${label}"

sleep 15

# ═══════════════════════════════════════════════════════════════════════════
# PART 2 — NM moderate rep 4
# ═══════════════════════════════════════════════════════════════════════════

NM_RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260504_183404_raac_nm_eval13"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
HEAP_NM=4000000000
NETWORKCONFIG_NM="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER_NM="/home/yeochan.yoon/banning/experiments/raac/scripts/parse_gc_nettrace/bin/Release/net10.0/parse_gc_nettrace"

wait_for_rpc_nm() {
    local max=120 c=0
    echo -n "  Waiting for RPC"
    while [ $c -lt $max ]; do
        curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1 && echo " READY" && return 0
        echo -n "."; sleep 1; c=$((c+1))
    done
    echo " TIMEOUT"; return 1
}

stop_nm() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

restart_ai_nm() {
    local base_thr="$1" min_thr="$2" delta_high="$3"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" \
    AI_GC_LOG_PATH="" AI_DELTA_LOW_MB="100" AI_DELTA_HIGH_MB="${delta_high}" \
    nohup python3 serve.py > /tmp/serve_ai.log 2>&1 &
    echo "  AI service started: base=${base_thr} min=${min_thr} delta_high=${delta_high}MB (PID $!)"
    sleep 6
    cd /home/yeochan.yoon/caliper-stress-test
}

echo ""
echo "══════════════════════════════════════════"
echo "PART 2 — NM moderate rep 4"
echo "══════════════════════════════════════════"

label="moderate_nm_4"
run_dir="${NM_RESULTS_DIR}/${label}"
mkdir -p "${run_dir}"
data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_supplement"
raac_log_dir="${run_dir}/raac_logs"
rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
export RAAC_LOG_DIR="${raac_log_dir}"

restart_ai_nm "0.95" "0.70" "350"
ensure_ai_besu || { echo "AI service failed"; exit 1; }  # reuse same health check

pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

DOTNET_GCHeapHardLimit="${HEAP_NM}" DOTNET_GCHighMemPercent=75 \
nohup "${DOTNET_BIN}" "${NM_DLL}" \
    --config="${NM_CFG}" \
    --datadir="${data_dir}" \
    --JsonRpc.Enabled=true --JsonRpc.Host=0.0.0.0 --JsonRpc.Port=8545 \
    --JsonRpc.WebSocketsPort=8546 \
    --Network.DiscoveryPort=30303 \
    > "${run_dir}/nm_console.log" 2>&1 &
nm_pid=$!; echo "  NM PID: ${nm_pid}"

sleep 10
kill -0 ${nm_pid} 2>/dev/null || { echo "  NM failed to start"; unset RAAC_LOG_DIR; exit 1; }
wait_for_rpc_nm || { stop_nm ${nm_pid}; unset RAAC_LOG_DIR; exit 1; }

node "${DEPLOY_NM}" > "${run_dir}/deploy.log" 2>&1
grep -q "Contract" "${run_dir}/deploy.log" || { stop_nm ${nm_pid}; unset RAAC_LOG_DIR; exit 1; }
sleep 5

# dotnet-trace for GC metrics
nettrace_file="${run_dir}/nm_gc.nettrace"
"${DT_BIN}" collect --process-id ${nm_pid} \
    --providers Microsoft-Windows-DotNETRuntime:0x1:4 \
    --output "${nettrace_file}" > "${run_dir}/dotnet_trace.log" 2>&1 &
trace_pid=$!

echo "  Running Caliper..."
timeout 2400 npx caliper launch manager \
    --caliper-workspace ./ \
    --caliper-benchconfig "${BENCHCONFIG_RAAC}" \
    --caliper-networkconfig "${NETWORKCONFIG_NM}" \
    > "${run_dir}/caliper_console.log" 2>&1 || true

kill ${trace_pid} 2>/dev/null || true; wait ${trace_pid} 2>/dev/null || true
cp /tmp/serve_ai.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
cp report.html "${run_dir}/report.html" 2>/dev/null || true
stop_nm ${nm_pid}; rm -rf "${data_dir}"
unset RAAC_LOG_DIR 2>/dev/null || true

if [ -f "${nettrace_file}" ]; then
    gc_out=$("${GC_PARSER_NM}" "${nettrace_file}" 2>/dev/null | tail -1 || echo "parse_error")
    echo "${gc_out}" > "${run_dir}/gc_summary.txt"
    echo "  GC: ${gc_out}"
else
    echo "  nettrace not captured"
fi

if ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
    total=$(cat "${raac_log_dir}"/*.jsonl | wc -l || echo 0)
    rejects=$(grep -h '"ai_action":"reject"' "${raac_log_dir}"/*.jsonl 2>/dev/null | wc -l || echo 0)
    echo "  RAAC: rejects=${rejects}/${total}"
fi
echo "  DONE: ${label}"

echo ""
echo "======================================================================"
echo "eval13 SUPPLEMENT COMPLETE  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Besu  static_besu_4 → ${BESU_RESULTS_DIR}/static_besu_4/"
echo "  NM    moderate_nm_4 → ${NM_RESULTS_DIR}/moderate_nm_4/"
echo "======================================================================"
