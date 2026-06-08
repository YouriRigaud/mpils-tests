#!/usr/bin/env python3
"""
Compute per-instance median objective and tuning time across seeds
for the expansion parameter budget study.

Input: results.csv files produced by run-study-expansion.sh, laid out as:
  <results-dir>/expbud<B>_es<ES>/<batch>/seed-<N>/results.csv

Each CSV has columns:
  instance, expansion_budget, early_stop, seed, objective, tuning_time

Output: expansion_study_summary.csv
  instance, expansion_budget, early_stop, median_obj, median_time_s, n_seeds

Usage:
  python summarize-study-expansion.py \
      --results-dir /scratch/yorig/study-expansion \
      --output      expansion_study_summary.csv
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
    ap.add_argument("--output",      default="expansion_study_summary.csv")
    args = ap.parse_args()

    results_dir = Path(args.results_dir)

    # data[(instance, expansion_budget, early_stop)] = {"objectives": [], "times": []}
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
                        instance        = row["instance"]
                        expansion_budget= int(row["expansion_budget"])
                        early_stop      = row["early_stop"]
                        obj_str         = row["objective"]
                        time_str        = row["tuning_time"]
                    except (KeyError, ValueError):
                        continue

                    if obj_str == "NA" or time_str == "NA":
                        continue

                    try:
                        obj  = float(obj_str)
                        time = int(time_str)
                    except ValueError:
                        continue

                    key = (instance, expansion_budget, early_stop)
                    data[key]["objectives"].append(obj)
                    data[key]["times"].append(time)
        except OSError as e:
            print(f"Warning: could not read {csv_path}: {e}")

    rows = []
    for (instance, expansion_budget, early_stop), d in data.items():
        if not d["objectives"]:
            continue
        med_obj  = low_median(d["objectives"])
        med_time = low_median(d["times"])
        n_seeds  = len(d["objectives"])
        rows.append((instance, expansion_budget, early_stop, med_obj, med_time, n_seeds))

    # Sort by instance, early_stop, expansion_budget
    rows.sort(key=lambda r: (r[0], r[2], r[1]))

    output_path = Path(args.output)
    with open(output_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["instance", "expansion_budget", "early_stop",
                    "median_obj", "median_time_s", "n_seeds"])
        for instance, expansion_budget, early_stop, med_obj, med_time, n_seeds in rows:
            w.writerow([instance, expansion_budget, early_stop,
                        f"{med_obj:.2f}", med_time, n_seeds])

    n_conditions = len(set((r[1], r[2]) for r in rows))
    n_instances  = len(set(r[0] for r in rows))
    print(f"Written: {output_path}  ({n_instances} instances, {n_conditions} conditions)")

    # Print summary table: mean across instances for each (expansion_budget, early_stop)
    from collections import defaultdict as dd
    cell = dd(list)
    for instance, expansion_budget, early_stop, med_obj, *_ in rows:
        cell[(expansion_budget, early_stop)].append(med_obj)

    budgets    = sorted(set(r[1] for r in rows))
    earlystops = sorted(set(r[2] for r in rows), reverse=True)  # yes before no

    print()
    print("Mean of per-instance medians across all instances")
    header = f"{'budget':>8}" + "".join(f"  es={es:>3}" for es in earlystops)
    print(header)
    print("-" * len(header))
    for b in budgets:
        row = f"{b:>8}"
        for es in earlystops:
            vals = cell[(b, es)]
            if vals:
                row += f"  {sum(vals)/len(vals):7.2f}"
            else:
                row += "       NA"
        print(row)


if __name__ == "__main__":
    main()
