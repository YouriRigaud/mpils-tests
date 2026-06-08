#!/usr/bin/env python3
"""
Compute per-instance median objective and tuning time across seeds
for the exploration budget factor study.

Expects the output layout produced by submit-study-expl-budget.sh:
  <results-dir>/<batch>/<factor>-expl-factor/seed-<N>/metrics_*.csv

Each metrics CSV (written by run-instances.sh) has columns:
  instance, seed, objective, tuning_time

Output: expl_budget_summary.csv
  instance, expl_factor, median_obj, median_time_s, n_seeds

Also prints a mean-across-instances table to stdout.

Usage:
  python summarize-study-expl-budget.py \
      --results-dir /scratch/yorig/mpils-results-grid-seconds-10-expl-budget \
      --output      expl_budget_summary.csv
"""

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path


def low_median(values):
    s = sorted(values)
    return s[(len(s) - 1) // 2]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--output",      default="expl_budget_summary.csv")
    args = ap.parse_args()

    results_dir = Path(args.results_dir)

    # data[(instance, expl_factor)] = {"objectives": [], "times": []}
    data = defaultdict(lambda: {"objectives": [], "times": []})

    factor_re = re.compile(r'^(\d+)-expl-factor$')

    for metrics_csv in sorted(results_dir.rglob("metrics_*.csv")):
        # Extract expl_factor from path: .../batch/<factor>-expl-factor/seed-N/metrics_*.csv
        expl_factor = None
        for part in metrics_csv.parts:
            m = factor_re.match(part)
            if m:
                expl_factor = int(m.group(1))
                break

        if expl_factor is None:
            print(f"Warning: could not extract expl_factor from path: {metrics_csv}")
            continue

        try:
            with open(metrics_csv, newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    try:
                        instance = row["instance"]
                        obj_str  = row["objective"]
                        time_str = row["tuning_time"]
                    except KeyError:
                        continue

                    if obj_str == "NA" or time_str == "NA":
                        continue

                    try:
                        obj  = float(obj_str)
                        time = int(time_str)
                    except ValueError:
                        continue

                    data[(instance, expl_factor)]["objectives"].append(obj)
                    data[(instance, expl_factor)]["times"].append(time)
        except OSError as e:
            print(f"Warning: could not read {metrics_csv}: {e}")

    if not data:
        print("No data found.")
        return

    rows = []
    for (instance, expl_factor), d in data.items():
        if not d["objectives"]:
            continue
        med_obj  = low_median(d["objectives"])
        med_time = low_median(d["times"])
        n_seeds  = len(d["objectives"])
        rows.append((instance, expl_factor, med_obj, med_time, n_seeds))

    rows.sort(key=lambda r: (r[0], r[1]))

    output_path = Path(args.output)
    with open(output_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["instance", "expl_factor", "median_obj", "median_time_s", "n_seeds"])
        for instance, expl_factor, med_obj, med_time, n_seeds in rows:
            w.writerow([instance, expl_factor, f"{med_obj:.2f}", med_time, n_seeds])

    n_factors   = len(set(r[1] for r in rows))
    n_instances = len(set(r[0] for r in rows))
    print(f"Written: {output_path}  ({n_instances} instances, {n_factors} expl_factor values)")

    # Summary table: mean of per-instance medians across all instances
    factors = sorted(set(r[1] for r in rows))
    cell_obj  = defaultdict(list)
    cell_time = defaultdict(list)
    for instance, expl_factor, med_obj, med_time, _ in rows:
        cell_obj[expl_factor].append(med_obj)
        cell_time[expl_factor].append(med_time)

    print()
    print("Mean of per-instance medians across all instances")
    print(f"{'expl_factor':>12}  {'mean_obj':>9}  {'mean_time_s':>11}  {'n_inst':>6}")
    print("-" * 46)
    for f in factors:
        objs  = cell_obj[f]
        times = cell_time[f]
        mean_obj  = sum(objs)  / len(objs)  if objs  else float("nan")
        mean_time = sum(times) / len(times) if times else float("nan")
        print(f"{f:>12}  {mean_obj:9.2f}  {int(mean_time):>11}  {len(objs):>6}")


if __name__ == "__main__":
    main()
