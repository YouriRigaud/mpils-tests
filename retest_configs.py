#!/usr/bin/env python3
"""
Re-evaluate irace or SMAC best configurations with the fixed cplex_evaluate.py.

Directory layouts expected:
  irace: {results_dir}/{N}proc/{medium}/{instance}/seed-{S}/best_configuration.prm
  smac:  {results_dir}/{N}proc/{medium}/{instance}/seed-{S}/{instance}_best.prm

Usage:
  python retest_configs.py --tuner irace \\
      --results-dir /scratch/yorig/irace-results-seconds-10-1pils \\
      --instances-base /home/yorig/tuner/mpils-tests/instances/miplib \\
      --output retest-irace-1pils.csv

  python retest_configs.py --tuner smac \\
      --results-dir /scratch/yorig/smac-results-seconds-10-memoire \\
      --instances-base /home/yorig/tuner/mpils-tests/instances/miplib \\
      --output retest-smac.csv --all-seeds
"""

import argparse
import csv
import subprocess
import sys
import time
from pathlib import Path

PROCS   = [1, 2, 4, 8, 16, 24]
MEDIUMS = ["medium-1", "medium-2"]


def low_median(values):
    s = sorted(v for v in values if v is not None)
    if not s:
        return None
    return s[(len(s) - 1) // 2]


def find_config(results_dir: Path, tuner: str, proc: int,
                medium: str, instance: str, seed: int) -> Path | None:
    seed_dir = results_dir / f"{proc}proc" / medium / instance / f"seed-{seed}"
    if tuner == "irace":
        p = seed_dir / "best_configuration.prm"
    else:
        p = seed_dir / f"{instance}_best.prm"
    return p if p.is_file() else None


def evaluate(instance_path: Path, config_path: Path, tests_dir: Path,
             solver_time: int, threads: int, mode: str) -> float | None:
    try:
        r = subprocess.run(
            [sys.executable, str(tests_dir / "cplex_evaluate.py"),
             str(instance_path), str(config_path),
             str(solver_time), str(threads), mode],
            capture_output=True, text=True,
            timeout=solver_time * 4 + 60
        )
        return float(r.stdout.strip())
    except Exception:
        return None


def find_instance_path(instances_base: Path, medium: str, instance: str) -> Path | None:
    for ext in (".mps", ".lp"):
        p = instances_base / medium / (instance + ext)
        if p.is_file():
            return p
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tuner", choices=["irace", "smac"], required=True)
    ap.add_argument("--results-dir", required=True,
                    help="Root of the tuner results tree")
    ap.add_argument("--instances-base", required=True,
                    help="Directory containing medium-1/ and medium-2/ instance folders")
    ap.add_argument("--tests-dir", default=str(Path(__file__).parent),
                    help="Directory containing cplex_evaluate.py (default: same dir as this script)")
    ap.add_argument("--output", required=True,
                    help="Output CSV path")
    ap.add_argument("--all-seeds", action="store_true",
                    help="Write one row per (instance, seed) instead of low-median across seeds")
    ap.add_argument("--seeds", type=int, default=10,
                    help="Number of seeds (default: 10)")
    ap.add_argument("--solver-time", type=int, default=10)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--mode", default="seconds")
    args = ap.parse_args()

    results_dir   = Path(args.results_dir)
    instances_base = Path(args.instances_base)
    tests_dir     = Path(args.tests_dir)
    output_path   = Path(args.output)

    print(f"Tuner        : {args.tuner}", file=sys.stderr)
    print(f"Results dir  : {results_dir}", file=sys.stderr)
    print(f"Instances    : {instances_base}", file=sys.stderr)
    print(f"Output       : {output_path}", file=sys.stderr)
    print(f"Solver time  : {args.solver_time}s ({args.mode})", file=sys.stderr)
    print(f"Threads      : {args.threads}", file=sys.stderr)
    print(f"Seeds        : 1-{args.seeds}", file=sys.stderr)
    print(f"All seeds    : {args.all_seeds}", file=sys.stderr)

    # data[instance][proc][seed] = gap or None
    data: dict[str, dict[int, dict[int, float | None]]] = {}
    # preserve instance → medium mapping for stable ordering
    instance_medium: dict[str, str] = {}

    total = 0
    missing = 0

    for proc in PROCS:
        for medium in MEDIUMS:
            medium_dir = results_dir / f"{proc}proc" / medium
            if not medium_dir.is_dir():
                continue
            for inst_dir in sorted(medium_dir.iterdir()):
                if not inst_dir.is_dir():
                    continue
                instance = inst_dir.name
                instance_path = find_instance_path(instances_base, medium, instance)
                if instance_path is None:
                    print(f"  WARNING: instance file not found for {instance} in {medium}",
                          file=sys.stderr)
                    continue
                instance_medium.setdefault(instance, medium)
                data.setdefault(instance, {}).setdefault(proc, {})

                for seed in range(1, args.seeds + 1):
                    config = find_config(results_dir, args.tuner, proc, medium, instance, seed)
                    total += 1
                    if config is None:
                        missing += 1
                        data[instance][proc][seed] = None
                        print(f"  MISSING  {proc}proc/{medium}/{instance}/seed-{seed}",
                              file=sys.stderr)
                        continue

                    t0 = time.time()
                    gap = evaluate(instance_path, config, tests_dir,
                                   args.solver_time, args.threads, args.mode)
                    elapsed = time.time() - t0
                    data[instance][proc][seed] = gap
                    status = f"{gap:.4f}%" if gap is not None else "FAILED"
                    print(f"  {proc:>2}proc  {medium}  {instance:<30}  seed-{seed}  "
                          f"{status}  ({elapsed:.1f}s)", file=sys.stderr)

    print(f"\nDone: {total} evaluations, {missing} missing configs.", file=sys.stderr)

    # Write CSV
    instance_order = sorted(data, key=lambda i: (instance_medium.get(i, ""), i))

    with open(output_path, "w", newline="") as f:
        w = csv.writer(f)

        if args.all_seeds:
            header = ["instance", "seed"] + [f"{p}proc_obj" for p in PROCS]
            w.writerow(header)
            all_seeds = sorted({s for idata in data.values()
                                   for pdata in idata.values()
                                   for s in pdata})
            for instance in instance_order:
                for seed in all_seeds:
                    row = [instance, seed]
                    for proc in PROCS:
                        val = data.get(instance, {}).get(proc, {}).get(seed)
                        row.append(f"{val:.4f}" if val is not None else "NA")
                    w.writerow(row)
        else:
            header = ["instance"] + [f"{p}proc_obj" for p in PROCS]
            w.writerow(header)
            rows = []
            for instance in instance_order:
                row = [instance]
                for proc in PROCS:
                    vals = [v for v in data.get(instance, {}).get(proc, {}).values()
                            if v is not None]
                    med = low_median(vals) if vals else None
                    row.append(f"{med:.4f}" if med is not None else "NA")
                rows.append(row)

            # mean row
            mean_row = ["mean"]
            for proc in PROCS:
                medians = []
                for instance in instance_order:
                    vals = [v for v in data.get(instance, {}).get(proc, {}).values()
                            if v is not None]
                    med = low_median(vals)
                    if med is not None:
                        medians.append(med)
                mean_row.append(f"{sum(medians)/len(medians):.4f}" if medians else "NA")
            rows.append(mean_row)
            w.writerows(rows)

    print(f"Written: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
