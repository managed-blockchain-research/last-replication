#!/usr/bin/env python3
import argparse
import json
import pandas as pd
import numpy as np


def _find_col(df, candidates):
    lower_map = {c.lower().strip(): c for c in df.columns}
    for cand in candidates:
        if cand in lower_map:
            return lower_map[cand]
    return None


def _pick_counter_col(df):
    candidates = [
        "counter name",
        "countername",
        "counter_name",
        "name",
        "display name",
        "displayname",
        "counter",
    ]
    return _find_col(df, candidates)


def _pick_value_col(df):
    candidates = [
        "value",
        "counter value",
        "countervalue",
        "mean/increment",
        "mean",
        "increment"
    ]
    return _find_col(df, candidates)


def _summarize_series(series):
    series = series.dropna().astype(float)
    if series.empty:
        return None
    return {
        "avg": float(series.mean()),
        "p95": float(np.percentile(series, 95)),
        "max": float(series.max()),
        "min": float(series.min()),
        "last": float(series.iloc[-1]),
        "first": float(series.iloc[0]),
        "delta": float(series.iloc[-1] - series.iloc[0]),
    }


def summarize(input_csv, output_json):
    df = pd.read_csv(input_csv)
    counter_col = _pick_counter_col(df)
    value_col = _pick_value_col(df)

    if not counter_col or not value_col:
        raise ValueError("Could not find counter/value columns in CSV.")

    df[counter_col] = df[counter_col].astype(str).str.lower()

    targets = {
        "time_in_gc_percent": "time-in-gc",
        "alloc_rate_bytes_per_sec": "alloc-rate",
        "gc_heap_size_bytes": "gc-heap-size",
        "gen0_gc_count": "gen-0-gc-count",
        "gen1_gc_count": "gen-1-gc-count",
        "gen2_gc_count": "gen-2-gc-count",
        "loh_size_bytes": "loh-size",
        "loh_fragmentation_percent": "loh-fragmentation",
        "pinned_objects_size_bytes": "pinned-objects-size",
    }

    summary = {}
    for key, pattern in targets.items():
        series = df[df[counter_col].str.contains(pattern)][value_col]
        stats = _summarize_series(series)
        if stats:
            summary[key] = stats

    with open(output_json, "w") as f:
        json.dump(summary, f, indent=2)

    print(f"Wrote summary: {output_json}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Summarize dotnet-counters CSV output.")
    parser.add_argument("--input", required=True, help="Path to dotnet-counters CSV file.")
    parser.add_argument("--output", required=True, help="Path to summary JSON output.")
    args = parser.parse_args()

    summarize(args.input, args.output)
