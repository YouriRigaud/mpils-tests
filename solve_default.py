#!/usr/bin/env python3
"""
Run CPLEX on one instance with default parameters (threads=N, parallel=1, no tuning).
Prints one CSV line to stdout: status,cplex_time_s,wall_time_s,gap_pct,nodes_explored

Usage:
    python solve_default.py instance.lp threads [time_limit_s]

time_limit_s defaults to 3600.
"""
import sys
import time
import cplex


def main():
    if len(sys.argv) not in (3, 4):
        print("usage: solve_default.py instance threads [time_limit_s]", file=sys.stderr)
        sys.exit(1)

    instance_path = sys.argv[1]
    threads      = int(sys.argv[2])
    time_limit   = int(sys.argv[3]) if len(sys.argv) == 4 else 3600

    c = cplex.Cplex()
    c.set_log_stream(None)
    c.set_results_stream(None)
    c.set_warning_stream(None)
    c.set_error_stream(None)

    try:
        c.read(instance_path)
    except Exception as e:
        print(f"read_error,NA,NA,NA,NA", file=sys.stderr)
        sys.exit(1)

    c.parameters.threads.set(threads)
    c.parameters.parallel.set(1)
    c.parameters.timelimit.set(time_limit)
    c.parameters.mip.display.set(0)

    wall_start = time.time()
    try:
        c.solve()
    except Exception as e:
        wall_time = time.time() - wall_start
        print(f"solve_error,NA,{wall_time:.1f},NA,NA")
        sys.exit(0)

    wall_time  = time.time() - wall_start
    status_str = c.solution.status[c.solution.get_status()]
    cplex_time = c.solution.get_solve_time()

    try:
        gap   = f"{c.solution.MIP.get_mip_relative_gap() * 100.0:.4f}"
    except Exception:
        gap   = "NA"

    try:
        nodes = c.solution.progress.get_num_nodes_processed()
    except Exception:
        nodes = "NA"

    print(f"{status_str},{cplex_time:.1f},{wall_time:.1f},{gap},{nodes}")


if __name__ == "__main__":
    main()
