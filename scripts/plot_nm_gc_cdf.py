"""
Generate fig_nm_gc_pause_cdf.pdf — journal-quality CDF of NM GC pause durations.

Usage: python3 plot_nm_gc_cdf.py [--data /tmp/nm_gc_per_event.csv]
Output: fig_nm_gc_pause_cdf.pdf in the same directory as this script.
"""

import argparse
import csv
import os
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

# ── Config ────────────────────────────────────────────────────────────────────

VARIANTS = ["baseline", "lass75", "last_al", "last_lass75"]
LABELS = {
    "baseline":    "Baseline (FIFO)",
    "lass75":      "LASS-75",
    "last_al":     "LAST-AL",
    "last_lass75": "LAST + LASS-75",
}
COLORS = {
    "baseline":    "#1565c0",   # strong blue
    "lass75":      "#2e7d32",   # forest green
    "last_al":     "#c62828",   # strong red
    "last_lass75": "#6a1b9a",   # deep purple
}
LINESTYLES = {
    "baseline":    "-",
    "lass75":      "--",
    "last_al":     ":",
    "last_lass75": "-.",
}
LINEWIDTH = 1.8
MARKER_PERCS = [50, 95, 99]

# ── Parse arguments ───────────────────────────────────────────────────────────

parser = argparse.ArgumentParser()
parser.add_argument("--data", default="/tmp/nm_gc_per_event.csv",
                    help="Per-event CSV produced by NettraceGcParser --csv")
parser.add_argument("--out", default=None,
                    help="Output PDF path (default: fig_nm_gc_pause_cdf.pdf next to this script)")
args = parser.parse_args()

out_path = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "fig_nm_gc_pause_cdf.pdf")
out_path = os.path.normpath(out_path)

# ── Load data ─────────────────────────────────────────────────────────────────

data: dict[str, list[float]] = defaultdict(list)
with open(args.data) as f:
    for row in csv.DictReader(f):
        data[row["variant"]].append(float(row["pause_ms"]))

# Sanity check
for v in VARIANTS:
    if v not in data:
        sys.exit(f"ERROR: variant '{v}' not found in {args.data}")
    print(f"  {LABELS[v]}: n={len(data[v])}, "
          f"mean={np.mean(data[v]):.0f}ms, "
          f"p50={np.percentile(data[v], 50):.0f}ms, "
          f"p95={np.percentile(data[v], 95):.0f}ms, "
          f"p99={np.percentile(data[v], 99):.0f}ms, "
          f"max={max(data[v]):.0f}ms")

# ── Style ─────────────────────────────────────────────────────────────────────

plt.rcParams.update({
    "font.family":        "serif",
    "font.size":          9,
    "axes.titlesize":     10,
    "axes.labelsize":     9,
    "xtick.labelsize":    8,
    "ytick.labelsize":    8,
    "legend.fontsize":    8,
    "lines.linewidth":    LINEWIDTH,
    "pdf.fonttype":       42,      # embeds fonts for IEEE submission
    "ps.fonttype":        42,
    "figure.dpi":         300,
    "savefig.bbox":       "tight",
    "savefig.pad_inches": 0.05,
})

fig, ax = plt.subplots(figsize=(3.5, 2.6))   # single-column IEEE width

# ── Plot ECDF per variant ─────────────────────────────────────────────────────

for v in VARIANTS:
    pauses = np.sort(data[v])
    cdf = np.arange(1, len(pauses) + 1) / len(pauses)
    ax.plot(pauses, cdf,
            color=COLORS[v],
            linestyle=LINESTYLES[v],
            linewidth=LINEWIDTH,
            label=LABELS[v],
            zorder=3)

# ── Percentile markers (vertical dashed lines for LAST-AL at P95/P99) ─────────

# Highlight LAST-AL tail vs LAST+LASS-75 tail with annotation
last_al_p99  = np.percentile(data["last_al"],     99)
combo_p99    = np.percentile(data["last_lass75"],  99)
last_al_p95  = np.percentile(data["last_al"],      95)
combo_p95    = np.percentile(data["last_lass75"],  95)

# Thin vertical reference lines at P95/P99 for last_al
for perc, yval in [(95, 0.95), (99, 0.99)]:
    val = np.percentile(data["last_al"], perc)
    ax.axvline(val, color=COLORS["last_al"], linestyle=":", linewidth=0.7,
               alpha=0.5, zorder=1)

# Annotation: P99 gap between LAST-AL and LAST+LASS
ax.annotate(
    f"P99 gap\n{last_al_p99/1000:.1f}s → {combo_p99/1000:.1f}s",
    xy=(last_al_p99, 0.99),
    xytext=(last_al_p99 * 1.5, 0.80),
    fontsize=6.5,
    color="#555",
    arrowprops=dict(arrowstyle="-|>", color=COLORS["last_al"],
                    lw=0.8, connectionstyle="arc3,rad=0.2"),
    ha="left",
)

# ── Axes formatting ───────────────────────────────────────────────────────────

ax.set_xscale("log")
ax.set_xlim(10, 12_000)
ax.set_ylim(-0.02, 1.05)
ax.set_xlabel("GC Pause Duration (ms, log scale)")
ax.set_ylabel("CDF")

ax.xaxis.set_major_formatter(ticker.FuncFormatter(
    lambda x, _: f"{int(x):,}" if x >= 1 else f"{x:.1f}"
))
ax.set_xticks([10, 100, 500, 1000, 3000, 7000])
ax.xaxis.set_major_formatter(ticker.FuncFormatter(
    lambda x, _: {10: "10", 100: "100", 500: "500",
                  1000: "1k", 3000: "3k", 7000: "7k"}.get(int(x), str(int(x)))
))

# P50/P95/P99 horizontal guides
for yline in [0.50, 0.95, 0.99]:
    ax.axhline(yline, color="#aaa", linestyle="--", linewidth=0.5, zorder=0)
    ax.text(10.5, yline + 0.01, f"P{int(yline*100)}", fontsize=6, color="#888", va="bottom")

ax.grid(which="both", axis="x", linestyle=":", linewidth=0.4, color="#ddd", zorder=0)
ax.spines[["top", "right"]].set_visible(False)

# ── Legend ────────────────────────────────────────────────────────────────────

legend = ax.legend(
    loc="lower right",
    framealpha=0.92,
    edgecolor="#ccc",
    handlelength=2.0,
    borderpad=0.5,
    labelspacing=0.3,
)

# ── Save ──────────────────────────────────────────────────────────────────────

fig.savefig(out_path, format="pdf")
print(f"\nSaved: {out_path}")

# Also print key stats table
print("\n── Key Percentiles (ms) ──────────────────────────────────────────")
print(f"{'Variant':<22} {'P50':>7} {'P95':>7} {'P99':>7} {'Max':>7}")
print("-" * 50)
for v in VARIANTS:
    p = data[v]
    print(f"{LABELS[v]:<22} {np.percentile(p,50):>7.0f} "
          f"{np.percentile(p,95):>7.0f} {np.percentile(p,99):>7.0f} "
          f"{max(p):>7.0f}")
