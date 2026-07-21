#!/usr/bin/env python3.11
"""
Bootstrap-CI statistical report for RAAC multi-arm GC-pause results.

Georges/Buytaert/Eeckhout (OOPSLA 2007) argue that a single JVM-invocation's
internal repetitions aren't independent (JIT/heap-history carries over), so
multiple independent process invocations plus a confidence interval — not a
bare mean over n=3 — is the right way to report JVM performance numbers. This
script implements that for RAAC's per-arm GC-pause measurements: percentile
bootstrap CI (not a t-CI) because the data is visibly skewed/bimodal (some
aggressive runs fully suppress GC and land at/near 0ms).

Expects a results directory of subdirs named "<arm>_<rep>" (e.g.
"static_besu_1", "raac_moderate_besu_7"), each containing a "gc_summary.txt"
with either a numeric total STW ms value or the literal "no_gc_events"
(treated as 0).

Usage:
  python3 bootstrap_ci_report.py --results-dir <dir> --baseline static \
      --resamples 10000 --out report.md
"""
import argparse
import json
import re
import sys
from pathlib import Path

try:
    import numpy as np
except ImportError:
    print("ERROR: numpy required", file=sys.stderr)
    sys.exit(1)


def load_arm_values(results_dir: Path):
    """Return {arm_name: [gc_ms, ...]} scanning <arm>_<rep> subdirs."""
    arms = {}
    for d in sorted(results_dir.iterdir()):
        if not d.is_dir():
            continue
        m = re.match(r"^(.+)_(\d+)$", d.name)
        if not m:
            continue
        arm = m.group(1)
        summary_path = d / "gc_summary.txt"
        if not summary_path.exists():
            continue
        raw = summary_path.read_text().strip()
        if raw in ("", "no_gc_events", "parse_error"):
            val = 0.0
        else:
            try:
                val = float(raw)
            except ValueError:
                continue
        arms.setdefault(arm, []).append(val)
    return arms


def percentile_bootstrap_ci(values, resamples=10000, alpha=0.05, seed=42):
    rng = np.random.default_rng(seed)
    values = np.asarray(values, dtype=float)
    n = len(values)
    boot_means = np.empty(resamples)
    for i in range(resamples):
        sample = rng.choice(values, size=n, replace=True)
        boot_means[i] = sample.mean()
    lo = np.percentile(boot_means, 100 * (alpha / 2))
    hi = np.percentile(boot_means, 100 * (1 - alpha / 2))
    return lo, hi


def summarize(values, resamples):
    arr = np.asarray(values, dtype=float)
    n = len(arr)
    mean = float(arr.mean())
    median = float(np.median(arr))
    std = float(arr.std(ddof=1)) if n > 1 else 0.0
    ci_lo, ci_hi = percentile_bootstrap_ci(arr, resamples=resamples) if n > 1 else (mean, mean)
    suppressed = int((arr <= 1.0).sum())  # "fully suppressed" ~ 0ms (allow 1ms float slack)
    return {
        "n": n, "mean": mean, "median": median, "std": std,
        "ci95_lo": float(ci_lo), "ci95_hi": float(ci_hi),
        "gc_suppressed_ratio": f"{suppressed}/{n}",
        "values": arr.tolist(),
    }


def main():
    ap = argparse.ArgumentParser(description="Bootstrap CI report for RAAC multi-arm results")
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--baseline", default="static", help="arm name to compute relative reduction against")
    ap.add_argument("--resamples", type=int, default=10000)
    ap.add_argument("--out", default=None, help="markdown output path (also prints to stdout)")
    ap.add_argument("--out-json", default=None)
    args = ap.parse_args()

    results_dir = Path(args.results_dir)
    arms = load_arm_values(results_dir)
    if not arms:
        print(f"ERROR: no <arm>_<rep> subdirs with gc_summary.txt found under {results_dir}", file=sys.stderr)
        sys.exit(1)

    summaries = {arm: summarize(vals, args.resamples) for arm, vals in arms.items()}

    baseline_mean = summaries.get(args.baseline, {}).get("mean")

    lines = []
    lines.append(f"# GC Pause Bootstrap-CI Report — {results_dir.name}\n")
    lines.append(f"Percentile bootstrap CI, {args.resamples} resamples, 95% interval. "
                 f"'GC suppressed' = runs with total STW pause <= 1ms.\n")
    lines.append("| Arm | n | Mean (ms) | Median (ms) | 95% CI (ms) | vs baseline | GC suppressed |")
    lines.append("|---|---|---|---|---|---|---|")
    for arm, s in sorted(summaries.items(), key=lambda kv: kv[1]["mean"], reverse=True):
        vs_baseline = "—"
        if baseline_mean and arm != args.baseline and baseline_mean > 0:
            pct = 100.0 * (s["mean"] - baseline_mean) / baseline_mean
            vs_baseline = f"{pct:+.1f}%"
        lines.append(
            f"| {arm} | {s['n']} | {s['mean']:.1f} | {s['median']:.1f} | "
            f"[{s['ci95_lo']:.1f}, {s['ci95_hi']:.1f}] | {vs_baseline} | {s['gc_suppressed_ratio']} |"
        )

    report = "\n".join(lines) + "\n"
    print(report)

    if args.out:
        Path(args.out).write_text(report)
        print(f"[report] wrote {args.out}", file=sys.stderr)
    if args.out_json:
        Path(args.out_json).write_text(json.dumps(summaries, indent=2))
        print(f"[report] wrote {args.out_json}", file=sys.stderr)


if __name__ == "__main__":
    main()
