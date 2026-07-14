#!/bin/bash
#
# Evaluate the default CPLEX configuration on all miplib instances.
# Writes one row per instance to a CSV: instance,batch,default_gap
#
# Usage:
#   sbatch submit-test-default.sh
#
#SBATCH --job-name=test-default
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=0:30:00
#SBATCH --mem-per-cpu=8G
#SBATCH --output=test-default_%j.out
#SBATCH --error=test-default_%j.err

set -euo pipefail

TESTS_DIR="/home/yorig/tuner/mpils-tests"
INSTANCES_BASE="${TESTS_DIR}/instances/miplib"
VENV_DIR="/home/yorig/envs/smac-cplex"
OUTPUT="${TESTS_DIR}/default-gaps.csv"

SOLVER_TIME=10
CPLEX_THREADS=8
SOLVER_TIME_MODE=seconds

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

echo "instance,batch,default_gap" > "$OUTPUT"

for batch in medium-1 medium-2; do
    batch_dir="${INSTANCES_BASE}/${batch}"
    [[ -d "$batch_dir" ]] || continue

    for instance_path in $(find "$batch_dir" -maxdepth 1 -type f -name '*.mps' | sort); do
        instance=$(basename "$instance_path" .mps)
        gap=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
            "$instance_path" "$EMPTY_PRM" \
            "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")
        echo "${instance},${batch},${gap}" | tee -a "$OUTPUT"
    done
done

echo
echo "Done. Results: $OUTPUT"
