#!/usr/bin/env python3
"""
Summarize irace CPLEX tuning results.

  objective    = best MIP gap (%) found by irace's final elite configuration
  tuning_time  = timeUsed / parallel  (approximation of wall-clock time, seconds)

Both values are extracted from irace.Rdata via a single Rscript call.

Results directory structure expected:
  <results_dir>/<N>proc/<batch>/<instance_stem>/seed-<S>/irace.Rdata

Output (median mode): irace-median-result.csv
  instance, 1proc_obj, 1proc_time_s, ..., 24proc_obj, 24proc_time_s
  + mean row at the bottom.

Output (--all-seeds mode): irace-all-seeds.csv
  instance, seed, 1proc_obj, 1proc_time_s, ..., 24proc_obj, 24proc_time_s

Usage (on the cluster):
  python summarize-irace-medians.py \\
      --results-dir /scratch/yorig/irace-results-ticks-10000 \\
      --output      irace-median-result.csv

  python summarize-irace-medians.py \\
      --results-dir /scratch/yorig/irace-results-ticks-10000 \\
      --output      irace-all-seeds.csv --all-seeds
"""

import argparse
import csv
import re
import subprocess
import sys
import tempfile
from pathlib import Path


PROCS   = [1, 2, 4, 8, 16, 24]
MEDIUMS = ["medium-1", "medium-2"]

# R script run once over all irace.Rdata files.
# Prints a CSV to stdout: path,objective,tuning_time
_R_EXTRACT = r"""
suppressMessages(library(irace))

args  <- commandArgs(trailingOnly = TRUE)
paths <- args  # one path per argument

cat("path,objective,tuning_time\n")

for (path in paths) {
    obj  <- NA_real_
    time <- NA_real_
    tryCatch({
        env <- new.env(parent = emptyenv())
        load(path, envir = env)
        ir <- env$iraceResults

        # Best cost: minimum across final elite configurations on the single instance
        experiments   <- ir$experiments
        final_elites  <- ir$allElites[[length(ir$allElites)]]
        elite_ids     <- as.character(final_elites)
        valid_ids     <- elite_ids[elite_ids %in% colnames(experiments)]
        if (length(valid_ids) > 0) {
            costs <- as.numeric(experiments[1, valid_ids])
            obj   <- min(c(costs[!is.na(costs)], 100.0))
        }

        # Wall-clock approximation: total CPU time / number of parallel workers
        n_workers <- max(as.integer(ir$scenario$parallel), 1L)
        time_cpu  <- ir$state$timeUsed
        if (!is.null(time_cpu) && !is.na(time_cpu)) {
            time <- round(time_cpu / n_workers)
        }
    }, error = function(e) {
        message("Warning: failed to read ", path, ": ", conditionMessage(e))
    })
    cat(sprintf("%s,%.4f,%s\n", path,
                ifelse(is.na(obj),  100.0, obj),
                ifelse(is.na(time), "NA",  as.character(time))))
}
"""


