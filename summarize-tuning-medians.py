#!/usr/bin/env python3

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path
from statistics import median, median_high, median_low

SEED_DIR_RE = re.compile(r"^seed-([1-9][0-9]*)$")


PROC_DIR_RE = re.compile(r"^([1-9][0-9]*)proc(?:-([1-9][0-9]*)pils)?$")


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Aggregate tuning_metrics_*.csv files and write median objective/"
            "tuning_time per instance and MPI process count."
        )
    )
    parser.add_argument(
        "results_root",
        nargs="?",
        default="results/mpils-results-grid-ticks-10000",
        help="Root results directory to scan (default: results/mpils-results-grid-ticks-10000)",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="median_tuning_metrics.csv",
        help="Output CSV path (default: median_tuning_metrics.csv)",
    )
    parser.add_argument(
        "--instance-dirs",
        nargs="+",
        metavar="NAME",
        help="Only include these top-level instance dirs, for example: medium-1 medium-2",
    )
    parser.add_argument(
        "--experiment",
        choices=("standard", "single-ils", "split", "all"),
        default="all",
        help=(
            "Which experiment type to include: "
            "standard = Nproc-1pils only (N independent ILS, 1 proc each); "
            "single-ils = Nproc-Npils only (1 ILS, N procs); "
            "split = fixed total procs, varying pils (use --split-procs); "
            "all = everything (default)"
        ),
    )
    parser.add_argument(
        "--split-procs",
        type=int,
        default=24,
        help="Total proc count for the split experiment (default: 24, used with --experiment split)",
    )
    parser.add_argument(
        "--median-method",
        choices=("low", "high", "average"),
        default="low",
        help=(
            "Median method for an even number of seeds: low/high select an observed "
            "value, average uses the arithmetic midpoint (default: low)"
        ),
    )
    parser.add_argument(
        "--all-seeds",
        action="store_true",
        help=(
            "Output one row per (instance, seed) instead of the median. "
            "Columns: instance, seed, {config}_objective, {config}_tuning_time, ..."
        ),
    )
    return parser.parse_args()


def config_for(path, results_root):
    """Return (proc, pils) from path, or None if no matching component found."""
    for part in path.relative_to(results_root).parts:
        match = PROC_DIR_RE.match(part)
        if match:
            proc = int(match.group(1))
            pils = int(match.group(2)) if match.group(2) else 1
            return (proc, pils)
    return None


def seed_for(path, results_root):
    """Return the seed integer from a seed-N directory in the path, or None."""
    for part in path.relative_to(results_root).parts:
        match = SEED_DIR_RE.match(part)
        if match:
            return int(match.group(1))
    return None


def config_label(proc, pils):
    return f"{proc}proc-{pils}pils"


def include_config(proc, pils, experiment, split_procs):
    if experiment == "standard":
        return pils == 1
    if experiment == "single-ils":
        return proc == pils
    if experiment == "split":
        return proc == split_procs
    return True  # all


def as_float(value, csv_path, row_number, column):
    try:
        return float(value)
    except ValueError as exc:
        raise ValueError(
            f"{csv_path}:{row_number}: invalid {column} value: {value!r}"
        ) from exc


def format_number(value):
    return f"{value:.12g}"


def median_value(values, method):
    if method == "low":
        return median_low(values)
    if method == "high":
        return median_high(values)
    return median(values)


