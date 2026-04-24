#!/bin/bash
#SBATCH --job-name=mpils-batch
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --time=24:00:00
#SBATCH --mem=0
#SBATCH --output=job_%j.out
#SBATCH --error=job_%j.err
#SBATCH --distribution=block:block

set -euo pipefail

MPI_PROCS=1
CPLEX_THREADS=2
SOLVER_TIME=15
SOLVER_TIME_MODE="seconds"

INSTANCES_DIR="/path/to/instances"
TUNER_DIR="/path/to/tuner"
WORKING_ROOT="/scratch/${USER}/mpils-work"
RESULTS_ROOT="/scratch/${USER}/mpils-results"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"${SCRIPT_DIR}/run-instances.sh" \
  --instances-dir "$INSTANCES_DIR" \
  --tuner-dir "$TUNER_DIR" \
  --working-root "$WORKING_ROOT" \
  --results-root "$RESULTS_ROOT" \
  --mpi-procs "$MPI_PROCS" \
  --cplex-threads "$CPLEX_THREADS" \
  --solver-time "$SOLVER_TIME" \
  --solver-time-mode "$SOLVER_TIME_MODE"