def low_median(values):
    s = sorted(values)
    return s[(len(s) - 1) // 2]


def collect(results_dir: Path) -> dict:
    """
    Return data[instance][proc][seed] = (objective, tuning_time).
    Calls Rscript once for all irace.Rdata files found.
    """
    rdata_files = sorted(results_dir.rglob("irace.Rdata"))
    if not rdata_files:
        print(f"No irace.Rdata files found under {results_dir}", file=sys.stderr)
        return {}

    # Run R extraction script
    with tempfile.NamedTemporaryFile(suffix=".R", mode="w", delete=False) as tf:
        tf.write(_R_EXTRACT)
        r_script = tf.name

    try:
        result = subprocess.run(
            ["Rscript", r_script] + [str(p) for p in rdata_files],
            capture_output=True, text=True
        )
    finally:
        Path(r_script).unlink(missing_ok=True)

    if result.returncode != 0:
        print(f"Rscript error:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)

    if result.stderr:
        for line in result.stderr.splitlines():
            print(f"[R] {line}", file=sys.stderr)

    # Parse CSV output from R
    r_results = {}
    reader = csv.DictReader(result.stdout.splitlines())
    for row in reader:
        path = row["path"]
        try:
            obj  = float(row["objective"])
        except (ValueError, KeyError):
            obj  = None
        t_str = row.get("tuning_time", "NA")
        try:
            time = int(t_str) if t_str not in ("NA", "") else None
        except ValueError:
            time = None
        r_results[path] = (obj, time)

    # Map paths back to (instance, proc, seed)
    proc_re = re.compile(r"^(\d+)proc$")
    seed_re = re.compile(r"^seed-(\d+)$")

    data = {}
    for rdata_path in rdata_files:
        path_str = str(rdata_path)
        parts = rdata_path.relative_to(results_dir).parts
        # Expected: <N>proc / <batch> / <instance> / seed-<S> / irace.Rdata
        proc = seed = instance = None
        for part in parts:
            m = proc_re.match(part)
            if m:
                proc = int(m.group(1))
            m = seed_re.match(part)
            if m:
                seed = int(m.group(1))
        # instance is the directory just before seed-S
        try:
            seed_idx = next(i for i, p in enumerate(parts) if seed_re.match(p))
            instance = parts[seed_idx - 1]
        except StopIteration:
            continue

        if proc is None or seed is None or instance is None:
            continue
        if proc not in PROCS:
            continue

        obj, time = r_results.get(path_str, (None, None))
        data.setdefault(instance, {}).setdefault(proc, {})[seed] = (obj, time)

    return data


def instance_order(results_dir: Path) -> list:
    order, seen = [], set()
    for proc in PROCS:
        for medium in MEDIUMS:
            medium_dir = results_dir / f"{proc}proc" / medium
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
    ap.add_argument("--results-dir", default="irace-results-ticks-10000",
                    help="Root results directory (default: irace-results-ticks-10000)")
    ap.add_argument("--output", default="irace-median-result.csv",
                    help="Output CSV path (default: irace-median-result.csv)")
    ap.add_argument("--all-seeds", action="store_true",
                    help="Output one row per (instance, seed) instead of the median.")
    args = ap.parse_args()

    results_dir = Path(args.results_dir)
    output_path = Path(args.output)

    if not results_dir.is_dir():
        sys.exit(f"results dir not found: {results_dir}")

    print(f"Scanning {results_dir} for irace.Rdata files…", file=sys.stderr)
    data  = collect(results_dir)
    order = instance_order(results_dir)

    # Fallback order if instance_order found nothing
    if not order:
        order = sorted(data)

    header = ["instance"]
    for proc in PROCS:
        header += [f"{proc}proc_obj", f"{proc}proc_time_s"]

    n_rdata = sum(len(seeds) for proc_data in data.values() for seeds in proc_data.values())
    print(f"Found {n_rdata} irace.Rdata files across {len(data)} instances.", file=sys.stderr)

    with open(output_path, "w", newline="") as f:
        w = csv.writer(f)

        if args.all_seeds:
            header = ["instance", "seed"] + header[1:]
            w.writerow(header)
            for instance in order:
                seeds = sorted({s for pd in data.get(instance, {}).values() for s in pd})
                for seed in seeds:
                    row = [instance, seed]
                    for proc in PROCS:
                        entry = data.get(instance, {}).get(proc, {}).get(seed)
                        if entry is None:
                            row += ["NA", "NA"]
                        else:
                            obj, t = entry
                            row += [
                                f"{obj:.4f}" if obj is not None else "NA",
                                str(t)       if t   is not None else "NA",
                            ]
                    w.writerow(row)
        else:
            w.writerow(header)
            rows = []
            for instance in order:
                row = [instance]
                for proc in PROCS:
                    seed_data = data.get(instance, {}).get(proc, {})
                    objs  = [v[0] for v in seed_data.values() if v[0] is not None]
                    times = [v[1] for v in seed_data.values() if v[1] is not None]
                    if objs:
                        row += [f"{low_median(objs):.4f}",
                                str(low_median(times)) if times else "NA"]
                    else:
                        row += ["NA", "NA"]
                rows.append(row)

            mean_row = ["mean"]
            for proc in PROCS:
                objs, times = [], []
                for instance in order:
                    sd = data.get(instance, {}).get(proc, {})
                    o  = [v[0] for v in sd.values() if v[0] is not None]
                    t  = [v[1] for v in sd.values() if v[1] is not None]
                    if o:
                        objs.append(low_median(o))
                    if t:
                        times.append(low_median(t))
                mean_row += [
                    f"{sum(objs)/len(objs):.4f}" if objs else "NA",
                    f"{sum(times)//len(times)}"  if times else "NA",
                ]
            rows.append(mean_row)
            w.writerows(rows)

    print(f"Written: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
