#!/usr/bin/env bash
# Supplemental run for eval13 — moderate_nm_6
# nm3: adaptation lag (invalid), nm4: threshold drift (high GC), nm5: NM degraded from calm-1
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_eval13_supplement3.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "eval13 SUPPLEMENT3  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  NM : moderate_nm_6  (nm3=lag, nm4=drift, nm5=NM degraded)"
echo "======================================================================"

NM_RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260504_183404_raac_nm_eval13"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
HEAP_NM=4000000000
NETWORKCONFIG_NM="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER_NM="/home/yeochan.yoon/banning/experiments/raac/scripts/parse_gc_nettrace/bin/Release/net10.0/parse_gc_nettrace"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
export RAAC_AI_URL="http://127.0.0.1:8000"

wait_for_rpc() {
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

ensure_ai() {
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

label="moderate_nm_6"
run_dir="${NM_RESULTS_DIR}/${label}"
mkdir -p "${run_dir}"
data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_supplement3"
raac_log_dir="${run_dir}/raac_logs"
rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
export RAAC_LOG_DIR="${raac_log_dir}"

pkill -f "serve\.py" 2>/dev/null || true
sleep 2
cd "${AI_SERVICE_DIR}"
OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
AI_THRESHOLD_BASE="0.95" AI_THRESHOLD_MIN="0.70" \
AI_GC_LOG_PATH="" AI_DELTA_LOW_MB="100" AI_DELTA_HIGH_MB="350" \
nohup python3 serve.py > /tmp/serve_ai.log 2>&1 &
echo "  AI service started (PID $!)"
sleep 6
cd /home/yeochan.yoon/caliper-stress-test

ensure_ai || { echo "AI service failed"; exit 1; }

pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

nettrace_file="${run_dir}/nm_gc.nettrace"

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
wait_for_rpc || { stop_nm ${nm_pid}; unset RAAC_LOG_DIR; exit 1; }

node "${DEPLOY_NM}" > "${run_dir}/deploy.log" 2>&1
grep -q "Contract" "${run_dir}/deploy.log" || { stop_nm ${nm_pid}; unset RAAC_LOG_DIR; exit 1; }
sleep 5

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

# RAAC 검증
if ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
    python3 - "${raac_log_dir}" <<'PYEOF'
import os, sys, json, glob, statistics
log_dir = sys.argv[1]
events = []
for f in glob.glob(os.path.join(log_dir, "*.jsonl")):
    with open(f) as fh:
        for line in fh:
            try: events.append(json.loads(line))
            except: pass
total = len(events)
rejects = sum(1 for e in events if e.get("ai_action") == "reject")
thrs = [e.get("dyn_threshold") for e in events if "dyn_threshold" in e]
pressures = [e.get("gc_pressure") for e in events if "gc_pressure" in e]
pct = rejects/total*100 if total > 0 else 0
thr_str = f"{min(thrs):.3f}-{max(thrs):.3f}" if thrs else "N/A"
p_mean = f"{statistics.mean(pressures):.3f}" if pressures else "N/A"
print(f"  RAAC: {rejects}/{total} rejected ({pct:.1f}%)  threshold={thr_str}  gc_pressure_mean={p_mean}")
# chunk별 reject rate
chunk = max(total // 6, 1)
for i in range(6):
    seg = events[i*chunk:(i+1)*chunk]
    r = sum(1 for e in seg if e.get("ai_action") == "reject")
    print(f"    Chunk {i+1}: {r}/{len(seg)} ({r/len(seg)*100:.1f}%)")
PYEOF
fi

# caliper round 타이밍 검증
python3 - "${run_dir}/caliper_console.log" <<'PYEOF'
import re, sys
rounds = []
with open(sys.argv[1], "r", errors="replace") as f:
    for line in f:
        m = re.search(r'(\d{2}:\d{2}:\d{2}).*?(Started|Finished) round \d+ \(([^)]+)\)', line)
        if m: rounds.append((m.group(1), m.group(2), m.group(3)))
        ms = re.search(r'Finished round \d+ \(([^)]+)\) in ([\d.]+)', line)
        if ms: rounds.append(("", "Duration", f"{ms.group(1)}={ms.group(2)}s"))
print("  Caliper rounds:")
for ts, ev, name in rounds:
    print(f"    {ts} {ev} {name}")
PYEOF

echo "  DONE: ${label}"

echo ""
echo "======================================================================"
echo "eval13 SUPPLEMENT3 COMPLETE  $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
