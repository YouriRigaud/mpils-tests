#!/bin/bash
#
# Submit ParamILS comparison runs: same resources as MPILS, wall-clock budget.
#
# K independent ParamILS workers run as a portfolio — all start from the same
# default initial configuration and explore different trajectories via different
# random seeds. All 71 parameters are active from the start (no initial
# selection/expansion phase).
#
# BEFORE SUBMITTING: update the three SBATCH lines marked [CHANGE PER SUBMISSION].
# Same topology rules as submit-run-instances.sh:
#
#   --ntasks          = MPI_PROCS
#   --ntasks-per-socket = ceil(MPI_PROCS / 2)
#   --cpus-per-task   = CPLEX_THREADS (8, one chiplet)
#
#   procs  --ntasks  --ntasks-per-socket
#     1       1             1
#     2       2             1
#     4       4             2
#     8       8             4
#    16      16             8
#    24      24            12   ← full node
#
# PARAMILS_BUDGETS_FILE defaults to TESTS_DIR/paramils_budgets_${MPI_PROCS}proc.csv.
# Each file maps instance stems (no .mps) to their wall-clock budget in seconds,
# derived from the median MPILS tuning time at that proc count.
# Override with --export=ALL,...,PARAMILS_BUDGETS_FILE=/other/path if needed.
#
# Submission commands (only --ntasks and --ntasks-per-socket change):
#
#   sbatch --ntasks=1  --ntasks-per-socket=1  --export=ALL,MPI_PROCS=1  submit-run-paramils.sh
#   sbatch --ntasks=2  --ntasks-per-socket=1  --export=ALL,MPI_PROCS=2  submit-run-paramils.sh
#   sbatch --ntasks=4  --ntasks-per-socket=2  --export=ALL,MPI_PROCS=4  submit-run-paramils.sh
#   sbatch --ntasks=8  --ntasks-per-socket=4  --export=ALL,MPI_PROCS=8  submit-run-paramils.sh
#   sbatch --ntasks=16 --ntasks-per-socket=8  --export=ALL,MPI_PROCS=16 submit-run-paramils.sh
#   sbatch --ntasks=24 --ntasks-per-socket=12 --export=ALL,MPI_PROCS=24 submit-run-paramils.sh
#
#SBATCH --job-name=paramils-batch
# 2 instance dirs * 10 seeds = 20 array tasks.
#SBATCH --array=0-19
#SBATCH --nodes=1                  # all ranks on the same physical node
#SBATCH --exclusive                # no other job shares this node
#SBATCH --ntasks=1                 # [CHANGE PER SUBMISSION] = MPI_PROCS
#SBATCH --ntasks-per-socket=1      # [CHANGE PER SUBMISSION] = ceil(MPI_PROCS / 2)
#SBATCH --cpus-per-task=8          # [CHANGE PER SUBMISSION] = CPLEX_THREADS (1 chiplet)
#SBATCH --time=24:00:00
#SBATCH --mem=0
#SBATCH --output=job_%A_%a.out
#SBATCH --error=job_%A_%a.err

set -euo pipefail

TESTS_DIR="/home/yorig/tuner/mpils-tests"

INSTANCE_DIR_NAMES=(${INSTANCE_DIR_NAMES:-medium-1 medium-2})
SEEDS=(${SEEDS:-1 2 3 4 5 6 7 8 9 10})

MPI_PROCS="${MPI_PROCS:-1}"
CPLEX_THREADS="${CPLEX_THREADS:-8}"
SOLVER_TIME="${SOLVER_TIME:-10000}"
SOLVER_TIME_MODE="${SOLVER_TIME_MODE:-ticks}"
PARAMILS_BUDGETS_FILE="${PARAMILS_BUDGETS_FILE:-${TESTS_DIR}/paramils_budgets_${MPI_PROCS}proc.csv}"
[[ -f "$PARAMILS_BUDGETS_FILE" ]] || { echo "Error: budgets file not found: $PARAMILS_BUDGETS_FILE" >&2; exit 1; }

TUNER_DIR="${TUNER_DIR:-/home/yorig/tuner/mpils}"
RESULTS_ROOT="${RESULTS_ROOT:-/scratch/${USER}/paramils-results-${SOLVER_TIME_MODE}-${SOLVER_TIME}}"
PARAMETERS_FILE="${PARAMETERS_FILE:-}"

task_id="${SLURM_ARRAY_TASK_ID:-0}"
num_instance_dirs="${#INSTANCE_DIR_NAMES[@]}"
num_seeds="${#SEEDS[@]}"
total_tasks=$((num_instance_dirs * num_seeds))

# Verify SBATCH --ntasks matches MPI_PROCS so the allocation is correct.
if [[ -n "${SLURM_NTASKS:-}" && "${SLURM_NTASKS}" -ne "$MPI_PROCS" ]]; then
  echo "Error: MPI_PROCS=${MPI_PROCS} but Slurm allocated SLURM_NTASKS=${SLURM_NTASKS}" >&2
  echo "Update both MPI_PROCS and #SBATCH --ntasks to the same value." >&2
  exit 1
fi

if [[ "$task_id" -ge "$total_tasks" ]]; then
  echo "Skipping array task ${task_id}; only ${total_tasks} combinations are defined."
  exit 0
fi

seed_index=$((task_id % num_seeds))
instance_dir_index=$((task_id / num_seeds))

BATCH_NAME="${INSTANCE_DIR_NAMES[$instance_dir_index]}"
SEED="${SEEDS[$seed_index]}"

INSTANCES_DIR="${TESTS_DIR}/instances/miplib/${BATCH_NAME}"
OUTPUT_ROOT="${RESULTS_ROOT}/${BATCH_NAME}/${MPI_PROCS}proc-paramils/seed-${SEED}"

echo "Array task       : ${task_id}/${total_tasks}"
echo "Instance dir     : $BATCH_NAME"
echo "MPI procs        : $MPI_PROCS"
echo "ParamILS workers : $MPI_PROCS  (1 per MPI rank, independent portfolio)"
echo "CPLEX threads    : $CPLEX_THREADS"
echo "Solver time      : $SOLVER_TIME"
echo "Solver time mode : $SOLVER_TIME_MODE"
echo "ParamILS budgets : $PARAMILS_BUDGETS_FILE"
echo "Seed             : $SEED"
echo "Output root      : $OUTPUT_ROOT"

run_args=(
  --instances-dir "$INSTANCES_DIR"
  --tuner-dir "$TUNER_DIR"
  --output-root "$OUTPUT_ROOT"
  --mpi-procs "$MPI_PROCS"
  --cplex-threads "$CPLEX_THREADS"
  --solver-time "$SOLVER_TIME"
  --solver-time-mode "$SOLVER_TIME_MODE"
  --seed "$SEED"
  --local-search-engine paramils
  --paramils-budgets-file "$PARAMILS_BUDGETS_FILE"
)

if [[ -n "$PARAMETERS_FILE" ]]; then
  run_args+=(--parameters-file "$PARAMETERS_FILE")
fi

"${TESTS_DIR}/run-instances.sh" "${run_args[@]}"
