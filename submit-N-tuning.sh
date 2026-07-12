#!/bin/bash
#
# Experiment N — per-instance tuning on hard N instances.
#
# Each array task tunes N${i}.lp independently with MPILS (24 procs, 4 per ILS = 6 ILS chains).
# Evaluation budget: 60 seconds per CPLEX call.
# Wall time: 3h → ~90 evaluations per ILS chain.
#
# Usage:
#   sbatch submit-N-tuning.sh
#
#SBATCH --job-name=mpils-N
#SBATCH --array=1-15
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --ntasks=24
#SBATCH --ntasks-per-socket=12
#SBATCH --cpus-per-task=8
#SBATCH --time=3:00:00
#SBATCH --mem=0
#SBATCH --output=mpils-N_%A_%a.out
#SBATCH --error=mpils-N_%A_%a.err

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
INSTANCES_DIR="/home/yorig/Instances_MPILS"
TUNER_DIR="/home/yorig/tuner/mpils"
TESTS_DIR="/home/yorig/tuner/mpils-tests"
RESULTS_ROOT="/scratch/${USER}/mpils-results-N-seconds-60"

MPI_PROCS=24
MPI_PROCS_PER_ILS=4
CPLEX_THREADS=8
SOLVER_TIME=60
SOLVER_TIME_MODE=seconds
SEED=1

# ── Instance for this array task ─────────────────────────────────────────────
i=${SLURM_ARRAY_TASK_ID}
INSTANCE_PATH="${INSTANCES_DIR}/N${i}.lp"
INSTANCE_STEM="N${i}"

[[ -f "$INSTANCE_PATH" ]] || { echo "ERROR: instance not found: $INSTANCE_PATH" >&2; exit 1; }

OUTPUT_DIR="${RESULTS_ROOT}/${INSTANCE_STEM}/${INSTANCE_STEM}_seed-${SEED}"
mkdir -p "$OUTPUT_DIR"

TUNER_APP="${TUNER_DIR}/build/mpils"
[[ -x "$TUNER_APP" ]] || { echo "ERROR: tuner binary not found: $TUNER_APP" >&2; exit 1; }

PARAMETERS_FILE="${TUNER_DIR}/cplex/params_12_cpx.txt"

# ── Thread isolation ──────────────────────────────────────────────────────────
export OMP_NUM_THREADS=$CPLEX_THREADS
export CPLEX_NUM_THREADS=$CPLEX_THREADS
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

# ── Info ──────────────────────────────────────────────────────────────────────
echo "=== Experiment N — Instance ${INSTANCE_STEM} ==="
echo "SLURM_JOB_ID         : ${SLURM_JOB_ID:-NA}"
echo "SLURM_ARRAY_TASK_ID  : ${SLURM_ARRAY_TASK_ID}"
echo "SLURM_JOB_NODELIST   : ${SLURM_JOB_NODELIST:-NA}"
echo "Instance             : $INSTANCE_PATH"
echo "Output dir           : $OUTPUT_DIR"
echo "MPI procs            : $MPI_PROCS  (${MPI_PROCS_PER_ILS} per ILS → $((MPI_PROCS / MPI_PROCS_PER_ILS)) ILS chains)"
echo "Solver time          : ${SOLVER_TIME}s (${SOLVER_TIME_MODE})"
echo "Seed                 : $SEED"
echo "=============================================="

# ── Launch MPILS ─────────────────────────────────────────────────────────────
srun \
    --ntasks=$MPI_PROCS \
    --cpus-per-task=$CPLEX_THREADS \
    --ntasks-per-socket=12 \
    --distribution=block:block:block \
    --hint=nomultithread \
    --cpu-bind=cores \
    --mem-bind=local \
    "$TUNER_APP" \
        "$INSTANCE_PATH" \
        --project-dir "$TUNER_DIR" \
        --working-dir "$OUTPUT_DIR" \
        --parameters-file "$PARAMETERS_FILE" \
        --clean-working-dir \
        --solver-threads "$CPLEX_THREADS" \
        --solver-time "$SOLVER_TIME" \
        --solver-time-mode "$SOLVER_TIME_MODE" \
        --seed "$SEED" \
        --no-shared-cache \
        --disable-mip-starts \
        --expansion-value-strategy all \
        --mpi-procs-per-ils "$MPI_PROCS_PER_ILS" \
        --no-solver-wall-watchdog

RC=$?

echo
if [[ -f "${OUTPUT_DIR}/best_configuration.prm" ]]; then
    echo "SUCCESS: best_configuration.prm written."
else
    echo "WARNING: best_configuration.prm not found (tuner rc=${RC})."
fi
echo "Output: $OUTPUT_DIR"
