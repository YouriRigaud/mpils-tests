#!/usr/bin/env python3

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path
from statistics import median, median_high, median_low


PROC_DIR_RE = re.compile(r"^([1-9][0-9]*)proc$")


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
        "--median-method",
        choices=("low", "high", "average"),
        default="low",
        help=(
            "Median method for an even number of seeds: low/high select an observed "
            "value, average uses the arithmetic midpoint (default: low)"
        ),
    )
    return parser.parse_args()


def proc_count_for(path, results_root):
    relative_parts = path.relative_to(results_root).parts
    for part in relative_parts:
        match = PROC_DIR_RE.match(part)
        if match:
            return int(match.group(1))
    raise ValueError(f"could not find <N>proc component in path: {path}")


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
    values = defaultdict(lambda: defaultdict(lambda: {"objective": [], "tuning_time": []}))

    metrics_files = sorted(results_root.rglob("tuning_metrics_*.csv"))
    if not metrics_files:
        raise SystemExit(f"no tuning_metrics_*.csv files found under: {results_root}")

    for metrics_path in metrics_files:
        relative_parts = metrics_path.relative_to(results_root).parts
        if selected_instance_dirs and relative_parts[0] not in selected_instance_dirs:
            continue

        proc_count = proc_count_for(metrics_path, results_root)
        with metrics_path.open(newline="") as csv_file:
            reader = csv.DictReader(csv_file)
            required_columns = {"instance", "objective", "tuning_time"}
            missing_columns = required_columns - set(reader.fieldnames or [])
            if missing_columns:
                missing = ", ".join(sorted(missing_columns))
                raise SystemExit(f"{metrics_path}: missing columns: {missing}")

            for row_number, row in enumerate(reader, start=2):
                instance = row["instance"]
                values[instance][proc_count]["objective"].append(
                    as_float(row["objective"], metrics_path, row_number, "objective")
                )
                values[instance][proc_count]["tuning_time"].append(
                    as_float(row["tuning_time"], metrics_path, row_number, "tuning_time")
                )

    if not values:
        selected = ", ".join(sorted(selected_instance_dirs))
        raise SystemExit(f"no metric rows matched selected instance dirs: {selected}")

    proc_counts = sorted({proc for per_proc in values.values() for proc in per_proc})
    header = ["instance"]
    for proc_count in proc_counts:
        header.extend([f"{proc_count}proc_objective", f"{proc_count}proc_tuning_time"])

    with output_path.open("w", newline="") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(header)

        for instance in sorted(values):
            row = [instance]
            for proc_count in proc_counts:
                metrics = values[instance].get(proc_count)
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
    print("proc counts: " + ", ".join(f"{proc}proc" for proc in proc_counts))


if __name__ == "__main__":
    main()
