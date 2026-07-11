#!/bin/bash
#
# Submit irace CPLEX tuning runs — one irace process per instance per seed,
# running N_WORKERS parallel evaluations simultaneously.
#
# irace is run per instance (single-instance mode) so results are directly
# comparable to MPILS, ParamILS, and SMAC which also tune per instance.
#
# Resources (same pattern as submit-run-smac.sh):
#   N_WORKERS parallel CPLEX evaluations, each using CPLEX_THREADS threads.
#   --ntasks = N_WORKERS  (one slot per parallel evaluation)
#   --cpus-per-task = CPLEX_THREADS
#
#   N_WORKERS  CPLEX_THREADS  --ntasks  --cpus-per-task
#       1           8             1           8
#       2           8             2           8
#       4           8             4           8
#       8           8             8           8
#      16           8            16           8
#      24           8            24           8
#
# Budget file: CSV with columns instance,wall_time (stem without .mps).
#   Defaults to TESTS_DIR/paramils_budgets_${N_WORKERS}proc.csv.
#
# Submission examples:
#   sbatch --ntasks=1  --cpus-per-task=8 --export=ALL,N_WORKERS=1  submit-run-irace.sh
#   sbatch --ntasks=4  --cpus-per-task=8 --export=ALL,N_WORKERS=4  submit-run-irace.sh
#   sbatch --ntasks=24 --cpus-per-task=8 --export=ALL,N_WORKERS=24 submit-run-irace.sh
#
#SBATCH --job-name=irace-cplex
# 2 instance dirs * 10 seeds = 20 array tasks
#SBATCH --array=0-19
#SBATCH --ntasks=24                 # [CHANGE] = N_WORKERS
#SBATCH --cpus-per-task=8          # fixed: one chiplet per evaluation slot
#SBATCH --time=6:00:00
#SBATCH --mem-per-cpu=2G
#SBATCH --output=job_%A_%a.out
#SBATCH --error=job_%A_%a.err

set -euo pipefail

TESTS_DIR="${TESTS_DIR:-/home/yorig/tuner/mpils-tests}"
IRACE_DIR="${IRACE_DIR:-${TESTS_DIR}/irace-cplex}"
VENV_DIR="${VENV_DIR:-/home/yorig/envs/smac-cplex}"

INSTANCE_DIR_NAMES=(${INSTANCE_DIR_NAMES:-medium-1 medium-2})
SEEDS=(${SEEDS:-1 2 3 4 5 6 7 8 9 10})

N_WORKERS="${N_WORKERS:-24}"
CPLEX_THREADS="${CPLEX_THREADS:-8}"
SOLVER_TIME="${SOLVER_TIME:-10}"
SOLVER_TIME_MODE="${SOLVER_TIME_MODE:-seconds}"

BUDGETS_FILE="${BUDGETS_FILE:-${TESTS_DIR}/paramils_budgets_${N_WORKERS}proc.csv}"
[[ -f "$BUDGETS_FILE" ]] || { echo "Error: budgets file not found: $BUDGETS_FILE" >&2; exit 1; }

RESULTS_ROOT="${RESULTS_ROOT:-/scratch/${USER}/irace-results-${SOLVER_TIME_MODE}-${SOLVER_TIME}-Npils/${N_WORKERS}proc}"

task_id="${SLURM_ARRAY_TASK_ID:-0}"
num_seeds="${#SEEDS[@]}"
seed_index=$((task_id % num_seeds))
instance_dir_index=$((task_id / num_seeds))

BATCH_NAME="${INSTANCE_DIR_NAMES[$instance_dir_index]}"
SEED="${SEEDS[$seed_index]}"
INSTANCES_DIR="${TESTS_DIR}/instances/miplib/${BATCH_NAME}"

echo "===== irace launch info ====="
echo "Array task   : ${task_id}"
echo "Instance dir : $BATCH_NAME"
echo "Seed         : $SEED"
echo "N workers    : $N_WORKERS"
echo "CPLEX threads: $CPLEX_THREADS"
echo "Solver time  : $SOLVER_TIME ($SOLVER_TIME_MODE)"
echo "Budgets file : $BUDGETS_FILE"
echo "Results root : $RESULTS_ROOT"
echo "============================="

