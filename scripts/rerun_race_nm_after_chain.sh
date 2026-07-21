#!/bin/bash
# Wait for chain_race_then_raac.sh (PID 3505100) to finish, then re-run RACE NM eval.
# Run with: nohup bash rerun_race_nm_after_chain.sh > /tmp/rerun_race_nm.log 2>&1 &
CHAIN_PID=3505100
LOG="/tmp/rerun_race_nm.log"

echo "[$(date)] Watcher started. Waiting for chain PID ${CHAIN_PID} to finish..."

while kill -0 "${CHAIN_PID}" 2>/dev/null; do
    sleep 30
done

echo "[$(date)] Chain (PID ${CHAIN_PID}) finished. Starting RACE NM re-run..."
sleep 10  # brief pause to let all cleanup finish

cd /home/yeochan.yoon/caliper-stress-test
bash /home/yeochan.yoon/caliper-stress-test/scripts/run_race_nm_eval.sh >> "${LOG}" 2>&1

echo "[$(date)] RACE NM re-run complete."
