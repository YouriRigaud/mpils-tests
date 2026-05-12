#!/usr/bin/env python3
"""
Standalone CPLEX evaluator called as a subprocess by smac_tune_cplex.py.
Prints the MIP gap (%) to stdout and exits cleanly.
This isolation prevents the CPLEX C extension from corrupting the dask
worker process during garbage collection.

Usage:
    python cplex_evaluate.py instance.mps config.prm solver_time threads
"""
import sys
import cplex

def main():
    if len(sys.argv) != 5:
        print("100.0")
        sys.exit(0)

    instance_path, prm_path, solver_time_str, threads_str = sys.argv[1:]
    solver_time = int(solver_time_str)
    threads = int(threads_str)

    c = cplex.Cplex()
    c.set_log_stream(None)
    c.set_results_stream(None)
    c.set_warning_stream(None)
    c.set_error_stream(None)

    try:
        c.read(instance_path)
        c.parameters.read_file(prm_path)
    except Exception:
        print("100.0")
        sys.exit(0)

    c.parameters.threads.set(threads)
    c.parameters.dettimelimit.set(solver_time)
    c.parameters.mip.display.set(0)

    try:
        c.solve()
        gap = c.solution.MIP.get_mip_relative_gap() * 100.0
        print(f"{round(gap, 4)}")
    except Exception:
        print("100.0")


if __name__ == "__main__":
    main()
