#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/yeochan.yoon/caliper-stress-test"
NET_START="${ROOT}/scripts/start_nethermind_spaceneth.sh"
NET_DEPLOY="${ROOT}/deploy_contract_nethermind.js"
NET_TEST="${ROOT}/extreme_nethermind_test.py"

BESU_BASELINE_START="${ROOT}/scripts/start_besu_tiny_heap_baseline.sh"
BESU_ESPILL_START="${ROOT}/scripts/start_besu_tiny_heap.sh"
BESU_TEST="${ROOT}/extreme_baseline_test.py"
BESU_STOP="${ROOT}/scripts/stop_besu.sh"

TS="$(date +%Y%m%d_%H%M%S)"
NET_OUT_DIR="${ROOT}/results/nethermind/retry-${TS}"
BESU_OUT_DIR="${ROOT}/results/extreme/retry-${TS}"

NET_WORKERS=10
NET_SLOTS=50
NET_DURATION=300

BESU_WARMUP_DURATION=1800
BESU_WARMUP_SLOTS=400
BESU_DURATION=600
BESU_WORKERS=30
BESU_SLOTS=200

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

echo "==> Ensuring ports are free (8545, 8546, 30303)..."
stop_port_processes 8545 8546 30303
ensure_ports_free 8545 8546 30303

echo "==> Starting Nethermind (spaceneth)..."
bash "${NET_START}"

echo "==> Deploying StateBloater to Nethermind..."
node "${NET_DEPLOY}"

mkdir -p "${NET_OUT_DIR}"

echo "==> Nethermind baseline (low intensity: ${NET_WORKERS} workers, ${NET_SLOTS} slots)..."
python3 "${NET_TEST}" \
  --duration "${NET_DURATION}" \
  --workers "${NET_WORKERS}" \
  --slots "${NET_SLOTS}" \
  --use-dotnet-trace \
  --no-collect-metrics \
  --output "${NET_OUT_DIR}/baseline"

echo "==> Nethermind e-spill (low intensity: ${NET_WORKERS} workers, ${NET_SLOTS} slots)..."
python3 "${NET_TEST}" \
  --duration "${NET_DURATION}" \
  --workers "${NET_WORKERS}" \
  --slots "${NET_SLOTS}" \
  --use-dotnet-trace \
  --no-collect-metrics \
  --output "${NET_OUT_DIR}/espill"

if [[ -f /tmp/nethermind_spaceneth.pid ]]; then
  echo "==> Stopping Nethermind..."
  kill "$(cat /tmp/nethermind_spaceneth.pid)" || true
  sleep 5
fi

echo "==> Ensuring ports are free (8545, 8546, 30303)..."
stop_port_processes 8545 8546 30303
ensure_ports_free 8545 8546 30303

mkdir -p "${BESU_OUT_DIR}"

echo "==> Starting Besu baseline (JFR enabled)..."
bash "${BESU_BASELINE_START}"

echo "==> Besu baseline with warm-up..."
python3 "${BESU_TEST}" \
  --duration "${BESU_DURATION}" \
  --workers "${BESU_WORKERS}" \
  --slots "${BESU_SLOTS}" \
  --warmup-duration "${BESU_WARMUP_DURATION}" \
  --warmup-slots "${BESU_WARMUP_SLOTS}" \
  --output "${BESU_OUT_DIR}/baseline"

echo "==> Stopping Besu baseline..."
bash "${BESU_STOP}"
sleep 5

echo "==> Starting Besu e-spill (JFR enabled)..."
bash "${BESU_ESPILL_START}"

echo "==> Besu e-spill with warm-up..."
python3 "${BESU_TEST}" \
  --duration "${BESU_DURATION}" \
  --workers "${BESU_WORKERS}" \
  --slots "${BESU_SLOTS}" \
  --warmup-duration "${BESU_WARMUP_DURATION}" \
  --warmup-slots "${BESU_WARMUP_SLOTS}" \
  --output "${BESU_OUT_DIR}/espill"

echo "==> Stopping Besu e-spill..."
bash "${BESU_STOP}"

echo "✅ Retry experiments finished."
