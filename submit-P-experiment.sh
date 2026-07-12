#!/bin/bash
#
# Experiment P — transfer tuning on hard P instances.
#
# Phase 1: Tune P1.lp with MPILS (24 procs, 4 per ILS = 6 ILS chains, 120s/eval, ~3h wall).
# Phase 2: Test the best found config AND the default config on P1.lp–P15.lp (120s each).
#          Results written to P_transfer_results.csv for comparison.
#
# Usage:
#   sbatch submit-P-experiment.sh
#
#SBATCH --job-name=mpils-P
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --ntasks=24
#SBATCH --ntasks-per-socket=12
#SBATCH --cpus-per-task=8
#SBATCH --time=5:00:00
#SBATCH --mem=0
#SBATCH --output=mpils-P_%j.out
#SBATCH --error=mpils-P_%j.err

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
INSTANCES_DIR="/home/yorig/Instances_MPILS"
TUNER_DIR="/home/yorig/tuner/mpils"
TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"
RESULTS_ROOT="/scratch/${USER}/mpils-results-P-seconds-120"

MPI_PROCS=24
MPI_PROCS_PER_ILS=4
CPLEX_THREADS=8
SOLVER_TIME=120
SOLVER_TIME_MODE=seconds
SEED=1

TUNER_APP="${TUNER_DIR}/build/mpils"
PARAMETERS_FILE="${TUNER_DIR}/cplex/params_12_cpx.txt"

[[ -x "$TUNER_APP" ]]      || { echo "ERROR: tuner binary not found: $TUNER_APP" >&2; exit 1; }
[[ -f "$PARAMETERS_FILE" ]] || { echo "ERROR: parameters file not found: $PARAMETERS_FILE" >&2; exit 1; }

# ── Thread isolation ──────────────────────────────────────────────────────────
export OMP_NUM_THREADS=$CPLEX_THREADS
export CPLEX_NUM_THREADS=$CPLEX_THREADS
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

mkdir -p "$RESULTS_ROOT"

# ════════════════════════════════════════════════════════════════════════════
# Phase 1 — Tune P1.lp
# ════════════════════════════════════════════════════════════════════════════
P1_PATH="${INSTANCES_DIR}/P1.lp"
[[ -f "$P1_PATH" ]] || { echo "ERROR: instance not found: $P1_PATH" >&2; exit 1; }

P1_OUTPUT="${RESULTS_ROOT}/P1/P1_seed-${SEED}"
mkdir -p "$P1_OUTPUT"

BEST_CONFIG="${P1_OUTPUT}/best_configuration.prm"

echo "=== Phase 1: Tuning P1.lp ==="
echo "SLURM_JOB_ID       : ${SLURM_JOB_ID:-NA}"
echo "SLURM_JOB_NODELIST : ${SLURM_JOB_NODELIST:-NA}"
echo "Instance           : $P1_PATH"
echo "Output dir         : $P1_OUTPUT"
echo "MPI procs          : $MPI_PROCS  (${MPI_PROCS_PER_ILS} per ILS → $((MPI_PROCS / MPI_PROCS_PER_ILS)) ILS chains)"
echo "Solver time        : ${SOLVER_TIME}s (${SOLVER_TIME_MODE})"
echo "Seed               : $SEED"
echo "======================================="

srun \
    --ntasks=$MPI_PROCS \
    --cpus-per-task=$CPLEX_THREADS \
    --ntasks-per-socket=12 \
    --distribution=block:block:block \
    --hint=nomultithread \
    --cpu-bind=cores \
    --mem-bind=local \
    "$TUNER_APP" \
        "$P1_PATH" \
        --project-dir "$TUNER_DIR" \
        --working-dir "$P1_OUTPUT" \
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

echo "=== Phase 1 complete ==="

[[ -f "$BEST_CONFIG" ]] || {
    echo "ERROR: Phase 1 did not produce best_configuration.prm at: $BEST_CONFIG" >&2
    exit 1
}

echo "Best config: $BEST_CONFIG"

# ════════════════════════════════════════════════════════════════════════════
# Phase 2 — Test MPILS config and default on P1–P15
# ════════════════════════════════════════════════════════════════════════════
echo
echo "=== Phase 2: Testing on P1–P15 ==="

source "${VENV_DIR}/bin/activate"

EMPTY_PRM=$(mktemp /tmp/empty_default_XXXXXX.prm)
trap "rm -f '$EMPTY_PRM'" EXIT
# Empty file = CPLEX default parameters (no overrides)
: > "$EMPTY_PRM"

RESULTS_CSV="${RESULTS_ROOT}/P_transfer_results.csv"
echo "instance,default_gap,mpils_gap" > "$RESULTS_CSV"

for i in $(seq 1 15); do
    INSTANCE="${INSTANCES_DIR}/P${i}.lp"
    if [[ ! -f "$INSTANCE" ]]; then
        echo "WARNING: instance not found, skipping: $INSTANCE" >&2
        echo "P${i},NA,NA" >> "$RESULTS_CSV"
        continue
    fi

    echo -n "P${i}: "

    default_gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
        "$INSTANCE" "$EMPTY_PRM" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")

    mpils_gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
        "$INSTANCE" "$BEST_CONFIG" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")

    echo "default=${default_gap}%  mpils=${mpils_gap}%"
    echo "P${i},${default_gap},${mpils_gap}" >> "$RESULTS_CSV"
done

echo
echo "=== Phase 2 complete ==="
echo "Results: $RESULTS_CSV"
