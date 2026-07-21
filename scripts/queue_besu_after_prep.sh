#!/bin/bash
# Queue fresh Besu MATS eval to start after PREP eval finishes.
set -e

PREP_PID="${1:?Usage: $0 <PREP_HARNESS_PID>}"
LOG="/home/yeochan.yoon/caliper-stress-test/queue_besu_after_prep.log"
BESU_HARNESS="/home/yeochan.yoon/caliper-stress-test/scripts/run_mats_eval_besu.sh"
COOLDOWN=120

echo "[$(date)] Queue watcher started. Waiting for PREP PID ${PREP_PID}..." | tee -a "${LOG}"

while kill -0 "${PREP_PID}" 2>/dev/null; do
    sleep 30
done

echo "[$(date)] PREP PID ${PREP_PID} exited. Cooling down ${COOLDOWN}s..." | tee -a "${LOG}"
sleep "${COOLDOWN}"

pkill -9 -f "nethermind.dll" 2>/dev/null || true
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 5

echo "[$(date)] Launching Besu MATS evaluation harness (fresh 25 runs)..." | tee -a "${LOG}"
nohup bash "${BESU_HARNESS}" >> "${LOG}" 2>&1 &
BESU_PID=$!
echo "[$(date)] Besu MATS harness PID: ${BESU_PID}" | tee -a "${LOG}"
echo "${BESU_PID}" > /home/yeochan.yoon/caliper-stress-test/besu_mats_harness3.pid
echo "[$(date)] Queue watcher done." | tee -a "${LOG}"
