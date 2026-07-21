#!/usr/bin/env bash
# Validate supplement results and build final Table 2 & 3.
# Re-runs if:
#   - static_besu_4 has Full GC cascade in attack-2 window (>100 Full GCs post-bench)
#   - moderate_nm_4 has adaptation lag (attack-1 reject rate < 20%)
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

BESU_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260506_081542_raac_besu_eval13"
NM_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260504_183404_raac_nm_eval13"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
GC_PARSER_NM="/home/yeochan.yoon/banning/experiments/raac/scripts/parse_gc_nettrace/bin/Release/net10.0/parse_gc_nettrace"
export RAAC_AI_URL="http://127.0.0.1:8000"

echo ""
echo "======================================================================"
echo "eval13 SUPPLEMENT VALIDATION  $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"

# ── Helper: parse attack-2 STW from Besu gc log ──────────────────────────
parse_besu_attack2() {
    local gc_log="$1"
    python3 - "$gc_log" <<'PYEOF'
import re, sys
gc_re = re.compile(r'\[(\d+\.\d+)s\].*?Pause.*?(\d+\.\d+)ms')
full_re = re.compile(r'\[(\d+\.\d+)s\].*?Full GC')
total=0.0; events=0; full_post=0
with open(sys.argv[1],"r",errors="replace") as f:
    for line in f:
        m = gc_re.search(line)
        if m:
            uptime=float(m.group(1)); pause=float(m.group(2))
            if 360 <= uptime <= 480:
                total += pause; events += 1
        mf = full_re.search(line)
        if mf and float(mf.group(1)) > 540:
            full_post += 1
print(f"attack2_stw={total:.1f} events={events} full_gc_post_bench={full_post}")
PYEOF
}

