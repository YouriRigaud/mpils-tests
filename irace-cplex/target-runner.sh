#!/bin/bash
#
# irace target runner — evaluates one CPLEX configuration on one instance.
#
# Called by irace as:
#   ./target-runner.sh <config_id> <instance_id> <seed> <instance_path> <bound> \
#       --PARAM1 val1 --PARAM2 val2 ...
#
# Prints "cost time" to stdout (irace format). Any other output must go to stderr.
#
set -euo pipefail

TESTS_DIR="${TESTS_DIR:-/home/yorig/tuner/mpils-tests}"
VENV_DIR="${VENV_DIR:-/home/yorig/envs/smac-cplex}"
SOLVER_TIME="${SOLVER_TIME:-10000}"
SOLVER_TIME_MODE="${SOLVER_TIME_MODE:-ticks}"
CPLEX_THREADS="${CPLEX_THREADS:-8}"

CONFIG_ID="$1"
INSTANCE_ID="$2"
SEED="$3"
INSTANCE="$4"
BOUND="$5"
shift 5

# Write tunable params to a temp .prm file
TMPFILE=$(mktemp /tmp/irace_cfg_${CONFIG_ID}_XXXXXX.prm)
trap "rm -f '$TMPFILE'" EXIT

# Tunable params passed by irace as --NAME value pairs
while [[ $# -ge 2 ]]; do
    PNAME="${1#--}"
    PVAL="$2"
    echo "$PNAME $PVAL" >> "$TMPFILE"
    shift 2
done

# Activate the Python environment that has the cplex package
source "${VENV_DIR}/bin/activate"

# Run CPLEX and print "cost time" to stdout (irace format)
start_ms=$(date +%s%3N)
cost=$(python3 "${TESTS_DIR}/cplex_evaluate.py" \
    "$INSTANCE" "$TMPFILE" "$SOLVER_TIME" "$CPLEX_THREADS" "$SOLVER_TIME_MODE")
elapsed_ms=$(( $(date +%s%3N) - start_ms ))
elapsed=$(( elapsed_ms / 1000 ))
[[ $elapsed -lt 1 ]] && elapsed=1
echo "$cost $elapsed"
