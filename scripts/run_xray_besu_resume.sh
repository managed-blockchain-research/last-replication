#!/bin/bash
# ============================================================
# XRAY-v2 Resume: Besu n=30 + Figures + LaTeX + PDF
#
# NM Clique n=30 already complete (20260627_000957_xray_nm_clique_n30).
# This script runs Phase 1b (Besu) then Phases 2-4.
# ============================================================
set -euo pipefail

CALIPER_DIR="/home/yeochan.yoon/caliper-stress-test"
PAPER_DIR="/home/yeochan.yoon/banning/papers/xray"
LOG="/tmp/xray_besu_resume.log"

export PATH="/home/yeochan.yoon/texlive/2025/bin/x86_64-linux:/home/yeochan.yoon/.dotnet/tools:/home/yeochan.yoon/.dotnet:${PATH}"
export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"

exec > >(tee -a "${LOG}") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Resource check (abort only on OOM risk) ───────────────────────────────────
check_resources() {
    local waited=0
    while true; do
        local avail_gb load swap_free_kb
        avail_gb=$(free -g | awk '/^Mem/{print $7}')
        load=$(awk '{print $1}' /proc/loadavg | cut -d. -f1)
        swap_free_kb=$(awk '/^SwapFree/{print $2}' /proc/meminfo)

        local ok=1
        (( avail_gb < 50 )) && { log "WAIT: Only ${avail_gb}GB available (need ≥50GB)"; ok=0; }
        (( load > 20 ))     && { log "WAIT: Load ${load} > 20"; ok=0; }
        if (( swap_free_kb < 102400 )) && (( avail_gb < 30 )); then
            log "ABORT: Swap exhausted AND avail<30GB — OOM risk"; exit 1
        fi
        (( ok )) && { log "Resources OK: ${avail_gb}GB avail, load≈${load}"; return 0; }

        waited=$((waited + 600))
        (( waited > 14400 )) && { log "ABORT: Resources not free after 4h"; exit 1; }
        log "Retrying in 10min... (${waited}s waited)"
        sleep 600
    done
}

# ══════════════════════════════════════════════════════════════
# PHASE 1b — Besu n=30
# ══════════════════════════════════════════════════════════════
log "=== PHASE 1b: Besu n=30 ==="
check_resources

BESU_N30_LOG="/tmp/xray_besu_n30.log"
cd "${CALIPER_DIR}"
bash scripts/run_xray_besu_n30.sh 30 > "${BESU_N30_LOG}" 2>&1
log "Besu n=30 complete. Log: ${BESU_N30_LOG}"

# ══════════════════════════════════════════════════════════════
# PHASE 2 — Figures
# ══════════════════════════════════════════════════════════════
log "=== PHASE 2: Generate figures ==="

NM_RUN=$(ls -td /home/yeochan.yoon/banning/experiments/xray/results/xray_clique_nm/*/ 2>/dev/null | head -1)
BESU_RUN=$(ls -td /home/yeochan.yoon/banning/experiments/xray/results/besu_n30/*/ 2>/dev/null | head -1)

if [ -z "${NM_RUN}" ] || [ -z "${BESU_RUN}" ]; then
    log "ERROR: Missing result directories"
    log "  NM:   ${NM_RUN:-MISSING}"
    log "  Besu: ${BESU_RUN:-MISSING}"
    exit 1
fi
log "NM results:   ${NM_RUN}"
log "Besu results: ${BESU_RUN}"

cd "${PAPER_DIR}"
pip install scipy --quiet 2>/dev/null || true
python3 scripts/gen_figures_n30.py 2>&1 | tee /tmp/xray_figures.log
log "Figures generated."

# ══════════════════════════════════════════════════════════════
# PHASE 3 — Manuscript update
# ══════════════════════════════════════════════════════════════
log "=== PHASE 3: Update manuscript ==="
python3 scripts/update_paper_n30.py 2>&1 | tee /tmp/xray_paper_update.log

sed -i 's/three replications/30 replications/g'                              main.tex
sed -i 's/NethDev consensus ceiling/Clique PoA consensus/g'                  main.tex
sed -i 's/spaceneth NethDev mode (chainId 99)/Clique PoA consensus (chainId 1337)/g' main.tex
sed -i 's/no server-GC override/Server GC enabled via DOTNET_gcServer=1/g'  main.tex
log "Manuscript updated."

# ══════════════════════════════════════════════════════════════
# PHASE 4 — LaTeX compile
# ══════════════════════════════════════════════════════════════
log "=== PHASE 4: LaTeX compilation ==="
cd "${PAPER_DIR}"

run_latex() {
    pdflatex -interaction=nonstopmode -halt-on-error main.tex 2>&1
    bibtex main 2>&1 || true
    pdflatex -interaction=nonstopmode -halt-on-error main.tex 2>&1
    pdflatex -interaction=nonstopmode -halt-on-error main.tex 2>&1
}

run_latex > /tmp/xray_latex1.log 2>&1 || true

if grep -q "Emergency stop\|Fatal error\|cannot find file" /tmp/xray_latex1.log 2>/dev/null; then
    log "LaTeX critical error. Checking..."
    grep -E "Error|error|missing|undefined" /tmp/xray_latex1.log | head -20
    if [ -f main.tex.bak ]; then
        cp main.tex.bak main.tex
        sed -i 's/n = 3/n = 30/g' main.tex
        sed -i 's/three-replication/30-replication/g' main.tex
        run_latex > /tmp/xray_latex2.log 2>&1 || true
    fi
fi

if grep -q "Overfull .hbox" /tmp/xray_latex1.log 2>/dev/null; then
    log "Overfull hbox — applying emergencystretch fix..."
    sed -i 's/\\setlength{\\emergencystretch}{3em}/\\setlength{\\emergencystretch}{5em}/' main.tex
    run_latex > /tmp/xray_latex3.log 2>&1 || true
fi

run_latex > /tmp/xray_latex_final.log 2>&1 || true

if [ -f main.pdf ]; then
    cp main.pdf XRAY.pdf
    PAGES=$(python3 -c "
import subprocess
try:
    out = subprocess.check_output(['pdfinfo','XRAY.pdf'],stderr=subprocess.DEVNULL).decode()
    for l in out.split('\n'):
        if 'Pages' in l: print(l.strip()); break
except Exception: print('pages: unknown')
" 2>/dev/null || echo "pdfinfo unavailable")
    log "SUCCESS: XRAY.pdf generated (${PAGES})"
else
    log "ERROR: PDF not generated"
    tail -30 /tmp/xray_latex_final.log
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "════════════════════════════════════════════════"
log "XRAY-v2 Resume Complete"
log "════════════════════════════════════════════════"
log "Besu n=30 log:  ${BESU_N30_LOG}"
log "Figures:        ${PAPER_DIR}/xray_fig[1-6]_*.{pdf,svg}"
log "Paper:          ${PAPER_DIR}/XRAY.pdf"
log "Master log:     ${LOG}"
log ""
log "Key metrics:"
grep -E "TPS=|PAF|tau|gen2|mean" "${BESU_N30_LOG}" 2>/dev/null | tail -10 || true
