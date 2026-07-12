#!/usr/bin/env python3
"""
Standalone CPLEX evaluator called as a subprocess by smac_tune_cplex.py.
Prints the MIP gap (%) to stdout and exits cleanly.
This isolation prevents the CPLEX C extension from corrupting the dask
worker process during garbage collection.

Usage:
    python cplex_evaluate.py instance.mps config.prm solver_time threads [ticks|seconds]
"""
import sys
import cplex

def main():
    if len(sys.argv) not in (5, 6):
        print("100.0")
        sys.exit(0)

    instance_path, prm_path, solver_time_str, threads_str = sys.argv[1:5]
    time_mode = sys.argv[5] if len(sys.argv) == 6 else "ticks"
    solver_time = int(solver_time_str)
    threads = int(threads_str)

    c = cplex.Cplex()
    c.set_log_stream(None)
    c.set_results_stream(None)
    c.set_warning_stream(None)
    c.set_error_stream(None)

    try:
        c.read(instance_path)
    except Exception:
        print("100.0")
        sys.exit(0)

    import os, tempfile
    with open(prm_path) as pf:
        for line in pf:
            line = line.strip()
            if not line:
                continue
            try:
                fd, tfname = tempfile.mkstemp(suffix='.prm')
                with os.fdopen(fd, 'w') as tf:
                    tf.write(line + "\n")
                c.parameters.read_file(tfname)
            except Exception:
                pass
            finally:
                try:
                    os.unlink(tfname)
                except Exception:
                    pass

    c.parameters.threads.set(threads)
    c.parameters.parallel.set(1)  # deterministic parallel mode, overrides any value in .prm
    if time_mode == "seconds":
        c.parameters.timelimit.set(solver_time)
    else:
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
