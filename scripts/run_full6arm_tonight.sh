#!/usr/bin/env bash
# Wrapper for the 23:00 KST scheduled run: pre-flight load/mem check (logged,
# not blocking — the point of running at night is that this window is
# already the safe one) then launch the full 6-arm eval.
#
# This is the guaranteed-fallback trigger. If an earlier 20:00/21:00/22:00
# opportunistic check already started the run (load was low enough), a
# marker file exists and this script must NOT start a second, conflicting run.
set -uo pipefail
MARKER="/home/yeochan.yoon/caliper-stress-test/FULL6ARM_STARTED.marker"

if [ -f "${MARKER}" ]; then
    echo "$(date): marker ${MARKER} already exists (started at $(cat "${MARKER}")) — skipping 23:00 fallback launch."
    exit 0
fi

PREFLIGHT_LOG="/home/yeochan.yoon/caliper-stress-test/preflight_$(date +%Y%m%d_%H%M%S).log"

{
    echo "=== Pre-flight check $(date) ==="
    uptime
    free -h
    echo "=== atq / other scheduled jobs ==="
    atq 2>/dev/null || true
    echo "=== top CPU procs ==="
    ps -eo pid,user,pcpu,pmem,etime,comm --sort=-pcpu | head -10
} > "${PREFLIGHT_LOG}" 2>&1

cat "${PREFLIGHT_LOG}"

date > "${MARKER}"
bash /home/yeochan.yoon/caliper-stress-test/scripts/run_raac_full_6arm.sh
