#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/yeochan.yoon/caliper-stress-test"
NET_SCRIPT="${ROOT}/scripts/start_nethermind_spaceneth.sh"
NET_STOP="${ROOT}/scripts/stop_nethermind_spaceneth.sh"
DEPLOY_NET="${ROOT}/deploy_contract_nethermind.js"
NET_TEST="${ROOT}/extreme_nethermind_test.py"
NET_RESULTS="${ROOT}/results/nethermind"

BESU_BASELINE_SCRIPT="${ROOT}/scripts/start_besu_tiny_heap_baseline.sh"
BESU_ESPILL_SCRIPT="${ROOT}/scripts/start_besu_tiny_heap.sh"
BESU_TEST="${ROOT}/extreme_baseline_test.py"

STOP_BESU="${ROOT}/scripts/stop_besu.sh"

WORKERS=20
DURATION=600
SLOTS=200

echo "==> Starting Nethermind (spaceneth)..."
echo "==> Running Nethermind baseline test (metrics enabled)..."
unset NETHERMIND_GC_WORKSTATION || true
unset NETHERMIND_HEAP_MB || true
bash "${NET_STOP}" || true
sleep 2
bash "${NET_SCRIPT}"
echo "==> Deploying StateBloater to Nethermind (baseline)..."
node "${DEPLOY_NET}"
python3 "${NET_TEST}" \
  --duration "${DURATION}" \
  --workers "${WORKERS}" \
  --slots "${SLOTS}" \
  --output "results/nethermind/baseline"

echo "==> Running Nethermind e-spill test (metrics enabled)..."
export NETHERMIND_GC_WORKSTATION=1
export NETHERMIND_HEAP_MB=4096
bash "${NET_STOP}" || true
sleep 2
bash "${NET_SCRIPT}"
echo "==> Deploying StateBloater to Nethermind (espill)..."
node "${DEPLOY_NET}"
python3 "${NET_TEST}" \
  --duration "${DURATION}" \
  --workers "${WORKERS}" \
  --slots "${SLOTS}" \
  --output "results/nethermind/espill"

if [[ -f /tmp/nethermind_spaceneth.pid ]]; then
  echo "==> Stopping Nethermind..."
  bash "${NET_STOP}" || true
  sleep 5
fi

echo "==> Starting Besu baseline (JFR enabled)..."
bash "${BESU_BASELINE_SCRIPT}"

echo "==> Running Besu baseline test..."
python3 "${BESU_TEST}" \
  --duration "${DURATION}" \
  --workers "${WORKERS}" \
  --slots "${SLOTS}" \
  --output "results/extreme/baseline"

echo "==> Stopping Besu baseline..."
bash "${STOP_BESU}"
sleep 5

echo "==> Starting Besu e-spill (JFR enabled)..."
bash "${BESU_ESPILL_SCRIPT}"

echo "==> Running Besu e-spill test..."
python3 "${BESU_TEST}" \
  --duration "${DURATION}" \
  --workers "${WORKERS}" \
  --slots "${SLOTS}" \
  --output "results/extreme/espill"

echo "==> Stopping Besu e-spill..."
bash "${STOP_BESU}"

echo "✅ Nethermind and Besu runs complete with monitoring enabled."
