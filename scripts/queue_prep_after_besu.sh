#!/bin/bash
# Queue PREP experiment to start after Besu MATS experiment finishes.
# Usage: bash queue_prep_after_besu.sh <BESU_HARNESS_PID>
#
# Watches BESU_HARNESS_PID; when it exits, waits 120s cooldown then
# launches run_prep_eval.sh in the background.
set -e

BESU_PID="${1:?Usage: $0 <BESU_HARNESS_PID>}"
LOG="/home/yeochan.yoon/caliper-stress-test/queue_prep.log"
PREP_HARNESS="/home/yeochan.yoon/caliper-stress-test/scripts/run_prep_eval.sh"
COOLDOWN=120

echo "[$(date)] Queue watcher started. Waiting for Besu PID ${BESU_PID}..." | tee -a "${LOG}"

while kill -0 "${BESU_PID}" 2>/dev/null; do
    sleep 30
done

echo "[$(date)] Besu PID ${BESU_PID} exited. Cooling down ${COOLDOWN}s..." | tee -a "${LOG}"
sleep "${COOLDOWN}"

# Kill any lingering processes
pkill -9 -f "nethermind.dll" 2>/dev/null || true
pkill -9 -f "besu" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
sleep 5

echo "[$(date)] Launching PREP evaluation harness..." | tee -a "${LOG}"
nohup bash "${PREP_HARNESS}" >> "${LOG}" 2>&1 &
PREP_PID=$!
echo "[$(date)] PREP harness PID: ${PREP_PID}" | tee -a "${LOG}"
echo "${PREP_PID}" > /home/yeochan.yoon/caliper-stress-test/prep_harness.pid
echo "[$(date)] Queue watcher done." | tee -a "${LOG}"
