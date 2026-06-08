#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./run-instances.sh \
    --instances-dir PATH \
    --tuner-dir PATH \
    --output-root PATH \
    --mpi-procs N \
    --cplex-threads N \
    --solver-time N \
    --solver-time-mode MODE \
    --seed N \
    [--mpi-procs-per-ils N] \
    [--local-search-engine ENGINE] \
    [--paramils-budgets-file PATH] \
    [--parameters-file PATH]

Required arguments:
  --instances-dir PATH       Directory scanned recursively for *.mps instances
  --tuner-dir PATH           Root directory of the tuner repository (passed as
                             --project-dir to the binary so it can locate
                             param_ils/, cplex/, etc. regardless of CWD)
  --output-root PATH         Root directory for per-instance tuner outputs
  --mpi-procs N              Number of MPI ranks/tasks for each tuner launch
  --cplex-threads N          Number of CPLEX threads per rank
  --solver-time N            Solver cutoff used by the tuner for each evaluation
  --solver-time-mode MODE    Solver time mode: seconds or ticks
  --seed N                   Base random seed passed to the tuner

Optional arguments:
  --mpi-procs-per-ils N      MPI ranks dedicated to each ILS instance (default: 1)
                             Must divide --mpi-procs evenly.
                             ILS instances = mpi-procs / mpi-procs-per-ils
  --local-search-engine NAME iterated_local_search (default) or paramils
  --paramils-budgets-file PATH
                             CSV file with per-instance wall-clock budgets
                             (required when --local-search-engine paramils).
                             Format: header line "instance,wall_time", then one
                             row per instance: stem (no .mps), seconds.
  --parameters-file PATH     Parameter definition file (default: TUNER_DIR/cplex/params_12_cpx.txt)

Notes:
  - This script runs the tuner only. It does not perform a post-tuning CPLEX test.
  - Submit it from an existing Slurm allocation or use submit-run-instances.sh.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

extract_last_value() {
  local pattern="$1"
  local file_path="$2"

  awk -F': ' -v pattern="$pattern" '$0 ~ pattern { value=$2 } END { if (value != "") print value }' "$file_path"
}

require_positive_integer() {
  local value="$1"
  local name="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be an integer >= 1"
}

instances_dir=""
tuner_dir=""
output_root=""
mpi_procs=""
mpi_procs_per_ils="1"
local_search_engine=""
paramils_budgets_file=""
cplex_threads=""
solver_time=""
solver_time_mode=""
seed=""
parameters_file=""
exploration_budget_factor=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instances-dir)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      instances_dir="$2"
      shift 2
      ;;
    --tuner-dir)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      tuner_dir="$2"
      shift 2
      ;;
    --output-root)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      output_root="$2"
      shift 2
      ;;
    --mpi-procs)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      mpi_procs="$2"
      shift 2
      ;;
    --cplex-threads)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      cplex_threads="$2"
      shift 2
      ;;
    --solver-time)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      solver_time="$2"
      shift 2
      ;;
    --solver-time-mode)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      solver_time_mode="$2"
      shift 2
      ;;
    --seed)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      seed="$2"
      shift 2
      ;;
    --mpi-procs-per-ils)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      mpi_procs_per_ils="$2"
      shift 2
      ;;
    --local-search-engine)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      local_search_engine="$2"
      shift 2
      ;;
    --paramils-budgets-file)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      paramils_budgets_file="$2"
      shift 2
      ;;
    --exploration-budget-factor)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      exploration_budget_factor="$2"
      shift 2
      ;;
    --parameters-file)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      parameters_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$instances_dir" ]] || fail "--instances-dir is required"
[[ -n "$tuner_dir" ]] || fail "--tuner-dir is required"
[[ -n "$output_root" ]] || fail "--output-root is required"
[[ -n "$mpi_procs" ]] || fail "--mpi-procs is required"
[[ -n "$cplex_threads" ]] || fail "--cplex-threads is required"
[[ -n "$solver_time" ]] || fail "--solver-time is required"
[[ -n "$solver_time_mode" ]] || fail "--solver-time-mode is required"
[[ -n "$seed" ]] || fail "--seed is required"

require_positive_integer "$mpi_procs" "--mpi-procs"
require_positive_integer "$mpi_procs_per_ils" "--mpi-procs-per-ils"
require_positive_integer "$cplex_threads" "--cplex-threads"
require_positive_integer "$solver_time" "--solver-time"
require_positive_integer "$seed" "--seed"
(( mpi_procs % mpi_procs_per_ils == 0 )) || \
  fail "--mpi-procs-per-ils=${mpi_procs_per_ils} does not divide --mpi-procs=${mpi_procs} evenly"

case "$solver_time_mode" in
  seconds|ticks)
    ;;
  *)
    fail "--solver-time-mode must be one of: seconds, ticks"
    ;;
