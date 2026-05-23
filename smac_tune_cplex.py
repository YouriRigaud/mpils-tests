#!/usr/bin/env python3
"""
SMAC-based CPLEX parameter tuner — single-instance tuning.

Each CPLEX evaluation runs in an isolated subprocess (cplex_evaluate.py)
to prevent the CPLEX C extension from crashing the dask worker on cleanup.

Usage:
    python smac_tune_cplex.py \
        --instance /path/to/instance.mps \
        --params-file /path/to/params_12_cpx.txt \
        --solver-time 10000 \
        --threads 8 \
        --walltime 2719 \
        --n-workers 24 \
        --output-dir /path/to/output \
        --seed 1
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

# os._exit(0) is called at the end of main() to skip Python finalization.
# When n_workers > 1, SMAC uses dask; its DaskParallelRunner.__del__ triggers
# the CPLEX C extension's none_dealloc crash during GC, returning non-zero and
# killing the outer loop in submit-run-smac.sh. os._exit bypasses all finalizers
# since every result is already flushed to disk before it is called.
from pathlib import Path

from ConfigSpace import ConfigurationSpace
from ConfigSpace.hyperparameters import CategoricalHyperparameter
from smac import Scenario
from smac import HyperparameterOptimizationFacade as HPOFacade

# Path to the subprocess evaluator (same directory as this script)
_EVALUATOR = Path(__file__).parent / "cplex_evaluate.py"


# ---------------------------------------------------------------------------
# Parameter file parsing
# ---------------------------------------------------------------------------

def parse_params_file(path: str) -> ConfigurationSpace:
    cs = ConfigurationSpace()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            default_match = re.search(r'\[([^\]]+)\]', line)
            if not default_match:
                continue
            default_str = default_match.group(1).strip()
            rest = re.sub(r'\[.*?\]', '', line).split()
            if len(rest) < 2:
                continue
            name = rest[0]
            value_strs = rest[1:]
            if len(value_strs) <= 1:
                continue  # fixed parameter — not tunable

            def parse_val(s):
                try:
                    f = float(s)
                    return int(f) if f == int(f) else f
                except ValueError:
                    return s

            values = [parse_val(v) for v in value_strs]
            default = parse_val(default_str)
            if default not in values:
                default = values[0]

            str_values = [str(v) for v in values]
            str_default = str(default)

            hp = CategoricalHyperparameter(name, choices=str_values,
                                           default_value=str_default)
            cs.add(hp)

    return cs


# ---------------------------------------------------------------------------
# Target function — runs CPLEX in an isolated subprocess
# ---------------------------------------------------------------------------

def make_target(instance_path: str, solver_time: int, threads: int):
    evaluator = str(_EVALUATOR)
    python = sys.executable

    def target(config, seed: int = 0, budget: float = None) -> float:
        # Write a temporary .prm file with this configuration
        with tempfile.NamedTemporaryFile(suffix='.prm', mode='w',
                                         delete=False) as f:
            for name, value in config.items():
                f.write(f"{name} {value}\n")
            prm_path = f.name

        try:
            result = subprocess.run(
                [python, evaluator, instance_path, prm_path,
                 str(solver_time), str(threads)],
                capture_output=True, text=True,
                timeout=solver_time * 10,  # safety cap: 10x the tick budget
            )
            gap = float(result.stdout.strip())
        except Exception:
            gap = 100.0
        finally:
            try:
                os.unlink(prm_path)
            except OSError:
                pass

        return gap

    return target


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--instance",    required=True)
    p.add_argument("--params-file", required=True)
    p.add_argument("--solver-time", type=int, default=10000)
    p.add_argument("--threads",     type=int, default=8)
    p.add_argument("--walltime",    type=int, required=True)
    p.add_argument("--n-workers",   type=int, default=1)
    p.add_argument("--output-dir",  required=True)
    p.add_argument("--seed",        type=int, default=1)
    return p.parse_args()


def main():
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    cs = parse_params_file(args.params_file)
    print(f"Configuration space: {len(list(cs.values()))} tunable parameters")

    target = make_target(args.instance, args.solver_time, args.threads)

    scenario = Scenario(
        configspace=cs,
        name=Path(args.instance).stem,
        output_directory=output_dir,
        walltime_limit=args.walltime,
        n_trials=10_000_000,
        n_workers=args.n_workers,
        seed=args.seed,
        deterministic=False,
    )

    smac = HPOFacade(scenario=scenario, target_function=target, overwrite=True)

    print(f"Starting SMAC: {Path(args.instance).stem}  "
          f"budget={args.walltime}s  workers={args.n_workers}  seed={args.seed}")

    t0 = time.time()
    incumbent = smac.optimize()
    elapsed = time.time() - t0

    best_gap = target(incumbent, seed=args.seed)
    print(f"Done in {elapsed:.0f}s — best gap: {best_gap:.2f}%")

    prm_path = output_dir / f"{Path(args.instance).stem}_best.prm"
    with open(prm_path, 'w') as f:
        for k, v in sorted(incumbent.items()):
            f.write(f"{k} {v}\n")
    print(f"Best config saved to {prm_path}")

    # Skip Python finalization to avoid the dask + CPLEX C extension crash.
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(0)


if __name__ == "__main__":
    main()
