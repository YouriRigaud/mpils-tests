#!/bin/bash
#
# Solve P1.lp–P15.lp with default CPLEX parameters to measure natural solve time.
# 3 array tasks, 5 instances each (task 1: P1–P5, task 2: P6–P10, task 3: P11–P15).
# Results collected in: /scratch/${USER}/solve-default-P/results.csv
#
# Usage:
#   sbatch submit-P-solve.sh
#
#SBATCH --job-name=solve-P
#SBATCH --array=1-3
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=8:00:00
#SBATCH --mem-per-cpu=8G
#SBATCH --output=solve-P_%A_%a.out
#SBATCH --error=solve-P_%A_%a.err

set -euo pipefail

INSTANCES_DIR="/home/yorig/Instances_MPILS"
TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"
RESULTS_DIR="/scratch/${USER}/solve-default-P"
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

# Write header once if the file doesn't exist yet (race-safe via flock)
{
    flock -x 200
    [[ -f "$RESULTS_CSV" ]] || echo "instance,status,wall_time_s,gap_pct,nodes_explored" > "$RESULTS_CSV"
} 200>"${RESULTS_DIR}/results.csv.lock"

# 5 instances per task: task 1 → P1–P5, task 2 → P6–P10, task 3 → P11–P15
task=${SLURM_ARRAY_TASK_ID}
start=$(( (task - 1) * 5 + 1 ))
end=$(( task * 5 ))

for i in $(seq "$start" "$end"); do
    INSTANCE_STEM="P${i}"
    INSTANCE_PATH="${INSTANCES_DIR}/${INSTANCE_STEM}.lp"

    if [[ ! -f "$INSTANCE_PATH" ]]; then
        echo "WARNING: not found, skipping: $INSTANCE_PATH" >&2
        {
            flock -x 200
            echo "${INSTANCE_STEM},not_found,NA,NA,NA,NA" >> "$RESULTS_CSV"
        } 200>"${RESULTS_DIR}/results.csv.lock"
        continue
    fi

    echo "--- Solving ${INSTANCE_STEM} (threads=${THREADS}, time_limit=${TIME_LIMIT}s) ---"
    result=$(python3 "${TESTS_DIR}/solve_default.py" "$INSTANCE_PATH" "$THREADS" "$TIME_LIMIT")
    echo "${INSTANCE_STEM}: ${result}"

    {
        flock -x 200
        echo "${INSTANCE_STEM},${result}" >> "$RESULTS_CSV"
    } 200>"${RESULTS_DIR}/results.csv.lock"
done

echo "Task ${task} done (P${start}–P${end})."
