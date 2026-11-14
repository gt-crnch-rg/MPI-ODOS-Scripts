#!/bin/sh
#
# DPU (aarch64 / BlueField) build -- run from the repo root after setup.sh,
# on the DPU itself or in an arm64 container (see dpu_scripts/Dockerfile).
# Shared scripts (compile_1_ucx.sh, compile_3_ompi.sh) are in the repo root;
# DPU-specific ones are in dpu_scripts/ (this file's directory).
#
# Builds:
#   build/ucx/aarch64/install        UCX
#   build/ompi/aarch64/install       Open MPI + ODOS pml/osc plugins (DOCA Comch)
#   build/service/{ref,mpi}/build    doca-omp-service
#
# Environment:
#   DOCA_PATH   DOCA SDK (default /opt/mellanox/doca); DOCA >= 3.3 required
#   CMAKE       cmake binary (default: cmake from PATH)
#   SERVICE_CC  compiler for doca-omp-service (see compile_5_service.sh)
#
# Check the result with: sh dpu_scripts/verify_build.sh ./build

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
DOCA_PATH=${DOCA_PATH:-/opt/mellanox/doca}
CMAKE=${CMAKE:-cmake}

if [ "`uname -m`" != aarch64 ]; then
    echo "compile_dpu.sh: this is an aarch64 (DPU) build, but this machine is `uname -m`." >&2
    exit 1
fi

# DOCA >= 3.3: the patched sources use Comch, which replaced Comm Channel.
if [ ! -f "$DOCA_PATH/VERSION" ]; then
    echo "compile_dpu.sh: no DOCA SDK at $DOCA_PATH (set DOCA_PATH)." >&2
    exit 1
fi
DOCA_VERSION=`cat "$DOCA_PATH/VERSION"`
major=`echo "$DOCA_VERSION" | cut -d. -f1`
minor=`echo "$DOCA_VERSION" | cut -d. -f2`
if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 3 ]; }; then
    echo "compile_dpu.sh: DOCA $DOCA_VERSION at $DOCA_PATH; DOCA >= 3.3 is required." >&2
    exit 1
fi
echo "compile_dpu.sh: building against DOCA $DOCA_VERSION at $DOCA_PATH"

rm -rf ./build/ucx/aarch64/build

set -x
sh compile_1_ucx.sh  ./build/ucx/aarch64
sh compile_3_ompi.sh ./build/ompi/aarch64 `pwd`/build/ucx/aarch64/install "$DOCA_PATH" "$CMAKE"
sh "$SCRIPT_DIR/compile_5_service.sh" ./build/service "$DOCA_PATH" `pwd`/build/ompi/aarch64/install "$CMAKE"
set +x
