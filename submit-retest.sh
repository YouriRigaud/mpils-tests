#!/bin/bash
#
# Re-evaluate irace or SMAC best configurations with the fixed cplex_evaluate.py.
#
# Usage:
#   sbatch submit-retest.sh {irace|smac} {results_dir} {output.csv} [--all-seeds]
#
# Examples:
#   sbatch submit-retest.sh irace /scratch/yorig/irace-results-seconds-10-1pils  retest-irace-1pils.csv
#   sbatch submit-retest.sh irace /scratch/yorig/irace-results-seconds-10-4pils  retest-irace-4pils.csv
#   sbatch submit-retest.sh smac  /scratch/yorig/smac-results-seconds-10-memoire retest-smac.csv
#   sbatch submit-retest.sh irace /scratch/yorig/irace-results-seconds-10-1pils  retest-irace-allseeds.csv --all-seeds
#
#SBATCH --job-name=retest
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=4:00:00
#SBATCH --mem-per-cpu=8G
#SBATCH --output=retest_%j.out
#SBATCH --error=retest_%j.err

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"
INSTANCES_BASE="${TESTS_DIR}/instances/miplib"

SOLVER_TIME=10
CPLEX_THREADS=8
SOLVER_TIME_MODE=seconds

# ── Arguments ─────────────────────────────────────────────────────────────────
TUNER="${1:-}"
RESULTS_DIR="${2:-}"
OUTPUT="${3:-}"
ALL_SEEDS_FLAG=""
if [[ "${4:-}" == "--all-seeds" ]]; then
    ALL_SEEDS_FLAG="--all-seeds"
fi

if [[ "$TUNER" != "irace" && "$TUNER" != "smac" ]]; then
    echo "Usage: sbatch submit-retest.sh {irace|smac} {results_dir} {output.csv} [--all-seeds]" >&2
    exit 1
fi
if [[ -z "$RESULTS_DIR" ]]; then
    echo "Error: results_dir is required as the second argument." >&2
    exit 1
fi
if [[ -z "$OUTPUT" ]]; then
    echo "Error: output CSV path is required as the third argument." >&2
    exit 1
fi

# ── Environment ───────────────────────────────────────────────────────────────
source "${VENV_DIR}/bin/activate"

export OMP_NUM_THREADS=$CPLEX_THREADS
export CPLEX_NUM_THREADS=$CPLEX_THREADS
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

# ── Run ───────────────────────────────────────────────────────────────────────
echo "=== Retest: ${TUNER} ==="
echo "SLURM_JOB_ID  : ${SLURM_JOB_ID:-NA}"
echo "Results dir   : $RESULTS_DIR"
echo "Instances     : $INSTANCES_BASE"
echo "Output        : $OUTPUT"
echo "Solver time   : ${SOLVER_TIME}s (${SOLVER_TIME_MODE})"
echo "Threads       : $CPLEX_THREADS"
[[ -n "$ALL_SEEDS_FLAG" ]] && echo "Mode          : all-seeds" || echo "Mode          : median"
echo "======================================="

python3 "${TESTS_DIR}/retest_configs.py" \
    --tuner "$TUNER" \
    --results-dir "$RESULTS_DIR" \
    --instances-base "$INSTANCES_BASE" \
    --tests-dir "$TESTS_DIR" \
    --output "$OUTPUT" \
    --solver-time "$SOLVER_TIME" \
    --threads "$CPLEX_THREADS" \
    --mode "$SOLVER_TIME_MODE" \
    $ALL_SEEDS_FLAG

echo
echo "Done. Results written to: $OUTPUT"
