#!/bin/bash
#
# Submit ILS exploration budget study jobs.
#
# Sweeps k × n_params × instance_dir × seed on all medium instances.
# Each array task runs one (k, n_params, dir, seed) combo: 9 instances sequentially.
#
# Study grid:
#   k       : 2 5 10 15 20  (5 values)
#   n_params: 5 10 20       (3 values)
#   dirs    : medium-1 medium-2
#   seeds   : 1 2 3 4 5
#   Total   : 5 × 3 × 2 × 5 = 150 array tasks
#
# Each task needs 1 rank × 8 cores. Multiple tasks can share a node.
#
# Submission:
#   sbatch submit-study-ils-budget.sh
#   sbatch --export=ALL,SOLVER_TIME=10000,SOLVER_TIME_MODE=ticks submit-study-ils-budget.sh
#
#SBATCH --job-name=ils-budget-study
#SBATCH --array=0-149
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=24:00:00
#SBATCH --mem-per-cpu=2G
#SBATCH --output=job_%A_%a.out
#SBATCH --error=job_%A_%a.err

set -euo pipefail

TESTS_DIR="/home/yorig/tuner/mpils-tests"

K_VALUES=(2 5 10 15 20)
N_VALUES=(5 10 20)
INSTANCE_DIR_NAMES=(medium-1 medium-2)
SEEDS=(1 2 3 4 5)

TUNER_DIR="${TUNER_DIR:-/home/yorig/tuner/mpils}"
RESULTS_ROOT="${RESULTS_ROOT:-/scratch/${USER}/study-ils-budget}"
CPLEX_THREADS="${CPLEX_THREADS:-8}"
SOLVER_TIME="${SOLVER_TIME:-10}"
SOLVER_TIME_MODE="${SOLVER_TIME_MODE:-seconds}"
PARAMETERS_FILE="${PARAMETERS_FILE:-}"

n_k=${#K_VALUES[@]}
n_n=${#N_VALUES[@]}
n_dirs=${#INSTANCE_DIR_NAMES[@]}
n_seeds=${#SEEDS[@]}
total_tasks=$(( n_k * n_n * n_dirs * n_seeds ))

task_id="${SLURM_ARRAY_TASK_ID:-0}"

if [[ "$task_id" -ge "$total_tasks" ]]; then
  echo "Skipping array task ${task_id}; only ${total_tasks} combinations defined."
  exit 0
fi

k_idx=$(( task_id % n_k ))
n_idx=$(( task_id / n_k % n_n ))
dir_idx=$(( task_id / (n_k * n_n) % n_dirs ))
seed_idx=$(( task_id / (n_k * n_n * n_dirs) ))

K="${K_VALUES[$k_idx]}"
N="${N_VALUES[$n_idx]}"
BATCH_NAME="${INSTANCE_DIR_NAMES[$dir_idx]}"
SEED="${SEEDS[$seed_idx]}"

INSTANCES_DIR="${TESTS_DIR}/instances/miplib/${BATCH_NAME}"
OUTPUT_DIR="${RESULTS_ROOT}/k${K}_n${N}/${BATCH_NAME}/seed-${SEED}"

echo "===== ILS budget study task ====="
echo "Array task   : ${task_id}/${total_tasks}"
echo "k            : $K"
echo "n_params     : $N"
echo "n_evals      : $((K * N))"
echo "Instance dir : $BATCH_NAME"
echo "Seed         : $SEED"
echo "CPLEX threads: $CPLEX_THREADS"
echo "Solver time  : $SOLVER_TIME ($SOLVER_TIME_MODE)"
echo "Output dir   : $OUTPUT_DIR"
echo "================================="

run_args=(
  --instances-dir    "$INSTANCES_DIR"
  --tuner-dir        "$TUNER_DIR"
  --output-dir       "$OUTPUT_DIR"
  --k                "$K"
  --n-params         "$N"
  --cplex-threads    "$CPLEX_THREADS"
  --solver-time      "$SOLVER_TIME"
  --solver-time-mode "$SOLVER_TIME_MODE"
  --seed             "$SEED"
)

[[ -n "$PARAMETERS_FILE" ]] && run_args+=(--parameters-file "$PARAMETERS_FILE")

"${TESTS_DIR}/run-study-ils-budget.sh" "${run_args[@]}"
