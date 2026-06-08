#!/bin/bash
#
# Submit expansion parameter budget study jobs.
#
# Sweeps --expansion-parameter-budget × early-stop × instance_dir × seed
# on all medium instances. Each array task runs 1 (budget, early_stop, dir, seed)
# combo: 9 instances sequentially, with the full MPILS pipeline.
#
# Study grid:
#   expansion_budget : 5 10 20 100   (4 values)
#   early_stop       : yes no         (2 values)
#   dirs             : medium-1 medium-2
#   seeds            : 1..10
#   Total            : 4 × 2 × 2 × 10 = 160 array tasks
#
# Submission:
#   sbatch submit-study-expansion.sh
#   sbatch --export=ALL,SOLVER_TIME=10000,SOLVER_TIME_MODE=ticks submit-study-expansion.sh
#
#SBATCH --job-name=expansion-study
#SBATCH --array=0-159
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=24:00:00
#SBATCH --mem-per-cpu=2G
#SBATCH --output=job_%A_%a.out
#SBATCH --error=job_%A_%a.err

set -euo pipefail

TESTS_DIR="/home/yorig/tuner/mpils-tests"

EXPANSION_BUDGETS=(5 10 20 100)
EARLY_STOPS=(yes no)
INSTANCE_DIR_NAMES=(medium-1 medium-2)
SEEDS=(1 2 3 4 5 6 7 8 9 10)

TUNER_DIR="${TUNER_DIR:-/home/yorig/tuner/mpils}"
RESULTS_ROOT="${RESULTS_ROOT:-/scratch/${USER}/study-expansion}"
CPLEX_THREADS="${CPLEX_THREADS:-8}"
SOLVER_TIME="${SOLVER_TIME:-10}"
SOLVER_TIME_MODE="${SOLVER_TIME_MODE:-seconds}"
PARAMETERS_FILE="${PARAMETERS_FILE:-}"

n_budgets=${#EXPANSION_BUDGETS[@]}
n_es=${#EARLY_STOPS[@]}
n_dirs=${#INSTANCE_DIR_NAMES[@]}
n_seeds=${#SEEDS[@]}
total_tasks=$(( n_budgets * n_es * n_dirs * n_seeds ))

task_id="${SLURM_ARRAY_TASK_ID:-0}"

if [[ "$task_id" -ge "$total_tasks" ]]; then
  echo "Skipping array task ${task_id}; only ${total_tasks} combinations defined."
  exit 0
fi

budget_idx=$(( task_id % n_budgets ))
es_idx=$(( task_id / n_budgets % n_es ))
dir_idx=$(( task_id / (n_budgets * n_es) % n_dirs ))
seed_idx=$(( task_id / (n_budgets * n_es * n_dirs) ))

EXPANSION_BUDGET="${EXPANSION_BUDGETS[$budget_idx]}"
EARLY_STOP="${EARLY_STOPS[$es_idx]}"
BATCH_NAME="${INSTANCE_DIR_NAMES[$dir_idx]}"
SEED="${SEEDS[$seed_idx]}"

INSTANCES_DIR="${TESTS_DIR}/instances/miplib/${BATCH_NAME}"
OUTPUT_DIR="${RESULTS_ROOT}/expbud${EXPANSION_BUDGET}_es${EARLY_STOP}/${BATCH_NAME}/seed-${SEED}"

echo "===== Expansion study task ====="
echo "Array task      : ${task_id}/${total_tasks}"
echo "Expansion budget: $EXPANSION_BUDGET"
echo "Early stop      : $EARLY_STOP"
echo "Instance dir    : $BATCH_NAME"
echo "Seed            : $SEED"
echo "CPLEX threads   : $CPLEX_THREADS"
echo "Solver time     : $SOLVER_TIME ($SOLVER_TIME_MODE)"
echo "Output dir      : $OUTPUT_DIR"
echo "================================"

run_args=(
  --instances-dir    "$INSTANCES_DIR"
  --tuner-dir        "$TUNER_DIR"
  --output-dir       "$OUTPUT_DIR"
  --expansion-budget "$EXPANSION_BUDGET"
  --early-stop       "$EARLY_STOP"
  --cplex-threads    "$CPLEX_THREADS"
  --solver-time      "$SOLVER_TIME"
  --solver-time-mode "$SOLVER_TIME_MODE"
  --seed             "$SEED"
)

[[ -n "$PARAMETERS_FILE" ]] && run_args+=(--parameters-file "$PARAMETERS_FILE")

"${TESTS_DIR}/run-study-expansion.sh" "${run_args[@]}"
