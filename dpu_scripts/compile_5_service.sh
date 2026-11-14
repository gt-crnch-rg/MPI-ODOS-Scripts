#!/bin/sh
#
# Builds doca-omp-service (ref/ and mpi/) for the BlueField DPU (aarch64).
#
# usage: sh compile_5_service.sh <service dir> [doca path] <mpi install> [cmake]
#
#   doca path    default: $DOCA_PATH, else /opt/mellanox/doca (DOCA >= 3.3)
#   mpi install  the aarch64 Open MPI install (used by mpi/ only)
#   cmake        default: cmake from PATH
#
# Environment:
#   SERVICE_CC   C compiler. Default: clang if present, else cc. The cluster
#                build used armclang; any LLVM clang with libomp (Ubuntu:
#                clang + libomp-dev) is the closest match, because the service
#                dlopen()s ODOS-compiled offload code that calls into the
#                LLVM OpenMP runtime.
#
# The service sources are ported to DOCA Comch by patches/doca-omp-service
# (applied by setup.sh); the unpatched DOCA 2.0 sources do not build here.

ROOT=`pwd`
SERVICEDIR=$1
DOCAPATH=${2:-${DOCA_PATH:-/opt/mellanox/doca}}
MPIPATH=$3
CMAKE=${4:-cmake}

if [ -z "$SERVICE_CC" ]; then
    if command -v clang >/dev/null 2>&1; then SERVICE_CC=clang; else SERVICE_CC=cc; fi
fi

set -x
cd $SERVICEDIR

cd ref
rm -rf build && mkdir build && cd build
$CMAKE ../ -DCMAKE_C_COMPILER=$SERVICE_CC -DDOCA_PATH=$DOCAPATH && make -j`nproc`

cd ../../mpi
rm -rf build && mkdir build && cd build
$CMAKE ../ -DCMAKE_C_COMPILER=$SERVICE_CC -DDOCA_PATH=$DOCAPATH -DMPI_PATH=$MPIPATH && make -j`nproc`
set +x

cd $ROOT