def main():
    args = parse_args()
    results_root = Path(args.results_root)
    output_path = Path(args.output)

    if not results_root.is_dir():
        raise SystemExit(f"results root not found: {results_root}")

    selected_instance_dirs = set(args.instance_dirs or [])
    experiment = args.experiment
    split_procs = args.split_procs
    all_seeds_mode = args.all_seeds

    # median mode: {instance: {col_key: {objective: [], tuning_time: []}}}
    values = defaultdict(lambda: defaultdict(lambda: {"objective": [], "tuning_time": []}))
    # all-seeds mode: {instance: {seed: {col_key: {objective, tuning_time}}}}
    seed_values = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    skipped_na = []  # (metrics_path, instance) pairs skipped due to NA

    metrics_files = sorted(results_root.rglob("tuning_metrics_*.csv"))
    if not metrics_files:
        raise SystemExit(f"no tuning_metrics_*.csv files found under: {results_root}")

    for metrics_path in metrics_files:
        relative_parts = metrics_path.relative_to(results_root).parts
        if selected_instance_dirs and relative_parts[0] not in selected_instance_dirs:
            continue

        cfg = config_for(metrics_path, results_root)
        if cfg is None:
            continue
        proc, pils = cfg
        if not include_config(proc, pils, experiment, split_procs):
            continue
        col_key = config_label(proc, pils)

        seed = seed_for(metrics_path, results_root)

        with metrics_path.open(newline="") as csv_file:
            reader = csv.DictReader(csv_file)
            required_columns = {"instance", "objective", "tuning_time"}
            missing_columns = required_columns - set(reader.fieldnames or [])
            if missing_columns:
                missing = ", ".join(sorted(missing_columns))
                raise SystemExit(f"{metrics_path}: missing columns: {missing}")

            for row_number, row in enumerate(reader, start=2):
                if row["objective"] == "NA" or row["tuning_time"] == "NA":
                    skipped_na.append((metrics_path, row["instance"]))
                    continue
                instance = row["instance"]
                obj = as_float(row["objective"], metrics_path, row_number, "objective")
                t   = as_float(row["tuning_time"], metrics_path, row_number, "tuning_time")
                values[instance][col_key]["objective"].append(obj)
                values[instance][col_key]["tuning_time"].append(t)
                if all_seeds_mode and seed is not None:
                    seed_values[instance][seed][col_key] = {"objective": obj, "tuning_time": t}

    if not values:
        selected = ", ".join(sorted(selected_instance_dirs))
        raise SystemExit(f"no metric rows matched selected instance dirs: {selected}")

    def sort_key(label):
        m = re.match(r"(\d+)proc-(\d+)pils", label)
        return (int(m.group(1)), int(m.group(2))) if m else (0, 0)

    col_keys = sorted({k for per_cfg in values.values() for k in per_cfg}, key=sort_key)

    with output_path.open("w", newline="") as csv_file:
        writer = csv.writer(csv_file)

        if all_seeds_mode:
            header = ["instance", "seed"]
            for key in col_keys:
                header.extend([f"{key}_objective", f"{key}_tuning_time"])
            writer.writerow(header)

            for instance in sorted(seed_values):
                for seed in sorted(seed_values[instance]):
                    row = [instance, seed]
                    for key in col_keys:
                        entry = seed_values[instance][seed].get(key)
                        if entry is None:
                            row.extend(["", ""])
                        else:
                            row.extend([
                                format_number(entry["objective"]),
                                format_number(entry["tuning_time"]),
                            ])
                    writer.writerow(row)
        else:
            header = ["instance"]
            for key in col_keys:
                header.extend([f"{key}_objective", f"{key}_tuning_time"])
            writer.writerow(header)

            for instance in sorted(values):
                row = [instance]
                for key in col_keys:
                    metrics = values[instance].get(key)
                    if metrics is None:
                        row.extend(["", ""])
                        continue
                    row.extend(
                        [
                            format_number(median_value(metrics["objective"], args.median_method)),
                            format_number(median_value(metrics["tuning_time"], args.median_method)),
                        ]
                    )
                writer.writerow(row)

    print(f"wrote {output_path}")
    print(f"metrics files: {len(metrics_files)}")
    print(f"instances: {len(values)}")
    print("configs: " + ", ".join(col_keys))
    if skipped_na:
        from collections import Counter
        counts = Counter((str(p), inst) for p, inst in skipped_na)
        print(f"WARNING: skipped {len(skipped_na)} NA row(s) across {len(counts)} (file, instance) pair(s):")
        for (path, inst), n in sorted(counts.items()):
            print(f"  {n}x  {inst}  in  {path}")


if __name__ == "__main__":
    main()
