#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./run-instances.sh \
    --instances-dir PATH \
    --tuner-dir PATH \
    --working-root PATH \
    --results-root PATH \
    --mpi-procs N \
    --cplex-threads N \
    --solver-time N \
    --solver-time-mode MODE

Required arguments:
  --instances-dir PATH     Directory scanned recursively for *.mps instances
  --tuner-dir PATH         Root directory of the tuner repository
  --working-root PATH      Root directory for temporary per-instance working dirs
  --results-root PATH      Root directory for archived per-instance results
  --mpi-procs N            Number of MPI ranks/tasks for each tuner launch
  --cplex-threads N        Number of CPLEX threads per rank
  --solver-time N          Solver cutoff used by the tuner for each evaluation
  --solver-time-mode MODE  Solver time mode: seconds or ticks

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
working_root=""
results_root=""
mpi_procs=""
cplex_threads=""
solver_time=""
solver_time_mode=""

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
    --working-root)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      working_root="$2"
      shift 2
      ;;
    --results-root)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      results_root="$2"
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
[[ -n "$working_root" ]] || fail "--working-root is required"
[[ -n "$results_root" ]] || fail "--results-root is required"
[[ -n "$mpi_procs" ]] || fail "--mpi-procs is required"
[[ -n "$cplex_threads" ]] || fail "--cplex-threads is required"
[[ -n "$solver_time" ]] || fail "--solver-time is required"
[[ -n "$solver_time_mode" ]] || fail "--solver-time-mode is required"

require_positive_integer "$mpi_procs" "--mpi-procs"
require_positive_integer "$cplex_threads" "--cplex-threads"
require_positive_integer "$solver_time" "--solver-time"

case "$solver_time_mode" in
  seconds|ticks)
    ;;
  *)
    fail "--solver-time-mode must be one of: seconds, ticks"
    ;;
esac

instances_dir=$(realpath "$instances_dir")
tuner_dir=$(realpath "$tuner_dir")
working_root=$(realpath -m "$working_root")
results_root=$(realpath -m "$results_root")

[[ -d "$instances_dir" ]] || fail "instances directory not found: $instances_dir"
[[ -d "$tuner_dir" ]] || fail "tuner directory not found: $tuner_dir"

tuner_app="${tuner_dir}/build/mpils"
[[ -x "$tuner_app" ]] || fail "tuner executable not found or not executable: $tuner_app"

command -v srun >/dev/null 2>&1 || fail "srun not found in PATH"

if [[ -n "${SLURM_NTASKS:-}" && "${SLURM_NTASKS}" -ne "$mpi_procs" ]]; then
  fail "--mpi-procs=${mpi_procs} but Slurm allocated SLURM_NTASKS=${SLURM_NTASKS}"
fi

if [[ -n "${SLURM_CPUS_PER_TASK:-}" && "${SLURM_CPUS_PER_TASK}" -ne "$cplex_threads" ]]; then
  fail "--cplex-threads=${cplex_threads} but Slurm allocated SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK}"
fi

mkdir -p "$working_root" "$results_root"

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
summary_csv="${results_root}/summary_${run_stamp}.csv"
metrics_csv="${results_root}/tuning_metrics_${run_stamp}.csv"
echo "instance,tuner_rc,best_configuration_present,save_dir,log_path" >"$summary_csv"
echo "instance,objective,tuning_time" >"$metrics_csv"

echo "===== Launch info ====="
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-NA}"
echo "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST:-NA}"
echo "SLURM_NTASKS=${SLURM_NTASKS:-NA}"
echo "SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-NA}"
echo "instances_dir=$instances_dir"
echo "tuner_dir=$tuner_dir"
echo "working_root=$working_root"
echo "results_root=$results_root"
echo "mpi_procs=$mpi_procs"
echo "cplex_threads=$cplex_threads"
echo "solver_time=$solver_time"
echo "solver_time_mode=$solver_time_mode"
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
  work_dir="${working_root}/${instance_stem}_${timestamp}"
  save_dir="${results_root}/${instance_stem}_${timestamp}"
  log_file="${save_dir}/run.log"
  tuner_log="${work_dir}/tuner.log"
  tuner_rc=0
  best_configuration_present=0
  objective="NA"
  tuning_time="NA"

  echo
  echo "------------------------------------------"
  echo "Instance #$count: $instance_name"
  echo "Date / Time       : $(date)"
  echo "Instance path     : $instance_path"
  echo "Work dir          : $work_dir"
  echo "Save dir          : $save_dir"
  echo "------------------------------------------"

  rm -rf "$work_dir"
  mkdir -p "$work_dir" "$save_dir"

  set +e
  srun \
    --ntasks="$mpi_procs" \
    --cpus-per-task="$cplex_threads" \
    --distribution=block:block \
    --cpu-bind=cores \
    --mem-bind=local \
    "$tuner_app" \
      "$instance_path" \
      --working-dir "$work_dir" \
      --parameters-file /home/yorig/tuner/mpils/cplex/params_12_cpx.txt \
      --no-clean-working-dir \
      --shared-cache \
      --expansion-value-strategy all \
      --solver-threads "$cplex_threads" \
      --solver-time "$solver_time" \
      --solver-time-mode "$solver_time_mode" \
      </dev/null >"$log_file" 2>&1
  tuner_rc=$?
  set -e

  if [[ -d "$work_dir" ]]; then
    cp -r "$work_dir"/. "$save_dir"/
  fi

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

  if [[ -f "${save_dir}/best_configuration.prm" || -f "${work_dir}/best_configuration.prm" ]]; then
    best_configuration_present=1
  fi

  if [[ "$tuner_rc" -eq 0 ]]; then
    ((++success))
  else
    ((++failure))
    failed_instances+=("${instance_name} (rc=${tuner_rc})")
  fi

  echo "${instance_name},${tuner_rc},${best_configuration_present},${save_dir},${log_file}" >>"$summary_csv"
  echo "${instance_name},${objective},${tuning_time}" >>"$metrics_csv"
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
