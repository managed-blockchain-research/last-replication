#!/bin/bash
# ============================================================
# Full Evaluation Pipeline
#   Phase 1: Besu sensitivity (lass60 + lass90) — SKIP if already done
#   Phase 2: Nethermind sensitivity (ctrl + lass60 + lass75 + lass90)
#   Phase 3: Synthesis report
#
# Usage:
#   bash run_full_evaluation.sh [--skip-besu]
#   --skip-besu: skip Phase 1 if already done, pass existing dir via BESU_SENS_DIR
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

SKIP_BESU=0
for arg in "$@"; do
    [ "$arg" = "--skip-besu" ] && SKIP_BESU=1
done

BESU_BASELINE_DIR="/home/yeochan.yoon/caliper-stress-test/results/validation_caliper_1g/20260422_133356_caliper5x5"

echo "======================================================================"
echo "FULL EVALUATION PIPELINE"
echo "======================================================================"

# ── Phase 1: Besu Sensitivity ─────────────────────────────────────────────────
if [ "${SKIP_BESU}" -eq 0 ]; then
    echo ""
    echo "PHASE 1: Besu Sensitivity (lass60 + lass90)"
    bash scripts/run_caliper_besu_sensitivity.sh
    # The script writes its results dir to provenance.txt; find the most recent
    BESU_SENS_DIR=$(ls -dt results/validation_caliper_1g/*_besu_sensitivity 2>/dev/null | head -1)
    echo "Besu sensitivity dir: ${BESU_SENS_DIR}"
else
    BESU_SENS_DIR="${BESU_SENS_DIR:-$(ls -dt results/validation_caliper_1g/*_besu_sensitivity 2>/dev/null | head -1)}"
    echo "PHASE 1: Skipped (using ${BESU_SENS_DIR})"
fi

if [ -z "${BESU_SENS_DIR}" ]; then
    echo "ERROR: BESU_SENS_DIR not set and no besu_sensitivity dir found."
    exit 1
fi

# ── Phase 2: Nethermind Sensitivity ──────────────────────────────────────────
echo ""
echo "PHASE 2: Nethermind Sensitivity (ctrl + lass60 + lass75 + lass90)"
bash scripts/run_caliper_nm_sensitivity.sh
NM_RESULTS_DIR=$(ls -dt results/validation_nethermind/*_nm_sensitivity 2>/dev/null | head -1)
echo "Nethermind sensitivity dir: ${NM_RESULTS_DIR}"

# ── Phase 3: Synthesis ───────────────────────────────────────────────────────
echo ""
echo "PHASE 3: Synthesis Report"
python3 scripts/analyze_synthesis.py \
    --besu-baseline "${BESU_BASELINE_DIR}" \
    --besu-sensitivity "${BESU_SENS_DIR}" \
    --nm-results "${NM_RESULTS_DIR}" \
    | tee /home/yeochan.yoon/caliper-stress-test/final_synthesis_1GB.md

echo ""
echo "======================================================================"
echo "ALL PHASES COMPLETE"
echo "======================================================================"
echo "Reports:"
echo "  Besu sensitivity:  ${BESU_SENS_DIR}/final_besu_sensitivity_1GB.md"
echo "  NM evaluation:     ${NM_RESULTS_DIR}/final_nethermind_evaluation_1GB.md"
echo "  Synthesis:         final_synthesis_1GB.md"
echo "======================================================================"
