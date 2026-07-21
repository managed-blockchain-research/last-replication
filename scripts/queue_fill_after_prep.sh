#!/bin/bash
# Auto-fill PREP paper TODOs and generate DOCX when eval finishes.
set -e

PREP_PID="${1:?Usage: $0 <PREP_HARNESS_PID>}"
LOG="/home/yeochan.yoon/caliper-stress-test/queue_fill_after_prep.log"
PAPERS_DIR="/home/yeochan.yoon/banning/papers"
PREP_RESULTS_BASE="/home/yeochan.yoon/caliper-stress-test/results/prep_eval"
PATH="$HOME/texlive/2025/bin/x86_64-linux:$PATH"
export PATH

echo "[$(date)] Watcher started. Waiting for PREP PID ${PREP_PID}..." | tee -a "${LOG}"

while kill -0 "${PREP_PID}" 2>/dev/null; do
    sleep 60
done

echo "[$(date)] PREP eval complete. Finding latest results dir..." | tee -a "${LOG}"
sleep 10

PREP_RESULTS=$(ls -td "${PREP_RESULTS_BASE}"/*/  2>/dev/null | head -1)
if [ -z "${PREP_RESULTS}" ]; then
    echo "[$(date)] ERROR: No PREP results dir found" | tee -a "${LOG}"
    exit 1
fi
echo "[$(date)] Using results: ${PREP_RESULTS}" | tee -a "${LOG}"

# Count valid runs
N=$(find "${PREP_RESULTS}" -name "gc_summary.txt" | wc -l)
echo "[$(date)] Found ${N} completed runs" | tee -a "${LOG}"

echo "[$(date)] Running fill_todos.py prep..." | tee -a "${LOG}"
python3 "${PAPERS_DIR}/fill_todos.py" prep "${PREP_RESULTS}" 2>&1 | tee -a "${LOG}"

echo "[$(date)] Generating PREP DOCX..." | tee -a "${LOG}"
python3 "${PAPERS_DIR}/prep/gen_docx.py" 2>&1 | tee -a "${LOG}"

echo "[$(date)] PREP paper post-processing complete!" | tee -a "${LOG}"
echo "[$(date)] PDF: ${PAPERS_DIR}/prep/main.pdf" | tee -a "${LOG}"
echo "[$(date)] DOCX: ${PAPERS_DIR}/prep/prep.docx" | tee -a "${LOG}"
