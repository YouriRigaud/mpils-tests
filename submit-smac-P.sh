#!/bin/bash
#
# Experiment P — SMAC tuning on P1.lp, then test on P1–P15.
#
# Phase 1: Tune P1.lp with SMAC.
#   - 300s/eval (same as MPILS)
#   - 24 workers × 8 threads = 192 CPUs (same total compute as MPILS 24 procs × 8 threads)
#   - walltime = MPILS P1 tuning time (hardcoded for fair comparison)
#
# Phase 2: Test P1_best.prm and default config on P1–P15 at 300s each.
#   Output: RESULTS_ROOT/P_smac_transfer_results.csv
#
# Usage:
#   sbatch submit-smac-P.sh
#
#SBATCH --job-name=smac-P
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=192
#SBATCH --time=11:00:00
#SBATCH --mem-per-cpu=2G
#SBATCH --output=smac-P_%j.out
#SBATCH --error=smac-P_%j.err

set -euo pipefail

INSTANCES_DIR="/home/yorig/Instances_MPILS"
TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"
PARAMS_FILE="${TESTS_DIR}/params_12_cpx.txt"
RESULTS_ROOT="/scratch/${USER}/smac-results-P-seconds-300"

N_WORKERS=24
CPLEX_THREADS=8
SOLVER_TIME=300
SOLVER_TIME_MODE=seconds
SEED=1

WALLTIME=25198   # MPILS P1 tuning time (seconds)

P1_PATH="${INSTANCES_DIR}/P1.lp"
[[ -f "$P1_PATH" ]] || { echo "ERROR: P1.lp not found: $P1_PATH" >&2; exit 1; }


OUTPUT_DIR="${RESULTS_ROOT}/P1/seed-${SEED}"
mkdir -p "$OUTPUT_DIR"

source "${VENV_DIR}/bin/activate"

export OMP_NUM_THREADS=$CPLEX_THREADS
export CPLEX_NUM_THREADS=$CPLEX_THREADS
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

# ── Phase 1: Tune P1.lp ──────────────────────────────────────────────────────
echo "=== Phase 1: SMAC tuning of P1.lp ==="
echo "SLURM_JOB_ID  : ${SLURM_JOB_ID:-NA}"
echo "Instance      : $P1_PATH"
echo "Output dir    : $OUTPUT_DIR"
echo "N workers     : $N_WORKERS  (× ${CPLEX_THREADS} threads = $((N_WORKERS * CPLEX_THREADS)) CPUs)"
echo "Solver time   : ${SOLVER_TIME}s (${SOLVER_TIME_MODE})"
echo "Wall budget   : ${WALLTIME}s  (MPILS P1 tuning time)"
echo "Seed          : $SEED"
echo "=============================================="

python "${TESTS_DIR}/smac_tune_cplex.py" \
    --instance         "$P1_PATH" \
    --params-file      "$PARAMS_FILE" \
    --solver-time      "$SOLVER_TIME" \
    --solver-time-mode "$SOLVER_TIME_MODE" \
    --threads          "$CPLEX_THREADS" \
    --walltime         "$WALLTIME" \
    --n-workers        "$N_WORKERS" \
    --output-dir       "$OUTPUT_DIR" \
    --seed             "$SEED" \
    || echo "Warning: smac_tune_cplex.py exited non-zero (likely dask cleanup crash); continuing."

BEST_CONFIG="${OUTPUT_DIR}/P1_best.prm"
if [[ ! -f "$BEST_CONFIG" ]]; then
    echo "ERROR: P1_best.prm not found — cannot proceed to test phase." >&2
    exit 1
fi
echo "SUCCESS: P1_best.prm written."

# ── Phase 2: Test on P1–P15 ──────────────────────────────────────────────────
echo
echo "=== Phase 2: Testing on P1–P15 ==="

EMPTY_PRM=$(mktemp /tmp/empty_XXXXXX.prm)
trap "rm -f '$EMPTY_PRM'" EXIT
: > "$EMPTY_PRM"

RESULTS_CSV="${RESULTS_ROOT}/P_smac_transfer_results.csv"
echo "instance,default_gap,smac_gap" > "$RESULTS_CSV"

for i in $(seq 1 15); do
    INSTANCE_PATH="${INSTANCES_DIR}/P${i}.lp"
    [[ -f "$INSTANCE_PATH" ]] || { echo "  WARNING: P${i}.lp not found, skipping." ; continue; }

    echo "--- P${i} ---"

    default_gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
        "$INSTANCE_PATH" "$EMPTY_PRM" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")

    smac_gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
        "$INSTANCE_PATH" "$BEST_CONFIG" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")

    echo "  default gap : ${default_gap}%"
    echo "  smac gap    : ${smac_gap}%"

    echo "P${i},${default_gap},${smac_gap}" >> "$RESULTS_CSV"
done

echo
echo "Done. Results: $RESULTS_CSV"
