#!/bin/bash
#
# Run an ILS exploration budget study on a batch of instances.
#
# Runs a single ILS process (--exploration-only) with a fixed evaluation budget
# of k × n_params per instance. No expansion or pruning phases.
#
# Usage:
#   ./run-study-ils-budget.sh \
#     --instances-dir instances/miplib/medium-1 \
#     --tuner-dir /home/yorig/tuner/mpils \
#     --output-dir /scratch/yorig/study-ils-budget/k2_n5/medium-1/seed-1 \
#     --k 2 --n-params 5 \
#     --cplex-threads 8 --solver-time 10 --solver-time-mode seconds \
#     --seed 1
#
# Output: $output_dir/results.csv  (instance,k,n_params,seed,objective,tuning_time)

set -euo pipefail

fail() { echo "Error: $*" >&2; exit 1; }

require_positive_integer() {
  local value="$1" name="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be an integer >= 1"
}

extract_last_value() {
  local pattern="$1" file="$2"
  awk -F': ' -v p="$pattern" '$0 ~ p { v=$2 } END { if (v!="") print v }' "$file"
}

instances_dir=""
tuner_dir=""
output_dir=""
k=""
n_params=""
cplex_threads="8"
solver_time=""
solver_time_mode=""
seed=""
parameters_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instances-dir)   [[ $# -ge 2 ]] || fail "missing value for $1"; instances_dir="$2";   shift 2 ;;
    --tuner-dir)       [[ $# -ge 2 ]] || fail "missing value for $1"; tuner_dir="$2";       shift 2 ;;
    --output-dir)      [[ $# -ge 2 ]] || fail "missing value for $1"; output_dir="$2";      shift 2 ;;
    --k)               [[ $# -ge 2 ]] || fail "missing value for $1"; k="$2";               shift 2 ;;
    --n-params)        [[ $# -ge 2 ]] || fail "missing value for $1"; n_params="$2";        shift 2 ;;
    --cplex-threads)   [[ $# -ge 2 ]] || fail "missing value for $1"; cplex_threads="$2";   shift 2 ;;
    --solver-time)     [[ $# -ge 2 ]] || fail "missing value for $1"; solver_time="$2";     shift 2 ;;
    --solver-time-mode)[[ $# -ge 2 ]] || fail "missing value for $1"; solver_time_mode="$2";shift 2 ;;
    --seed)            [[ $# -ge 2 ]] || fail "missing value for $1"; seed="$2";            shift 2 ;;
    --parameters-file) [[ $# -ge 2 ]] || fail "missing value for $1"; parameters_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "$instances_dir"    ]] || fail "--instances-dir is required"
[[ -n "$tuner_dir"        ]] || fail "--tuner-dir is required"
[[ -n "$output_dir"       ]] || fail "--output-dir is required"
[[ -n "$k"                ]] || fail "--k is required"
[[ -n "$n_params"         ]] || fail "--n-params is required"
[[ -n "$solver_time"      ]] || fail "--solver-time is required"
[[ -n "$solver_time_mode" ]] || fail "--solver-time-mode is required"
[[ -n "$seed"             ]] || fail "--seed is required"

require_positive_integer "$k"             "--k"
require_positive_integer "$n_params"      "--n-params"
require_positive_integer "$cplex_threads" "--cplex-threads"
require_positive_integer "$solver_time"   "--solver-time"
require_positive_integer "$seed"          "--seed"

case "$solver_time_mode" in
  seconds|ticks) ;;
  *) fail "--solver-time-mode must be seconds or ticks" ;;
esac

instances_dir=$(realpath "$instances_dir")
tuner_dir=$(realpath "$tuner_dir")
output_dir=$(realpath -m "$output_dir")

[[ -d "$instances_dir" ]] || fail "instances directory not found: $instances_dir"
[[ -d "$tuner_dir"     ]] || fail "tuner directory not found: $tuner_dir"

tuner_app="${tuner_dir}/build/mpils"
[[ -x "$tuner_app" ]] || fail "tuner executable not found: $tuner_app"

if [[ -n "$parameters_file" ]]; then
  parameters_file=$(realpath "$parameters_file")
else
  parameters_file="${tuner_dir}/cplex/params_12_cpx.txt"
fi
[[ -f "$parameters_file" ]] || fail "parameters file not found: $parameters_file"

command -v srun >/dev/null 2>&1 || fail "srun not found in PATH"

n_evals=$(( k * n_params ))

mkdir -p "$output_dir"

export OMP_NUM_THREADS="$cplex_threads"
export CPLEX_NUM_THREADS="$cplex_threads"
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

mapfile -d '' instances < <(find "$instances_dir" -type f -name '*.mps' -print0 | sort -z)
[[ "${#instances[@]}" -gt 0 ]] || fail "no .mps instances found under: $instances_dir"

results_csv="${output_dir}/results.csv"
echo "instance,k,n_params,seed,objective,tuning_time" >"$results_csv"

echo "===== ILS budget study ====="
echo "instances_dir=$instances_dir"
echo "output_dir=$output_dir"
echo "k=$k  n_params=$n_params  n_evals=$n_evals"
echo "cplex_threads=$cplex_threads"
echo "solver_time=$solver_time ($solver_time_mode)"
echo "seed=$seed"
echo "instance_count=${#instances[@]}"
echo "============================"

for instance_path in "${instances[@]}"; do
  instance_name=$(basename "$instance_path")
  instance_stem="${instance_name%.mps}"
  instance_output_dir="${output_dir}/${instance_stem}"
  log_file="${instance_output_dir}/tuner.log"
  objective="NA"
  tuning_time="NA"

  echo
  echo "--- ${instance_stem} ---"

  [[ ! -e "$instance_output_dir" ]] || fail "output dir already exists: $instance_output_dir"
  mkdir -p "$instance_output_dir"

  tuner_args=(
    "$instance_path"
    --project-dir                 "$tuner_dir"
    --working-dir                 "$instance_output_dir"
    --parameters-file             "$parameters_file"
    --clean-working-dir
    --solver-threads              "$cplex_threads"
    --solver-time                 "$solver_time"
    --solver-time-mode            "$solver_time_mode"
    --seed                        "$seed"
    --exploration-only
    --initial-selected-parameters "$n_params"
    --number-of-evaluations       "$n_evals"
    --disable-mip-starts
    --no-solver-wall-watchdog
  )

  set +e
  srun \
    --ntasks=1 \
    --cpus-per-task="$cplex_threads" \
    "$tuner_app" "${tuner_args[@]}" \
      </dev/null >"$log_file" 2>&1
  tuner_rc=$?
  set -e

  if [[ "$tuner_rc" -ne 0 ]]; then
    echo "Warning: tuner exited with rc=${tuner_rc} for ${instance_stem}" >&2
  fi

  if [[ -f "$log_file" ]]; then
    objective=$(extract_last_value '^Objective:' "$log_file")
    tuning_time=$(extract_last_value '^Total tuning time:' "$log_file")
    [[ -n "$objective"    ]] || objective="NA"
    if [[ -n "$tuning_time" ]]; then
      tuning_time="${tuning_time% seconds.}"
      tuning_time="${tuning_time% second.}"
    else
      tuning_time="NA"
    fi
  fi

  echo "${instance_stem}: objective=${objective}  tuning_time=${tuning_time}"
  echo "${instance_stem},${k},${n_params},${seed},${objective},${tuning_time}" >>"$results_csv"
done

echo
echo "Done. Results: $results_csv"
