#!/bin/bash
# Auto-fill MATS Besu paper TODOs and generate DOCX when eval finishes.
# Called with either a PID or with besu_mats_harness3.pid path.
set -e

PIDFILE="/home/yeochan.yoon/caliper-stress-test/besu_mats_harness3.pid"
LOG="/home/yeochan.yoon/caliper-stress-test/queue_fill_after_besu.log"
PAPERS_DIR="/home/yeochan.yoon/banning/papers"
BESU_RESULTS_BASE="/home/yeochan.yoon/caliper-stress-test/results/mats_eval_besu"
PATH="$HOME/texlive/2025/bin/x86_64-linux:$PATH"
export PATH

echo "[$(date)] Besu fill watcher started. Waiting for PID file..." | tee -a "${LOG}"

# Wait for the harness3 PID file to appear (written by queue_besu_after_prep.sh)
WAIT_MAX=28800  # 8 hours
WAITED=0
while [ ! -f "${PIDFILE}" ]; do
    sleep 60
    WAITED=$((WAITED + 60))
    if [ ${WAITED} -ge ${WAIT_MAX} ]; then
        echo "[$(date)] ERROR: PID file never appeared after ${WAIT_MAX}s" | tee -a "${LOG}"
        exit 1
    fi
done

BESU_PID=$(cat "${PIDFILE}")
echo "[$(date)] Besu MATS harness PID: ${BESU_PID}. Waiting for completion..." | tee -a "${LOG}"

while kill -0 "${BESU_PID}" 2>/dev/null; do
    sleep 60
done

echo "[$(date)] Besu eval complete. Finding latest results dir..." | tee -a "${LOG}"
sleep 10

BESU_RESULTS=$(ls -td "${BESU_RESULTS_BASE}"/*/  2>/dev/null | head -1)
if [ -z "${BESU_RESULTS}" ]; then
    echo "[$(date)] ERROR: No Besu results dir found" | tee -a "${LOG}"
    exit 1
fi
echo "[$(date)] Using results: ${BESU_RESULTS}" | tee -a "${LOG}"

N=$(find "${BESU_RESULTS}" -name "gc_summary.txt" | wc -l)
echo "[$(date)] Found ${N} completed Besu runs" | tee -a "${LOG}"

echo "[$(date)] Running fill_todos.py mats_besu..." | tee -a "${LOG}"
python3 "${PAPERS_DIR}/fill_todos.py" mats_besu "${BESU_RESULTS}" 2>&1 | tee -a "${LOG}"

echo "[$(date)] Generating MATS DOCX..." | tee -a "${LOG}"
python3 "${PAPERS_DIR}/mats/gen_docx.py" 2>&1 | tee -a "${LOG}"

echo "[$(date)] MATS paper Besu post-processing complete!" | tee -a "${LOG}"
echo "[$(date)] PDF: ${PAPERS_DIR}/mats/main.pdf" | tee -a "${LOG}"
echo "[$(date)] DOCX: ${PAPERS_DIR}/mats/mats.docx" | tee -a "${LOG}"