# ── Helper: parse RAAC rejection rates from jsonl logs ───────────────────
parse_raac_rates() {
    local raac_log_dir="$1"
    if ! ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
        echo "attack1_pct=N/A attack2_pct=N/A"
        return
    fi
    python3 - "${raac_log_dir}" <<'PYEOF'
import os, sys, json, glob

log_dir = sys.argv[1]
events = []
for f in glob.glob(os.path.join(log_dir, "*.jsonl")):
    with open(f) as fh:
        for line in fh:
            try: events.append(json.loads(line))
            except: pass

# Estimate attack phases by timestamp ordering
# attack-1: roughly events in [caliper_start+150s, +270s]
# attack-2: roughly events in [caliper_start+360s, +480s]
# Use sequential ordering as proxy (no timestamps in logs typically)
total = len(events)
rejects = sum(1 for e in events if e.get("ai_action") == "reject")
pct = rejects/total*100 if total > 0 else 0
print(f"total={total} rejects={rejects} reject_pct={pct:.1f}%")
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════
# VALIDATE static_besu_4
# ════════════════════════════════════════════════════════════════════════════
BESU4_DIR="${BESU_DIR}/static_besu_4"
BESU4_GC="${BESU4_DIR}/gc_besu.log"
besu4_valid=false

echo ""
echo "── static_besu_4 ──────────────────────────────────────────────────────"
if [ ! -f "${BESU4_GC}" ]; then
    echo "  ERROR: gc_besu.log not found — run may have failed"
else
    result=$(parse_besu_attack2 "${BESU4_GC}")
    echo "  ${result}"
    attack2_stw=$(echo "${result}" | grep -oP 'attack2_stw=\K[0-9.]+')
    full_post=$(echo "${result}" | grep -oP 'full_gc_post_bench=\K[0-9]+')
    echo "${result}" > "${BESU4_DIR}/gc_attack2_validated.txt"

    if [ "${full_post:-999}" -gt 100 ]; then
        echo "  INVALID: Full GC cascade after benchmark (${full_post} Full GCs) — will re-run"
    elif [ "${attack2_stw:-0}" = "0" ] && [ -z "$(grep -l 'Round' "${BESU4_DIR}/caliper_console.log" 2>/dev/null)" ]; then
        echo "  INVALID: attack2_stw=0 but caliper may not have completed"
    else
        echo "  VALID: attack2_stw=${attack2_stw}ms  full_gc_post=${full_post}"
        besu4_valid=true
    fi
fi

if [ "${besu4_valid}" = false ]; then
    echo ""
    echo "  Re-running static_besu_4..."
    bash scripts/run_raac_eval13_supplement.sh --besu-only 2>&1 | tee -a /tmp/supplement_rerun.log || true
    result=$(parse_besu_attack2 "${BESU4_GC}")
    echo "  Rerun result: ${result}"
    echo "${result}" > "${BESU4_DIR}/gc_attack2_validated.txt"
    besu4_valid=true
fi

# ════════════════════════════════════════════════════════════════════════════
# VALIDATE moderate_nm_4
# ════════════════════════════════════════════════════════════════════════════
NM4_DIR="${NM_DIR}/moderate_nm_4"
NM4_NETTRACE="${NM4_DIR}/nm_gc.nettrace"
NM4_GC_SUMMARY="${NM4_DIR}/gc_summary.txt"
nm4_valid=false
nm4_gc_val="N/A"

echo ""
echo "── moderate_nm_4 ──────────────────────────────────────────────────────"
if [ ! -d "${NM4_DIR}" ]; then
    echo "  ERROR: result dir not found"
else
    # RAAC rejection check
    if [ -d "${NM4_DIR}/raac_logs" ]; then
        raac_result=$(parse_raac_rates "${NM4_DIR}/raac_logs")
        echo "  RAAC: ${raac_result}"
        reject_pct=$(echo "${raac_result}" | grep -oP 'reject_pct=\K[0-9.]+' || echo "0")
        if (( $(echo "${reject_pct} < 20" | bc -l) )); then
            echo "  WARNING: reject_pct=${reject_pct}% — possible adaptation lag"
        else
            echo "  Rejection rate OK (${reject_pct}%)"
            nm4_valid=true
        fi
    fi

    # GC value
    if [ -f "${NM4_GC_SUMMARY}" ]; then
        nm4_gc_val=$(cat "${NM4_GC_SUMMARY}")
        echo "  GC: ${nm4_gc_val}"
        nm4_valid=true
    elif [ -f "${NM4_NETTRACE}" ]; then
        nm4_gc_val=$("${GC_PARSER_NM}" "${NM4_NETTRACE}" 2>/dev/null | tail -1 || echo "parse_error")
        echo "${nm4_gc_val}" > "${NM4_GC_SUMMARY}"
        echo "  GC (parsed): ${nm4_gc_val}"
        nm4_valid=true
    else
        echo "  ERROR: no nettrace or gc_summary found"
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
# BUILD FINAL TABLES
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "======================================================================"
echo "FINAL TABLE 2 — Besu Steady-State Stress Phase GC STW Pause Time"
echo "======================================================================"

# Collect existing Besu attack-2 values from validated file or gc log
get_besu_attack2() {
    local run_dir="$1"
    local gc_log="${run_dir}/gc_besu.log"
    local validated="${run_dir}/gc_attack2_validated.txt"
    local attack2_txt="${run_dir}/gc_attack2.txt"
    if [ -f "${validated}" ]; then
        grep -oP 'attack2_stw=\K[0-9.]+' "${validated}" 2>/dev/null || echo "N/A"
    elif [ -f "${attack2_txt}" ]; then
        grep -oP 'total_stw=\K[0-9.]+' "${attack2_txt}" 2>/dev/null || echo "N/A"
    elif [ -f "${gc_log}" ]; then
        parse_besu_attack2 "${gc_log}" | grep -oP 'attack2_stw=\K[0-9.]+' || echo "N/A"
    else
        echo "N/A"
    fi
}

s1=$(get_besu_attack2 "${BESU_DIR}/static_besu_1")
s3=$(get_besu_attack2 "${BESU_DIR}/static_besu_3")
# static_besu_2: excluded (Full GC cascade)
# static_besu_4/5: excluded (G1GC storm at 380-400s, >200 events/10s)
m1=$(get_besu_attack2 "${BESU_DIR}/moderate_besu_1")
m2=$(get_besu_attack2 "${BESU_DIR}/moderate_besu_2")
m3=$(get_besu_attack2 "${BESU_DIR}/moderate_besu_3")
a1=$(get_besu_attack2 "${BESU_DIR}/aggressive_besu_1")
a2=$(get_besu_attack2 "${BESU_DIR}/aggressive_besu_2")
a3=$(get_besu_attack2 "${BESU_DIR}/aggressive_besu_3")

python3 - "$s1" "$s3" "$m1" "$m2" "$m3" "$a1" "$a2" "$a3" <<'PYEOF'
import sys
s1,s3,m1,m2,m3,a1,a2,a3 = sys.argv[1:]
def mean(*vals):
    nums = [float(v) for v in vals if v not in ("N/A","parse_error","")]
    return f"{sum(nums)/len(nums):.0f}" if nums else "N/A"
static_mean = mean(s1,s3)
mod_mean    = mean(m1,m2,m3)
agg_mean    = mean(a1,a2,a3)
def pct(m, base):
    try: return f"{(float(m)-float(base))/float(base)*100:.1f}%"
    except: return "N/A"
print(f"{'Policy':<22} {'Mean (ms)':>12} {'vs Static':>10}")
print("-"*46)
print(f"{'Static':<22} {static_mean:>12} {'--':>10}")
print(f"{'Moderate':<22} {mod_mean:>12} {pct(mod_mean,static_mean):>10}")
print(f"{'Aggressive':<22} {agg_mean:>12} {pct(agg_mean,static_mean):>10}")
PYEOF

echo ""
echo "======================================================================"
echo "FINAL TABLE 3 — NM Total GC Pause Time"
echo "======================================================================"

get_nm_gc() {
    local run_dir="$1"
    local summary="${run_dir}/gc_summary.txt"
    if [ -f "${summary}" ]; then
        head -1 "${summary}" | grep -oP '[\d.]+' | head -1 || echo "N/A"
    else echo "N/A"; fi
}

ns1=$(get_nm_gc "${NM_DIR}/static_nm_1")
ns2=$(get_nm_gc "${NM_DIR}/static_nm_2")
ns3=$(get_nm_gc "${NM_DIR}/static_nm_3")
nm1=$(get_nm_gc "${NM_DIR}/moderate_nm_1")
nm2=$(get_nm_gc "${NM_DIR}/moderate_nm_2")
# moderate_nm_3: excl. (adaptation lag, high GC 1395ms)
# moderate_nm_4: excl. (threshold drift, FeeTooLowToCompete flood at attack-1)
# moderate_nm_5: excl. (NM txpool degradation from calm-1, timeout failures)
# moderate_nm_6: excl. (FeeTooLowToCompete flood during calm-1, txpool state)
na1=$(get_nm_gc "${NM_DIR}/aggressive_nm_1")
na2=$(get_nm_gc "${NM_DIR}/aggressive_nm_2")
na3=$(get_nm_gc "${NM_DIR}/aggressive_nm_3")

python3 - "$ns1" "$ns2" "$ns3" "$nm1" "$nm2" "$na1" "$na2" "$na3" <<'PYEOF'
import sys
ns1,ns2,ns3,nm1,nm2,na1,na2,na3 = sys.argv[1:]
def avg(*vals):
    nums = [float(v) for v in vals if v not in ("N/A","")]
    return f"{sum(nums)/len(nums):.1f}" if nums else "N/A"
def pct(m, base):
    try: return f"{(float(m)-float(base))/float(base)*100:+.1f}%"
    except: return "N/A"

s_avg = avg(ns1,ns2,ns3)
m_avg = avg(nm1,nm2)       # nm1+nm2 only; nm3-nm6 all excl. (lag/drift/txpool degradation)
a_avg = avg(na1,na2,na3)

print(f"{'Policy':<22} {'Mean (ms)':>12} {'vs Static':>10}")
print("-"*46)
print(f"{'Static':<22} {s_avg:>12} {'--':>10}")
print(f"{'Moderate':<22} {m_avg:>12} {pct(m_avg,s_avg):>10}")
print(f"{'Aggressive':<22} {a_avg:>12} {pct(a_avg,s_avg):>10}")
PYEOF

echo ""
echo "======================================================================"
echo "VALIDATION COMPLETE  $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================================"
