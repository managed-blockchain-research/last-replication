#!/bin/bash
# Wait for PREP Besu harness to finish, then run fill_todos.py prep_besu.
HARNESS_PID="${1:?Usage: $0 <HARNESS_PID> <BESU_RESULTS_DIR> <NM_RESULTS_DIR>}"
BESU_RESULTS_DIR="${2:?Missing BESU_RESULTS_DIR}"
NM_RESULTS_DIR="${3:?Missing NM_RESULTS_DIR}"
LOG="/home/yeochan.yoon/caliper-stress-test/queue_fill_prep_besu.log"

echo "[$(date)] Queue watcher started. Waiting for PREP Besu harness PID ${HARNESS_PID}..." | tee -a "${LOG}"

while kill -0 "${HARNESS_PID}" 2>/dev/null; do
    sleep 60
done

echo "[$(date)] Harness PID ${HARNESS_PID} exited. Cooldown 120s..." | tee -a "${LOG}"
sleep 120

echo "[$(date)] Running fill_todos.py all_prep..." | tee -a "${LOG}"
cd /home/yeochan.yoon/banning/papers
python3 fill_todos.py all_prep "${NM_RESULTS_DIR}" "${BESU_RESULTS_DIR}" 2>&1 | tee -a "${LOG}"
echo "[$(date)] fill_todos.py done." | tee -a "${LOG}"
