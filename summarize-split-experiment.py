#!/usr/bin/env python3
"""
Produce three CSV files summarising median objective and tuning time
from a results directory that contains both standard-grid and
mpi-procs-per-ils experiments.

  standard_grid.csv   — N ILS × 1 proc/ILS  (varying total procs, pils=1)
  single_ils.csv      — 1 ILS × N procs/ILS  (proc == pils)
  split_24proc.csv    — 24 procs, varying pils (1,2,4,6,8,12,24)

Each CSV has one row per instance and paired <config>_objective /
<config>_tuning_time columns, using the median across seeds.
NA rows are skipped with a warning.
"""

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path
from statistics import median

DIR_RE = re.compile(r"^(\d+)proc(?:-(\d+)pils)?$")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "results_root",
        help="Root results directory to scan",
    )
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Directory for output CSV files (default: current directory)",
    )
    parser.add_argument(
        "--split-procs",
        type=int,
        default=24,
        help="Total proc count used for the split experiment (default: 24)",
    )
    parser.add_argument(
        "--instance-dirs",
        nargs="+",
        metavar="NAME",
        help="Only include these top-level instance dirs, e.g. easy  or  medium-1 medium-2",
    )
    parser.add_argument(
        "--output-prefix",
        default="",
        help="Prefix for output filenames, e.g. 'easy_' or 'medium_' (default: none)",
    )
    return parser.parse_args()


def collect(results_root, selected_dirs=None):
    """
    Returns:
        data[(proc, pils)][instance] = {"obj": [...], "time": [...]}
        skipped: list of (path, instance) tuples where NA was encountered
    """
    data = defaultdict(lambda: defaultdict(lambda: {"obj": [], "time": []}))
    skipped = []

    for metrics_path in sorted(Path(results_root).rglob("tuning_metrics_*.csv")):
        parts = metrics_path.relative_to(results_root).parts
        if selected_dirs and parts[0] not in selected_dirs:
            continue
        # Determine (proc, pils) from the directory component
        config = None
        for part in parts:
            m = DIR_RE.match(part)
            if m:
                proc = int(m.group(1))
                pils = int(m.group(2)) if m.group(2) else 1
                config = (proc, pils)
                break
        if config is None:
            continue

        with metrics_path.open(newline="") as f:
            reader = csv.DictReader(f)
            if not {"instance", "objective", "tuning_time"} <= set(reader.fieldnames or []):
                continue
            for row in reader:
                if row["objective"] == "NA" or row["tuning_time"] == "NA":
                    skipped.append((str(metrics_path), row["instance"]))
                    continue
                try:
                    inst = row["instance"].replace(".mps", "")
                    data[config][inst]["obj"].append(float(row["objective"]))
                    data[config][inst]["time"].append(float(row["tuning_time"]))
                except ValueError:
                    pass

    return data, skipped


def med(values):
    return median(values) if values else None


def fmt(value):
    return f"{value:.6g}" if value is not None else ""


def write_csv(output_path, configs, data, config_label):
    """Write one CSV: rows=instances, cols=config pairs."""
    all_instances = sorted({inst for cfg in configs for inst in data.get(cfg, {})})
    header = ["instance"]
    for cfg in configs:
        label = config_label(cfg)
        header += [f"{label}_objective", f"{label}_tuning_time"]

    with open(output_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        for inst in all_instances:
            row = [inst]
            for cfg in configs:
                entry = data.get(cfg, {}).get(inst, {})
                row += [
                    fmt(med(entry.get("obj", []))),
                    fmt(med(entry.get("time", []))),
                ]
            writer.writerow(row)

    print(f"wrote {output_path}  ({len(all_instances)} instances, {len(configs)} configs)")


def main():
    args = parse_args()
    results_root = Path(args.results_root)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    split_procs = args.split_procs

    if not results_root.is_dir():
        raise SystemExit(f"results root not found: {results_root}")

    selected_dirs = set(args.instance_dirs) if args.instance_dirs else None
    prefix = args.output_prefix
    data, skipped = collect(results_root, selected_dirs)

    if skipped:
        from collections import Counter
        counts = Counter(skipped)
        print(f"WARNING: skipped {len(skipped)} NA row(s):")
        for (path, inst), n in sorted(counts.items()):
            print(f"  {n}x  {inst}  in  {path}")
        print()

    all_configs = sorted(data.keys())

    # --- 1. Standard grid: pils == 1, varying proc ---
    standard = sorted(
        {(p, pi) for p, pi in all_configs if pi == 1},
        key=lambda x: x[0],
    )
    write_csv(
        output_dir / f"{prefix}standard_grid.csv",
        standard,
        data,
        lambda cfg: f"{cfg[0]}proc",
    )

    # --- 2. Single ILS: proc == pils ---
    single = sorted(
        {(p, pi) for p, pi in all_configs if p == pi},
        key=lambda x: x[0],
    )
    write_csv(
        output_dir / f"{prefix}single_ils.csv",
        single,
        data,
        lambda cfg: f"{cfg[0]}proc-{cfg[1]}pils",
    )

    # --- 3. Split experiment: fixed split_procs, varying pils ---
    split = sorted(
        {(p, pi) for p, pi in all_configs if p == split_procs},
        key=lambda x: x[1],
    )
    write_csv(
        output_dir / f"{prefix}split_{split_procs}proc.csv",
        split,
        data,
        lambda cfg: f"{cfg[0]}proc-{cfg[1]}pils",
    )


if __name__ == "__main__":
    main()
