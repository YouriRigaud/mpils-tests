#!/bin/bash
#SBATCH --job-name=mpils-batch
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=8
#SBATCH --time=24:00:00
#SBATCH --mem=0
#SBATCH --output=job_%j.out
#SBATCH --error=job_%j.err
#SBATCH --distribution=block:block

set -euo pipefail

MPI_PROCS=4
CPLEX_THREADS=8
SOLVER_TIME=50000
SOLVER_TIME_MODE="ticks"

INSTANCES_DIR="/home/yorig/tuner/mpils-tests/instances/miplib/medium"
TUNER_DIR="/home/yorig/tuner/mpils"
OUTPUT_ROOT="/scratch/${USER}/mpils-results-med-50k-4proc-shared"


"/home/yorig/tuner/mpils-tests/run-instances.sh" \
  --instances-dir "$INSTANCES_DIR" \
  --tuner-dir "$TUNER_DIR" \
  --output-root "$OUTPUT_ROOT" \
  --mpi-procs "$MPI_PROCS" \
  --cplex-threads "$CPLEX_THREADS" \
  --solver-time "$SOLVER_TIME" \
  --solver-time-mode "$SOLVER_TIME_MODE"
