#!/bin/bash
#
# Experiment N — per-instance SMAC tuning on hard N instances.
#
# Mirrors submit-N-tuning.sh (MPILS) for a fair comparison:
#   - 60s/eval (same as MPILS)
#   - 24 SMAC workers × 8 threads = 192 CPUs (same total compute as MPILS 24 procs × 8 threads)
#   - walltime = MPILS tuning time per instance (hardcoded from test-N results)
#   - 1 seed per instance
#
# After completion, test the best config with submit-smac-N-test.sh.
#
# Usage:
#   sbatch submit-smac-N.sh
#
#SBATCH --job-name=smac-N
#SBATCH --array=1-15
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=192
#SBATCH --time=3:30:00
#SBATCH --mem-per-cpu=2G
#SBATCH --output=smac-N_%A_%a.out
#SBATCH --error=smac-N_%A_%a.err

set -euo pipefail

INSTANCES_DIR="/home/yorig/Instances_MPILS"
TESTS_DIR="/home/yorig/tuner/mpils-tests"
VENV_DIR="/home/yorig/envs/smac-cplex"
PARAMS_FILE="${TESTS_DIR}/params_12_cpx.txt"
RESULTS_ROOT="/scratch/${USER}/smac-results-N-seconds-60"

N_WORKERS=24
CPLEX_THREADS=8
SOLVER_TIME=60
SOLVER_TIME_MODE=seconds
SEED=1

# MPILS tuning times (seconds) per instance — used as SMAC wall budget for fair comparison
declare -A MPILS_WALLTIME
MPILS_WALLTIME[1]=4969
MPILS_WALLTIME[2]=4019
MPILS_WALLTIME[3]=5993
MPILS_WALLTIME[4]=124
MPILS_WALLTIME[5]=66
MPILS_WALLTIME[6]=375
MPILS_WALLTIME[7]=5085
MPILS_WALLTIME[8]=4860
MPILS_WALLTIME[9]=1059
MPILS_WALLTIME[10]=248
MPILS_WALLTIME[11]=186
MPILS_WALLTIME[12]=6725
MPILS_WALLTIME[13]=123
MPILS_WALLTIME[14]=62
MPILS_WALLTIME[15]=1869

i=${SLURM_ARRAY_TASK_ID}
INSTANCE_PATH="${INSTANCES_DIR}/N${i}.lp"
INSTANCE_STEM="N${i}"

[[ -f "$INSTANCE_PATH" ]] || { echo "ERROR: instance not found: $INSTANCE_PATH" >&2; exit 1; }

WALLTIME="${MPILS_WALLTIME[$i]}"

OUTPUT_DIR="${RESULTS_ROOT}/${INSTANCE_STEM}/seed-${SEED}"
mkdir -p "$OUTPUT_DIR"

source "${VENV_DIR}/bin/activate"

export OMP_NUM_THREADS=$CPLEX_THREADS
export CPLEX_NUM_THREADS=$CPLEX_THREADS
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

echo "=== SMAC Experiment N — Instance ${INSTANCE_STEM} ==="
echo "SLURM_JOB_ID         : ${SLURM_JOB_ID:-NA}"
echo "SLURM_ARRAY_TASK_ID  : ${SLURM_ARRAY_TASK_ID}"
echo "SLURM_JOB_NODELIST   : ${SLURM_JOB_NODELIST:-NA}"
echo "Instance             : $INSTANCE_PATH"
echo "Output dir           : $OUTPUT_DIR"
echo "N workers            : $N_WORKERS  (× ${CPLEX_THREADS} threads = $((N_WORKERS * CPLEX_THREADS)) CPUs)"
echo "CPLEX threads        : $CPLEX_THREADS"
echo "Solver time          : ${SOLVER_TIME}s (${SOLVER_TIME_MODE})"
echo "Wall budget          : ${WALLTIME}s  (MPILS tuning time for ${INSTANCE_STEM})"
echo "Seed                 : $SEED"
echo "=============================================="

python "${TESTS_DIR}/smac_tune_cplex.py" \
    --instance         "$INSTANCE_PATH" \
    --params-file      "$PARAMS_FILE" \
    --solver-time      "$SOLVER_TIME" \
    --solver-time-mode "$SOLVER_TIME_MODE" \
    --threads          "$CPLEX_THREADS" \
    --walltime         "$WALLTIME" \
    --n-workers        "$N_WORKERS" \
    --output-dir       "$OUTPUT_DIR" \
    --seed             "$SEED" \
    || echo "Warning: smac_tune_cplex.py exited non-zero (likely dask cleanup crash); continuing."

echo
if [[ -f "${OUTPUT_DIR}/${INSTANCE_STEM}_best.prm" ]]; then
    echo "SUCCESS: ${INSTANCE_STEM}_best.prm written."
else
    echo "WARNING: best prm not found in ${OUTPUT_DIR}."
fi
echo "Output: $OUTPUT_DIR"
