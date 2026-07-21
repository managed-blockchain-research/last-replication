#!/bin/bash
# Fix metrics.json files for runs that used the old column mapping.
# Old: tps=$4 (Fail count), p99_s=$8 (AvgLat) — correct: tps=$9 (Throughput), p99_s=$8 (AvgLat)
# Usage: fix_metrics_json.sh <results_dir>

set -e
RESULTS_DIR="${1:-.}"

fixed=0
for run_dir in "${RESULTS_DIR}"/*/; do
    clog="${run_dir}/caliper_console.log"
    mj="${run_dir}/metrics.json"
    [ -f "${clog}" ] || continue
    [ -f "${mj}" ] || continue

    measure_line=$(grep "| measure " "${clog}" | tail -1 2>/dev/null || true)
    [ -n "${measure_line}" ] || continue

    tps=$(echo "${measure_line}" | awk -F'|' '{print $9}' | tr -d ' ')
    avg_s=$(echo "${measure_line}" | awk -F'|' '{print $8}' | tr -d ' ')

    old_tps=$(python3 -c "import json; d=json.load(open('${mj}')); print(d.get('tps','?'))" 2>/dev/null)

    if [[ "${old_tps}" != "${tps}" ]]; then
        echo "  Fixing $(basename ${run_dir}): tps ${old_tps} → ${tps}"
        echo "{\"tps\": ${tps:-null}, \"p99_s\": ${avg_s:-null}}" > "${mj}"
        fixed=$((fixed + 1))
    fi
done
echo "Fixed ${fixed} metrics.json file(s) in ${RESULTS_DIR}"
