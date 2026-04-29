#!/bin/bash
#
# Submit one batch of tuning runs: one proc count, all (instance_dir × seed) combos.
#
# BEFORE SUBMITTING: update the four SBATCH lines marked [CHANGE PER SUBMISSION]
# to match the target proc count. The relationship is:
#
#   --ntasks          = MPI_PROCS
#   --ntasks-per-socket = ceil(MPI_PROCS / 2)   ← keeps ranks balanced across the 2 sockets
#   --cpus-per-task   = CPLEX_THREADS            (8, matches one chiplet = one L3 cache)
#
# Node topology: 2 sockets × 4 NUMA × 3 chiplets × 8 cores = 192 cores.
# Each rank gets 1 dedicated chiplet (8 cores, 32 MiB L3). --ntasks-per-socket
# keeps ranks balanced across the 2 sockets so all workers get equal memory bandwidth.
#
#   procs  --ntasks  --ntasks-per-socket  mem ch/rank
#     1       1             1              12.0   (1 chiplet, socket 0 only)
#     2       2             1              12.0   (1 chiplet per socket)
#     4       4             2               6.0
#     8       8             4               3.0
#    16      16             8               1.5
#    24      24            12               1.0   ← full node, perfect fill
#
# Example submissions (update the three [CHANGE] lines below first):
#   sbatch --export=ALL,MPI_PROCS=8   submit-run-instances.sh
#   sbatch --export=ALL,MPI_PROCS=24  submit-run-instances.sh
#
#SBATCH --job-name=mpils-batch
# 3 instance dirs * 10 seeds = 30 array tasks.
#SBATCH --array=0-29
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

INSTANCE_DIR_NAMES=(${INSTANCE_DIR_NAMES:-easy medium-1 medium-2})
SEEDS=(${SEEDS:-1 2 3 4 5 6 7 8 9 10})

MPI_PROCS="${MPI_PROCS:-1}"
CPLEX_THREADS="${CPLEX_THREADS:-8}"
SOLVER_TIME="${SOLVER_TIME:-10000}"
SOLVER_TIME_MODE="${SOLVER_TIME_MODE:-ticks}"

TUNER_DIR="${TUNER_DIR:-/home/yorig/tuner/mpils}"
RESULTS_ROOT="${RESULTS_ROOT:-/scratch/${USER}/mpils-results-grid-${SOLVER_TIME_MODE}-${SOLVER_TIME}}"
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
OUTPUT_ROOT="${RESULTS_ROOT}/${BATCH_NAME}/${MPI_PROCS}proc/seed-${SEED}"

echo "Array task      : ${task_id}/${total_tasks}"
echo "Instance dir    : $BATCH_NAME"
echo "MPI procs       : $MPI_PROCS"
echo "CPLEX threads   : $CPLEX_THREADS"
echo "Solver time     : $SOLVER_TIME"
echo "Solver time mode: $SOLVER_TIME_MODE"
echo "Seed            : $SEED"
echo "Output root     : $OUTPUT_ROOT"

run_args=(
  --instances-dir "$INSTANCES_DIR" \
  --tuner-dir "$TUNER_DIR" \
  --output-root "$OUTPUT_ROOT" \
  --mpi-procs "$MPI_PROCS" \
  --cplex-threads "$CPLEX_THREADS" \
  --solver-time "$SOLVER_TIME" \
  --solver-time-mode "$SOLVER_TIME_MODE" \
  --seed "$SEED"
)

if [[ -n "$PARAMETERS_FILE" ]]; then
  run_args+=(--parameters-file "$PARAMETERS_FILE")
fi

"${TESTS_DIR}/run-instances.sh" "${run_args[@]}"
