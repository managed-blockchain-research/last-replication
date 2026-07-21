#!/bin/bash
RDIR="/home/yeochan.yoon/caliper-stress-test/results/prep_eval_besu/20260518_074856_prep_eval_besu"
REPORT="/home/yeochan.yoon/banning/harness/morning_report.txt"
PDF="/home/yeochan.yoon/banning/papers/prep/main.pdf"
DOCX="/home/yeochan.yoon/banning/papers/prep/prep.docx"

{
echo "======================================================"
echo "PREP Besu Eval — Morning Report | $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================"
echo ""

# 완료/미완료 집계
done=0; fail=0
for v in baseline last_hfl mats prep prep_sched; do
  for r in 1 2 3 4 5; do
    d="$RDIR/${v}_${r}"
    if [ -f "$d/gc_summary.txt" ] && [ -f "$d/report.html" ]; then
      done=$((done+1))
    else
      fail=$((fail+1))
      echo "  [MISSING] ${v}_${r}"
    fi
  done
done
echo ""
echo "완료: ${done}/25  |  미완료: ${fail}/25"
echo ""

# 각 variant별 gc ms/s (mean ± std across reps)
echo "=== GC pause (ms/s) per variant ==="
for v in baseline last_hfl mats prep prep_sched; do
  vals=""
  for r in 1 2 3 4 5; do
    f="$RDIR/${v}_${r}/gc_summary.txt"
    [ ! -f "$f" ] && continue
    gc=$(grep total_gc_ms "$f" | cut -d= -f2)
    dur=$(grep trace_duration_ms "$f" | cut -d= -f2)
    dur_s=$(echo "scale=4; $dur / 1000" | bc)
    ps=$(echo "scale=4; $gc / $dur_s" | bc 2>/dev/null)
    vals="$vals $ps"
  done
  n=$(echo $vals | wc -w)
  mean=$(echo $vals | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s/NF}')
  printf "  %-14s N=%-2s  mean=%.2f ms/s\n" "$v" "$n" "$mean"
done
echo ""

# 논문 파일 상태
echo "=== 논문 파일 ==="
if [ -f "$PDF" ]; then
  sz=$(du -sh "$PDF" | cut -f1)
  ts=$(stat -c '%y' "$PDF" | cut -d. -f1)
  echo "  PDF  : $PDF ($sz) [$ts]"
else
  echo "  PDF  : NOT FOUND"
fi
if [ -f "$DOCX" ]; then
  sz=$(du -sh "$DOCX" | cut -f1)
  ts=$(stat -c '%y' "$DOCX" | cut -d. -f1)
  echo "  DOCX : $DOCX ($sz) [$ts]"
else
  echo "  DOCX : NOT FOUND"
fi
echo ""

# resume 로그 마지막 10줄
echo "=== Resume log (last 10 lines) ==="
tail -10 /home/yeochan.yoon/banning/harness/prep_besu_resume.log 2>/dev/null || echo "  (no log)"

echo ""
echo "======================================================"
} > "$REPORT" 2>&1

echo "Morning report written to: $REPORT"
