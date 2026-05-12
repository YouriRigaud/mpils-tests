#!/usr/bin/env python3
"""
SMAC-based CPLEX parameter tuner.

Tunes CPLEX parameters for a single MIP instance using SMAC3.
The parameter space is read from params_12_cpx.txt.
Each evaluation runs CPLEX on the instance with a fixed deterministic
tick budget (same as MPILS), returning the MIP gap.

Usage:
    python smac_tune_cplex.py \
        --instance /path/to/instance.mps \
        --params-file /path/to/params_12_cpx.txt \
        --solver-time 10000 \
        --walltime 2719 \
        --n-workers 24 \
        --output-dir /path/to/output \
        --seed 1
"""

import argparse
import re
import os
import sys
import time
from pathlib import Path

import cplex
from ConfigSpace import ConfigurationSpace
from ConfigSpace.hyperparameters import CategoricalHyperparameter
from smac import Scenario
from smac import HyperparameterOptimizationFacade as HPOFacade


# ---------------------------------------------------------------------------
# Parameter file parsing
# ---------------------------------------------------------------------------

def parse_params_file(path: str) -> ConfigurationSpace:
    """
    Parse params_12_cpx.txt and build a ConfigurationSpace.
    Format per line:  PARAM_NAME  v1  v2  ...  [default]
    Parameters with a single fixed value are skipped (not tunable).
    """
    cs = ConfigurationSpace()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            # Extract default value from brackets
            default_match = re.search(r'\[([^\]]+)\]', line)
            if not default_match:
                continue
            default_str = default_match.group(1).strip()

            # Extract parameter name and values
            rest = re.sub(r'\[.*?\]', '', line).split()
            if len(rest) < 2:
                continue
            name = rest[0]
            value_strs = rest[1:]

            # Skip fixed parameters (only one possible value)
            if len(value_strs) <= 1:
                continue

            # Convert values to appropriate Python types
            def parse_val(s):
                try:
                    f = float(s)
                    return int(f) if f == int(f) else f
                except ValueError:
                    return s

            values = [parse_val(v) for v in value_strs]
            default = parse_val(default_str)

            if default not in values:
                # Shouldn't happen, but guard against formatting quirks
                default = values[0]

            # Use string representation to avoid SMAC type issues with large ints
            str_values = [str(v) for v in values]
            str_default = str(default)

            hp = CategoricalHyperparameter(name, choices=str_values,
                                           default_value=str_default)
            cs.add_hyperparameter(hp)

    return cs


# ---------------------------------------------------------------------------
# Target function: run CPLEX and return MIP gap
# ---------------------------------------------------------------------------

def make_target(instance_path: str, solver_time: int, threads: int):
    """
    Returns a SMAC-compatible target function that evaluates one CPLEX
    configuration on the given instance.

    solver_time: deterministic tick budget (CPX_PARAM_DETTILIM)
    """
    def target(config, seed: int = 0, budget: float = None) -> float:
        c = cplex.Cplex()
        c.set_log_stream(None)
        c.set_results_stream(None)
        c.set_warning_stream(None)
        c.set_error_stream(None)

        try:
            c.read(instance_path)
        except Exception as e:
            return 100.0  # infeasible read → worst gap

        # Apply configuration
        for name, value in config.items():
            try:
                # Navigate parameter hierarchy from the CPLEX name
                # e.g. CPXPARAM_MIP_Cuts_Cliques → c.parameters.mip.cuts.cliques
                _set_cplex_param(c, name, value)
            except Exception:
                pass  # silently skip unknown params

        # Fixed settings
        c.parameters.threads.set(threads)
        c.parameters.dettimelimit.set(solver_time)
        c.parameters.mip.display.set(0)

        try:
            c.solve()
        except Exception:
            return 100.0

        try:
            gap = c.solution.MIP.get_mip_relative_gap() * 100.0
            gap = round(gap, 2)
            return gap
        except Exception:
            return 100.0  # no feasible solution found

    return target


# CPXPARAM_X_Y_Z  →  c.parameters.x.y.z.set(value)
_PARAM_PREFIX = "CPXPARAM_"

def _set_cplex_param(c: cplex.Cplex, name: str, value_str: str):
    """Navigate c.parameters hierarchy and set value."""
    if not name.startswith(_PARAM_PREFIX):
        return
    parts = name[len(_PARAM_PREFIX):].lower().split('_')

    obj = c.parameters
    for part in parts[:-1]:
        obj = getattr(obj, part)
    leaf = getattr(obj, parts[-1])

    try:
        v = float(value_str)
        iv = int(v)
        leaf.set(iv if iv == v else v)
    except (ValueError, AttributeError):
        pass


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--instance",     required=True, help="Path to .mps instance")
    p.add_argument("--params-file",  required=True, help="Path to params_12_cpx.txt")
    p.add_argument("--solver-time",  type=int, default=10000,
                   help="Deterministic tick budget per evaluation (default: 10000)")
    p.add_argument("--threads",      type=int, default=8,
                   help="CPLEX threads per evaluation (default: 8)")
    p.add_argument("--walltime",     type=int, required=True,
                   help="Total wall-clock tuning budget in seconds")
    p.add_argument("--n-workers",    type=int, default=1,
                   help="Parallel SMAC workers (default: 1)")
    p.add_argument("--output-dir",   required=True, help="Directory for SMAC output")
    p.add_argument("--seed",         type=int, default=1, help="Random seed (default: 1)")
    return p.parse_args()


def main():
    args = parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Build configuration space
    cs = parse_params_file(args.params_file)
    print(f"Configuration space: {len(cs.get_hyperparameters())} tunable parameters")

    # Target function
    target = make_target(args.instance, args.solver_time, args.threads)

    # SMAC scenario
    scenario = Scenario(
        configspace=cs,
        name=Path(args.instance).stem,
        output_directory=output_dir,
        walltime_limit=args.walltime,
        n_trials=10_000_000,        # effectively unlimited — walltime drives termination
        n_workers=args.n_workers,
        seed=args.seed,
        deterministic=False,
    )

    smac = HPOFacade(scenario=scenario, target_function=target, overwrite=True)

    print(f"Starting SMAC on {args.instance}")
    print(f"  walltime budget : {args.walltime}s")
    print(f"  workers         : {args.n_workers}")
    print(f"  solver ticks    : {args.solver_time}")
    print(f"  seed            : {args.seed}")

    t0 = time.time()
    incumbent = smac.optimize()
    elapsed = time.time() - t0

    # Report best configuration
    best_gap = target(incumbent, seed=args.seed)
    print(f"\nTuning complete in {elapsed:.0f}s")
    print(f"Best gap: {best_gap:.2f}%")
    print("Best configuration:")
    for k, v in sorted(incumbent.items()):
        print(f"  {k} = {v}")

    # Save best config as .prm file
    prm_path = output_dir / f"{Path(args.instance).stem}_best.prm"
    with open(prm_path, 'w') as f:
        for k, v in sorted(incumbent.items()):
            f.write(f"{k} {v}\n")
    print(f"Saved best config to {prm_path}")


if __name__ == "__main__":
    main()