esac

case "$local_search_engine" in
  ""|iterated_local_search|paramils) ;;
  *) fail "--local-search-engine must be one of: iterated_local_search, paramils" ;;
esac
if [[ "$local_search_engine" == "paramils" ]]; then
  [[ -n "$paramils_budgets_file" ]] || fail "--paramils-budgets-file is required when --local-search-engine paramils"
  paramils_budgets_file=$(realpath "$paramils_budgets_file")
  [[ -f "$paramils_budgets_file" ]] || fail "paramils budgets file not found: $paramils_budgets_file"
fi

instances_dir=$(realpath "$instances_dir")
tuner_dir=$(realpath "$tuner_dir")
output_root=$(realpath -m "$output_root")

[[ -d "$instances_dir" ]] || fail "instances directory not found: $instances_dir"
[[ -d "$tuner_dir" ]] || fail "tuner directory not found: $tuner_dir"

tuner_app="${tuner_dir}/build/mpils"
[[ -x "$tuner_app" ]] || fail "tuner executable not found or not executable: $tuner_app"
if [[ -n "$parameters_file" ]]; then
  parameters_file=$(realpath -m "$parameters_file")
else
  parameters_file="${tuner_dir}/cplex/params_12_cpx.txt"
fi
[[ -f "$parameters_file" ]] || fail "parameters file not found: $parameters_file"

command -v srun >/dev/null 2>&1 || fail "srun not found in PATH"

if [[ -n "${SLURM_NTASKS:-}" && "${SLURM_NTASKS}" -lt "$mpi_procs" ]]; then
  fail "--mpi-procs=${mpi_procs} but Slurm allocated only SLURM_NTASKS=${SLURM_NTASKS}"
fi

if [[ -n "${SLURM_CPUS_PER_TASK:-}" && "${SLURM_CPUS_PER_TASK}" -ne "$cplex_threads" ]]; then
  fail "--cplex-threads=${cplex_threads} but Slurm allocated SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK}"
fi

# Compute balanced socket placement.
# Node topology: 2 sockets × 12 chiplets × 8 cores = 192 cores/node.
# block:block fills socket 0 first, saturating it before using socket 1 —
# causing up to 3× memory-bandwidth asymmetry between workers (e.g. at 16 procs:
# 12 ranks on socket 0 vs 4 on socket 1, 1.0 vs 3.0 mem channels/rank).
# --ntasks-per-socket distributes evenly so all workers get equal bandwidth.
cores_per_node=192
sockets_per_node=2
chiplets_per_node=$((cores_per_node / cplex_threads))  # total chiplets available
ntasks_per_socket=$(( (mpi_procs + sockets_per_node - 1) / sockets_per_node ))
# Warn if mpi_procs is odd (can't split evenly)
if (( mpi_procs % sockets_per_node != 0 )); then
  echo "Warning: mpi_procs=${mpi_procs} is not divisible by ${sockets_per_node} sockets; socket load will be slightly uneven (${ntasks_per_socket} vs $((mpi_procs / sockets_per_node)) ranks per socket)." >&2
fi

mkdir -p "$output_root"

export OMP_NUM_THREADS="$cplex_threads"
export CPLEX_NUM_THREADS="$cplex_threads"
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

mapfile -d '' instances < <(find "$instances_dir" -type f -name '*.mps' -print0 | sort -z)
[[ "${#instances[@]}" -gt 0 ]] || fail "no .mps instances found under: $instances_dir"

run_stamp=$(date +%Y%m%d_%H%M%S)
summary_csv="${output_root}/summary_${run_stamp}.csv"
metrics_csv="${output_root}/tuning_metrics_${run_stamp}.csv"
echo "instance,seed,tuner_rc,best_configuration_present,output_dir,log_path" >"$summary_csv"
echo "instance,seed,objective,tuning_time" >"$metrics_csv"

echo "===== Launch info ====="
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-NA}"
echo "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST:-NA}"
echo "SLURM_NTASKS=${SLURM_NTASKS:-NA}"
echo "SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-NA}"
echo "instances_dir=$instances_dir"
echo "tuner_dir=$tuner_dir"
echo "parameters_file=$parameters_file"
echo "output_root=$output_root"
echo "mpi_procs=$mpi_procs"
echo "mpi_procs_per_ils=$mpi_procs_per_ils"
echo "ils_count=$((mpi_procs / mpi_procs_per_ils))"
echo "local_search_engine=${local_search_engine:-default}"
[[ -n "$paramils_budgets_file" ]] && echo "paramils_budgets_file=$paramils_budgets_file"
echo "ntasks_per_socket=$ntasks_per_socket"
echo "cplex_threads=$cplex_threads"
echo "solver_time=$solver_time"
echo "solver_time_mode=$solver_time_mode"
echo "seed=$seed"
echo "summary_csv=$summary_csv"
echo "metrics_csv=$metrics_csv"
echo "instance_count=${#instances[@]}"
echo "======================="

