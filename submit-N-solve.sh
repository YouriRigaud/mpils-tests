#!/bin/bash
#
# Solve N1.lp–N15.lp sequentially with default CPLEX parameters to measure natural solve time.
# Results collected in: /scratch/${USER}/solve-default-N/results.csv
#
# Usage:
#   sbatch submit-N-solve.sh
#
#SBATCH --job-name=solve-N
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=24:00:00
#SBATCH --mem-per-cpu=8G
#SBATCH --output=solve-N_%j.out
#SBATCH --error=solve-N_%j.err

set -euo pipefail

INSTANCES_DIR="/home/yorig/Instances_MPILS"
TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"
RESULTS_DIR="/scratch/${USER}/solve-default-N"
THREADS=8
TIME_LIMIT=3600   # safety cap per instance; we want to see when the solver finishes naturally

mkdir -p "$RESULTS_DIR"

source "${VENV_DIR}/bin/activate"

export OMP_NUM_THREADS=$THREADS
export CPLEX_NUM_THREADS=$THREADS
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

RESULTS_CSV="${RESULTS_DIR}/results.csv"
echo "instance,status,wall_time_s,gap_pct,nodes_explored" > "$RESULTS_CSV"

for i in $(seq 1 15); do
    INSTANCE_STEM="N${i}"
    INSTANCE_PATH="${INSTANCES_DIR}/${INSTANCE_STEM}.lp"

    if [[ ! -f "$INSTANCE_PATH" ]]; then
        echo "WARNING: not found, skipping: $INSTANCE_PATH" >&2
        echo "${INSTANCE_STEM},not_found,NA,NA,NA,NA" >> "$RESULTS_CSV"
        continue
    fi

    echo "--- Solving ${INSTANCE_STEM} (threads=${THREADS}, time_limit=${TIME_LIMIT}s) ---"
    result=$(python3 "${TESTS_DIR}/solve_default.py" "$INSTANCE_PATH" "$THREADS" "$TIME_LIMIT")
    echo "${INSTANCE_STEM}: ${result}"
    echo "${INSTANCE_STEM},${result}" >> "$RESULTS_CSV"
done

echo
echo "Done. Results: $RESULTS_CSV"
