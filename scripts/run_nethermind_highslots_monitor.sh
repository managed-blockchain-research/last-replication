#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/yeochan.yoon/caliper-stress-test"
NET_START="${ROOT}/scripts/start_nethermind_spaceneth.sh"
NET_STOP="${ROOT}/scripts/stop_nethermind_spaceneth.sh"
NET_DEPLOY="${ROOT}/deploy_contract_nethermind.js"
NET_TEST="${ROOT}/extreme_nethermind_test.py"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT}/results/nethermind/highslots-monitor-${TS}"

WORKERS=14
SLOTS=300
DURATION=600

MONITOR_URL="http://127.0.0.1:52325/metrics"
DIAG_PORT="/tmp/dotnet-monitor.sock"

stop_port_processes() {
  ports="$*"
  for port in ${ports}; do
    pids="$(lsof -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "${pids}" ]]; then
      echo "==> Freeing port ${port} (PIDs: ${pids})"
      kill ${pids} || true
    fi
  done
}

ensure_ports_free() {
  ports="$*"
  retries=5
  delay=2
  for attempt in $(seq 1 "${retries}"); do
    busy=0
    for port in ${ports}; do
      if lsof -iTCP:"${port}" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
        busy=1
        break
      fi
    done
    if [[ "${busy}" -eq 0 ]]; then
      return 0
    fi
    echo "==> Ports still busy, retry ${attempt}/${retries}..."
    stop_port_processes ${ports}
    sleep "${delay}"
  done
  echo "ERROR: Ports still in use after ${retries} attempts. Aborting."
  return 1
}

start_dotnet_monitor() {
  export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
  export PATH="/home/yeochan.yoon/.dotnet:${PATH}:${HOME}/.dotnet/tools"
  rm -f "${DIAG_PORT}" || true
  nohup dotnet-monitor collect \
    --no-auth true \
    --urls http://127.0.0.1:52323 \
    --metricUrls http://127.0.0.1:52325 \
    --metrics true \
    --configuration-file-path "${ROOT}/scripts/dotnet_monitor_config.json" \
    --diagnostic-port "${DIAG_PORT}" \
    > "${OUT_DIR}/dotnet_monitor.log" 2>&1 &
  echo $! > "${OUT_DIR}/dotnet_monitor.pid"
}

stop_dotnet_monitor() {
  if [[ -f "${OUT_DIR}/dotnet_monitor.pid" ]]; then
    kill "$(cat "${OUT_DIR}/dotnet_monitor.pid")" || true
    sleep 2
  fi
}

collect_metrics() {
  local name="$1"
  local outfile="${OUT_DIR}/${name}_metrics.prom"
  local samples=$((DURATION / 5))
  echo "# dotnet-monitor metrics scrape (${name})" > "${outfile}"
  for i in $(seq 1 "${samples}"); do
    echo "# ts=$(date +%s)" >> "${outfile}"
    curl -s "${MONITOR_URL}" >> "${outfile}" || true
    echo "" >> "${outfile}"
    sleep 5
  done
}

run_case() {
  name="$1"
  if [[ "${name}" == "baseline" ]]; then
    unset NETHERMIND_GC_WORKSTATION || true
    unset NETHERMIND_HEAP_MB || true
  else
    export NETHERMIND_GC_WORKSTATION=1
    export NETHERMIND_HEAP_MB=4096
  fi

  bash "${NET_STOP}" || true
  sleep 2
  bash "${NET_START}"

  echo "==> Deploying StateBloater to Nethermind (${name})..."
  node "${NET_DEPLOY}"

  echo "==> Collecting dotnet-monitor metrics (${name})..."
  collect_metrics "${name}" &
  METRICS_PID=$!

  echo "==> Nethermind ${name} (high slots)..."
  python3 "${NET_TEST}" \
    --duration "${DURATION}" \
    --workers "${WORKERS}" \
    --slots "${SLOTS}" \
    --output "${OUT_DIR}/${name}" \
    --no-collect-metrics

  wait "${METRICS_PID}" || true
}

mkdir -p "${OUT_DIR}"

echo "==> Ensuring ports are free (8545, 8546, 30303, 52323, 52325)..."
stop_port_processes 8545 8546 30303 52323 52325
ensure_ports_free 8545 8546 30303 52323 52325

echo "==> Starting dotnet-monitor..."
start_dotnet_monitor
sleep 3

echo "==> Starting Nethermind (spaceneth)..."
run_case baseline
run_case espill

if [[ -f /tmp/nethermind_spaceneth.pid ]]; then
  echo "==> Stopping Nethermind..."
  bash "${NET_STOP}" || true
  sleep 5
fi

stop_dotnet_monitor

echo "✅ Nethermind high-slots monitor run finished."
