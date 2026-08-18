#!/bin/bash
#
# Experiment N — SMAC test phase.
# Evaluates default config and SMAC best config on each N instance at 60s.
# Mirrors submit-N-test.sh (MPILS) for direct comparison.
#
# Reads: RESULTS_ROOT/N${i}/seed-1/N${i}_best.prm
# Writes: RESULTS_ROOT/N_smac_test_results.csv
#
# Usage:
#   sbatch submit-smac-N-test.sh
#
#SBATCH --job-name=smac-test-N
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=1:00:00
#SBATCH --mem-per-cpu=8G
#SBATCH --output=smac-test-N_%j.out
#SBATCH --error=smac-test-N_%j.err

set -euo pipefail

INSTANCES_DIR="/home/yorig/Instances_MPILS"
TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"
RESULTS_ROOT="/scratch/${USER}/smac-results-N-seconds-60"
SOLVER_TIME=60
SOLVER_TIME_MODE=seconds
CPLEX_THREADS=8
SEED=1

source "${VENV_DIR}/bin/activate"

export OMP_NUM_THREADS=$CPLEX_THREADS
export CPLEX_NUM_THREADS=$CPLEX_THREADS
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

EMPTY_PRM=$(mktemp /tmp/empty_XXXXXX.prm)
trap "rm -f '$EMPTY_PRM'" EXIT
: > "$EMPTY_PRM"

RESULTS_CSV="${RESULTS_ROOT}/N_smac_test_results.csv"
echo "instance,best_config_found,default_gap,smac_gap" > "$RESULTS_CSV"

for i in $(seq 1 15); do
    INSTANCE_STEM="N${i}"
    INSTANCE_PATH="${INSTANCES_DIR}/${INSTANCE_STEM}.lp"
    BEST_CONFIG="${RESULTS_ROOT}/${INSTANCE_STEM}/seed-${SEED}/${INSTANCE_STEM}_best.prm"

    echo "--- ${INSTANCE_STEM} ---"

    best_config_found=0
    [[ -f "$BEST_CONFIG" ]] && best_config_found=1

    default_gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
        "$INSTANCE_PATH" "$EMPTY_PRM" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")

    if [[ "$best_config_found" -eq 1 ]]; then
        smac_gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
            "$INSTANCE_PATH" "$BEST_CONFIG" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")
    else
        smac_gap="NA"
        echo "  WARNING: no best prm found in ${RESULTS_ROOT}/${INSTANCE_STEM}/seed-${SEED}/"
    fi

    echo "  default gap : ${default_gap}%"
    echo "  smac gap    : ${smac_gap}%"

    echo "${INSTANCE_STEM},${best_config_found},${default_gap},${smac_gap}" >> "$RESULTS_CSV"
done

echo
echo "Done. Results: $RESULTS_CSV"
