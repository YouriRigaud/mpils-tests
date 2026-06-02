#!/usr/bin/env python3
"""
Compute low-median objective and tuning time across seeds for the ILS budget study.

Input: results.csv files produced by run-study-ils-budget.sh, laid out as:
  <results-dir>/k<K>_n<N>/<batch>/<seed-N>/results.csv

Each CSV has columns: instance, k, n_params, seed, objective, tuning_time

Output: study_ils_budget_summary.csv
  instance, k, n_params, median_obj, median_time_s

Usage:
  python summarize-study-ils-budget.py \
      --results-dir /scratch/yorig/study-ils-budget \
      --output      study_ils_budget_summary.csv
"""

import argparse
import csv
from collections import defaultdict
from pathlib import Path


def low_median(values):
    s = sorted(values)
    return s[(len(s) - 1) // 2]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--output",      default="study_ils_budget_summary.csv")
    args = ap.parse_args()

    results_dir = Path(args.results_dir)

    # data[(instance, k, n_params)] = {"objectives": [], "times": []}
    data = defaultdict(lambda: {"objectives": [], "times": []})

    csv_files = sorted(results_dir.rglob("results.csv"))
    if not csv_files:
        print(f"No results.csv files found under {results_dir}")
        return

    for csv_path in csv_files:
        try:
            with open(csv_path, newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    try:
                        instance = row["instance"]
                        k        = int(row["k"])
                        n_params = int(row["n_params"])
                        obj_str  = row["objective"]
                        time_str = row["tuning_time"]
                    except (KeyError, ValueError):
                        continue

                    if obj_str == "NA" or time_str == "NA":
                        continue

                    try:
                        obj  = float(obj_str)
                        time = int(time_str)
                    except ValueError:
                        continue

                    key = (instance, k, n_params)
                    data[key]["objectives"].append(obj)
                    data[key]["times"].append(time)
        except OSError as e:
            print(f"Warning: could not read {csv_path}: {e}")

    # Build sorted output rows: sort by (instance, n_params, k)
    rows = []
    for (instance, k, n_params), d in data.items():
        if not d["objectives"]:
            continue
        med_obj  = low_median(d["objectives"])
        med_time = low_median(d["times"])
        n_seeds  = len(d["objectives"])
        rows.append((instance, k, n_params, med_obj, med_time, n_seeds))

    rows.sort(key=lambda r: (r[0], r[2], r[1]))  # instance, n_params, k

    output_path = Path(args.output)
    with open(output_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["instance", "k", "n_params", "median_obj", "median_time_s", "n_seeds"])
        for instance, k, n_params, med_obj, med_time, n_seeds in rows:
            w.writerow([instance, k, n_params, f"{med_obj:.2f}", med_time, n_seeds])

    n_conditions = len(set((r[1], r[2]) for r in rows))
    n_instances  = len(set(r[0] for r in rows))
    print(f"Written: {output_path}  ({n_instances} instances, {n_conditions} (k, n_params) conditions)")


if __name__ == "__main__":
    main()
