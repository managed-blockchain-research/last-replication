#!/bin/bash
# Waits for NM MATS harness to finish, then launches Besu MATS harness.
NM_PID=2154158
BESU_SCRIPT="/home/yeochan.yoon/caliper-stress-test/scripts/run_mats_eval_besu.sh"
LOG="/home/yeochan.yoon/caliper-stress-test/queue_besu.log"

echo "[$(date)] Watcher started. Waiting for NM MATS PID ${NM_PID} to finish..." | tee "${LOG}"

while kill -0 "${NM_PID}" 2>/dev/null; do
    sleep 30
done

echo "[$(date)] NM MATS finished. Waiting 90s cooldown before Besu..." | tee -a "${LOG}"
sleep 90

# Ensure ports are free
pkill -9 -f "Nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 10

echo "[$(date)] Launching Besu MATS harness..." | tee -a "${LOG}"
bash "${BESU_SCRIPT}" >> "${LOG}" 2>&1
echo "[$(date)] Besu MATS harness exited." | tee -a "${LOG}"
