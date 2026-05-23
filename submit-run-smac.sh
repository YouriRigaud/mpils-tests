#!/bin/bash
#
# Submit SMAC-based CPLEX tuning runs: single-instance tuning, per-instance
# wall-clock budget read from a budgets CSV file.
#
# Each array task processes one batch (medium-1 or medium-2) for one seed,
# running SMAC sequentially on each instance in the batch.
#
# Resources:
#   Each SMAC evaluation runs CPLEX with CPLEX_THREADS threads.
#   N_WORKERS evaluations run in parallel via dask.
#   Total CPUs needed: N_WORKERS × CPLEX_THREADS.
#
#   N_WORKERS  CPLEX_THREADS  --cpus-per-task
#       1           8              8
#       4           8             32
#      24           8            192   ← full node
#
# BUDGETS_FILE: CSV with instance,wall_time  (one row per instance, stem without .mps).
#   Defaults to TESTS_DIR/paramils_budgets_max.csv.
#   Override via --export=ALL,BUDGETS_FILE=/other/path
#
# Submission:
#   sbatch --cpus-per-task=192 \
#          --export=ALL,N_WORKERS=24 \
#          submit-run-smac.sh
#
#   sbatch --cpus-per-task=8 \
#          --export=ALL,N_WORKERS=1,BUDGETS_FILE=paramils_budgets_2proc.csv \
#          submit-run-smac.sh
#
#SBATCH --job-name=smac-cplex
# 2 instance dirs * 10 seeds = 20 array tasks.
#SBATCH --array=0-19
#SBATCH --ntasks=2
#SBATCH --cpus-per-task=8     # [CHANGE] = N_WORKERS × CPLEX_THREADS
#SBATCH --time=12:00:00
#SBATCH --mem-per-cpu=2G
#SBATCH --output=job_%A_%a.out
#SBATCH --error=job_%A_%a.err

set -euo pipefail

TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"

INSTANCE_DIR_NAMES=(${INSTANCE_DIR_NAMES:-medium-1 medium-2})
SEEDS=(${SEEDS:-1 2 3 4 5 6 7 8 9 10})

N_WORKERS="${N_WORKERS:-2}"
CPLEX_THREADS="${CPLEX_THREADS:-8}"
SOLVER_TIME="${SOLVER_TIME:-10}"
SOLVER_TIME_MODE="${SOLVER_TIME_MODE:-seconds}"

BUDGETS_FILE="${BUDGETS_FILE:-${TESTS_DIR}/paramils_budgets_2proc.csv}"
PARAMS_FILE="${PARAMS_FILE:-${TESTS_DIR}/params_12_cpx.txt}"
RESULTS_ROOT="${RESULTS_ROOT:-/scratch/${USER}/smac-results-${SOLVER_TIME_MODE}-${SOLVER_TIME}/${N_WORKERS}proc}"

[[ -f "$BUDGETS_FILE" ]] || { echo "Error: budgets file not found: $BUDGETS_FILE" >&2; exit 1; }
[[ -f "$PARAMS_FILE"  ]] || { echo "Error: params file not found: $PARAMS_FILE" >&2; exit 1; }

task_id="${SLURM_ARRAY_TASK_ID:-0}"
num_instance_dirs="${#INSTANCE_DIR_NAMES[@]}"
num_seeds="${#SEEDS[@]}"
total_tasks=$((num_instance_dirs * num_seeds))

if [[ "$task_id" -ge "$total_tasks" ]]; then
  echo "Skipping array task ${task_id}; only ${total_tasks} combinations defined."
  exit 0
fi

seed_index=$((task_id % num_seeds))
instance_dir_index=$((task_id / num_seeds))

BATCH_NAME="${INSTANCE_DIR_NAMES[$instance_dir_index]}"
SEED="${SEEDS[$seed_index]}"

INSTANCES_DIR="${TESTS_DIR}/instances/miplib/${BATCH_NAME}"

echo "===== SMAC launch info ====="
echo "Array task      : ${task_id}/${total_tasks}"
echo "Instance dir    : $BATCH_NAME"
echo "Seed            : $SEED"
echo "N workers       : $N_WORKERS"
echo "CPLEX threads   : $CPLEX_THREADS"
echo "Solver time     : $SOLVER_TIME ($SOLVER_TIME_MODE)"
echo "Budgets file    : $BUDGETS_FILE"
echo "Results root    : $RESULTS_ROOT"
echo "============================"

# Activate the virtual environment
source "${VENV_DIR}/bin/activate"

# Process each instance sequentially within this array task
mapfile -d '' instances < <(find "$INSTANCES_DIR" -type f -name '*.mps' -print0 | sort -z)

for instance_path in "${instances[@]}"; do
  instance_name=$(basename "$instance_path")
  instance_stem="${instance_name%.mps}"

  # Look up per-instance wall-clock budget
  budget=$(awk -F',' -v stem="$instance_stem" \
    'NR>1 && $1==stem { print int($2); exit }' "$BUDGETS_FILE")

  if [[ -z "$budget" ]]; then
    echo "Skipping ${instance_name}: not found in $BUDGETS_FILE" >&2
    continue
  fi

  output_dir="${RESULTS_ROOT}/${BATCH_NAME}/${instance_stem}/seed-${SEED}"
  mkdir -p "$output_dir"

  echo
  echo "------------------------------------------"
  echo "Instance : $instance_name"
  echo "Budget   : ${budget}s"
  echo "Output   : $output_dir"
  echo "------------------------------------------"

  python "${TESTS_DIR}/smac_tune_cplex.py" \
    --instance      "$instance_path" \
    --params-file   "$PARAMS_FILE" \
    --solver-time   "$SOLVER_TIME" \
    --threads       "$CPLEX_THREADS" \
    --walltime      "$budget" \
    --n-workers     "$N_WORKERS" \
    --output-dir    "$output_dir" \
    --seed          "$SEED"
done

echo
echo "Batch ${BATCH_NAME} seed-${SEED} complete."
