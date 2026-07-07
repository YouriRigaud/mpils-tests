#!/usr/bin/env python3
"""
Compute low-median SMAC objective and tuning time across seeds,
for each (proc count, instance).

  objective    = min cost found by SMAC for that seed (gap %)
  tuning_time  = last_endtime - first_starttime from runhistory (seconds)

Output: smac-median-result.csv
  instance, 1proc_obj, 1proc_time_s, 2proc_obj, 2proc_time_s, ..., 24proc_obj, 24proc_time_s
  + mean row at the bottom.

Usage (on the cluster):
  python summarize-smac-medians.py \
      --results-dir /scratch/yorig/smac-results-seconds-10 \
      --output      smac-median-result.csv
"""

import argparse
import csv
import json
from pathlib import Path


PROCS   = [1, 2, 4, 8, 16, 24]
MEDIUMS = ["medium-1", "medium-2"]


def low_median(values):
    s = sorted(values)
    return s[(len(s) - 1) // 2]


def read_runhistory(rh_path: Path):
    """Return (objective, tuning_time_s) for one seed run, or None if unreadable."""
    try:
        with open(rh_path) as f:
            rh = json.load(f)
    except (json.JSONDecodeError, OSError):
        print(f"Warning: skipping unreadable runhistory: {rh_path}")
        return None

    data = rh.get("data", [])
    if not data:
        return None

    costs = [r["cost"] for r in data if isinstance(r.get("cost"), (int, float))]
    objective = min(costs) if costs else 100.0
    objective = min(objective, 100.0)

    tuning_time = round(data[-1]["endtime"] - data[0]["starttime"])
    if tuning_time < 0:
        print(f"Warning: negative tuning time ({tuning_time}s) in {rh_path}, time set to NA.")
        tuning_time = None
    return objective, tuning_time


def collect(results_dir: Path) -> dict:
    """
    Return data[instance][proc][seed] = (objective, tuning_time).
    """
    data = {}

    for proc in PROCS:
        proc_dir = results_dir / f"{proc}proc"
        if not proc_dir.exists():
            print(f"Warning: missing {proc_dir}")
            continue

        for medium in MEDIUMS:
            medium_dir = proc_dir / medium
            if not medium_dir.exists():
                continue

            for inst_dir in sorted(medium_dir.iterdir()):
                if not inst_dir.is_dir():
                    continue
                instance = inst_dir.name

                data.setdefault(instance, {}).setdefault(proc, {})

                for seed_dir in sorted(inst_dir.iterdir()):
                    if not seed_dir.is_dir() or not seed_dir.name.startswith("seed-"):
                        continue
                    try:
                        seed = int(seed_dir.name.split("-", 1)[1])
                    except (IndexError, ValueError):
                        continue
                    rh_files = list(seed_dir.rglob("runhistory.json"))
                    if not rh_files:
                        print(f"Warning: no runhistory.json in {seed_dir}")
                        continue
                    rh_path = max(rh_files, key=lambda p: p.stat().st_mtime)
                    result = read_runhistory(rh_path)
                    if result is None:
                        continue
                    data[instance][proc][seed] = result

    return data


def instance_order(results_dir: Path) -> list:
    order, seen = [], set()
    for medium in MEDIUMS:
        medium_dir = results_dir / "1proc" / medium
        if not medium_dir.exists():
            continue
        for inst_dir in sorted(medium_dir.iterdir()):
            if inst_dir.is_dir() and inst_dir.name not in seen:
                order.append(inst_dir.name)
                seen.add(inst_dir.name)
    return order


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", default="smac-results-seconds-10")
    ap.add_argument("--output",      default="smac-median-result.csv")
    ap.add_argument("--all-seeds", action="store_true",
                    help="Output one row per (instance, seed) instead of the median.")
    args = ap.parse_args()

    results_dir = Path(args.results_dir)
    output_path = Path(args.output)

    data  = collect(results_dir)
    order = instance_order(results_dir)

    header = ["instance"]
    for proc in PROCS:
        header += [f"{proc}proc_obj", f"{proc}proc_time_s"]

    with open(output_path, "w", newline="") as f:
        w = csv.writer(f)

        if args.all_seeds:
            header = ["instance", "seed"] + header[1:]
            w.writerow(header)
            for instance in order:
                seeds = sorted({s for proc_data in data.get(instance, {}).values()
                                   for s in proc_data})
                for seed in seeds:
                    row = [instance, seed]
                    for proc in PROCS:
                        entry = data.get(instance, {}).get(proc, {}).get(seed)
                        if entry is None:
                            row += ["NA", "NA"]
                        else:
                            obj, t = entry
                            row += [f"{obj:.2f}", "NA" if t is None else str(t)]
                    w.writerow(row)
        else:
            w.writerow(header)
            rows = []
            for instance in order:
                row = [instance]
                for proc in PROCS:
                    seed_data = data.get(instance, {}).get(proc, {})
                    objs  = [v[0] for v in seed_data.values()]
                    times = [v[1] for v in seed_data.values() if v[1] is not None]
                    if objs:
                        row += [f"{low_median(objs):.2f}",
                                str(low_median(times)) if times else "NA"]
                    else:
                        row += ["NA", "NA"]
                rows.append(row)

            mean_row = ["mean"]
            for proc in PROCS:
                objs, times = [], []
                for instance in order:
                    seed_data = data.get(instance, {}).get(proc, {})
                    if seed_data:
                        objs.append(low_median([v[0] for v in seed_data.values()]))
                        valid_times = [v[1] for v in seed_data.values() if v[1] is not None]
                        if valid_times:
                            times.append(low_median(valid_times))
                mean_row += [
                    f"{sum(objs)/len(objs):.2f}" if objs else "NA",
                    f"{sum(times)//len(times)}"  if times else "NA",
                ]
            rows.append(mean_row)
            w.writerows(rows)

    print(f"Written: {output_path}  ({len(order)} instances, {len(PROCS)} proc counts)")


if __name__ == "__main__":
    main()