count=0
success=0
failure=0
failed_instances=()

for instance_path in "${instances[@]}"; do
  ((++count))
  instance_name=$(basename "$instance_path")
  instance_stem="${instance_name%.mps}"
  timestamp=$(date +%Y%m%d_%H%M%S)
  output_dir="${output_root}/${count}_${instance_stem}_seed-${seed}_${timestamp}"
  log_file="${output_dir}/run.log"
  tuner_log="${output_dir}/tuner.log"
  tuner_rc=0
  best_configuration_present=0
  objective="NA"
  tuning_time="NA"

  echo
  echo "------------------------------------------"
  echo "Instance #$count: $instance_name"
  echo "Date / Time       : $(date)"
  echo "Instance path     : $instance_path"
  echo "Output dir        : $output_dir"
  echo "------------------------------------------"

  [[ ! -e "$output_dir" ]] || fail "output directory already exists: $output_dir"
  mkdir -p "$output_dir"

  # Build tuner flag array depending on search engine
  tuner_args=(
    "$instance_path"
    --project-dir "$tuner_dir"
    --working-dir "$output_dir"
    --parameters-file "$parameters_file"
    --clean-working-dir
    --solver-threads "$cplex_threads"
    --solver-time "$solver_time"
    --solver-time-mode "$solver_time_mode"
    --seed "$seed"
  )
  if [[ "$local_search_engine" == "paramils" ]]; then
    # Look up per-instance wall-clock budget from the budgets CSV.
    # The file has a header and rows of the form: instance_stem,seconds
    instance_wall_time=$(awk -F',' -v stem="$instance_stem" \
      'NR>1 && $1==stem { print int($2); exit }' "$paramils_budgets_file")
    if [[ -z "$instance_wall_time" ]]; then
      echo "Skipping ${instance_name}: not found in budgets file ${paramils_budgets_file}" >&2
      echo "${instance_name},${seed},skipped,0,NA,NA" >>"$summary_csv"
      echo "${instance_name},${seed},NA,NA" >>"$metrics_csv"
      continue
    fi
    echo "ParamILS wall time for ${instance_name}: ${instance_wall_time}s"
    tuner_args+=(
      --local-search-engine paramils
      --exploration-only
      --initial-selected-parameters 71
      --no-random-worker-initial-configs
      --paramils-wall-time "$instance_wall_time"
    )
  else
    tuner_args+=(
      --no-shared-cache
      --disable-mip-starts
      --expansion-value-strategy all
      --mpi-procs-per-ils "$mpi_procs_per_ils"
      --no-solver-wall-watchdog
      --exploration-budget-factor "$exploration_budget_factor"
    )
    [[ -n "$local_search_engine" ]] && \
      tuner_args+=(--local-search-engine "$local_search_engine")
  fi

  set +e
  srun \
    --ntasks="$mpi_procs" \
    --cpus-per-task="$cplex_threads" \
    --ntasks-per-socket="$ntasks_per_socket" \
    --distribution=block:block:block \
    --hint=nomultithread \
    --cpu-bind=cores \
    --mem-bind=local \
    "$tuner_app" "${tuner_args[@]}" \
      </dev/null >"$log_file" 2>&1
  tuner_rc=$?
  set -e

  if [[ -f "$tuner_log" ]]; then
    objective=$(extract_last_value '^Objective:' "$tuner_log")
    tuning_time=$(extract_last_value '^Total tuning time:' "$tuner_log")

    [[ -n "$objective" ]] || objective="NA"
    if [[ -n "$tuning_time" ]]; then
      tuning_time="${tuning_time% seconds.}"
      tuning_time="${tuning_time% second.}"
    else
      tuning_time="NA"
    fi
  fi

  if [[ -f "${output_dir}/best_configuration.prm" ]]; then
    best_configuration_present=1
  fi

  if [[ "$tuner_rc" -eq 0 ]]; then
    ((++success))
  else
    ((++failure))
    failed_instances+=("${instance_name} (rc=${tuner_rc})")
  fi

  echo "${instance_name},${seed},${tuner_rc},${best_configuration_present},${output_dir},${log_file}" >>"$summary_csv"
  echo "${instance_name},${seed},${objective},${tuning_time}" >>"$metrics_csv"
done

echo
echo "=========================================="
echo "All runs completed."
echo "Total instances : $count"
echo "Successful runs : $success"
echo "Failed runs     : $failure"
echo "Summary CSV     : $summary_csv"
echo "Metrics CSV     : $metrics_csv"
if [[ "${#failed_instances[@]}" -gt 0 ]]; then
  echo "Failed instances:"
  for item in "${failed_instances[@]}"; do
    echo "  - $item"
  done
fi
echo "=========================================="
