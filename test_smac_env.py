#!/usr/bin/env python3
"""Quick environment check for SMAC-based CPLEX tuning."""

import sys

errors = []
warnings = []

# --- ConfigSpace ---
try:
    import ConfigSpace
    from ConfigSpace import ConfigurationSpace
    from ConfigSpace.hyperparameters import CategoricalHyperparameter
    print(f"[OK] ConfigSpace {ConfigSpace.__version__}")
except ImportError as e:
    errors.append(f"ConfigSpace: {e}")

# --- SMAC ---
try:
    import smac
    from smac import Scenario, HyperparameterOptimizationFacade
    version = getattr(smac, "__version__", None) or \
              getattr(__import__("importlib.metadata", fromlist=["version"]),
                      "version", lambda *a: "unknown")("smac")
    print(f"[OK] SMAC {version}")
except ImportError as e:
    errors.append(f"SMAC: {e}")

# --- CPLEX Python API ---
try:
    import cplex
    print(f"[OK] cplex {cplex.__version__}")
    # Quick functional test: create an instance and read a parameter
    c = cplex.Cplex()
    c.set_log_stream(None)
    c.set_results_stream(None)
    v = c.parameters.mip.cuts.cliques.get()
    print(f"  CPXPARAM_MIP_Cuts_Cliques default = {v}  (expected 0)")
    v2 = c.parameters.mip.strategy.probe.get()
    print(f"  CPXPARAM_MIP_Strategy_Probe default = {v2}  (expected 0)")
    v3 = c.parameters.dettimelimit.get()
    print(f"  CPX_PARAM_DETTILIM default = {v3}")
except ImportError as e:
    errors.append(f"cplex: {e}  — try: module load cplex OR pip install cplex")
except Exception as e:
    warnings.append(f"cplex imported but functional test failed: {e}")

# --- dask (optional, needed for n_workers > 1) ---
try:
    import dask
    print(f"[OK] dask {dask.__version__}  (parallel workers supported)")
except ImportError:
    warnings.append("dask not found — SMAC will run with n_workers=1 only")

# --- Summary ---
print()
if errors:
    print("ERRORS (must fix before running):")
    for e in errors:
        print(f"  ✗ {e}")
    sys.exit(1)
if warnings:
    print("WARNINGS:")
    for w in warnings:
        print(f"  ! {w}")
print("Environment OK" if not errors else "")