# Load R (adjust module name for your cluster)
module load r/4.4.0 2>/dev/null || module load r 2>/dev/null || true

# Safety timeout per evaluation: 3x the solver time in seconds
# (for ticks mode, 10000 ticks ~ a few seconds; use a safe upper bound)
RUNNER_TIMEOUT=30

mapfile -d '' instances < <(find "$INSTANCES_DIR" -type f -name '*.mps' -print0 | sort -z)

for instance_path in "${instances[@]}"; do
    instance_stem=$(basename "$instance_path" .mps)

    budget=$(awk -F',' -v stem="$instance_stem" \
        'NR>1 && $1==stem { print int($2); exit }' "$BUDGETS_FILE")

    if [[ -z "$budget" ]]; then
        echo "Skipping ${instance_stem}: not found in $BUDGETS_FILE" >&2
        continue
    fi

    output_dir="${RESULTS_ROOT}/${BATCH_NAME}/${instance_stem}/seed-${SEED}"
    mkdir -p "$output_dir"

    echo
    echo "------------------------------------------"
    echo "Instance : $instance_stem"
    echo "Budget   : ${budget}s wall-clock"
    echo "maxTime  : $((N_WORKERS * budget))s (N_WORKERS × budget)"
    echo "Output   : $output_dir"
    echo "------------------------------------------"

    # Generate per-run scenario file.
    # The instance path is repeated FIRST_TEST times so that irace has enough
    # rows for the first racing test (Friedman/t-test needs >= firstTest rows).
    # With deterministic=1 irace evaluates each (config, instance-row) pair
    # once and uses direct comparison, so identical rows do not waste budget.
    INSTANCES_TMP="${output_dir}/instances.txt"
    SCENARIO_TMP="${output_dir}/scenario.txt"
    FIRST_TEST=5
    : > "$INSTANCES_TMP"
    for ((i=0; i<FIRST_TEST; i++)); do
        echo "$instance_path" >> "$INSTANCES_TMP"
    done

    sed \
        -e "s|\[INSTANCES_FILE\]|${INSTANCES_TMP}|g" \
        -e "s|\[MAX_TIME\]|$((N_WORKERS * budget))|g" \
        -e "s|\[N_WORKERS\]|${N_WORKERS}|g" \
        -e "s|\[SEED\]|${SEED}|g" \
        -e "s|\[RUNNER_TIMEOUT\]|${RUNNER_TIMEOUT}|g" \
        "${IRACE_DIR}/scenario.txt" > "$SCENARIO_TMP"

    # Export variables read by target-runner.sh
    export TESTS_DIR VENV_DIR SOLVER_TIME SOLVER_TIME_MODE CPLEX_THREADS

    # Run irace from the output directory (irace writes logs there)
    cd "$output_dir"
    Rscript -e "
        library(irace)
        irace(scenario = readScenario(filename = '${SCENARIO_TMP}',
                                      scenario = defaultScenario()))
    " || echo "Warning: irace exited non-zero for ${instance_stem}; continuing."

    # Extract best configuration and evaluate it
    if [[ -f "${output_dir}/irace.Rdata" ]]; then
        Rscript -e "
            library(irace)
            load('${output_dir}/irace.Rdata')
            best <- getFinalElites(iraceResults, n = 1)
            cfg  <- as.data.frame(best[, !names(best) %in% c('.ID.', '.PARENT.')])
            write.csv(cfg, '${output_dir}/best_configuration.csv', row.names = FALSE)
            cat('Best configuration written.\n')
        " 2>/dev/null || true

        # Write best config as .prm for CPLEX
        if [[ -f "${output_dir}/best_configuration.csv" ]]; then
            python3 - <<PYEOF
import csv, os
out = '${output_dir}/best_configuration.prm'
with open('${output_dir}/best_configuration.csv') as f:
    row = next(csv.DictReader(f))
with open(out, 'w') as f:
    for k, v in row.items():
        f.write(f"{k} {v}\n")
print(f"Best config saved to {out}")
PYEOF
        fi
    fi

    cd - > /dev/null
done

echo
echo "Batch ${BATCH_NAME} seed-${SEED} complete."
