#!/bin/bash
#
# Experiment N — test phase.
# For each N instance, evaluate the default config and the MPILS-tuned config
# at the same time budget used during tuning, and compare gaps.
#
# Reads tuning results from: RESULTS_ROOT/N${i}/N${i}_seed-1/
# Writes:                     RESULTS_ROOT/N_test_results.csv
#
# Usage:
#   sbatch submit-N-test.sh
#
#SBATCH --job-name=test-N
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=2:00:00
#SBATCH --mem-per-cpu=8G
#SBATCH --output=test-N_%j.out
#SBATCH --error=test-N_%j.err

set -euo pipefail

INSTANCES_DIR="/home/yorig/Instances_MPILS"
TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"
RESULTS_ROOT="/scratch/${USER}/mpils-results-N-seconds-90"
SOLVER_TIME=90
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

RESULTS_CSV="${RESULTS_ROOT}/N_test_results.csv"
echo "instance,tuning_objective,tuning_time_s,best_config_found,default_gap,mpils_gap" > "$RESULTS_CSV"

for i in $(seq 1 15); do
    INSTANCE_STEM="N${i}"
    INSTANCE_PATH="${INSTANCES_DIR}/${INSTANCE_STEM}.lp"
    TUNING_DIR="${RESULTS_ROOT}/${INSTANCE_STEM}/${INSTANCE_STEM}_seed-${SEED}"
    BEST_CONFIG="${TUNING_DIR}/best_configuration.prm"
    TUNER_LOG="${TUNING_DIR}/tuner.log"

    echo "--- ${INSTANCE_STEM} ---"

    # Extract tuning metrics from tuner.log
    tuning_objective="NA"
    tuning_time="NA"
    if [[ -f "$TUNER_LOG" ]]; then
        obj=$(awk -F': ' '/^Objective:/ { value=$2 } END { print value }' "$TUNER_LOG")
        tt=$(awk -F': ' '/^Total tuning time:/ { value=$2 } END { print value }' "$TUNER_LOG")
        [[ -n "$obj" ]] && tuning_objective="$obj"
        if [[ -n "$tt" ]]; then
            tt="${tt% seconds.}"
            tt="${tt% second.}"
            tuning_time="$tt"
        fi
    fi

    best_config_found=0
    if [[ -f "$BEST_CONFIG" ]]; then
        best_config_found=1
    fi

    # Evaluate default config
    default_gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
        "$INSTANCE_PATH" "$EMPTY_PRM" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")

    # Evaluate MPILS config (fall back to default if no config found)
    if [[ "$best_config_found" -eq 1 ]]; then
        mpils_gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
            "$INSTANCE_PATH" "$BEST_CONFIG" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")
    else
        mpils_gap="NA"
        echo "  WARNING: no best_configuration.prm found in ${TUNING_DIR}"
    fi

    echo "  tuning objective : ${tuning_objective}"
    echo "  tuning time      : ${tuning_time}s"
    echo "  default gap      : ${default_gap}%"
    echo "  mpils gap        : ${mpils_gap}%"

    echo "${INSTANCE_STEM},${tuning_objective},${tuning_time},${best_config_found},${default_gap},${mpils_gap}" >> "$RESULTS_CSV"
done

echo
echo "Done. Results: $RESULTS_CSV"
