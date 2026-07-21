#!/usr/bin/env python3
"""
논문 'Mitigating the Latency Cliff in Managed Blockchain Clients'에 사용된
정확한 데이터만 모아 CDF 그리기용 latency_ms CSV 생성.

출처 (EXPERIMENT_RESULT_FILES_INDEX.md 기준):
- Besu: results/extreme/baseline_latency.csv, espill_latency.csv (96.2%/98.1% run)
- Nethermind: results/nethermind/gcdump-20260130_125919/baseline_pre_latency.csv, espill_pre_latency.csv (5.7% run)
"""
import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "paper_cdf_latency.csv"

SOURCES = [
    ("Besu", "Baseline", ROOT / "results" / "extreme" / "baseline_latency.csv"),
    ("Besu", "LASS",     ROOT / "results" / "extreme" / "espill_latency.csv"),
    ("Nethermind", "Baseline", ROOT / "results" / "nethermind" / "gcdump-20260130_125919" / "baseline_pre_latency.csv"),
    ("Nethermind", "LASS",     ROOT / "results" / "nethermind" / "gcdump-20260130_125919" / "espill_pre_latency.csv"),
]

def main():
    with open(OUTPUT, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["client", "config", "latency_ms"])
        for client, config, path in SOURCES:
            if not path.exists():
                print(f"Skip (not found): {path}")
                continue
            n = 0
            with open(path, newline="") as inf:
                r = csv.DictReader(inf)
                for row in r:
                    if row.get("success", "").strip().lower() != "true":
                        continue
                    try:
                        lat = float(row["latency_ms"])
                    except (KeyError, ValueError):
                        continue
                    w.writerow([client, config, round(lat, 6)])
                    n += 1
            print(f"{client} {config}: {n} rows from {path.name}")
    print(f"Written: {OUTPUT}")

if __name__ == "__main__":
    main()
