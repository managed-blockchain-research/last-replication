#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/yeochan.yoon/caliper-stress-test"
NET_START="${ROOT}/scripts/start_nethermind_spaceneth.sh"
NET_STOP="${ROOT}/scripts/stop_nethermind_spaceneth.sh"
NET_DEPLOY="${ROOT}/deploy_contract_nethermind.js"
NET_TEST="${ROOT}/extreme_nethermind_test.py"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT}/results/nethermind/moderate-${TS}"

WORKERS=14
SLOTS=100
DURATION=600

COUNTERS="System.Runtime[cpu-usage,gc-heap-size,gen-0-size,gen-1-size,gen-2-size,loh-size,loh-fragmentation,gen-0-gc-count,gen-1-gc-count,gen-2-gc-count,time-in-gc,pinned-objects-size,alloc-rate]"

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

  pid="$(cat /tmp/nethermind_spaceneth.pid)"
  mkdir -p "${OUT_DIR}"

  export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
  export PATH="/home/yeochan.yoon/.dotnet:${PATH}:${HOME}/.dotnet/tools"

  echo "==> dotnet-counters monitor (${name})..."
  timeout $((DURATION + 30)) \
    dotnet-counters monitor --process-id "${pid}" \
      --counters "${COUNTERS}" \
      > "${OUT_DIR}/${name}_counters_monitor.log" 2>&1 &
  MONITOR_PID=$!

  echo "==> dotnet-counters collect (${name})..."
  dotnet-counters collect --process-id "${pid}" \
    --counters "${COUNTERS}" \
    --format json \
    --duration 00:10:00 \
    --output "${OUT_DIR}/${name}_counters.json" \
    > "${OUT_DIR}/${name}_counters_collect.log" 2>&1 &
  COLLECT_PID=$!

  echo "==> Nethermind ${name} (moderate intensity)..."
  python3 "${NET_TEST}" \
    --duration "${DURATION}" \
    --workers "${WORKERS}" \
    --slots "${SLOTS}" \
    --output "${OUT_DIR}/${name}" \
    --no-collect-metrics

  wait "${COLLECT_PID}" || true
  wait "${MONITOR_PID}" || true
}

echo "==> Ensuring ports are free (8545, 8546, 30303)..."
stop_port_processes 8545 8546 30303
ensure_ports_free 8545 8546 30303

echo "==> Starting Nethermind (spaceneth)..."
run_case baseline
run_case espill

if [[ -f /tmp/nethermind_spaceneth.pid ]]; then
  echo "==> Stopping Nethermind..."
  bash "${NET_STOP}" || true
  sleep 5
fi

echo "✅ Nethermind moderate-intensity run finished."
